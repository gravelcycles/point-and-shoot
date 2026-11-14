import Observation
import Photos
import UIKit

/// The camera roll, kept live. Registers for Photos change notifications so new captures,
/// saved edits, favorites and deletes show up everywhere instantly — including edits made
/// in Apple's Photos app while we're in the background.
@Observable
final class RollStore: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var assets: [PHAsset] = []
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// Thumbnail of the newest item, for the camera's roll button.
    private(set) var latestThumbnail: UIImage?
    private(set) var latestThumbnailDate = Date.distantPast
    /// Which asset `latestThumbnail` shows (nil when the roll is empty or not loaded yet).
    private(set) var latestThumbnailID: String?
    /// True once the first fetch has been published.
    private(set) var isLoaded = false

    let imageManager = PHCachingImageManager()

    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var started = false
    /// Fetching and walking up to 2000 assets happens here, never on the main thread.
    @ObservationIgnored private let work = DispatchQueue(label: "roll.store", qos: .userInitiated)
    @ObservationIgnored private var latestKey: String?

    var isAuthorized: Bool { status == .authorized || status == .limited }

    /// Start quietly if the user already granted access; never prompts.
    func activateIfAuthorized() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != status { status = current }
        guard isAuthorized else { return }
        // Refetch on every return to the app (off the main thread). The change observer
        // covers the normal case; this catches anything it missed while we were away.
        start()
    }

    func requestAccess() async {
        let granted = await PhotoLibrary.requestReadWrite()
        await MainActor.run {
            status = granted
            if isAuthorized { start() }
        }
    }

    func contains(_ id: String) -> Bool {
        assets.contains { $0.localIdentifier == id }
    }

    func asset(withID id: String) -> PHAsset? {
        assets.first { $0.localIdentifier == id }
    }

    private func start() {
        started = true
        if !registered {
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
        work.async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            // Recent history is what a camera roll is for; keeps every update instant.
            options.fetchLimit = 2000
            let result = PHAsset.fetchAssets(with: options)
            self.fetchResult = result
            self.publish(result)
        }
    }

    /// Call on `work`. Walks the fetch result off the main thread, then hands the array over.
    private func publish(_ result: PHFetchResult<PHAsset>) {
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        DispatchQueue.main.async {
            self.assets = list
            self.isLoaded = true
            self.refreshLatestThumbnail()
        }
    }

    private func refreshLatestThumbnail() {
        guard let newest = assets.first else {
            // Everything deleted: no stale thumbnail, and re-render whatever comes next.
            latestThumbnail = nil
            latestThumbnailID = nil
            latestKey = nil
            latestThumbnailDate = Date()
            return
        }
        // Re-render when the newest item changes *or* gets edited.
        let key = newest.revisionKey
        guard key != latestKey else { return }
        latestKey = key
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        imageManager.requestImage(for: newest, targetSize: CGSize(width: 200, height: 200),
                                  contentMode: .aspectFill, options: options) { [weak self] image, _ in
            guard let self, let image else { return }
            DispatchQueue.main.async {
                // A slow request for an item that's since been deleted or replaced: drop it.
                guard self.latestKey == key else { return }
                self.latestThumbnail = image
                self.latestThumbnailID = newest.localIdentifier
                self.latestThumbnailDate = Date()
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        work.async {
            guard let current = self.fetchResult else { return }
            guard let details = changeInstance.changeDetails(for: current) else { return }
            let updated = details.fetchResultAfterChanges
            self.fetchResult = updated
            self.publish(updated)
        }
    }
}

extension PHAsset {
    /// Identity that changes when the asset is edited, so cached images refresh.
    var revisionKey: String {
        "\(localIdentifier)|\(modificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
