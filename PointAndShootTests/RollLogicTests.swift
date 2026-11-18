import XCTest
@testable import PointAndShoot

/// The viewer's selection and the camera thumbnail's handoff: the states behind
/// "stuck on Developing…", "lands on a deleted photo" and "thumbnail of a deleted shot".
final class RollLogicTests: XCTestCase {
    private let pending = ViewerSelection.pendingID

    private func reconcile(awaiting: Bool, selected: String?, inFlight: Int = 0,
                           lastSaved: String?, ids: [String], lastIndex: Int = 0) -> ViewerSelection.State {
        ViewerSelection.reconcile(.init(awaitingCapture: awaiting, selectedID: selected),
                                  capturesInFlight: inFlight, lastSavedAssetID: lastSaved,
                                  assetIDs: ids, lastIndex: lastIndex)
    }

    func testPendingShotResolvesWhenItLandsInTheRoll() {
        let s = reconcile(awaiting: true, selected: pending, lastSaved: "new", ids: ["new", "a"])
        XCTAssertEqual(s, .init(awaitingCapture: false, selectedID: "new"))
    }

    func testStillWaitingWhileTheCaptureIsInFlight() {
        let s = reconcile(awaiting: true, selected: pending, inFlight: 1, lastSaved: "old", ids: ["old"])
        XCTAssertEqual(s, .init(awaitingCapture: true, selectedID: pending))
    }

    func testWaitsForTheRollToCatchUp() {
        let s = reconcile(awaiting: true, selected: pending, lastSaved: "new", ids: ["a"])
        XCTAssertTrue(s.awaitingCapture)
        XCTAssertEqual(s.selectedID, pending)
    }

    func testFailedSaveStopsWaiting() {
        let s = reconcile(awaiting: true, selected: pending, lastSaved: nil, ids: ["a", "b"])
        XCTAssertFalse(s.awaitingCapture, "A failed save must not leave Developing… up forever")
        XCTAssertEqual(s.selectedID, "a")
    }

    func testDeletingLandsOnTheNeighbour() {
        // "b" was at index 1 in [c, b, a]; after deleting it the roll is [c, a].
        let s = reconcile(awaiting: false, selected: "b", lastSaved: nil, ids: ["c", "a"], lastIndex: 1)
        XCTAssertEqual(s.selectedID, "a")
    }

    func testDeletingTheOldestLandsOnTheNextOldest() {
        let s = reconcile(awaiting: false, selected: "a", lastSaved: nil, ids: ["c", "b"], lastIndex: 2)
        XCTAssertEqual(s.selectedID, "b")
    }

    func testDeletingEverythingClearsTheSelection() {
        let s = reconcile(awaiting: false, selected: "a", lastSaved: nil, ids: [], lastIndex: 0)
        XCTAssertNil(s.selectedID)
    }

    func testNoSelectionPicksTheNewest() {
        let s = reconcile(awaiting: false, selected: nil, lastSaved: nil, ids: ["n", "o"])
        XCTAssertEqual(s.selectedID, "n")
    }

    // MARK: Thumbnail handoff

    private let new = UUID()
    private let old = UUID()

    private func release(thumb: Bool = true, inFlight: Int = 0, saved: Bool = true,
                         developing: Bool = false, inLibrary: Bool = true, showingNew: Bool = true) -> Bool {
        let lib = inLibrary ? [new, old] : [old]
        return ThumbnailHandoff.shouldRelease(hasCaptureThumbnail: thumb, capturesInFlight: inFlight,
                                              lastSavedID: saved ? new : nil,
                                              developing: developing ? [new] : [],
                                              libraryContains: { lib.contains($0) },
                                              shownID: showingNew ? new : old,
                                              newestID: lib.first)
    }

    func testHandsOverOnceTheLibraryShowsTheShot() {
        XCTAssertTrue(release())
    }

    func testKeepsTheCaptureThumbnailUntilEverythingIsReady() {
        XCTAssertFalse(release(thumb: false))
        XCTAssertFalse(release(inFlight: 1), "Another shot is still saving")
        XCTAssertFalse(release(showingNew: false), "The thumbnail shown is still the previous photo")
        XCTAssertFalse(release(developing: true), "Its look is still being developed")
    }

    func testReleasesWhenTheShotIsGone() {
        XCTAssertTrue(release(inLibrary: false), "Trashed before it was shown")
        XCTAssertTrue(release(saved: false), "Nothing was saved")
    }
}
