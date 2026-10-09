import XCTest

final class StressTimelineUITests: XCTestCase {
    @MainActor
    func testDayWithoutTimedReadingsHasNoTimelineCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["today-screen"].firstMatch.waitForExistence(timeout: 10))
        let stress = app.descendants(matching: .any)["today-metric-stress"].firstMatch
        XCTAssertTrue(stress.isHittable)
        stress.tap()

        XCTAssertTrue(app.descendants(matching: .any)["stress-screen"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["stress-day-timeline"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Through the day"].exists)
    }
}
