import XCTest

/// The bedtime Live Activity (DEC-12.17) from Settings: off by default, on after the toggle and Save, one step ticked
/// updates it, off ends it. The app runs on a fixture clock at 19:49 with fixture evening rules
/// (`LOOPR_BEDTIME_PROBE`, debug builds). A small overlay reports
/// `Activity<LooprBedtimeActivityAttributes>.activities.count` as "activities=N done=M", so the test reads the real
/// ActivityKit state. Run it on a stock worker: slim workers turn off Live Activities, and then the count stays 0.
final class BedtimeLiveActivityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testToggleStartsUpdatesAndEndsTheBedtimeActivity() throws {
        let app = launch()
        let count = element(app, "bedtime-activity-count")
        XCTAssertTrue(count.waitForExistence(timeout: 30), "The probe overlay did not appear")
        XCTAssertTrue(label(count, contains: "activities=0"), "The activity must be off until the person turns it on")

        XCTAssertTrue(app.openLooprSettings(), "Settings did not open")
        openWidgetsAndWatch(app)
        let toggle = element(app, "settings-bedtime-live-activity")
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Bedtime on the lock screen is off by default")

        flip(toggle)
        save(app)
        XCTAssertTrue(label(count, contains: "activities=1"), "Turning it on inside the window starts the activity")
        XCTAssertTrue(label(count, contains: "done=1"), "The kept kitchen rule is the first done step")

        let tick = element(app, "bedtime-activity-tick")
        XCTAssertTrue(tick.waitForExistence(timeout: 5))
        tick.tap()
        XCTAssertTrue(label(count, contains: "done=2"), "Checking the next rule updates the running activity")
        XCTAssertTrue(label(count, contains: "activities=1"), "An update does not start a second activity")

        scrollTo(toggle, in: app)
        flip(toggle)
        save(app)
        XCTAssertTrue(label(count, contains: "activities=0"), "Turning it off ends the activity")
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-your-data-fixture",
                               "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launchEnvironment["LOOPR_BEDTIME_PROBE"] = "19:49"
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func openWidgetsAndWatch(_ app: XCUIApplication) {
        let row = element(app, "settings-privacy")
        scrollTo(row, in: app)
        row.tap()
        XCTAssertTrue(element(app, "settings-bedtime-live-activity").waitForExistence(timeout: 15),
                      "The Widgets and Watch page has no bedtime toggle")
    }

    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target) did not appear")
        for _ in 0..<8 where !(target.isHittable && target.frame.midY < app.frame.height * 0.85) {
            app.swipeUp()
        }
    }

    /// The row's switch sits at its trailing edge.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func save(_ app: XCUIApplication) {
        let button = element(app, "settings-save")
        scrollTo(button, in: app)
        button.tap()
    }

    @MainActor
    private func label(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 25) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
