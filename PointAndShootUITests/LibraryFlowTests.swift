import XCTest

/// The app's own library (`ShotStore`) seeded with generated shots: opening the viewer,
/// the filmstrip, Keep, trash with Undo, the grid's batch trash and restoring from the Trash.
/// No Photos permission is involved: shots live in the app until they're exported.
final class LibraryFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-seed", "3"]
        app.launch()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 15), "camera UI didn't appear")
        XCTAssertTrue(app.staticTexts["roll.seeded"].waitForExistence(timeout: 30), "library wasn't seeded")
        XCTAssertTrue(waitForRollCount(3), "expected 3 seeded shots, have \(rollCount())")
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

    private func openViewer() {
        app.buttons["camera.thumbnail"].tap()
        XCTAssertTrue(app.buttons["viewer.delete"].waitForExistence(timeout: 6), "viewer didn't open")
    }

    func testThumbnailOpensTheViewerAndCloseReturnsToTheCamera() {
        openViewer()
        app.buttons["viewer.close"].tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 4))
    }

    func testTrashFromTheViewerAndUndo() {
        openViewer()
        let before = rollCount()
        app.buttons["viewer.delete"].tap()
        XCTAssertTrue(waitForRollCount(before - 1), "The photo wasn't trashed (\(before) → \(rollCount()))")
        // The viewer stays usable, on a neighbouring photo.
        XCTAssertTrue(app.buttons["viewer.delete"].isEnabled)
        let undo = app.buttons["viewer.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Undo after trashing")
        undo.tap()
        XCTAssertTrue(waitForRollCount(before), "Undo didn't bring the photo back")
    }

    func testTrashingEveryPhotoLeavesAnEmptyViewer() {
        openViewer()
        for _ in 0..<3 {
            app.buttons["viewer.delete"].tap()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(waitForRollCount(0))
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 3))
    }

    func testFilmstripShowsEveryShotAndKeepTags() {
        openViewer()
        let cells = app.descendants(matching: .any).matching(identifier: "viewer.filmstrip.cell")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(cells.count, 3)
        cells.element(boundBy: 2).tap()
        app.buttons["viewer.keep"].tap()
        XCTAssertTrue(app.staticTexts["Kept"].waitForExistence(timeout: 3), "Keep didn't tag the photo")
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
        let tone = app.buttons["editor.tool.tone"]
        XCTAssertTrue(tone.waitForExistence(timeout: 4))
        tone.tap()
        Thread.sleep(forTimeInterval: 2)   // the photo finishes loading; zoom turns on
        canvas.pinch(withScale: 3, velocity: 2)
        canvas.swipeLeft()                  // one finger pans while zoomed
        canvas.doubleTap()
        canvas.doubleTap()
        canvas.pinch(withScale: 0.6, velocity: -2)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(app.state, .runningForeground)
        // Zooming is not an edit: nothing to undo.
        let undo = app.buttons["editor.undo"]
        XCTAssertTrue(undo.exists)
        XCTAssertFalse(undo.isEnabled, "pinch-zooming changed the edit")
    }

    func testEditorSubTabsSlidersAndSave() {
        openViewer()
        app.buttons["viewer.edit"].tap()
        XCTAssertTrue(app.buttons["editor.tool.tone"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["editor.tool.tone"].tap()
        let exposure = app.descendants(matching: .any).matching(identifier: "editor.slider.exposure").firstMatch
        XCTAssertTrue(exposure.waitForExistence(timeout: 3), "Tone shows no Exposure slider")
        exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: exposure.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)))
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "dragging the slider made no edit")
        // Every tool's sub-tabs exist.
        app.buttons["editor.tool.color"].tap()
        XCTAssertTrue(app.buttons["editor.sub.balance"].waitForExistence(timeout: 2))
        app.buttons["editor.sub.mixer"].tap()
        app.buttons["editor.tool.texture"].tap()
        XCTAssertTrue(app.buttons["editor.sub.grain"].waitForExistence(timeout: 2))
        app.buttons["editor.tool.crop"].tap()
        app.buttons["editor.tool.looks"].tap()
        // ✓ saves and closes; the viewer is back.
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.buttons["viewer.edit"].waitForExistence(timeout: 6), "✓ didn't close the editor")
    }

    func testGridSelectTrashTwoThenRestoreFromTheTrash() {
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
        XCTAssertTrue(waitForRollCount(before - 2), "Batch trash didn't remove both (\(before) → \(rollCount()))")
        app.buttons["grid.trash"].tap()
        let trashed = app.descendants(matching: .any).matching(identifier: "trash.cell")
        XCTAssertTrue(trashed.firstMatch.waitForExistence(timeout: 4))
        XCTAssertEqual(trashed.count, 2)
        trashed.element(boundBy: 0).tap()
        XCTAssertTrue(waitForRollCount(before - 1), "Restoring from the Trash didn't bring it back")
    }
}

/// Grants the app full Photos access the way a person would, so the Photos integration unit
/// tests (which run after the UI tests) can use the library. Export is the only part of the
/// app that touches Photos now.
final class PhotosAccessTests: XCTestCase {
    func testGrantPhotosAccess() throws {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["-uitest", "-uitest-photos", "1"]
        app.launch()
        let seeded = app.staticTexts["roll.seeded"]
        let until = Date().addingTimeInterval(40)
        while !seeded.exists && Date() < until {
            for source in [springboard.alerts, app.alerts] {
                let alert = source.firstMatch
                guard alert.exists else { continue }
                for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] where alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(seeded.exists, "the app never finished asking for Photos access")
    }
}
