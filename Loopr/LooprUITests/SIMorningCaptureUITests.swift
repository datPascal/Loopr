import XCTest

final class SIMorningCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testGoodDay() {
        let app = captureToday("good", expecting: "supported")
        XCTAssertTrue(element(app, "today-contributor-skin_temperature_deviation").label.contains("+0.2 °C"))
        XCTAssertTrue(element(app, "today-contributor-sleep_duration").label.contains("Same as usual"))
    }
    @MainActor func testLoadLowersThePlan() { captureToday("load-heavy", expecting: "The range is lower after a heavy week") }
    @MainActor func testLowRecoveryWithShortSleep() { captureToday("low", expecting: "Sleep was short") }
    @MainActor func testEarlyEstimate() { captureToday("early", expecting: "Early estimate") }
    @MainActor func testFlaggedOvernightCheck() {
        let app = captureToday("flagged", expecting: "Sleep was short")
        let check = element(app, "today-heads-up")
        reveal(app, check)
        capture("flagged-check-line")
        check.tap()
        XCTAssertTrue(element(app, "heart-vitals-section").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Heart"].isSelected)
        capture("overnight-check-detail")
    }
    @MainActor func testMissingStress() {
        let app = captureToday("missing-stress", expecting: "supported")
        XCTAssertTrue(element(app, "today-metric-stress").label.contains("No clean heart data today"))
    }
    @MainActor func testStaleData() { captureToday("stale", expecting: "No new nights") }
    @MainActor func testFirstNight() { captureToday("first-night", expecting: "1 of 4 nights") }
    @MainActor func testEmpty() { captureToday("empty", expecting: "Waiting for last night") }
    @MainActor func testLargestText() { captureToday("flagged", expecting: "Sleep was short", large: true) }
    @MainActor func testLargestTextBriefingCopy() {
        let app = launch("flagged", large: true)
        let driver = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sleep was short")).firstMatch
        reveal(app, driver, top: 360)
        capture("largest-text-full-driver")
        let plan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep strain between")).firstMatch
        reveal(app, plan, top: 360)
        capture("largest-text-full-plan")
    }
    @MainActor func testStressLearningLanguage() {
        let app = launch("good", deepLink: "today/stress", extra: ["--loopr-hourly-stress-fixture=learning"])
        let timeline = element(app, "hourly-stress-timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        reveal(app, timeline)
        capture("stress-learning")
    }
    @MainActor func testRecoveryWeights() {
        let app = launch("good")
        let hero = element(app, "today-metric-recovery")
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        hero.tap()
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: 20))
        capture("recovery-weights")
        app.swipeUp()
        capture("recovery-explanation")
    }
    @MainActor func testNotificationSettings() {
        let app = launch("good", deepLink: "settings/notifications")
        let toggle = element(app, "settings-notification-recoveryReadiness")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        reveal(app, toggle)
        capture("notification-settings")
    }

    @discardableResult @MainActor
    private func captureToday(_ mode: String, expecting: String, large: Bool = false) -> XCUIApplication {
        let app = launch(mode, large: large)
        let hero = element(app, "today-metric-recovery")
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let expected = NSPredicate(format: "label CONTAINS %@", expecting)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: hero)], timeout: 10), .completed)
        let suffix = large ? "largest-text" : mode
        capture("\(suffix)-briefing")
        if large {
            app.swipeUp()
            capture("largest-text-briefing-plan")
            reveal(app, element(app, "today-contributor-rmssd"))
            capture("largest-text-contributors-top")
            reveal(app, element(app, "today-contributor-respiratory_rate"))
            capture("largest-text-contributors-middle")
        }
        if mode == "empty" {
            let empty = element(app, "today-signals-empty")
            reveal(app, empty)
            XCTAssertEqual(empty.label, "Wear your band overnight and sync in the morning.")
            XCTAssertFalse(element(app, "today-contributor-rmssd").exists)
            capture("empty-signals")
        } else if mode == "stale" {
            XCTAssertFalse(element(app, "today-signals-header").exists)
            XCTAssertFalse(element(app, "today-contributor-rmssd").exists)
        } else {
            let contributor = element(app, "today-contributor-skin_temperature_deviation")
            reveal(app, contributor)
            capture("\(suffix)-contributors")
        }
        if large {
            reveal(app, element(app, "today-metric-sleep"))
            capture("largest-text-sleep-ring")
            reveal(app, element(app, "today-metric-strain"))
            capture("largest-text-strain-ring")
        }
        let rings = element(app, "today-metric-stress")
        reveal(app, rings)
        if ["good", "low", "flagged", "load-heavy", "missing-stress"].contains(mode) {
            for id in ["strain", "stress"] {
                XCTAssertFalse(element(app, "today-metric-\(id)").label.contains("Learning your usual"))
            }
        }
        capture("\(suffix)-rings")
        if mode == "good", !large {
            app.swipeUp()
            capture("tonight-goals")
            app.swipeUp()
            capture("more")
        }
        return app
    }
    @MainActor private func launch(_ mode: String, deepLink: String = "today", large: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-si-morning-fixture=\(mode)", "--loopr-deep-link=\(deepLink)"]
        app.launchArguments += extra
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement, top: CGFloat = 110) {
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.frame.maxY - 34
        for _ in 0..<12 {
            let frame = target.frame
            if frame.minY > top, frame.maxY < bottom - 8 { break }
            let dy = frame.maxY >= bottom - 8 ? -min(frame.maxY - bottom + 60, window.frame.height * 0.5)
                : min(top + 20 - frame.minY, window.frame.height * 0.5)
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }
    @MainActor private func capture(_ surface: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-morning-\(surface)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
