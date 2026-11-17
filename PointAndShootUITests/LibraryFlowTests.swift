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
        // Seeding asks for Photos access: allow it like a person would, then wait for the
        // seeded photos to be saved and the roll to settle.
        let seeded = app.staticTexts["roll.seeded"]
        let until = Date().addingTimeInterval(40)
        while !seeded.exists && Date() < until {
            allowPhotosAccessIfAsked()
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard seeded.exists, rollCount() >= 3 else {
            let message = "No Photos access in this simulator (roll has \(rollCount()) items)"
            if ProcessInfo.processInfo.environment["CI"] != nil { XCTFail(message); return }
            throw XCTSkip(message)
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

    /// Taps "Allow Full Access" (or "Allow") on iOS's Photos permission prompt, if it's up.
    private func allowPhotosAccessIfAsked() {
        for source in [springboard.alerts, app.alerts] {
            let alert = source.firstMatch
            guard alert.exists else { continue }
            for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
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

    // MARK: Zoom

    /// The viewer's zoom state, as the app sees it (a -uitest probe).
    private func zoomProbe() -> String {
        let probe = app.staticTexts.matching(identifier: "viewer.zoomProbe").firstMatch
        return probe.exists ? probe.label : "no probe"
    }

    /// The viewer's recent gesture decisions (readable from the camera screen too).
    private func viewerEvents() -> String {
        let probe = app.staticTexts.matching(identifier: "viewer.events").firstMatch
        return probe.exists ? probe.label : "no probe"
    }

    func testPinchZoomInTheViewerPansInsteadOfDismissing() {
        openViewer()
        let photo = app.descendants(matching: .any).matching(identifier: "viewer.photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 6), "the photo page isn't zoomable")
        photo.pinch(withScale: 3, velocity: 2)
        Thread.sleep(forTimeInterval: 0.8)
        let afterZoom = zoomProbe()
        XCTAssertTrue(afterZoom.hasPrefix("zoomed=1"), "pinching didn't zoom: \(afterZoom)")
        // Zoomed in, a downward drag moves around the photo; it mustn't close the viewer.
        photo.swipeDown()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.buttons["viewer.close"].exists, "a drag while zoomed dismissed the viewer (\(afterZoom))")
        // Double-tap back to fit.
        photo.doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        let afterFit = zoomProbe()
        XCTAssertTrue(afterFit.hasPrefix("zoomed=0"), "double-tap didn't go back to fit: \(afterFit)")
        // Hide the controls with a tap first: XCUITest starts a pinch-in at the corners of
        // the element, which would land on the close button in the top bar.
        photo.tap()
        let close = app.buttons["viewer.close"]
        var deadline = Date().addingTimeInterval(3)
        while close.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(close.exists, "a single tap didn't hide the controls (\(zoomProbe()))")
        // Pinching in below fit bounces back. The top finger moves down the screen, but it's
        // a pinch, not a swipe-down: the viewer stays open.
        photo.pinch(withScale: 0.5, velocity: -2)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(photo.exists && !app.buttons["strip.ev"].exists,
                      "pinching in at fit closed the viewer (before: \(afterFit); events: \(viewerEvents()))")
        // Tap brings the controls back, and they work.
        photo.tap()
        let trash = app.buttons["viewer.delete"]
        deadline = Date().addingTimeInterval(3)
        while !(trash.exists && trash.isHittable) && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(trash.exists && trash.isHittable, "controls didn't come back (\(zoomProbe()))")
    }

    func testPinchZoomInTheEditorDoesNotAdjustAnything() {
        openViewer()
        app.buttons["viewer.edit"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "editor.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8), "editor didn't open")
        // A tool whose one-finger swipes adjust a slider.
        let tune = app.buttons["editor.tool.tune"]
        XCTAssertTrue(tune.waitForExistence(timeout: 4))
        tune.tap()
        Thread.sleep(forTimeInterval: 2)   // the photo finishes loading; zoom turns on
        canvas.pinch(withScale: 3, velocity: 2)
        canvas.doubleTap()
        canvas.doubleTap()
        canvas.pinch(withScale: 0.6, velocity: -2)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(app.state, .runningForeground)
        // Zooming is not an edit: Save stays disabled.
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "pinch-zooming changed the edit")
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
