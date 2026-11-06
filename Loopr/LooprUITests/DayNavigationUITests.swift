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
        // Header labels are sentence case since build 18; match without case.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "YESTERDAY · MON 13 NOV")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.value as? String, "Yesterday, Monday 13 November")
        XCTAssertTrue(element(app, "day-navigator-today").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-more").waitForExistence(timeout: 5))

        // The day follows to Health, and into Sleep, whose header names that day's night.
        selectTab(app, "Data", root: "health-screen")
        XCTAssertEqual(element(app, "day-navigator").value as? String, "Yesterday, Monday 13 November")
        // Sleep opens under Health on that same day; its title bar names only the screen.
        XCTAssertTrue(app.openLooprArea("Sleep"))
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 5))

        // One more day back, on Today, is a day with nothing recorded. Health keeps its layout with empty readings.
        selectTab(app, "Today", root: "today-screen")
        tap(element(app, "day-navigator"), previous: true)
        XCTAssertTrue(element(app, "day-empty-state").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "day-empty-show-latest").exists)
        XCTAssertTrue(app.staticTexts["No band data on Sun 12 Nov"].exists)

        // The Today pill jumps back and disappears.
        element(app, "day-navigator-today").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "TUE 14 NOV")).firstMatch.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "SAT 11 NOV")).firstMatch.exists)
    }

    @MainActor
    func testASidewaysFlickChangesTheDayWithoutOpeningARow() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: 10))
        // Today changes the day with a sideways flick. Pushed screens such as Heart keep the system back swipe.
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        // The flick starts over Today's rows, which open other screens when tapped.
        element(app, "today-screen").swipeRight(velocity: .fast)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "YESTERDAY · MON 13 NOV")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "metric-detail-screen").exists)
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
        element(app, "today-screen").swipeLeft(velocity: .fast)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "TUE 14 NOV")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testHeaderKeepsTheSyncAgeAndDayControlsAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()

        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let sync = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synced 2 min ago")).firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        let date = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "TUE 14 NOV")).firstMatch
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
        if ["Sleep", "Heart", "Body", "Workouts"].contains(tab) { _ = app.openLooprArea(tab); return }

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
