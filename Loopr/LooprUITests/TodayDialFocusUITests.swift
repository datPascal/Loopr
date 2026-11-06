import XCTest

/// Tapping the day dial opens a card in the dial's own square, and Today stays the screen. The populated fixture's
/// clock is pinned at 13:30: lunch (photographed) sits at 12:30 and last night runs through the small hours.
/// Each test keeps screenshots from mid-flight and from the landed card, for review.
final class TodayDialFocusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-deep-link=today",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: wait))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A point on the dial at a wall-clock time and ring radius, as a share of the dial's square (340-point view box,
    /// noon at the top, clockwise).
    private func offset(hour: Double, radius: Double) -> CGVector {
        let angle = (hour / 24 * 360 + 180) * .pi / 180
        return CGVector(dx: (170 + radius * sin(angle)) / 340, dy: (170 - radius * cos(angle)) / 340)
    }

    @MainActor private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "DialFocus \(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func testTheLunchStickerGrowsIntoItsMealCardAndEditsInPlace() {
        let app = launch()
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        keep("meal 0 dial")
        dial.coordinate(withNormalizedOffset: offset(hour: 12.5, radius: 96)).tap()
        keep("meal 1 flight")
        let edit = element(app, "today-dial-focus-edit-meal")
        XCTAssertTrue(edit.waitForExistence(timeout: wait))
        Thread.sleep(forTimeInterval: 0.8)
        keep("meal 2 open")
        // Still Today: the card opened in place.
        XCTAssertTrue(element(app, "today-screen").exists)
        XCTAssertTrue(app.staticTexts["712 kcal"].exists)

        edit.tap()
        XCTAssertTrue(element(app, "food-review-metadata").waitForExistence(timeout: wait))
        keep("meal 3 editor")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(edit.waitForExistence(timeout: wait))

        let close = element(app, "today-dial-focus-close")
        XCTAssertTrue(close.waitForExistence(timeout: wait))
        close.tap()
        keep("meal 4 folding")
        XCTAssertTrue(edit.waitForNonExistence(timeout: wait))
        Thread.sleep(forTimeInterval: 0.5)
        keep("meal 5 closed")
    }

    @MainActor func testLastNightPeelsOffTheRingIntoSleepsStageChart() {
        let app = launch()
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        dial.coordinate(withNormalizedOffset: offset(hour: 3, radius: 120)).tap()
        keep("night 1 peel")
        keep("night 2 peel")
        let lanes = element(app, "today-dial-focus-stages-lanes")
        XCTAssertTrue(lanes.waitForExistence(timeout: wait))
        Thread.sleep(forTimeInterval: 1)
        keep("night 3 chart")
        XCTAssertTrue(element(app, "today-screen").exists)

        // Swiping the card down from its header folds the chart back into the ring.
        lanes.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: -1.2))
            .press(forDuration: 0.05, thenDragTo: lanes.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 4)))
        XCTAssertTrue(lanes.waitForNonExistence(timeout: wait))
        Thread.sleep(forTimeInterval: 0.6)
        keep("night 4 closed")
    }

    @MainActor func testAnEmptyStretchOfTheDialOpensNothing() {
        let app = launch()
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        // 17:00 on the rim, past everything the fixture logged.
        dial.coordinate(withNormalizedOffset: offset(hour: 17, radius: 150)).tap()
        XCTAssertFalse(element(app, "today-dial-focus-close").waitForExistence(timeout: 2))
    }
}
