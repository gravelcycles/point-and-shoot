import Foundation

/// Which photo the viewer shows, as a pure function so the states that broke on device
/// ("Developing…" forever, landing on a deleted photo) are unit-tested.
enum ViewerSelection {
    static let pendingID = "__pending__"

    struct State: Equatable {
        /// The viewer opened while a shot was still saving and is waiting for it.
        var awaitingCapture: Bool
        var selectedID: String?
    }

    /// - Parameters:
    ///   - assetIDs: the roll, newest first.
    ///   - lastIndex: where the selected photo was in the roll, for landing on the
    ///     neighbour after a delete.
    static func reconcile(_ state: State, capturesInFlight: Int, lastSavedAssetID: String?,
                          assetIDs: [String], lastIndex: Int) -> State {
        var s = state
        let ids = Set(assetIDs)
        if s.awaitingCapture, capturesInFlight == 0 {
            if let id = lastSavedAssetID, ids.contains(id) {
                s.awaitingCapture = false
                if s.selectedID == pendingID || s.selectedID == nil { s.selectedID = id }
            } else if lastSavedAssetID == nil {
                // The save failed: stop waiting.
                s.awaitingCapture = false
            }
        }
        if !s.awaitingCapture, let id = s.selectedID, id == pendingID || !ids.contains(id) {
            // Deleted (or the pending shot resolved): land on the neighbour, like Photos.
            let i = min(lastIndex, assetIDs.count - 1)
            s.selectedID = i >= 0 ? assetIDs[i] : nil
        }
        if s.selectedID == nil { s.selectedID = assetIDs.first }
        return s
    }
}

/// When the camera's thumbnail button stops showing the capture's own preview and hands
/// over to the roll (so later deletes anywhere are reflected).
enum ThumbnailHandoff {
    static func shouldRelease(hasCaptureThumbnail: Bool, capturesInFlight: Int,
                              lastSavedAssetID: String?, developingIDs: Set<String>,
                              rollContains: (String) -> Bool,
                              latestThumbnailID: String?, newestAssetID: String?) -> Bool {
        guard hasCaptureThumbnail, capturesInFlight == 0,
              let id = lastSavedAssetID, rollContains(id),
              !developingIDs.contains(id),
              let shown = latestThumbnailID, shown == newestAssetID else { return false }
        return true
    }
}
