import XCTest

/// Charts scrub only after a short hold, so a page scroll that starts on a
/// chart still scrolls (tabs spec, principle 7). Checked on a metric page,
/// where the trend chart covers most of the first screen.
final class ScrubGestureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQuickSwipeOnChartScrollsThePage() {
        let app = openMetricPage()
        let chart = element(app, "loopr-metric-trend-chart")
        let before = chart.frame.minY
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 0, dy: -260))
        start.press(forDuration: 0.02, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        settle(1)
        XCTAssertLessThan(chart.frame.minY, before - 40, "A quick swipe that starts on the chart should scroll the page")
    }

    @MainActor
    func testHoldThenDragScrubsAndKeepsThePageStill() {
        let app = openMetricPage()
        let chart = element(app, "loopr-metric-trend-chart")
        let before = chart.frame.minY
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 60, dy: -220))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        settle(1)
        XCTAssertEqual(chart.frame.minY, before, accuracy: 2, "Once scrubbing starts the page must hold still")
    }

    // MARK: Helpers

    @MainActor
    private func openMetricPage() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture"]
        app.launch()
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 15))
        let tab = app.tabBars.firstMatch.buttons["Heart"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let row = element(app, "heart-vital-rmssd")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<4 where !(row.isHittable && row.frame.maxY < app.tabBars.firstMatch.frame.minY - 8) {
            app.swipeUp()
        }
        row.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "loopr-metric-trend-chart").waitForExistence(timeout: 10))
        settle(1.5)
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
