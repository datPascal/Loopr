import XCTest

/// Patterns, opened through its route with the DEBUG fixture `--loopr-patterns-fixture`: a running test on day 6 of 14,
/// three found patterns, one hidden, a weekly review dated Sun 11 Oct, and both toggles on. No network. The running test
/// needs `--loopr-protocol-fixture=empty`: beside the populated protocol's magnesium experiment no test runs, because
/// Loopr runs one experiment at a time (ICP R1-VET-10).
final class PatternsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(fixture: Bool = true, runningTest: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=today/patterns"]
            + (fixture ? ["--loopr-patterns-fixture"] : []) + (fixture && runningTest ? ["--loopr-protocol-fixture=empty"] : []) + extra
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: 45), "Patterns did not open from its route")
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// 12-hour locales put a narrow no-break space before am and pm.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @MainActor private func reach(_ app: XCUIApplication, _ target: XCUIElement) {
        for _ in 0..<10 { if target.exists && target.isHittable { return }; app.swipeUp() }
        XCTFail("Could not reach \(target)")
    }

    /// The row is as wide as the card, and its label does not switch anything. Tap the switch at the trailing edge.
    @MainActor private func flip(_ toggle: XCUIElement, to value: String) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, "\(toggle.identifier) did not turn \(value == "1" ? "on" : "off")")
    }

    @MainActor private func segment(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons["patterns-segments-\(name)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
    }

    @MainActor func testOpensFromTheRouteWithTheRunningTestThreeFoundPatternsAndTheReview() {
        let app = launch()
        let card = element(app, "patterns-test-card")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertEqual(element(app, "patterns-test-day").label, "Day 6 of 14")
        XCTAssertEqual(plain(element(app, "patterns-test-title").label), "Kitchen closed at 8:30 pm", "the stored 20:30 is written in the simulator's 12-hour clock")
        XCTAssertEqual(plain(element(app, "patterns-test-status").label), "Kept on 5 of 6 nights. Too early to tell. A reminder comes at 8:15 pm.")
        XCTAssertTrue(element(app, "patterns-test-device").exists)
        XCTAssertTrue(card.staticTexts["66"].exists || card.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '66'")).firstMatch.exists)

        for index in 0..<3 { XCTAssertTrue(app.buttons["patterns-found-row-\(index)"].waitForExistence(timeout: 10), "found row \(index)") }
        // The counts stand where "Strong" stood (ICP R1-VET-13).
        XCTAssertTrue(app.buttons["patterns-found-row-0"].label.contains("9 nights with, 14 without"), app.buttons["patterns-found-row-0"].label)
        XCTAssertFalse(app.buttons["patterns-found-row-0"].label.contains("Strong"))
        XCTAssertFalse(app.buttons["patterns-found-row-3"].exists)

        let review = element(app, "patterns-weekly-review")
        reach(app, review)
        // The date is no longer set in capitals, so compare without case.
        XCTAssertTrue(review.label.uppercased().contains("SUN 11 OCT") && review.label.contains("Recovery averaged 71"), review.label)
        reach(app, element(app, "patterns-settings-card"))
        XCTAssertEqual(app.switches["patterns-morning-toggle"].value as? String, "1")
        XCTAssertEqual(app.switches["patterns-discovery-toggle"].value as? String, "1")
    }

    @MainActor func testSegmentsSwitchBetweenTestingFoundAndDismissed() {
        let app = launch()
        segment(app, "found")
        XCTAssertTrue(element(app, "patterns-found-list").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "patterns-test-card").exists)
        XCTAssertTrue(element(app, "patterns-footnote").exists)

        segment(app, "dismissed")
        XCTAssertTrue(element(app, "patterns-dismissed-row-0").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["patterns-restore-0"].exists)
        XCTAssertFalse(element(app, "patterns-found-list").exists)

        segment(app, "testing")
        XCTAssertTrue(element(app, "patterns-test-card").waitForExistence(timeout: 10))
    }

    @MainActor func testDismissingAPatternMovesItToDismissedAndRestoreBringsItBack() {
        let app = launch()
        segment(app, "found")
        let first = app.buttons["patterns-found-row-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let title = first.label
        first.tap()
        XCTAssertTrue(element(app, "patterns-detail").waitForExistence(timeout: 10))
        // A test is running, so this one cannot start, and the line above says until when. Not now is still open.
        XCTAssertFalse(app.buttons["patterns-detail-try"].isEnabled)
        XCTAssertEqual(app.buttons["patterns-detail-try"].label, "Try for 14 days")
        let busy = element(app, "patterns-detail-busy").label
        XCTAssertTrue(busy.hasPrefix("You can start this after your current test, Kitchen closed") && busy.contains(" ends on "), busy)
        XCTAssertEqual(app.buttons["patterns-detail-dismiss"].label, "Not now")
        app.buttons["patterns-detail-dismiss"].tap()

        XCTAssertTrue(app.buttons["patterns-found-row-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["patterns-found-row-2"].exists, "two patterns should be left")
        XCTAssertNotEqual(app.buttons["patterns-found-row-0"].label, title)

        segment(app, "dismissed")
        XCTAssertTrue(element(app, "patterns-dismissed-row-1").waitForExistence(timeout: 10), "the new dismissal joins the older one")
        // The newest dismissal is listed first.
        app.buttons["patterns-restore-0"].tap()
        XCTAssertFalse(element(app, "patterns-dismissed-row-1").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "patterns-dismissed-row-0").exists)

        segment(app, "found")
        XCTAssertTrue(app.buttons["patterns-found-row-2"].waitForExistence(timeout: 10), "the restored pattern is back")
    }

    @MainActor func testTheTogglesChangeAndTheBriefingOpensItsConsentWhenItIsSwitchedBackOn() {
        let app = launch()
        reach(app, element(app, "patterns-settings-card"))
        let discovery = app.switches["patterns-discovery-toggle"], morning = app.switches["patterns-morning-toggle"]
        XCTAssertEqual(discovery.value as? String, "1")
        flip(discovery, to: "0")
        flip(discovery, to: "1")
        flip(morning, to: "0")
        // Switching it on again needs consent, which was dropped when it went off. The existing review opens.
        morning.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "patterns-consent-sheet").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["coach-morning-enable"].waitForExistence(timeout: 15), "the sharing review did not open")
        app.buttons["Cancel"].firstMatch.tap()
        let close = app.buttons["patterns-consent-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: 10))
        reach(app, element(app, "patterns-settings-card"))
        XCTAssertEqual(app.switches["patterns-morning-toggle"].value as? String, "0", "cancelling the review leaves the briefing off")
    }

    /// ICP R3-OPT-8: the populated protocol runs Magnesium at night 9 of 14, so Testing names it instead of "No test running".
    @MainActor func testTheTestingTabNamesTheRunningProtocolExperiment() {
        let app = launch(fixture: false)
        let card = element(app, "patterns-testing-experiment")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(card.label.contains("Night 9 of 14") && card.label.contains("Magnesium"), card.label)
        XCTAssertFalse(element(app, "patterns-testing-empty").exists)
    }

    @MainActor func testEmptyStatesUseTheirOwnCopy() {
        // Without a protocol nothing runs, so Testing says so.
        let app = launch(fixture: false, extra: ["--loopr-protocol-fixture=empty"])
        XCTAssertEqual(element(app, "patterns-testing-empty").label, "No test running. Pick a pattern, or use Ask for a suggestion.")
        segment(app, "found")
        XCTAssertEqual(element(app, "patterns-found-empty").label, "Nothing clear yet. Loopr needs about 5 nights on each side before it says anything.")
        segment(app, "dismissed")
        XCTAssertEqual(element(app, "patterns-dismissed-empty").label, "Patterns you hide with Not now wait here. They stay off Today.")
    }

    /// ICP R1-VET-10, R1-DES-11: the populated protocol runs magnesium, so no pattern test starts beside it. Try is off
    /// and says why, naming the experiment.
    @MainActor func testTryWaitsWhileAProtocolExperimentRuns() {
        let app = launch(runningTest: false)
        XCTAssertTrue(element(app, "patterns-testing-experiment").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "patterns-test-card").exists, "one experiment at a time")
        segment(app, "found")
        let first = app.buttons["patterns-found-row-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(element(app, "patterns-detail").waitForExistence(timeout: 10))
        let try14 = app.buttons["patterns-detail-try"]
        XCTAssertTrue(try14.waitForExistence(timeout: 10))
        XCTAssertFalse(try14.isEnabled)
        XCTAssertEqual(try14.label, "Try for 14 days")
        let busy = element(app, "patterns-detail-busy")
        XCTAssertTrue(busy.label.hasPrefix("You can start this after the magnesium test ends on ") && busy.label.contains("one test at a time"),
                      busy.label)
    }
}
