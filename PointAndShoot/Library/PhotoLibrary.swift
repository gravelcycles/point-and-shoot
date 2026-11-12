import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    var errorDescription: String? { "Photo library access is off. Enable it in Settings." }
}

enum PhotoLibrary {
    static func ensureAddAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return
        case .notDetermined:
            let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if s == .authorized || s == .limited { return }
            throw PhotoLibraryError.notAuthorized
        default:
            throw PhotoLibraryError.notAuthorized
        }
    }

    static func requestReadWrite() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status
    }

    /// Saves a photo. When `rawCompanion` is given, Photos stores it as a RAW+HEIF/JPEG pair.
    static func savePhoto(primary: Data, rawCompanion: Data?) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: primary, options: nil)
            if let rawCompanion {
                request.addResource(with: .alternatePhoto, data: rawCompanion, options: nil)
            }
        }
    }

    static func saveVideo(at url: URL) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    static func saveCopy(data: Data) async throws {
        try await ensureAddAccess()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// Fetches the RAW (DNG) bytes behind an asset if it has any.
    static func rawData(for asset: PHAsset) async -> Data? {
        let resources = PHAssetResource.assetResources(for: asset)
        let rawResource = resources.first { r in
            let uti = r.uniformTypeIdentifier.lowercased()
            return uti.contains("raw-image") || uti.contains("dng")
        }
        guard let rawResource else { return nil }
        return await withCheckedContinuation { cont in
            var data = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(for: rawResource, options: options) { chunk in
                data.append(chunk)
            } completionHandler: { error in
                cont.resume(returning: error == nil ? data : nil)
            }
        }
    }
}
