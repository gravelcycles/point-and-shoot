import XCTest

/// The roll against a real (simulator) Photos library seeded with generated photos:
/// opening the viewer, deleting through iOS's own confirmation, Don't Allow, and batch
/// delete from the grid. Delete silently doing nothing (#19) is exactly what these catch.
///
/// Needs Photos access for the app (CI grants it with `simctl privacy`). Without it the
/// seeding saves nothing and the tests skip.
final class LibraryFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-seed", "3"]
        app.launch()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 15), "camera UI didn't appear")
        // Wait for the seeded photos to be saved, then for the roll to settle.
        guard app.staticTexts["roll.seeded"].waitForExistence(timeout: 30), rollCount() >= 3 else {
            throw XCTSkip("No Photos access in this simulator (roll has \(rollCount()) items)")
        }
        var last = rollCount()
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, Date().timeIntervalSince(stableSince) < 1.5 {
            Thread.sleep(forTimeInterval: 0.3)
            let now = rollCount()
            if now != last { last = now; stableSince = Date() }
        }
    }

    private func rollCount() -> Int {
        let probe = app.staticTexts.matching(identifier: "roll.count").firstMatch
        guard probe.exists else { return -1 }
        return Int(probe.label) ?? -1
    }

    private func waitForRollCount(_ expected: Int, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rollCount() == expected { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return rollCount() == expected
    }

    /// iOS's delete confirmation lives in the app or in SpringBoard depending on version.
    private func systemAlertButton(_ prefix: String, timeout: TimeInterval = 6) -> XCUIElement? {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", prefix)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for source in [app.alerts, springboard.alerts] {
                let button = source.buttons.matching(predicate).firstMatch
                if button.exists { return button }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private func openViewer() {
        app.buttons["camera.thumbnail"].tap()
        XCTAssertTrue(app.buttons["viewer.delete"].waitForExistence(timeout: 6), "viewer didn't open")
    }

    func testThumbnailOpensTheViewerAndCloseReturnsToTheCamera() {
        openViewer()
        app.buttons["viewer.close"].tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 4))
    }

    func testDeleteFromTheViewerRemovesThePhoto() throws {
        openViewer()
        let before = rollCount()
        app.buttons["viewer.delete"].tap()
        let confirm = try XCTUnwrap(systemAlertButton("Delete"), "Tapping trash showed no delete confirmation")
        confirm.tap()
        XCTAssertTrue(waitForRollCount(before - 1), "The photo wasn't deleted (roll \(before) → \(rollCount()))")
        // The viewer stays usable, on a neighbouring photo.
        XCTAssertTrue(app.buttons["viewer.delete"].isEnabled)
    }

    func testDontAllowKeepsThePhotoAndTrashStillWorks() throws {
        openViewer()
        let before = rollCount()
        app.buttons["viewer.delete"].tap()
        try XCTUnwrap(systemAlertButton("Don"), "no delete confirmation").tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(rollCount(), before, "Don't Allow deleted the photo anyway")
        // The button isn't left dead after a cancel.
        app.buttons["viewer.delete"].tap()
        try XCTUnwrap(systemAlertButton("Don"), "trash stopped responding after Don't Allow").tap()
    }

    func testGridSelectAndDeleteTwo() throws {
        openViewer()
        let before = rollCount()
        app.buttons["viewer.grid"].tap()
        XCTAssertTrue(app.buttons["grid.select"].waitForExistence(timeout: 4))
        app.buttons["grid.select"].tap()
        let cells = app.descendants(matching: .any).matching(identifier: "grid.cell")
        XCTAssertGreaterThanOrEqual(cells.count, 2)
        cells.element(boundBy: 0).tap()
        cells.element(boundBy: 1).tap()
        app.buttons["grid.delete"].tap()
        try XCTUnwrap(systemAlertButton("Delete"), "no delete confirmation for the batch").tap()
        XCTAssertTrue(waitForRollCount(before - 2), "Batch delete didn't remove both (roll \(before) → \(rollCount()))")
    }
}
