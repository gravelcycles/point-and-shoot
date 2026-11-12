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

    let imageManager = PHCachingImageManager()

    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var latestKey: String?

    var isAuthorized: Bool { status == .authorized || status == .limited }

    /// Start quietly if the user already granted access; never prompts.
    func activateIfAuthorized() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if isAuthorized { start() }
    }

    func requestAccess() async {
        status = await PhotoLibrary.requestReadWrite()
        if isAuthorized { start() }
    }

    func contains(_ id: String) -> Bool {
        assets.contains { $0.localIdentifier == id }
    }

    func asset(withID id: String) -> PHAsset? {
        assets.first { $0.localIdentifier == id }
    }

    private func start() {
        if !registered {
            PHPhotoLibrary.shared().register(self)
            registered = true
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        // Recent history is what a camera roll is for; keeps every update instant.
        options.fetchLimit = 2000
        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result
        publish(result)
    }

    private func publish(_ result: PHFetchResult<PHAsset>) {
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        refreshLatestThumbnail()
    }

    private func refreshLatestThumbnail() {
        guard let newest = assets.first else {
            latestThumbnail = nil
            return
        }
        // Re-render when the newest item changes *or* gets edited.
        let key = "\(newest.localIdentifier)|\(newest.modificationDate?.timeIntervalSince1970 ?? 0)"
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
                self.latestThumbnail = image
                self.latestThumbnailDate = Date()
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            guard let current = self.fetchResult,
                  let details = changeInstance.changeDetails(for: current) else { return }
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
