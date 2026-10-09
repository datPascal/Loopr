import XCTest

/// The wake alarm and the Settings home screen, driven through the fixture
/// launch mode. The fixture alarm controller never reaches the band, AlarmKit,
/// or notifications, so these tests schedule nothing real.
final class WakeAlarmUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingAWakeAlarmFromTodayTakesAtMostThreeTaps() {
        let app = launch(fixture: "empty")
        var taps = 0

        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        tap(element(app, "today-wake-alarm-card"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))

        // The save button is pinned above the tab bar, so no scrolling.
        let save = element(app, "wake-alarm-save")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        taps += 1

        XCTAssertLessThanOrEqual(taps, 3, "Setting an alarm from Today took \(taps) taps")
        let toggle = app.switches["wake-alarm-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        let band = element(app, "wake-alarm-band-status")
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        let confirmed = NSPredicate(format: "label ==[c] %@", "Confirmed")
        expectation(for: confirmed, evaluatedWith: band)
        waitForExpectations(timeout: 10)

        // Back on Today the card shows the alarm instead of the prompt.
        app.navigationBars.buttons.firstMatch.tap()
        let card = element(app, "today-wake-alarm-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let showsTime = NSPredicate(format: "label CONTAINS[c] %@", "Wake alarm")
        expectation(for: showsTime, evaluatedWith: card)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(card.label.contains("Set a wake alarm"), "Card still offers to set an alarm: \(card.label)")
    }

    @MainActor
    func testSleepCardOpensTheWakeAlarm() {
        let app = launch(fixture: "set")
        let sleepTab = app.tabBars.buttons["Sleep"].firstMatch
        XCTAssertTrue(sleepTab.waitForExistence(timeout: 10))
        sleepTab.tap()
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 5))

        var taps = 0
        tap(element(app, "sleep-wake-alarm-card"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))
        XCTAssertEqual(taps, 1)
    }

    @MainActor
    func testTestBuzzIsDisabledAndExplainedWithoutABand() {
        let app = launch(fixture: "disconnected", deepLink: "today/wake-alarm")
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 10))
        let test = app.buttons["wake-alarm-test"].firstMatch
        scrollUntilHittable(test, in: app)
        XCTAssertFalse(test.isEnabled)
        XCTAssertTrue(app.staticTexts[
            "Connect your band to test the buzz. Loopr can only reach a band that is connected."
        ].exists)
        let band = element(app, "wake-alarm-band-status")
        XCTAssertEqual(band.label.lowercased(), "not connected")
    }

    @MainActor
    func testSettingsReachesTheWakeAlarmAndTheAdvancedRows() {
        let app = launch(fixture: "set")
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))

        var taps = 0
        tap(element(app, "settings-wake-alarm"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))

        tap(element(app, "settings-advanced"), in: app, counting: &taps)
        tap(element(app, "settings-diagnostics"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "data-diagnostics-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testTodayGoalCardAndSettingsOpenTheSameGoalsEditor() {
        let app = launch(fixture: "empty")
        var taps = 0
        tap(element(app, "today-goal-movement"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "goal-settings-screen").waitForExistence(timeout: 5))
        // The one editor carries all five goals, not just steps and strain.
        XCTAssertTrue(element(app, "settings-goal-sleep-target").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings-goal-steps-target").exists)
    }

    // MARK: Screenshots

    /// Writes the review screenshots when `LOOPR_CAPTURE_DIR` is set. Skipped
    /// otherwise, so the normal lane does not spend time on it.
    @MainActor
    func testCaptureWakeAlarmAndSettingsScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set LOOPR_CAPTURE_DIR to capture screenshots.")
        }
        let appearance = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "dark"

        for state in ["empty", "set", "confirmed", "unconfirmed", "disconnected"] {
            let app = launch(fixture: state, deepLink: "today/wake-alarm", visualCapture: true)
            XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 10))
            settle()
            save(app, "wake-alarm-\(state)-\(appearance)-top", to: directory)
            let layers = element(app, "wake-alarm-band-status")
            scrollUntilHittable(layers, in: app)
            settle()
            save(app, "wake-alarm-\(state)-\(appearance)-layers", to: directory)
            app.terminate()
        }

        let today = launch(fixture: "confirmed", visualCapture: true)
        let card = element(today, "today-wake-alarm-card")
        scrollUntilHittable(card, in: today)
        settle()
        save(today, "today-wake-card-\(appearance)", to: directory)
        today.terminate()

        let settings = launch(fixture: "confirmed", deepLink: "settings", visualCapture: true)
        XCTAssertTrue(element(settings, "settings-modal").waitForExistence(timeout: 10))
        settle()
        save(settings, "settings-home-\(appearance)-top", to: directory)
        let advanced = element(settings, "settings-advanced")
        scrollUntilHittable(advanced, in: settings)
        advanced.tap()
        settle()
        settings.swipeUp()
        settle()
        save(settings, "settings-home-\(appearance)-bottom", to: directory)
        settings.terminate()
    }

    // MARK: Helpers

    @MainActor
    private func launch(fixture: String, deepLink: String? = nil, visualCapture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["--loopr-launch-mode=populated", "--loopr-wake-alarm-fixture=\(fixture)"]
        if let deepLink { arguments.append("--loopr-deep-link=\(deepLink)") }
        if visualCapture {
            // Follows the simulator appearance instead of the dark fixture
            // override, and hides the status bar clock.
            arguments += ["--loopr-phase06-screen=wake-alarm", "--loopr-visual-capture"]
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication, counting taps: inout Int, file: StaticString = #filePath, line: UInt = #line) {
        scrollUntilHittable(target, in: app, file: file, line: line)
        target.tap()
        taps += 1
    }

    /// Swipes are scrolling, not taps, so they do not count toward the budget.
    /// The drag runs down the left gutter: a swipe through the middle of the
    /// wake alarm screen would spin the time wheel instead of scrolling.
    @MainActor
    private func scrollUntilHittable(_ target: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target) did not appear", file: file, line: line)
        for _ in 0..<10 {
            // Keep clear of the tab bar and the pinned save bar above it.
            let limit = app.frame.height * 0.72
            if target.isHittable, target.frame.midY < limit, target.frame.midY > 80 { return }
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.7))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.isHittable, "\(target) never became hittable", file: file, line: line)
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String, to directory: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }
}
