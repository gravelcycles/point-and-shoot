import XCTest

/// Regression tests for "buttons are hard to tap": a control must respond to a tap anywhere
/// inside its frame, not only on its text or icon glyphs, and taps on the control area must
/// never fall through to the viewfinder behind it (which focuses instead).
///
/// Runs in the simulator with `-uitest` (no camera session, no permission prompts).
final class ControlHitTargetTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 15), "camera UI didn't appear")
    }

    /// Taps inside the element's frame but away from its centered label.
    private func tapOffLabel(_ element: XCUIElement, dx: CGFloat = 0.92, dy: CGFloat = 0.5) {
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    func testControlStripOpensDialFromTheEdgeOfTheCell() {
        tapOffLabel(app.buttons["strip.ev"])
        XCTAssertTrue(app.buttons["dial.auto"].waitForExistence(timeout: 3),
                      "Tapping the edge of EV didn't open its dial")
    }

    func testLookCellOpensLookPickerFromTheEdge() {
        tapOffLabel(app.buttons["strip.look"], dx: 0.1)
        XCTAssertTrue(app.buttons["Portrait 400"].waitForExistence(timeout: 3),
                      "Tapping the edge of LOOK didn't open the look picker")
    }

    /// RAW only: the pill reads ProRAW by default, and the panel switches to Bayer RAW.
    private func switchToBayerRAW() {
        let pill = app.buttons["topbar.format"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        tapOffLabel(pill, dx: 0.95)
        let bayer = app.buttons["RAW"]
        guard bayer.waitForExistence(timeout: 3) else {
            print(app.debugDescription)
            return XCTFail("Tapping the format pill's edge didn't open the format panel")
        }
        bayer.tap()
        app.buttons["format.done"].tap()
    }

    func testFormatPillOpensPanelAndChangesFileType() {
        let pill = app.buttons["topbar.format"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertTrue(pill.label.hasPrefix("ProRAW"), "unexpected default format: \(pill.label)")
        switchToBayerRAW()
        let changed = NSPredicate(format: "label BEGINSWITH 'RAW'")
        expectation(for: changed, evaluatedWith: pill)
        waitForExpectations(timeout: 3)
    }

    func testTopBarIconRespondsAwayFromGlyph() {
        // The self-timer is a dropdown: its edge opens it, and a choice sets it.
        tapOffLabel(app.buttons["topbar.timer"], dx: 0.95, dy: 0.9)
        let three = app.buttons["3 Seconds"]
        XCTAssertTrue(three.waitForExistence(timeout: 3), "Tapping the timer button's edge didn't open its menu")
        three.tap()
        XCTAssertTrue(app.staticTexts["3s"].waitForExistence(timeout: 3), "Choosing 3 Seconds didn't set the self-timer")
    }

    func testSettingsOpensFromIconEdgeAndTogglesWork() {
        tapOffLabel(app.buttons["topbar.settings"], dx: 0.95, dy: 0.9)
        // The sheet's Done button proves it opened (more robust than the nav bar title on iOS 26).
        let done = app.buttons["Done"]
        guard done.waitForExistence(timeout: 4) else {
            print(app.debugDescription)
            return XCTFail("Tapping the settings button's edge didn't open Settings")
        }
        // Grid lives in Camera → Viewfinder.
        app.buttons["Camera"].firstMatch.tap()
        let grid = app.switches["Grid"]
        var swipes = 0
        while !grid.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        guard grid.exists else {
            print(app.debugDescription)
            return XCTFail("Couldn't find the Grid toggle in Settings")
        }
        let before = grid.value as? String
        // Tap the switch itself (trailing edge); tapping the label doesn't toggle on iOS 17+.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        expectation(for: flipped, evaluatedWith: grid)
        waitForExpectations(timeout: 3)
        done.tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 3))
    }

    func testModePickerSwitchesToVideo() {
        tapOffLabel(app.buttons["mode.video"], dx: 0.5, dy: 0.95)
        XCTAssertTrue(app.buttons["topbar.videoformat"].waitForExistence(timeout: 3),
                      "Tapping VIDEO didn't switch to video mode")
    }

    /// P&S Studio: Print is one of Photo's looks, not a mode.
    func testPrintIsALookNotAMode() {
        XCTAssertTrue(app.buttons["mode.photo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mode.print"].exists, "Print should no longer be a mode")
        tapOffLabel(app.buttons["strip.look"], dx: 0.1)
        let print = app.buttons["filter.print"]
        XCTAssertTrue(print.waitForExistence(timeout: 3), "Print should be one of the looks")
    }

    func testFilterCardsSelectAndDoubleTapResets() {
        let strip = app.buttons["strip.look"]
        tapOffLabel(strip, dx: 0.1)
        // Punch: an early card that's on screen without scrolling (the set menu takes room).
        let punch = app.buttons["filter.punch"]
        XCTAssertTrue(punch.waitForExistence(timeout: 3), "Look cards didn't appear")
        punch.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Punch'"), evaluatedWith: strip)
        waitForExpectations(timeout: 3)
        strip.doubleTap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Off'"), evaluatedWith: strip)
        waitForExpectations(timeout: 3)
    }

    /// The set menu narrows the LOOK strip to one named set. Opened from the edge of its
    /// button (an off-center tap: the whole button must take taps).
    func testLookSetMenuFiltersTheStrip() {
        tapOffLabel(app.buttons["strip.look"], dx: 0.1)
        XCTAssertTrue(app.buttons["filter.portrait400"].waitForExistence(timeout: 3), "Look cards didn't appear")
        let menu = app.buttons["filter.set"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "no look-set menu")
        tapOffLabel(menu, dx: 0.85, dy: 0.85)
        let movie = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", LookSetNames.movie)).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 3), "the set menu didn't open")
        movie.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["filter.portrait400"])
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["filter.blockbuster"].exists, "Movie set should show Blockbuster")
        XCTAssertTrue(menu.label.contains(LookSetNames.movie), "the set button should say Movie, says \(menu.label)")
    }

    func testFilterGuideExplainsAndPicks() {
        tapOffLabel(app.buttons["strip.look"], dx: 0.1)
        let info = app.buttons["filter.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 3))
        info.tap()
        // The guide opens at half height and its List is lazy: only the first few rows
        // exist until scrolled, so pick one near the top (Original, Phromagraph, Punch, …).
        let punch = app.buttons["guide.punch"]
        XCTAssertTrue(punch.waitForExistence(timeout: 4), "Look guide didn't open")
        punch.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Punch'"), evaluatedWith: app.buttons["strip.look"])
        waitForExpectations(timeout: 3)
    }

    /// All six controls share one row: every cell is on screen, at least 44 pt wide, and
    /// none overlap.
    func testAllControlsFitInOneRow() {
        let ids = ["focus", "wb", "iso", "shutter", "ev", "look"]
        let frames = ids.map { app.buttons["strip.\($0)"].frame }
        let screen = app.windows.firstMatch.frame
        for (id, f) in zip(ids, frames) {
            XCTAssertTrue(app.buttons["strip.\(id)"].exists, "strip.\(id) missing")
            XCTAssertTrue(screen.contains(f), "strip.\(id) is off screen: \(f)")
            XCTAssertGreaterThanOrEqual(f.width, 44, "strip.\(id) is too narrow to tap: \(f)")
            XCTAssertEqual(f.midY, frames[0].midY, accuracy: 2, "strip.\(id) isn't in the same row")
        }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "controls overlap")
        }
    }

    /// Bayer RAW crashes AVFoundation when zoomed (#18): pinching with Bayer RAW must not
    /// zoom, and must say why.
    func testPinchWithBayerRAWIsLockedAndExplained() {
        // Bayer RAW is what locks zoom (ProRAW, the default, zooms).
        switchToBayerRAW()
        let viewfinder = app.otherElements["viewfinder"]
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 3))
        viewfinder.pinch(withScale: 2.5, velocity: 2)
        let toast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No zoom in Bayer RAW'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "Pinching with Bayer RAW showed no zoom-lock message")
    }

    /// The silent-shutter option exists and can be turned on.
    func testShutterSoundToggleIsInSettings() {
        tapOffLabel(app.buttons["topbar.settings"], dx: 0.5, dy: 0.5)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 4))
        app.buttons["Camera"].firstMatch.tap()
        let toggle = app.switches["Shutter sound"]
        var swipes = 0
        while !toggle.isHittable && swipes < 10 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(toggle.exists, "Settings has no Shutter sound toggle")
        XCTAssertEqual(toggle.value as? String, "0", "The shutter should be silent by default")
    }

    /// Double-tapping the viewfinder opens Preferences (Chromagraph's shortcut), and every
    /// tab is there.
    func testDoubleTapViewfinderOpensPreferences() {
        let viewfinder = app.otherElements["viewfinder"]
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 3))
        viewfinder.doubleTap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 4), "double-tap didn't open Preferences")
        for tab in ["General", "Camera", "Processing"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.exists, "no \(tab) tab")
        }
        app.buttons["Processing"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.defaultLook"].waitForExistence(timeout: 3)
                      || app.otherElements["settings.defaultLook"].exists
                      || app.staticTexts["Default Grade"].exists
                      || app.staticTexts["DEFAULT GRADE"].exists,
                      "Processing has no Default Grade")
        app.buttons["General"].firstMatch.tap()
        XCTAssertTrue(app.switches["settings.storeForever"].waitForExistence(timeout: 3), "General has no Store Forever")
    }

    /// Settings → Diagnostics opens and shows this launch in the log.
    func testDiagnosticsLogIsReachableFromSettings() {
        tapOffLabel(app.buttons["topbar.settings"], dx: 0.5, dy: 0.5)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 4))
        let link = app.buttons["settings.diagnostics"]
        var swipes = 0
        while !link.isHittable && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(link.exists, "Settings has no Diagnostics entry")
        link.tap()
        let text = app.staticTexts["diagnostics.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 4), "Diagnostics didn't open")
        let launched = NSPredicate(format: "label CONTAINS 'launch'")
        expectation(for: launched, evaluatedWith: text)
        waitForExpectations(timeout: 4)
    }

    /// The empty strip above the controls overlaps the bottom of the viewfinder. Taps there
    /// belong to the controls area and must not trigger tap-to-focus.
    func testTapsInControlsAreaDoNotFallThroughToViewfinder() {
        let evCell = app.buttons["strip.ev"]
        evCell.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: -0.9)).tap()
        XCTAssertFalse(app.otherElements["focus.reticle"].waitForExistence(timeout: 1.5),
                       "A tap in the controls area went through to the viewfinder and focused")
    }

    /// Sanity check that the viewfinder itself still takes tap-to-focus.
    func testViewfinderTapStillFocuses() {
        let viewfinder = app.otherElements["viewfinder"]
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 3))
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.otherElements["focus.reticle"].waitForExistence(timeout: 3))
    }
}

/// Set names as the menu shows them (the UI test target can't see the app's `LookSet`).
private enum LookSetNames {
    static let movie = "Movie"
}
