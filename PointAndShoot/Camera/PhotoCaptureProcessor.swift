import AVFoundation
import ImageIO
import UIKit

/// What a single shutter press is expected to produce and how to store it.
struct PhotoPlan {
    /// The RAW requested (nil: a processed photo only, where the lens has no RAW).
    var rawKind: Shot.Kind? = .bayerRAW
    /// Format of a processed-only fallback.
    var heif = true
    var fallbackNote: String?
    var location: TaggedLocation?
    /// The grade the new shot starts with (the active look).
    var look: EditRecipe?
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

/// Collects one shot's files and stores them in the app's library (`ShotStore`). Nothing
/// goes to the iOS photo library here: that happens on export.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let plan: PhotoPlan
    private let willCapture: () -> Void
    private let thumbnail: (UIImage) -> Void
    private let completion: (_ message: String?, _ shotID: UUID?) -> Void

    private var rawData: Data?
    private var processedData: Data?
    private var previewJPEG: Data?
    private var sentThumbnail = false
    private var captureError: Error?

    init(plan: PhotoPlan,
         willCapture: @escaping () -> Void,
         thumbnail: @escaping (UIImage) -> Void,
         completion: @escaping (_ message: String?, _ shotID: UUID?) -> Void) {
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
            let cgOrientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            previewJPEG = ShotRenderer.jpegData(of: cg, orientation: cgOrientation)
            let image = UIImage(cgImage: cg, scale: 1, orientation: UIImage.Orientation(cgOrientation))
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
        let original: Data
        let ext: String
        let kind: Shot.Kind
        if let rawData {
            original = rawData; ext = "dng"; kind = plan.rawKind ?? .bayerRAW
        } else if let processedData {
            original = processedData; ext = plan.heif ? "heic" : "jpg"; kind = .processed
        } else {
            completion("Nothing was captured", nil)
            return
        }
        let preview = previewJPEG
        let look = plan.look ?? EditRecipe()
        let note = plan.fallbackNote
        Task { @MainActor in
            do {
                let shot = try await ShotStore.shared.add(original: original, fileExtension: ext, kind: kind,
                                                          capturePreview: preview, recipe: look)
                self.completion(note, shot.id)
            } catch {
                Diag.error(.save, "couldn't store the shot", error)
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
