import XCTest

final class SIMorningCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testGoodDay() { captureToday("good", expecting: "supported") }
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
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
        capture("overnight-check-detail")
    }
    @MainActor func testMissingStress() { captureToday("missing-stress", expecting: "supported") }
    @MainActor func testStaleData() { captureToday("stale", expecting: "No new nights") }
    @MainActor func testFirstNight() { captureToday("first-night", expecting: "1 of 4 nights") }
    @MainActor func testEmpty() { captureToday("empty", expecting: "Waiting for last night") }
    @MainActor func testLargestText() { captureToday("flagged", expecting: "Sleep was short", large: true) }
    /// At the largest text size the recovery briefing stays whole and on screen. Since LV-04 step 2 (DEC-12.3) recovery
    /// is a readout under the day dial: its driver and strain plan are no longer visible lines, they are what the
    /// readout says to VoiceOver, and the morning note (LV-04 step 3) names the drivers on screen. The plan's range is
    /// still on screen in Your day's Strain row. So this checks the readout's words and that the page, the prompt chips,
    /// the readout and the Strain row sit inside the screen's width, which is what a clipped large-text layout breaks.
    @MainActor func testLargestTextBriefingCopy() {
        let app = launch("flagged", large: true)
        let window = app.windows.firstMatch.frame
        // The page itself keeps the screen's width: a long prompt chip once widened the whole scroll view.
        let page = element(app, "today-screen")
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        XCTAssertLessThanOrEqual(page.frame.width, window.width + 0.5)
        for index in 0..<3 {
            let chip = element(app, "today-ask-chip-\(index)")
            guard chip.exists else { continue }
            XCTAssertGreaterThanOrEqual(chip.frame.minX, window.minX - 0.5, "chip \(index)")
            XCTAssertLessThanOrEqual(chip.frame.maxX, window.maxX + 0.5, "chip \(index)")
        }
        let recovery = element(app, "today-metric-recovery")
        reveal(app, recovery, top: 360)
        XCTAssertTrue(recovery.label.contains("Sleep was short"), recovery.label)
        XCTAssertTrue(recovery.label.contains("Keep strain between"), recovery.label)
        XCTAssertGreaterThanOrEqual(recovery.frame.minX, window.minX - 0.5)
        XCTAssertLessThanOrEqual(recovery.frame.maxX, window.maxX + 0.5)
        capture("largest-text-full-driver")
        // The Strain row left Today with Your day in the UX simplification (2026-11-01).
    }
    /// Without the heads-up row the hero used to sit a gutter left of centre. Since LV-04 step 2 the hero is the day
    /// dial, with recovery as one of the readouts under it, so the dial is what has to sit in the middle.
    @MainActor func testHeroIsCentredWithAndWithoutTheHeadsUpRow() {
        var headsUpSeen: Set<Bool> = []
        for mode in ["good", "first-night", "stale", "empty"] {
            let app = launch(mode)
            XCTAssertTrue(element(app, "today-metric-recovery").waitForExistence(timeout: 20), mode)
            let hero = element(app, "today-dial")
            XCTAssertTrue(hero.waitForExistence(timeout: 20), mode)
            headsUpSeen.insert(element(app, "today-heads-up").waitForExistence(timeout: 2))
            XCTAssertEqual(hero.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, mode)
            app.terminate()
        }
        XCTAssertEqual(headsUpSeen, [true, false], "the modes must cover a day with and without the heads-up row")
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
        // DEC-07 took the contributor list, rings and signals off Today. The hero's state and copy, checked above, and
        // what follows it are what Today shows now.
        app.swipeUp()
        capture("\(suffix)-below-briefing")
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
