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
        Task.detached(priority: .userInitiated) {
            do {
                var primary = processed
                var alternate: Data? = plan.storeRAW ? raw : nil

                if plan.zeroDevelop, let raw {
                    primary = ZeroDeveloper.develop(dng: raw, asHEIF: plan.zeroAsHEIF)
                    if primary == nil { alternate = nil; primary = raw }
                }

                let assetID: String?
                let where_ = plan.location?.location
                if let primary {
                    assetID = try await PhotoLibrary.savePhoto(primary: primary, rawCompanion: primary == raw ? nil : alternate,
                                                               location: where_)
                } else if let raw {
                    assetID = try await PhotoLibrary.savePhoto(primary: raw, rawCompanion: nil, location: where_)
                } else {
                    self.completion("Nothing was captured", nil)
                    return
                }
                self.completion(plan.fallbackNote, assetID)
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
