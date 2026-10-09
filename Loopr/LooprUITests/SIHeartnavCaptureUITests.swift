import XCTest

final class SIHeartnavCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHeartStates() {
        for state in ["normal", "flagged", "learning", "empty"] {
            let app = launch(state: state, link: "heart")
            let vitals = element(app, "heart-vitals-section")
            XCTAssertTrue(vitals.waitForExistence(timeout: 20))
            XCTAssertTrue(app.tabBars.buttons["Heart"].isSelected)
            XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
            capture("heart-top-\(state)")
            let temperature = element(app, "heart-vital-skin_temperature_deviation")
            reveal(app, temperature)
            XCTAssertTrue(temperature.isHittable)
            if state == "normal" {
                XCTAssertTrue(app.staticTexts["All within your usual range"].exists)
                XCTAssertEqual(temperature.label, "Skin temperature, +0.2 degrees Celsius, vs usual")
                XCTAssertTrue(element(app, "heart-vital-resting_heart_rate").label.contains("Same as usual"))
                XCTAssertTrue(element(app, "heart-vital-respiratory_rate").label.contains("Same as usual"))
            }
            if state == "flagged" {
                XCTAssertTrue(app.staticTexts["2 signals outside your usual range"].exists)
                XCTAssertEqual(temperature.label, "Skin temperature, ±0.0 degrees Celsius, vs usual")
            }
            if state == "learning" {
                XCTAssertTrue(app.staticTexts["2 of 4 nights"].exists)
                XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "2 of 14 nights")).count, 3)
                for id in ["resting_heart_rate", "rmssd", "respiratory_rate", "skin_temperature_deviation"] {
                    XCTAssertFalse(element(app, "heart-vital-\(id)").label.contains("vs usual"))
                }
                XCTAssertFalse(app.staticTexts["Usual range appears after 14 nights"].exists)
            }
            if state == "empty" {
                XCTAssertTrue(app.staticTexts["No overnight readings"].exists)
                XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Wear your band overnight and sync in the morning.")).count, 1)
                XCTAssertFalse(app.staticTexts["Each signal needs 14 nights with a reading for its usual range."].exists)
                for id in ["resting_heart_rate", "rmssd", "respiratory_rate", "skin_temperature_deviation"] {
                    XCTAssertTrue(element(app, "heart-vital-\(id)").label.hasSuffix("No reading"))
                }
            }
            capture("vitals-\(state)")
            app.terminate()
        }
    }

    @MainActor
    func testAdvancedAndMetricDetail() {
        let app = launch(state: "normal", link: "heart")
        let hrv = element(app, "heart-vital-rmssd")
        XCTAssertTrue(hrv.waitForExistence(timeout: 20))
        reveal(app, hrv)
        hrv.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "metric-detail-trend").waitForExistence(timeout: 10))
        capture("metric-detail-from-vitals")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "heart-screen").waitForExistence(timeout: 10))
        let timeline = element(app, "heart-day-timeline")
        reveal(app, timeline)
        capture("heart-rate-through-day")
        let advanced = element(app, "heart-advanced-disclosure")
        reveal(app, advanced)
        advanced.tap()
        let sdnn = element(app, "heart-metric-sdnn")
        reveal(app, sdnn)
        XCTAssertTrue(sdnn.isHittable)
        reveal(app, app.staticTexts["How far your average heart rate fell during sleep compared with waking hours."].firstMatch)
        capture("advanced-readings")
        let poincare = element(app, "heart-beat-poincare")
        reveal(app, poincare)
        XCTAssertTrue(poincare.exists)
        capture("advanced-beat-plot")
        let tachogram = element(app, "heart-beat-tachogram")
        reveal(app, tachogram)
        XCTAssertTrue(tachogram.exists)
        capture("advanced-beat-through-night")
        let stress = element(app, "heart-stress-route")
        reveal(app, stress)
        capture("stress-entry-on-heart")
        stress.tap()
        XCTAssertTrue(element(app, "stress-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Heart"].isSelected)
        capture("stress-from-heart")
    }

    @MainActor
    func testLargeTextWithReduceMotion() {
        let app = launch(state: "flagged", link: "heart", extra: ["--loopr-si-heartnav-large-text"])
        XCTAssertTrue(element(app, "heart-vitals-section").waitForExistence(timeout: 20))
        capture("heart-large-text-top")
        let hrv = element(app, "heart-vital-rmssd")
        reveal(app, hrv)
        XCTAssertTrue(hrv.label.contains("HRV"))
        XCTAssertLessThanOrEqual(hrv.frame.width, app.windows.firstMatch.frame.width)
        capture("heart-large-text-hrv")
        let temperature = element(app, "heart-vital-skin_temperature_deviation")
        reveal(app, temperature)
        capture("heart-large-text-temperature")
    }

    @MainActor
    func testAdvancedEmptyState() {
        let app = launch(state: "empty", link: "heart/detail")
        XCTAssertTrue(element(app, "heart-advanced-section").waitForExistence(timeout: 20))
        capture("advanced-empty-readings")
        let beats = element(app, "heart-beat-to-beat-section")
        reveal(app, beats)
        capture("advanced-empty-beats")
    }

    @MainActor
    func testTodaySleepRingSelectsSleepAndKeepsTheDay() {
        let app = launch(state: "normal", link: "today")
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 20))
        app.tabBars.buttons["Sleep"].tap()
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 10))
        let duration = element(app, "sleep-metric-duration")
        reveal(app, duration)
        duration.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let navigator = element(app, "day-navigator")
        navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["YESTERDAY · MON 13 NOV"].waitForExistence(timeout: 5))
        let day = navigator.value as? String
        let sleep = element(app, "today-metric-sleep")
        reveal(app, sleep)
        sleep.tap()
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Sleep"].isSelected)
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
        XCTAssertEqual(element(app, "day-navigator").value as? String, day)
        capture("today-sleep-ring-lands-on-tab")
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
        capture("today-after-sleep-return")
    }

    @MainActor
    func testLegacyHistoryAndAdvancedDeepLinks() {
        let app = launch(state: "normal", link: "phase06/heart-trends")
        XCTAssertTrue(element(app, "heart-trends-screen").waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "heart-trends-range").exists)
        capture("metric-history-links")
        let row = element(app, "heart-vital-resting_heart_rate")
        reveal(app, row)
        row.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
        capture("metric-history-detail")
        app.terminate()
        let advanced = launch(state: "normal", link: "heart/detail")
        XCTAssertTrue(element(advanced, "heart-detail-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(element(advanced, "heart-advanced-section").exists)
        capture("advanced-deep-link")
    }

    @MainActor
    private func launch(state: String, link: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-si-heartnav-fixture=\(state)", "--loopr-metric-history-fixture", "--loopr-deep-link=\(link)"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.frame.minY - 8
        let navigator = element(app, "day-navigator")
        let top = navigator.exists ? max(115, navigator.frame.maxY + 16) : 115
        for _ in 0..<12 {
            var dy: CGFloat = -350
            if target.exists {
                let frame = target.frame
                if frame.minY >= top, frame.maxY <= bottom { break }
                dy = frame.maxY > bottom ? -min(frame.maxY - bottom + 50, 350) : min(top + 20 - frame.minY, 350)
            }
            // Start and finish inside the scrollable area, below the fixed
            // header even at the largest accessibility text size.
            let startY = dy < 0 ? bottom - 40 : top + 40
            dy = min(max(dy, top + 8 - startY), bottom - 8 - startY)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.frame.width * 0.94, dy: startY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(target.isHittable, "Missing visible control \(target.debugDescription)")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-heartnav-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
