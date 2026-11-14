import AVFoundation
import CoreLocation
import OSLog
import Photos
import PhotosUI
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
        // Photos rejects a RAW .alternatePhoto handed over as Data (PHPhotosErrorDomain
        // 3300, seen on device for every RAW+HEIF pair); from a file URL it's accepted,
        // which is what Apple's AVCam sample does. Write the DNG to a temp file and let
        // Photos move it in.
        var rawURL: URL?
        if let rawCompanion {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("dng")
            try rawCompanion.write(to: url)
            rawURL = url
        }
        defer { if let rawURL { try? FileManager.default.removeItem(at: rawURL) } }

        let box = IDBox()
        do {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            request.addResource(with: .photo, data: primary, options: nil)
            if let rawURL {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .alternatePhoto, fileURL: rawURL, options: options)
            }
            box.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        } catch {
            Diag.error(.save, "Photos save failed (\(primary.count / 1024) KB\(rawCompanion.map { " + RAW \($0.count / 1024) KB" } ?? ""))", error)
            throw error
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
    ///
    /// Always asks Photos to delete exactly what was tapped; it never silently skips (a
    /// pre-check that wrongly reported photos as already gone made Delete do nothing). Only
    /// if Photos refuses does it look for items deleted elsewhere meanwhile and retry with
    /// the rest.
    /// What happened to a delete, in words the user can screenshot. Every path is visible:
    /// a delete that silently did nothing on device (twice) is what this is for.
    enum DeleteOutcome {
        case deleted
        /// The user tapped Don't Allow on iOS's prompt.
        case kept
        case failed(String)
    }

    /// Deletes and reports the outcome. A "cancelled" error that comes back too fast for a
    /// person to have answered means iOS never showed its prompt: reported as a failure.
    ///
    /// On device (iOS 18, Limited Photos access) iOS sometimes never answers a delete: no
    /// prompt, no callback, and later Photos requests stall too (also reported on Apple's
    /// forums). So: one delete at a time (a second tap used to stack more stuck requests),
    /// and `onStall` fires if iOS hasn't answered after `stallAfter` seconds.
    @MainActor
    static func deleteReporting(_ assets: [PHAsset], stallAfter: Double = 8,
                                onStall: @escaping @MainActor () -> Void = {}) async -> DeleteOutcome {
        let ids = assets.map { String($0.localIdentifier.prefix(8)) }.joined(separator: ",")
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
        Diag.log(.delete, "delete \(assets.count) [\(ids)] · \(Diag.permissionSummary())")
        guard !assets.isEmpty else { return .failed("Nothing to delete") }
        guard !deleteInFlight else {
            Diag.error(.delete, "ignored: iOS hasn't answered the previous delete yet")
            return .failed("iOS hasn't answered the previous delete yet")
        }
        deleteInFlight = true
        defer { deleteInFlight = false }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(stallAfter))
            guard !Task.isCancelled else { return }
            Diag.error(.delete, "no answer from iOS after \(Int(stallAfter)) s (the delete request hasn't returned) · \(Diag.permissionSummary())")
            onStall()
        }
        defer { watchdog.cancel() }
        let start = Date()
        do {
            try await delete(assets)
            Diag.log(.delete, "deleted \(assets.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            return .deleted
        } catch {
            let ns = error as NSError
            let elapsed = Date().timeIntervalSince(start)
            Diag.error(.delete, "delete failed after \(Int(elapsed * 1000)) ms: \(ns.localizedDescription) (\(ns.domain) \(ns.code))")
            if isUserCancel(error) && elapsed > 0.8 { return .kept }
            let access = ["not asked", "restricted", "denied", "full", "limited"][min(max(status, 0), 4)]
            let what = isUserCancel(error) ? "iOS didn't show its delete prompt" : ns.localizedDescription
            return .failed("\(what) (\(ns.domain) \(ns.code), Photos access: \(access))")
        }
    }

    /// Limited Photos access: iOS's own picker for which photos the app may see. Shown from
    /// the topmost screen; the roll's change observer picks up the new selection.
    @MainActor
    static func chooseLimitedPhotos() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        Diag.log(.perms, "showing the limited-library picker")
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { ids in
            Diag.log(.perms, "limited-library picker closed: \(ids.count) newly chosen")
        }
    }

    /// A delete is waiting for iOS (main actor).
    @MainActor private static var deleteInFlight = false

    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                Diag.log(.delete, "change block ran (asking iOS to delete \(assets.count))")
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch where !isUserCancel(error) {
            let live = assets.filter { !isGone($0) }
            guard !live.isEmpty, live.count < assets.count else { throw error }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(live as NSArray)
            }
        }
    }

    /// True when the asset no longer exists in the library (deleted here, in Photos, on
    /// another device, or moved to Recently Deleted).
    /// Only consulted after an operation fails, never to decide whether to try.
    static func isGone(_ asset: PHAsset) -> Bool {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: options).count == 0
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
        PHAssetResource.assetResources(for: asset).contains(where: isRAWResource)
    }

    /// The RAW half of a RAW+processed pair always sits in the `.alternatePhoto` slot; a
    /// RAW-only asset is recognised by its type (Photos doesn't label every DNG
    /// "com.adobe.raw-image": the CI test DNG came back with another UTI).
    static func isRAWResource(_ r: PHAssetResource) -> Bool {
        if r.type == .alternatePhoto { return true }
        let uti = r.uniformTypeIdentifier.lowercased()
        return uti.contains("raw-image") || uti.contains("dng")
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
        let rawResource = resources.first { $0.type == .alternatePhoto } ?? resources.first(where: isRAWResource)
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
