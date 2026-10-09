import XCTest

/// The shared day: stepping back on one tab moves every day tab, past days
/// read with their own labels, a gap day says so plainly, and the Today pill
/// comes back. Runs on the populated fixture, which carries the fixture day,
/// the day before, an empty day, and one more day with data.
final class DayNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSteppingBackADayIsSharedByTheDayTabsAndTodayReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()

        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.value as? String, "Today, Tuesday 14 November")
        XCTAssertFalse(element(app, "day-navigator-today").exists)

        // Previous day. The title stays "Today"; the meta line names the day.
        tap(navigator, previous: true)
        XCTAssertTrue(app.staticTexts["YESTERDAY · MON 13 NOV"].waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.value as? String, "Yesterday, Monday 13 November")
        XCTAssertTrue(element(app, "day-navigator-today").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-goals").waitForExistence(timeout: 5))

        // The day follows to Sleep, with that day's night in the header.
        selectTab(app, "Sleep", root: "sleep-screen")
        XCTAssertTrue(app.staticTexts["SUN 12 → MON 13 NOV"].waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "day-navigator").value as? String, "Yesterday, Monday 13 November")

        // One more day back is a day with nothing recorded.
        tap(element(app, "day-navigator"), previous: true)
        XCTAssertTrue(element(app, "day-empty-state").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "day-empty-show-latest").exists)
        XCTAssertTrue(app.staticTexts["Nothing recorded on Sun 12 Nov"].exists)

        selectTab(app, "Heart", root: "heart-screen")
        XCTAssertTrue(element(app, "day-empty-state").waitForExistence(timeout: 5))

        // The Today pill jumps back and disappears.
        element(app, "day-navigator-today").tap()
        XCTAssertTrue(app.staticTexts["TUE 14 NOV"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "day-navigator-today").exists)
        selectTab(app, "Today", root: "today-screen")
        XCTAssertEqual(element(app, "day-navigator").value as? String, "Today, Tuesday 14 November")
    }

    @MainActor
    func testTheNavigatorStopsAtTheEarliestRecordedDay() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: 10))
        for _ in 0..<6 { tap(navigator, previous: true) }
        // The earliest fixture day is three days back; further taps stay there.
        XCTAssertEqual(navigator.value as? String, "Saturday 11 November")
        XCTAssertTrue(app.staticTexts["SAT 11 NOV"].exists)
    }

    @MainActor
    func testASidewaysFlickChangesTheDayWithoutOpeningARow() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: 10))
        selectTab(app, "Heart", root: "heart-screen")
        // The flick starts over the metric list, whose rows open detail pages.
        element(app, "heart-screen").swipeRight(velocity: .fast)
        XCTAssertTrue(app.staticTexts["YESTERDAY · MON 13 NOV"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "metric-detail-screen").exists)
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
        element(app, "heart-screen").swipeLeft(velocity: .fast)
        XCTAssertTrue(app.staticTexts["TUE 14 NOV"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHeaderKeepsTheSyncAgeAndDayControlsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()

        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let sync = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SYNCED 2 MIN AGO")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        let date = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "TUE 14 NOV")).firstMatch
        XCTAssertTrue(date.exists)
        XCTAssertTrue(element(app, "day-navigator").isHittable)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
    }

    @MainActor
    private func tap(_ navigator: XCUIElement, previous: Bool) {
        navigator.coordinate(withNormalizedOffset: CGVector(dx: previous ? 0.25 : 0.75, dy: 0.5)).tap()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ tab: String, root identifier: String) {
        for _ in 0..<4 {
            let button = app.tabBars.firstMatch.buttons[tab].firstMatch
            if button.waitForExistence(timeout: 3), button.isHittable {
                button.tap()
                if element(app, identifier).waitForExistence(timeout: 5) { return }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        XCTFail("Could not open \(tab)")
    }
}
