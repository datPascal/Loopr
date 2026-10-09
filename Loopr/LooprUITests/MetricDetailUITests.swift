import XCTest

/// Opens Heart Detail and metric detail pages with the Debug-only fixture
/// history, and attaches screenshots for design review.
final class MetricDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHeartDetailCardsOpenMetricPages() {
        let app = launch()
        selectTab(app, "Heart", root: "heart-screen")
        XCTAssertTrue(element(app, "heart-vitals-section").waitForExistence(timeout: 10))
        capture(app, "heart-overnight-vitals")
        tapWhenHittable(element(app, "heart-vital-rmssd"), in: app)
        assertMetricPage(app)
        captureScrolled(app, "metric-rmssd")
        goBack(app, to: "heart-screen")
        tapWhenHittable(element(app, "heart-vital-resting_heart_rate"), in: app)
        assertMetricPage(app)
        XCTAssertTrue(element(app, "metric-detail-status").waitForExistence(timeout: 5))
        captureScrolled(app, "metric-resting-heart-rate")

        tapWhenHittable(element(app, "metric-detail-trend-range-week"), in: app)
        settle()
        capture(app, "metric-resting-heart-rate-7d")
        tapWhenHittable(element(app, "metric-detail-trend-range-year"), in: app)
        settle()
        capture(app, "metric-resting-heart-rate-1y")
    }

    @MainActor
    func testHeartListRowOpensMetricPage() {
        let app = launch()
        selectTab(app, "Heart", root: "heart-screen")
        tapWhenHittable(element(app, "heart-advanced-disclosure"), in: app)
        tapWhenHittable(element(app, "heart-metric-sdnn"), in: app)
        assertMetricPage(app)
        captureScrolled(app, "metric-sdnn")
        goBack(app, to: "heart-screen")

        XCTAssertTrue(element(app, "heart-vitals-section").exists)
        XCTAssertFalse(element(app, "heart-trends-route").exists)
        capture(app, "heart-single-history-home")
    }

    @MainActor
    func testSleepRecoveryAndBodyOpenMetricPages() {
        let app = launch()

        selectTab(app, "Sleep", root: "sleep-screen")
        tapWhenHittable(element(app, "sleep-metric-duration"), in: app)
        assertMetricPage(app)
        captureScrolled(app, "metric-sleep-duration")

        // The recovery hero opens its breakdown first (Today redesign); the
        // recovery page is one tap further, from "Recovery history".
        selectTab(app, "Today", root: "today-screen")
        tapWhenHittable(element(app, "today-metric-recovery"), in: app)
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: 10))
        tapWhenHittable(element(app, "today-breakdown-recovery-metric"), in: app)
        assertMetricPage(app)
        captureScrolled(app, "metric-recovery")

        selectTab(app, "Body", root: "body-screen")
        tapWhenHittable(element(app, "body-strain-lens"), in: app)
        assertMetricPage(app)
        captureScrolled(app, "metric-strain")
    }

    /// A tab card zooms into its page; going back shrinks the page into the
    /// card and leaves the tab where it was.
    @MainActor
    func testZoomedPageReturnsToItsTab() {
        let app = launch()
        selectTab(app, "Sleep", root: "sleep-screen")
        tapWhenHittable(element(app, "sleep-metric-duration"), in: app)
        assertMetricPage(app)
        goBack(app, to: "sleep-screen")
        XCTAssertTrue(element(app, "sleep-metric-duration").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "metric-detail-screen").exists)
    }

    @MainActor
    func testMetricWithoutHistoryShowsHonestEmptyState() {
        let app = launch(extra: ["--loopr-metric-detail-empty-probe"])
        selectTab(app, "Heart", root: "heart-screen")
        tapWhenHittable(element(app, "heart-advanced-disclosure"), in: app)
        let dip = element(app, "heart-metric-heartRateDip")
        XCTAssertTrue(dip.waitForExistence(timeout: 5))
        tapWhenHittable(dip, in: app)
        XCTAssertTrue(element(app, "metric-detail-empty").waitForExistence(timeout: 10))
        capture(app, "metric-heart-rate-dip-empty")
    }

    // MARK: Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--loopr-launch-mode=populated",
            "--loopr-metric-history-fixture",
            "--loopr-appearance=dark",
            "-AppleInterfaceStyle", "Dark"
        ] + extra
        app.launch()
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func assertMetricPage(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10), "Metric detail did not open")
        XCTAssertTrue(element(app, "metric-detail-hero").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "metric-detail-trend").waitForExistence(timeout: 10), "Trend chart missing")
        settle()
    }

    @MainActor
    private func captureScrolled(_ app: XCUIApplication, _ name: String) {
        capture(app, name + "-1")
        let scroll = element(app, "metric-detail-screen")
        for page in 2...5 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            start.press(forDuration: 0.05, thenDragTo: end)
            settle(0.8)
            capture(app, name + "-\(page)")
        }
        for _ in 0..<5 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        settle(0.5)
    }

    @MainActor
    private func goBack(_ app: XCUIApplication, to identifier: String) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5), "Did not return to \(identifier)")
        settle(0.5)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ tab: String, root identifier: String) {
        for _ in 0..<6 {
            let tabButton = app.tabBars.firstMatch.buttons[tab].firstMatch
            if tabButton.waitForExistence(timeout: 3), tabButton.isHittable {
                tabButton.tap()
                if element(app, identifier).waitForExistence(timeout: 5) { return }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        XCTFail("Could not select \(tab) and reach \(identifier)")
    }

    @MainActor
    private func tapWhenHittable(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "Element \(target.identifier) did not appear")
        for _ in 0..<6 {
            let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            if target.isHittable, target.frame.midY < tabBarTop - 8, target.frame.minY > 90 {
                target.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Element \(target.identifier) is not hittable")
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
