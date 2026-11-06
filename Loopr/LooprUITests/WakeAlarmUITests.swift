import XCTest

/// The wake alarm and the Settings home screen, driven through the fixture
/// launch mode. The fixture alarm controller never reaches the band, AlarmKit,
/// or notifications, so these tests schedule nothing real.
final class WakeAlarmUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingAWakeAlarmFromTodayTakesAtMostFourTaps() {
        // The card left Today in FT-05.5, and Your day left in the UX simplification (2026-11-01). The shortest real
        // path from Today is "More from today" (1), the Bedtime row on the timeline (2), the Smart alarm row on Sleep (3)
        // and Save (4). An alarm that is on has its own timeline row, one tap from the open fold.
        let app = launch(fixture: "empty")
        var taps = 0

        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        tap(element(app, "today-more"), in: app, counting: &taps)
        tap(element(app, "today-timeline-bedtime"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 10))
        tap(element(app, "sleep-wake-alarm-card"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))

        // The save button is pinned above the tab bar, so no scrolling.
        let save = element(app, "wake-alarm-save")
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        taps += 1

        XCTAssertLessThanOrEqual(taps, 4, "Setting an alarm from Today took \(taps) taps")
        let toggle = app.switches["wake-alarm-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        let band = element(app, "wake-alarm-band-status")
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        let confirmed = NSPredicate(format: "label ==[c] %@", "Confirmed")
        expectation(for: confirmed, evaluatedWith: band)
        waitForExpectations(timeout: 10)

        // Back on Sleep the card shows the alarm instead of the prompt.
        app.navigationBars.buttons.firstMatch.tap()
        let card = element(app, "sleep-wake-alarm-card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let showsTime = NSPredicate(format: "label CONTAINS[c] %@", "Wake alarm")
        expectation(for: showsTime, evaluatedWith: card)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(card.label.contains("Set a wake alarm"), "Card still offers to set an alarm: \(card.label)")
    }

    @MainActor
    func testSleepCardOpensTheWakeAlarm() {
        let app = launch(fixture: "set")
        XCTAssertTrue(app.openLooprArea("Sleep"))
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 5))

        var taps = 0
        tap(element(app, "sleep-wake-alarm-card"), in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))
        XCTAssertEqual(taps, 1)
    }

    @MainActor
    func testTheAlarmRowOnTodaysTimelineOpensTheWakeAlarmInOneTap() {
        let app = launch(fixture: "set")
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let row = element(app, "today-timeline-alarm")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "an alarm that is on shows on Today's timeline")
        XCTAssertTrue(row.label.contains("Smart alarm"), row.label)

        var taps = 0
        tap(row, in: app, counting: &taps)
        XCTAssertTrue(element(app, "wake-alarm-hero").waitForExistence(timeout: 5))
        XCTAssertEqual(taps, 1, "Today to the alarm is one tap")
        XCTAssertFalse(element(app, "sleep-screen").exists, "the row skips Sleep")
    }

    @MainActor
    func testNoAlarmRowWhenTheAlarmIsOffOrTheDayIsPast() {
        let off = launch(fixture: "empty")
        XCTAssertTrue(element(off, "today-timeline-header").waitForExistence(timeout: 10))
        XCTAssertFalse(element(off, "today-timeline-alarm").exists, "no alarm, no row")
        off.terminate()

        let app = launch(fixture: "set")
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "today-timeline-alarm").waitForExistence(timeout: 10))
        navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "day-navigator-today").waitForExistence(timeout: 5), "now on a past day")
        XCTAssertTrue(element(app, "today-more").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "today-timeline-end").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "today-timeline-alarm").exists, "a past day shows no alarm row")
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
        // The avatar opens Your data since FT-01, so the Settings home opens through its route.
        let app = launch(fixture: "set", deepLink: "settings")
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 15))

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
    func testTheGoalsRouteOpensTheGoalsEditorWithAllFiveGoals() {
        // Today no longer has a Goals card (FT-05.5). A goals notification and this route still open the editor.
        let app = launch(fixture: "empty", deepLink: "today/goals")
        XCTAssertTrue(element(app, "goal-settings-screen").waitForExistence(timeout: 10))
        // The one editor carries all five goals, not just steps and strain.
        XCTAssertTrue(element(app, "settings-goal-sleep-target").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings-goal-steps-target").exists)
    }

    // MARK: Screenshots

    /// Writes the review screenshots to `LOOPR_CAPTURE_DIR`, or to a temporary folder in other lanes, which still check
    /// that every screen opens. The full lane allows no skipped tests.
    @MainActor
    func testCaptureWakeAlarmAndSettingsScreens() throws {
        let configured = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_DIR"] ?? ""
        let directory = configured.isEmpty
            ? FileManager.default.temporaryDirectory.appendingPathComponent("loopr-wake-alarm-capture", isDirectory: true).path
            : configured
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

        let sleep = launch(fixture: "confirmed", visualCapture: true)
        XCTAssertTrue(sleep.openLooprArea("Sleep"))
        let card = element(sleep, "sleep-wake-alarm-card")
        scrollUntilHittable(card, in: sleep)
        settle()
        save(sleep, "sleep-wake-card-\(appearance)", to: directory)
        sleep.terminate()

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
        // The timeline sits in "More from today"; only the four-tap test opens it by hand.
        if name.contains("FourTaps") == false { arguments += ["-loopr-open-folds", "YES"] }
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
