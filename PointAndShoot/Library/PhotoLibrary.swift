import AVFoundation
import CoreLocation
import Photos
import UIKit
import UniformTypeIdentifiers

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

    /// Holds the new asset's identifier out of the change block.
    private final class IDBox { var value: String? }

    /// Saves a photo and returns its library identifier. When `rawCompanion` is given,
    /// Photos stores it as a RAW+HEIF/JPEG pair.
    @discardableResult
    static func savePhoto(primary: Data, rawCompanion: Data?, location: CLLocation? = nil) async throws -> String? {
        try await ensureAddAccess()
        let box = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            request.addResource(with: .photo, data: primary, options: nil)
            if let rawCompanion {
                request.addResource(with: .alternatePhoto, data: rawCompanion, options: nil)
            }
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return box.value
    }

    @discardableResult
    static func saveVideo(at url: URL, location: CLLocation? = nil) async throws -> String? {
        try await ensureAddAccess()
        let box = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            request.addResource(with: .video, fileURL: url, options: options)
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return box.value
    }

    @discardableResult
    static func saveCopy(data: Data, location: CLLocation? = nil) async throws -> String? {
        try await ensureAddAccess()
        let box = IDBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            request.addResource(with: .photo, data: data, options: nil)
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return box.value
    }

    static func toggleFavorite(_ asset: PHAsset) async throws {
        let newValue = !asset.isFavorite
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = newValue
        }
    }

    /// iOS shows its own "Delete Photo?" confirmation.
    static func delete(_ asset: PHAsset) async throws {
        try await delete([asset])
    }

    /// One system "Delete N Photos?" confirmation for the whole batch.
    static func delete(_ assets: [PHAsset]) async throws {
        // Skip anything already deleted elsewhere: deleting a missing asset fails the batch.
        let assets = assets.filter { !isGone($0) }
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    /// True when the asset no longer exists in the library (deleted here, in Photos, on
    /// another device, or moved to Recently Deleted).
    static func isGone(_ asset: PHAsset) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).count == 0
    }

    /// The user tapping "Don't Allow"/"Cancel" on the system confirmation isn't an error.
    static func isUserCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.userCancelled.rawValue
    }

    /// Exports originals for several assets (for one share sheet).
    static func exportForSharing(_ assets: [PHAsset]) async -> [URL] {
        var urls: [URL] = []
        for asset in assets {
            if let url = await exportForSharing(asset) { urls.append(url) }
        }
        return urls
    }

    static func hasRAW(_ asset: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: asset).contains { r in
            let uti = r.uniformTypeIdentifier.lowercased()
            return uti.contains("raw-image") || uti.contains("dng")
        }
    }

    /// Writes the original file (HEIC/JPEG/DNG/MOV, full quality and metadata) to a temp
    /// URL for the share sheet.
    static func exportForSharing(_ asset: PHAsset) async -> URL? {
        if asset.mediaType == .video {
            // Copy the movie out of Photos' private storage so share targets can read it.
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                    ?? resources.first(where: { $0.type == .video }) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(resource.originalFilename)
            try? FileManager.default.removeItem(at: url)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            return await withCheckedContinuation { cont in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    cont.resume(returning: error == nil ? url : nil)
                }
            }
        }
        let result: (Data, String)? = await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                if let data, let uti { cont.resume(returning: (data, uti)) } else { cont.resume(returning: nil) }
            }
        }
        guard let result else { return nil }
        let (data, uti) = result
        let ext = UTType(uti)?.preferredFilenameExtension ?? "jpg"
        let name = (PHAssetResource.assetResources(for: asset).first?.originalFilename as NSString?)?
            .deletingPathExtension ?? "Photo"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.removeItem(at: url)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
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
