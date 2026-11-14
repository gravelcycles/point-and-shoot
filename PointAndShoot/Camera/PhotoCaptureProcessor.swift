import AVFoundation
import ImageIO
import UIKit

/// What a single shutter press is expected to produce and how to store it.
struct PhotoPlan {
    var expectsRAW = false
    var expectsProcessed = false
    /// Develop the Bayer RAW ourselves (Zero processing).
    var zeroDevelop = false
    var zeroAsHEIF = true
    /// Keep the DNG in the library (paired with the processed image when there is one).
    var storeRAW = true
    var fallbackNote: String?
    var location: TaggedLocation?
    /// Capture look to bake on as a non-destructive edit once saved.
    var look: EditRecipe?
    /// The viewfinder's scene key at the shutter (FilmLUT.sceneKey), for matching a film
    /// look's RAW develop to what was on screen.
    var viewfinderKey: Double?
}

/// Writes GPS (and compass heading) into the photo file's own EXIF.
private final class GPSCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let location: TaggedLocation
    init(_ location: TaggedLocation) { self.location = location }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = location.exifGPS
        return metadata
    }
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let plan: PhotoPlan
    private let willCapture: () -> Void
    private let thumbnail: (UIImage) -> Void
    private let completion: (_ message: String?, _ assetID: String?) -> Void

    private var rawData: Data?
    private var processedData: Data?
    private var sentThumbnail = false
    private var captureError: Error?
    private var flashFired = false

    init(plan: PhotoPlan,
         willCapture: @escaping () -> Void,
         thumbnail: @escaping (UIImage) -> Void,
         completion: @escaping (_ message: String?, _ assetID: String?) -> Void) {
        self.plan = plan
        self.willCapture = willCapture
        self.thumbnail = thumbnail
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.willCapture() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            captureError = error
            return
        }
        if photo.resolvedSettings.isFlashEnabled { flashFired = true }
        let data = plan.location.map { photo.fileDataRepresentation(with: GPSCustomizer($0)) }
            ?? photo.fileDataRepresentation()
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
        }
        if !sentThumbnail, let cg = photo.previewCGImageRepresentation() {
            sentThumbnail = true
            let raw = (photo.metadata[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
            let orientation = UIImage.Orientation(CGImagePropertyOrientation(rawValue: raw) ?? .up)
            let image = UIImage(cgImage: cg, scale: 1, orientation: orientation)
            DispatchQueue.main.async { self.thumbnail(image) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? captureError {
            completion("Capture failed: \(error.localizedDescription)", nil)
            return
        }
        let plan = self.plan
        let raw = rawData
        let processed = processedData
        // A flash shot looks nothing like the pre-flash viewfinder: match it to the
        // processed photo instead.
        let viewfinderKey = flashFired ? nil : plan.viewfinderKey
        Task.detached(priority: .userInitiated) {
            do {
                var primary = processed
                var alternate: Data? = plan.storeRAW ? raw : nil

                if plan.zeroDevelop, let raw {
                    primary = ZeroDeveloper.develop(dng: raw, asHEIF: plan.zeroAsHEIF)
                    if primary == nil { alternate = nil; primary = raw }
                }

                var assetID: String?
                var note = plan.fallbackNote
                let where_ = plan.location?.location
                if let primary {
                    let companion = primary == raw ? nil : alternate
                    do {
                        assetID = try await PhotoLibrary.savePhoto(primary: primary, rawCompanion: companion, location: where_)
                    } catch where companion != nil {
                        // Never lose the shot because Photos refused the RAW pairing: keep the
                        // photo, and the DNG as its own asset so nothing is thrown away.
                        assetID = try await PhotoLibrary.savePhoto(primary: primary, rawCompanion: nil, location: where_)
                        if let companion { _ = try? await PhotoLibrary.savePhoto(primary: companion, rawCompanion: nil, location: where_) }
                        note = "RAW saved as a separate photo (Photos error \((error as NSError).code))"
                    }
                } else if let raw {
                    assetID = try await PhotoLibrary.savePhoto(primary: raw, rawCompanion: nil, location: where_)
                } else {
                    self.completion("Nothing was captured", nil)
                    return
                }
                // Bake the filter/Print look *before* reporting the shot done: the viewer
                // keeps "Developing…" up until then, instead of showing the plain photo and
                // swapping in the filtered one a moment later.
                if let look = plan.look, let assetID {
                    try? await RecipeBaker.apply(look, toAssetWithID: assetID, rawData: raw, viewfinderKey: viewfinderKey)
                }
                self.completion(note, assetID)
            } catch {
                self.completion("Couldn't save: \(error.localizedDescription)", nil)
            }
        }
    }
}

extension UIImage.Orientation {
    init(_ cg: CGImagePropertyOrientation) {
        switch cg {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
