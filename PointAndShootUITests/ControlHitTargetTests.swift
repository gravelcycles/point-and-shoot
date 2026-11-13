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
        XCTAssertTrue(app.buttons["Warm 400"].waitForExistence(timeout: 3),
                      "Tapping the edge of LOOK didn't open the look picker")
    }

    func testFormatPillOpensPanelAndChangesFileType() {
        let pill = app.buttons["topbar.format"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3))
        XCTAssertTrue(pill.label.contains("HEIF"), "unexpected default format: \(pill.label)")
        tapOffLabel(pill, dx: 0.95)
        let jpeg = app.buttons["JPEG"]
        guard jpeg.waitForExistence(timeout: 3) else {
            print(app.debugDescription)
            return XCTFail("Tapping the format pill's edge didn't open the format panel")
        }
        jpeg.tap()
        app.buttons["format.done"].tap()
        let changed = NSPredicate(format: "label CONTAINS 'JPEG'")
        expectation(for: changed, evaluatedWith: pill)
        waitForExpectations(timeout: 3)
    }

    func testTopBarIconRespondsAwayFromGlyph() {
        tapOffLabel(app.buttons["topbar.timer"], dx: 0.95, dy: 0.9)
        XCTAssertTrue(app.staticTexts["3s"].waitForExistence(timeout: 3),
                      "Tapping the timer button's edge didn't change the self-timer")
    }

    func testSettingsOpensFromIconEdgeAndTogglesWork() {
        tapOffLabel(app.buttons["topbar.settings"], dx: 0.95, dy: 0.9)
        // The sheet's Done button proves it opened (more robust than the nav bar title on iOS 26).
        let done = app.buttons["Done"]
        guard done.waitForExistence(timeout: 4) else {
            print(app.debugDescription)
            return XCTFail("Tapping the settings button's edge didn't open Settings")
        }
        // Grid lives in Assists, further down the form.
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

    /// Print mode always shoots RAW and *is* the filter, so the format pill and the FILTER
    /// cell go away; the photo controls stay. Back in Photo they return.
    func testPrintModeDropsFormatAndFilterControls() {
        tapOffLabel(app.buttons["mode.print"], dx: 0.5, dy: 0.95)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["topbar.format"])
        expectation(for: gone, evaluatedWith: app.buttons["strip.look"])
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["topbar.timer"].exists, "Print mode should keep the self-timer")
        XCTAssertTrue(app.buttons["strip.ev"].exists, "Print mode should keep exposure controls")

        tapOffLabel(app.buttons["mode.photo"], dx: 0.5, dy: 0.95)
        XCTAssertTrue(app.buttons["topbar.format"].waitForExistence(timeout: 3),
                      "Back in Photo, the format pill should return")
        XCTAssertTrue(app.buttons["strip.look"].exists, "Back in Photo, FILTER should return")
    }

    func testFilterCardsSelectAndDoubleTapResets() {
        let strip = app.buttons["strip.look"]
        tapOffLabel(strip, dx: 0.1)
        let warm = app.buttons["filter.warm400"]
        XCTAssertTrue(warm.waitForExistence(timeout: 3), "Filter cards didn't appear")
        warm.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Warm 400'"), evaluatedWith: strip)
        waitForExpectations(timeout: 3)
        strip.doubleTap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Off'"), evaluatedWith: strip)
        waitForExpectations(timeout: 3)
    }

    func testFilterGuideExplainsAndPicks() {
        tapOffLabel(app.buttons["strip.look"], dx: 0.1)
        let info = app.buttons["filter.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 3))
        info.tap()
        // The guide opens at half height and its List is lazy: only the first few rows
        // exist until scrolled, so pick one near the top.
        let warm = app.buttons["guide.warm400"]
        XCTAssertTrue(warm.waitForExistence(timeout: 4), "Filter guide didn't open")
        warm.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Warm 400'"), evaluatedWith: app.buttons["strip.look"])
        waitForExpectations(timeout: 3)
    }

    /// The empty strip above the controls overlaps the bottom of the viewfinder. Taps there
    /// belong to the controls area and must not trigger tap-to-focus.
    func testTapsInControlsAreaDoNotFallThroughToViewfinder() {
        let focusCell = app.buttons["strip.focus"]
        focusCell.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: -0.9)).tap()
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
