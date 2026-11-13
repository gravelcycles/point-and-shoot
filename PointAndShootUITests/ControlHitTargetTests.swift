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

    func testOutlinedBadgeRespondsInsideItsBorder() {
        let format = app.buttons["badge.format"]
        XCTAssertTrue(format.waitForExistence(timeout: 3))
        let before = format.label
        tapOffLabel(format, dx: 0.94)
        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: format)
        waitForExpectations(timeout: 3)
    }

    func testTopBarIconRespondsAwayFromGlyph() {
        tapOffLabel(app.buttons["topbar.timer"], dx: 0.95, dy: 0.9)
        XCTAssertTrue(app.staticTexts["3s"].waitForExistence(timeout: 3),
                      "Tapping the timer button's edge didn't change the self-timer")
    }

    func testSettingsOpensFromIconEdgeAndTogglesWork() {
        tapOffLabel(app.buttons["topbar.settings"], dx: 0.95, dy: 0.9)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                      "Tapping the settings button's edge didn't open Settings")
        let grid = app.switches["Grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        let before = grid.value as? String
        grid.tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        expectation(for: flipped, evaluatedWith: grid)
        waitForExpectations(timeout: 3)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 3))
    }

    func testModePickerSwitchesToVideo() {
        tapOffLabel(app.buttons["mode.video"], dx: 0.5, dy: 0.95)
        XCTAssertTrue(app.buttons["badge.resolution"].waitForExistence(timeout: 3),
                      "Tapping VIDEO didn't switch to video mode")
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
