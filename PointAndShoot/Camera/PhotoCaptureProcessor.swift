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
    /// The saved asset is (true) / is no longer (false) waiting for its look to be baked.
    private let developing: (_ assetID: String, _ isDeveloping: Bool) -> Void

    private var rawData: Data?
    private var processedData: Data?
    private var sentThumbnail = false
    private var captureError: Error?
    private var flashFired = false

    init(plan: PhotoPlan,
         willCapture: @escaping () -> Void,
         thumbnail: @escaping (UIImage) -> Void,
         developing: @escaping (_ assetID: String, _ isDeveloping: Bool) -> Void = { _, _ in },
         completion: @escaping (_ message: String?, _ assetID: String?) -> Void) {
        self.developing = developing
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
            Diag.error(.capture, "capture failed", error)
            completion("Capture failed: \(error.localizedDescription)", nil)
            return
        }
        Diag.log(.capture, "captured: raw \(rawData.map { "\($0.count / 1024) KB" } ?? "none"), processed \(processedData.map { "\($0.count / 1024) KB" } ?? "none")")
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
                    let start = Date()
                    primary = ZeroDeveloper.develop(dng: raw, asHEIF: plan.zeroAsHEIF)
                    if primary == nil {
                        Diag.error(.save, "Zero develop failed; saving the DNG alone")
                        alternate = nil; primary = raw
                    } else {
                        Diag.log(.save, "Zero develop \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                    }
                }

                var assetID: String?
                var note = plan.fallbackNote
                let where_ = plan.location?.location
                if let primary {
                    let companion = primary == raw ? nil : alternate
                    do {
                        assetID = try await PhotoLibrary.savePhoto(primary: primary, rawCompanion: companion, location: where_)
                    } catch where companion != nil {
                        Diag.error(.save, "Photos refused the RAW pair; saving them separately", error)
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
                // Report the shot saved right away (the camera can suspend, the next shot
                // isn't held up), but mark it as still developing so the viewer shows
                // "Developing…" on its page until the look is baked, never the plain photo.
                // Bakes run one at a time: a full-resolution RAW develop each, and several
                // at once on a busy GPU is what made shots hang on "Developing…".
                guard let look = plan.look, let assetID else {
                    self.completion(note, assetID)
                    return
                }
                self.developing(assetID, true)
                self.completion(note, assetID)
                await BakeQueue.shared.run {
                    let start = Date()
                    let name = look.look ?? "look"
                    Diag.log(.bake, "baking \(name) onto \(assetID.prefix(8))\(raw == nil ? "" : " from RAW")")
                    do {
                        try await RecipeBaker.apply(look, toAssetWithID: assetID, rawData: raw, viewfinderKey: viewfinderKey)
                        Diag.log(.bake, "baked \(name) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                    } catch {
                        Diag.error(.bake, "bake of \(name) failed after \(Int(Date().timeIntervalSince(start) * 1000)) ms", error)
                    }
                }
                self.developing(assetID, false)
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

/// Runs look bakes strictly one after another, in capture order.
actor BakeQueue {
    static let shared = BakeQueue()
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
