import XCTest

/// Notifications, reached from Your data: its link to Heart alerts and the
/// "Reminders you set" section. Nothing here asks for notification permission
/// or switches an alert on.
final class SettingsAlertsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Notifications links to Heart alerts, and every alert starts off, so a new build never buzzes at night.
    @MainActor
    func testHeartAlertsAndNotificationsRowsOpenTheirScreens() {
        let app = launch()
        openNotifications(app)
        tapWhenHittable(element(app, "settings-notification-heart-alerts"), in: app)
        XCTAssertTrue(element(app, "settings-destination-heartAlerts").waitForExistence(timeout: 10))
        let high = element(app, "heart-alerts-high-toggle")
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        XCTAssertEqual(high.value as? String, "0")
    }

    /// DEC-07 line 1. "Reminders you set" is its own section: a switch that starts on, the reminders that wait, and the
    /// history of what was scheduled. A fresh install has none waiting. Nothing here asks for permission.
    @MainActor
    func testNotificationsListsRemindersYouSetWithItsSwitchAndHistory() {
        let app = launch()
        openNotifications(app)

        let toggle = element(app, "settings-notification-userReminders")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "the family is on by default")
        XCTAssertTrue(element(app, "settings-reminders-empty").waitForExistence(timeout: 5))
        let history = element(app, "settings-reminders-history")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
    }

    /// A fixture list with one Ask reminder and one Patterns test reminder. Cancel removes only that row. With
    /// `LOOPR_CAPTURE_DIR` set it also saves a capture of the list in the simulator's appearance.
    @MainActor
    func testRemindersYouSetListsEachReminderAndCancelsOne() {
        let directory = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        // The runner sets the simulator's appearance and names it here; one run captures one appearance.
        let appearance = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "system"
        do {
            let app = launch(["--loopr-reminders-fixture"])
            openNotifications(app)
            let ask = element(app, "settings-reminder-ask.fixture-wind-down")
            let test = element(app, "settings-reminder-patterns.fixture-late-dinner")
            XCTAssertTrue(ask.waitForExistence(timeout: 10), "the Ask reminder is listed")
            XCTAssertTrue(test.exists, "the Patterns test reminder is listed")
            XCTAssertFalse(element(app, "settings-reminders-empty").exists)
            XCTAssertTrue(ask.label.contains("Wind down") && ask.label.contains("Every day") && ask.label.contains("Ask"), ask.label)
            XCTAssertTrue(test.label.contains("Patterns test"), test.label)
            if let directory {
                // The list sits under quiet hours; drag the first reminder up to just below the title.
                ask.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)))
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
                let screenshot = app.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "settings-reminders-you-set-\(appearance)"; attachment.lifetime = .keepAlways
                add(attachment)
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-reminders-you-set-\(appearance).png"))
            }
            element(app, "settings-reminder-cancel-ask.fixture-wind-down").tap()
            XCTAssertFalse(ask.waitForExistence(timeout: 2), "Cancel removes the Ask reminder")
            XCTAssertTrue(element(app, "settings-reminder-patterns.fixture-late-dinner").exists, "the other reminder stays")
            app.terminate()
        }
    }

    /// A fixture launch that waits until the fixture has loaded, as the five-tab tests do. Taps before then land on
    /// the loading overlay.
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-your-data-fixture",
                               "--loopr-wake-alarm-fixture=set", "--loopr-appearance=system",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    /// The avatar opens Your data; its "Reminders you set" row opens Notifications.
    @MainActor
    private func openNotifications(_ app: XCUIApplication) {
        let avatar = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20))
        avatar.tap()
        XCTAssertTrue(element(app, "your-data-screen").waitForExistence(timeout: 20))
        tapWhenHittable(element(app, "your-data-reminders"), in: app)
        XCTAssertTrue(element(app, "settings-destination-notifications").waitForExistence(timeout: 15))
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tapWhenHittable(_ target: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target) did not appear", file: file, line: line)
        for _ in 0..<8 {
            if target.isHittable, target.frame.midY < app.frame.height * 0.85, target.frame.midY > 80 {
                target.tap()
                return
            }
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)))
        }
        XCTFail("\(target) never became hittable", file: file, line: line)
    }
}
