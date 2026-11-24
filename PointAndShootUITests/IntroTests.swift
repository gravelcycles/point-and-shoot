import XCTest

/// The first-run intro (`IntroView`). UI tests never see it unless launched with
/// `-uitest-intro`; Preferences → General → Show Introduction brings it back.
final class IntroTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func page() -> Int {
        let probe = app.staticTexts.matching(identifier: "intro.page").firstMatch
        guard probe.exists else { return -1 }
        return Int(probe.label) ?? -1
    }

    private func waitForPage(_ expected: Int, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if page() == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return page() == expected
    }

    private func launchOnIntro() {
        app.launchArguments = ["-uitest", "-uitest-intro"]
        app.launch()
        XCTAssertTrue(app.buttons["intro.next"].waitForExistence(timeout: 15), "the intro didn't appear")
        XCTAssertTrue(waitForPage(0))
    }

    /// Swipe and Next move through the pages; Skip goes straight to the camera.
    func testIntroSwipesAndSkips() {
        launchOnIntro()
        // The camera screen isn't built behind the intro (its permission prompt comes after).
        XCTAssertFalse(app.buttons["strip.ev"].exists, "the camera was built behind the intro")
        app.swipeLeft()
        XCTAssertTrue(waitForPage(1), "swiping didn't turn the page (\(page()))")
        app.buttons["intro.next"].tap()
        XCTAssertTrue(waitForPage(2), "Next didn't turn the page (\(page()))")
        app.swipeRight()
        XCTAssertTrue(waitForPage(1), "swiping back didn't turn the page (\(page()))")
        app.buttons["intro.skip"].tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 10), "Skip didn't open the camera")
        XCTAssertFalse(app.buttons["intro.next"].exists, "the intro is still up after Skip")
    }

    /// The last page explains the two permissions and ends on Start Shooting.
    func testIntroEndsOnStartShooting() {
        launchOnIntro()
        for expected in 1...4 {
            app.buttons["intro.next"].tap()
            XCTAssertTrue(waitForPage(expected), "Next didn't reach page \(expected) (\(page()))")
        }
        let start = app.buttons["intro.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3), "the last page has no Start Shooting")
        XCTAssertTrue(app.buttons["intro.allowCamera"].exists, "the last page doesn't explain camera access")
        XCTAssertTrue(app.buttons["intro.allowLocation"].exists, "the last page doesn't explain location access")
        start.tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 10), "Start Shooting didn't open the camera")
    }

    /// Preferences → General → Show Introduction brings it back over the camera.
    func testPreferencesShowsTheIntroAgain() {
        app.launchArguments = ["-uitest"]
        app.launch()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 15), "camera UI didn't appear")
        XCTAssertFalse(app.buttons["intro.next"].exists, "UI tests opened on the intro")
        app.buttons["topbar.settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 4), "Preferences didn't open")
        let row = app.buttons["settings.showIntro"]
        var swipes = 0
        while !row.isHittable && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(row.exists, "Preferences has no Show Introduction")
        row.tap()
        XCTAssertTrue(app.buttons["intro.next"].waitForExistence(timeout: 5), "Show Introduction didn't open the intro")
        app.buttons["intro.skip"].tap()
        XCTAssertTrue(app.buttons["strip.ev"].waitForExistence(timeout: 6), "Skip didn't return to the camera")
        XCTAssertFalse(app.buttons["intro.next"].exists, "the intro is still up after Skip")
    }
}
