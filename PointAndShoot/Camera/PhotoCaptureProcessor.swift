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
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let plan: PhotoPlan
    private let willCapture: () -> Void
    private let thumbnail: (UIImage) -> Void
    private let completion: (String?) -> Void

    private var rawData: Data?
    private var processedData: Data?
    private var sentThumbnail = false
    private var captureError: Error?

    init(plan: PhotoPlan,
         willCapture: @escaping () -> Void,
         thumbnail: @escaping (UIImage) -> Void,
         completion: @escaping (String?) -> Void) {
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
        if photo.isRawPhoto {
            rawData = photo.fileDataRepresentation()
        } else {
            processedData = photo.fileDataRepresentation()
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
            completion("Capture failed: \(error.localizedDescription)")
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

                if let primary {
                    try await PhotoLibrary.savePhoto(primary: primary, rawCompanion: primary == raw ? nil : alternate)
                } else if let raw {
                    try await PhotoLibrary.savePhoto(primary: raw, rawCompanion: nil)
                } else {
                    self.completion("Nothing was captured")
                    return
                }
                self.completion(plan.fallbackNote)
            } catch {
                self.completion("Couldn't save: \(error.localizedDescription)")
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
