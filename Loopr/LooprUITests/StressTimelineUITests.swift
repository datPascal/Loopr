import XCTest

final class StressTimelineUITests: XCTestCase {
    @MainActor
    func testDayWithoutTimedReadingsHasNoTimelineCard() {
        let app = XCUIApplication()
        // Today no longer has a Stress ring (FT-05.5), so the stress route opens the screen.
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=today/stress"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["stress-screen"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["stress-day-timeline"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Through the day"].exists)
    }
}
