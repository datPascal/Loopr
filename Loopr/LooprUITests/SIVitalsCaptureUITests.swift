import Foundation
import XCTest

final class SIVitalsCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(_ mode: String, today: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-metric-history-fixture", "--loopr-metric-range=month", "--loopr-si-vitals-fixture=\(mode)",
            "--loopr-deep-link=\(today ? "today" : "heart")"]
        if !today { app.launchArguments.append("--loopr-open-metric=skin_temperature_deviation") }
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func revealFully(_ app: XCUIApplication, _ target: XCUIElement, topInset: CGFloat = 100) {
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        let window = app.windows.firstMatch
        let bounds = window.frame
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : bounds.maxY - 34
        for _ in 0..<10 {
            let frame = target.frame
            if frame.minY >= topInset, frame.maxY <= bottom - 8 { break }
            let distance = frame.maxY > bottom - 8
                ? -min(frame.maxY - bottom + 60, bounds.height * 0.5)
                : min(topInset + 60 - frame.minY, bounds.height * 0.5)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-vitals-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testOvernightSettingsAndFlaggedAlert() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-si-vitals-fixture=outside", "--loopr-deep-link=settings/heart-alerts"]
        app.launch()
        XCTAssertTrue(element(app, "settings-destination-heartAlerts").waitForExistence(timeout: 30))
        let toggle = element(app, "heart-alerts-overnight-toggle")
        let explanation = element(app, "heart-alerts-overnight-explanation")
        revealFully(app, explanation, topInset: 200)
        XCTAssertTrue(explanation.isHittable)
        XCTAssertTrue(toggle.isHittable)
        capture("overnight-settings")
        app.terminate()
        app.launchArguments.append("--loopr-heart-alert=si-vitals-episode")
        app.launch()
        XCTAssertTrue(element(app, "heart-alert-detail").waitForExistence(timeout: 30))
        capture("overnight-alert")
    }

    @MainActor
    func testTemperatureStatesAndTodayFlag() {
        for mode in ["empty", "calibrating", "normal", "outside"] {
            let app = launch(mode)
            let target = element(app, mode == "empty" || mode == "calibrating" ? "metric-detail-empty" : "metric-detail-value")
            XCTAssertTrue(target.waitForExistence(timeout: 30))
            for _ in 0..<2 { app.swipeDown() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
            XCTAssertTrue(target.isHittable)
            if mode == "calibrating" { XCTAssertTrue(app.staticTexts["2 of 4 nights"].exists) }
            if mode == "normal" { XCTAssertTrue(app.staticTexts["Within your usual range"].exists) }
            if mode != "empty" { XCTAssertTrue(element(app, "metric-detail-temperature-approximate").exists) }
            if mode == "outside" { XCTAssertTrue(element(app, "metric-detail-usual-range").exists) }
            capture("temperature-\(mode)")
            if mode == "normal" || mode == "outside" {
                let chart = element(app, "metric-detail-trend")
                XCTAssertTrue(chart.exists)
                revealFully(app, chart)
                XCTAssertTrue(element(app, "metric-detail-trend-header").label.lowercased().contains("nights"))
                capture("temperature-\(mode)-chart")
            }
            app.terminate()
        }
        let app = launch("outside", today: true)
        let card = element(app, "today-heads-up")
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 30))
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        let recovery = element(app, "today-metric-recovery")
        XCTAssertTrue(recovery.isHittable)
        XCTAssertTrue(recovery.label.contains("9 bpm above your usual"))
        capture("today-flagged-recovery")
        revealFully(app, card)
        XCTAssertTrue(app.staticTexts["Three signals outside your usual range"].exists)
        capture("today-flagged")
    }
}
