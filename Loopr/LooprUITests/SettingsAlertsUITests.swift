import XCTest

/// The Settings rows that the settings and monitors lanes both touched. After
/// the merge, Heart alerts opens the heart alerts screen and Notifications
/// opens the notification screen that links back to it. Nothing here asks
/// for notification permission or switches an alert on.
final class SettingsAlertsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHeartAlertsAndNotificationsRowsOpenTheirScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-wake-alarm-fixture=set"]
        app.launch()
        app.buttons["open-settings"].firstMatch.tap()
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))

        tapWhenHittable(element(app, "settings-heart-alerts"), in: app)
        XCTAssertTrue(element(app, "settings-destination-heartAlerts").waitForExistence(timeout: 5))
        // Every alert starts off, so a new build never buzzes at night.
        let high = element(app, "heart-alerts-high-toggle")
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        XCTAssertEqual(high.value as? String, "0")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))

        tapWhenHittable(element(app, "settings-notifications"), in: app)
        XCTAssertTrue(element(app, "settings-destination-notifications").waitForExistence(timeout: 5))
        tapWhenHittable(element(app, "settings-notification-heart-alerts"), in: app)
        XCTAssertTrue(element(app, "settings-destination-heartAlerts").waitForExistence(timeout: 5))
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
