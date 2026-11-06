import XCTest

/// Repeatable gestures for comparing scroll work in the same simulator and
/// build configuration. The five tab roots (Today, Food, Fitness, Protocol, Data), the Sleep, Heart
/// and Body screens pushed on Data, the metric detail and the method page each get one test. Run a single test at a time to keep other UI tests
/// from changing the simulator's workload during a sample.
final class ScrollPerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // The five tab roots, then the Health screens pushed on Data.
    @MainActor func testTodayRoot() { measureRoot("Today", id: "today-screen") }
    @MainActor func testFoodRoot() { measureRoot("Food", id: "food-screen") }
    @MainActor func testFitnessRoot() { measureRoot("Fitness", id: "workouts-screen") }
    @MainActor func testProtocolRoot() { measureRoot("Protocol", id: "journal-screen") }
    @MainActor func testDataRoot() { measureRoot("Data", id: "health-screen") }
    @MainActor func testSleepRoot() { measureRoot("Sleep", id: "sleep-screen") }
    @MainActor func testHeartRoot() { measureRoot("Heart", id: "heart-screen") }
    @MainActor func testBodyRoot() { measureRoot("Body", id: "body-screen") }

    @MainActor func testLiveTodayRoot() { measureRoot("Today", id: "today-screen", live: true) }
    @MainActor func testLiveFoodRoot() { measureRoot("Food", id: "food-screen", live: true) }
    @MainActor func testLiveFitnessRoot() { measureRoot("Fitness", id: "workouts-screen", live: true) }
    @MainActor func testLiveProtocolRoot() { measureRoot("Protocol", id: "journal-screen", live: true) }
    @MainActor func testLiveDataRoot() { measureRoot("Data", id: "health-screen", live: true) }
    @MainActor func testLiveSleepRoot() { measureRoot("Sleep", id: "sleep-screen", live: true) }
    @MainActor func testLiveHeartRoot() { measureRoot("Heart", id: "heart-screen", live: true) }
    @MainActor func testLiveBodyRoot() { measureRoot("Body", id: "body-screen", live: true) }

    @MainActor
    func testMetricDetail() {
        let app = launch(extra: ["--loopr-metric-history-fixture"])
        selectTab(app, "Data", id: "health-screen")
        open(app, identifier: "health-tile-rmssd", id: "metric-detail-screen")
        measureScroll(app, id: "metric-detail-screen")
    }

    @MainActor
    func testLiveMetricDetail() {
        let app = launch(extra: ["--loopr-performance-live", "--loopr-metric-history-fixture"])
        selectTab(app, "Data", id: "health-screen")
        open(app, identifier: "health-tile-rmssd", id: "metric-detail-screen")
        measureScroll(app, id: "metric-detail-screen")
    }

    @MainActor
    func testMethodPage() {
        let app = launchMethod()
        measureScroll(app, id: "method-screen")
    }

    @MainActor
    func testLiveMethodPage() {
        let app = launchMethod(extra: ["--loopr-performance-live"])
        measureScroll(app, id: "method-screen")
    }

    @MainActor
    func testSleepTrends() {
        let app = launch()
        selectTab(app, "Sleep", id: "sleep-screen")
        // Sleep opens on the night; its range picker shows the trends on the same page.
        open(app, identifier: "sleep-scope-month", id: "sleep-trends-screen")
        measureScroll(app, id: "sleep-trends-screen")
    }

    @MainActor
    func testLiveSleepTrends() {
        let app = launch(extra: ["--loopr-performance-live"])
        selectTab(app, "Sleep", id: "sleep-screen")
        // Sleep opens on the night; its range picker shows the trends on the same page.
        open(app, identifier: "sleep-scope-month", id: "sleep-trends-screen")
        measureScroll(app, id: "sleep-trends-screen")
    }

    @MainActor
    func testHeartTrends() {
        let app = launch(extra: ["--loopr-deep-link=phase06/heart-trends"])
        XCTAssertTrue(element(app, "heart-trends-screen").waitForExistence(timeout: 15))
        measureScroll(app, id: "heart-trends-screen")
    }

    @MainActor
    func testLiveHeartTrends() {
        let app = launch(extra: ["--loopr-performance-live", "--loopr-deep-link=phase06/heart-trends"])
        XCTAssertTrue(element(app, "heart-trends-screen").waitForExistence(timeout: 15))
        measureScroll(app, id: "heart-trends-screen")
    }

    @MainActor
    func testRecoveryBreakdown() {
        let app = launch()
        open(app, identifier: "today-metric-recovery", id: "today-recovery-breakdown-screen")
        measureScroll(app, id: "today-recovery-breakdown-screen")
    }

    @MainActor
    func testLiveRecoveryBreakdown() {
        let app = launch(extra: ["--loopr-performance-live"])
        open(app, identifier: "today-metric-recovery", id: "today-recovery-breakdown-screen")
        measureScroll(app, id: "today-recovery-breakdown-screen")
    }

    @MainActor
    func testStressDetail() {
        let app = launch(extra: ["--loopr-deep-link=today/stress"])
        XCTAssertTrue(app.descendants(matching: .any)["stress-screen"].firstMatch.waitForExistence(timeout: 30))
        measureScroll(app, id: "stress-screen")
    }

    @MainActor
    func testLiveStressDetail() {
        let app = launch(extra: ["--loopr-performance-live", "--loopr-deep-link=today/stress"])
        XCTAssertTrue(app.descendants(matching: .any)["stress-screen"].firstMatch.waitForExistence(timeout: 30))
        measureScroll(app, id: "stress-screen")
    }

    @MainActor
    func testHeartLiveScreen() {
        let app = launch()
        selectTab(app, "Heart", id: "heart-screen")
        open(app, identifier: "heart-live-card", id: "heart-live-screen")
        measureScroll(app, id: "heart-live-screen")
    }

    @MainActor
    func testLiveHeartLiveScreen() {
        let app = launch(extra: ["--loopr-performance-live"])
        selectTab(app, "Heart", id: "heart-screen")
        open(app, identifier: "heart-live-card", id: "heart-live-screen")
        measureScroll(app, id: "heart-live-screen")
    }

    @MainActor
    func testSwitchTabsAndDay() {
        let app = launch()
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            for (tab, id) in [("Food", "food-screen"), ("Fitness", "workouts-screen"),
                              ("Protocol", "journal-screen"), ("Data", "health-screen"),
                              ("Today", "today-screen")] {
                selectTab(app, tab, id: id)
            }
            let navigator = element(app, "day-navigator")
            XCTAssertTrue(navigator.waitForExistence(timeout: 5))
            navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 5))
            navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func measureRoot(_ tab: String, id: String, live: Bool = false) {
        let app = launch(extra: live ? ["--loopr-performance-live"] : [])
        selectTab(app, tab, id: id)
        measureScroll(app, id: id)
    }

    @MainActor
    private func measureScroll(_ app: XCUIApplication, id: String) {
        let root = element(app, id)
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let scroll = root.scrollViews.firstMatch.exists ? root.scrollViews.firstMatch : root
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        // A live refresh or a short chart can leave a scroll signpost out of
        // one iteration. CPU time still covers the same fixed gestures.
        let cpuOnly = app.launchArguments.contains("--loopr-performance-live")
            || id == "heart-live-screen" || id == "stress-screen" || id == "metric-detail-screen"
        let metrics: [any XCTMetric] = cpuOnly
            ? [XCTCPUMetric(application: app)]
            : [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)]
        measure(metrics: metrics, options: options) {
            for _ in 0..<4 { drag(scroll, from: 0.82, to: 0.18) }
            for _ in 0..<4 { drag(scroll, from: 0.18, to: 0.82) }
        }
    }

    @MainActor
    private func drag(_ element: XCUIElement, from start: CGFloat, to end: CGFloat) {
        let source = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
        let target = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end))
        source.press(forDuration: 0.05, thenDragTo: target)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The entrance has its own suite (`EntrancePerformanceUITests`). Here it shows its final
        // state, so a first-visit animation never lands inside a scroll sample.
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state",
                               "-AppleInterfaceStyle", "Dark"] + extra
        app.launch()
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 15))
        return app
    }

    /// The PhenoAge method page, which opens on Data's stack from the DEBUG `--loopr-method=` argument.
    @MainActor
    private func launchMethod(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state",
                               "-AppleInterfaceStyle", "Dark", "--loopr-your-data-fixture",
                               "--loopr-method=phenoage", "--loopr-method-fixture"] + extra
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "method-screen").waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ name: String, id: String) {
        // Sleep, Heart and Body are pushed on Data.
        if ["Sleep", "Heart", "Body"].contains(name) { _ = app.openLooprArea(name); return }

        let button = app.tabBars.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 10))
    }

    @MainActor
    private func open(_ app: XCUIApplication, label: String, id: String) {
        let target = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 10))
    }

    @MainActor
    private func open(_ app: XCUIApplication, identifier: String, id: String) {
        let target = element(app, identifier)
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 10))
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
