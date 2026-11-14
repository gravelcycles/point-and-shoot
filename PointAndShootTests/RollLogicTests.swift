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

    private func release(thumb: Bool = true, inFlight: Int = 0, lastSaved: String? = "new",
                         developing: Set<String> = [], roll: [String] = ["new", "a"],
                         latest: String? = "new") -> Bool {
        ThumbnailHandoff.shouldRelease(hasCaptureThumbnail: thumb, capturesInFlight: inFlight,
                                       lastSavedAssetID: lastSaved, developingIDs: developing,
                                       rollContains: { roll.contains($0) },
                                       latestThumbnailID: latest, newestAssetID: roll.first)
    }

    func testHandsOverOnceTheRollShowsTheShot() {
        XCTAssertTrue(release())
    }

    func testKeepsTheCaptureThumbnailUntilEverythingIsReady() {
        XCTAssertFalse(release(thumb: false))
        XCTAssertFalse(release(inFlight: 1), "Another shot is still saving")
        XCTAssertFalse(release(roll: ["a"]), "The roll doesn't have the shot yet")
        XCTAssertFalse(release(latest: "a"), "The roll's thumbnail is still the previous photo")
        XCTAssertFalse(release(developing: ["new"]), "Its look is still being baked")
        XCTAssertFalse(release(lastSaved: nil))
    }
}
