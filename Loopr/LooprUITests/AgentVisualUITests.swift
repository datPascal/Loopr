import XCTest

/// Captures screens 16, 17, 01 and 03 of the five-tab design after the Ask and Patterns work: the Ask answer, Patterns, the
/// finished Today and Sleep with its What was different card. Every launch is a DEBUG fixture. Nothing here reaches a
/// provider or a network.
///
/// - Ask: `--loopr-agent-fixture` with `--loopr-agent-fixture-seed`, Ask opened from Sleep. The answer carries the deep sleep
///   chart, three sources and a card for a 14-day test.
/// - Patterns: `--loopr-patterns-fixture`, a running test on day 6 of 14, three found patterns, a weekly review.
/// - Today and Sleep: Alex on Tuesday 2023-11-14 in Australia/Perth, with the Train fixture (Upper A planned at 18:30),
///   the journal check-in fixture, late dinners on the days before an early dinner (`--loopr-agent-day-fixture`) and found
///   patterns with no running test, so the pattern card shows both buttons.
final class AgentVisualUITests: XCTestCase {
    private static let wait: TimeInterval = 30
    /// Scroll drags start in the left gutter, where no control sits.
    private static let gutter: CGFloat = 0.06

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testAskAnswerThroughTheComposer() {
        let app = launch(extra: ["--loopr-agent-fixture", "--loopr-agent-fixture-seed", "--loopr-your-data-fixture", "--loopr-metric-history-fixture", "--loopr-deep-link=sleep"])
        // The mockup's answer is about a night, so Ask opens from Sleep.
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: Self.wait))
        let ask = app.buttons["screen-ask"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: Self.wait))
        ask.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: Self.wait))
        let card = element(app, "agent-proposal-card")
        XCTAssertTrue(card.waitForExistence(timeout: Self.wait), "the seeded answer is open")
        XCTAssertTrue(element(app, "ask-composer").waitForExistence(timeout: Self.wait))
        let scroll = scrollView(containing: card, in: app)
        // The thread opens at its end. Go back to the top, then read down to the card and the composer.
        for _ in 0..<8 { drag(scroll, up: false) }
        captureThread(app, "16-ask", scroll: scroll, last: card, pinned: element(app, "ask-composer"))
    }

    @MainActor func testPatternsThroughTheSettingsCard() {
        // The fixture runs its test only beside an empty protocol: one experiment at a time (ICP R1-VET-10).
        let app = launch(extra: ["--loopr-deep-link=today/patterns", "--loopr-patterns-fixture", "--loopr-protocol-fixture=empty"])
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: 45), "Patterns did not open from its route")
        XCTAssertTrue(element(app, "patterns-test-card").waitForExistence(timeout: Self.wait))
        capture(app, "17-patterns", end: "patterns-settings-card", scroll: app.scrollViews["patterns-screen"].firstMatch)
    }

    @MainActor func testTodayThroughTheTimeline() {
        // The alarm is on, so Today's timeline carries its row, as in the mockup.
        // "More from today" starts open so the capture runs through the pattern and the timeline inside it.
        let app = launch(extra: dayFixture + ["--loopr-wake-alarm-fixture=set", "-loopr-open-folds", "YES"])
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: Self.wait))
        // The rail and the pattern card arrive after the first frame.
        XCTAssertTrue(element(app, "today-rail").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "today-pattern-card").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "today-timeline-bedtime").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "today-timeline-alarm").waitForExistence(timeout: Self.wait))
        capture(app, "01-today", end: "today-timeline-end", scroll: element(app, "today-screen").scrollViews.firstMatch.exists
                ? element(app, "today-screen").scrollViews.firstMatch : app.scrollViews.firstMatch)
    }

    @MainActor func testSleepWithTheDifferenceCardThroughTheWakeAlarm() {
        let app = launch(extra: dayFixture + ["--loopr-deep-link=sleep"])
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: Self.wait))
        let different = element(app, "sleep-what-was-different")
        XCTAssertTrue(different.waitForExistence(timeout: 60), "the comparison of the night with the last 28 days is on screen")
        capture(app, "03-sleep", end: "sleep-wake-alarm-card", scroll: element(app, "sleep-screen").scrollViews.firstMatch.exists
                ? element(app, "sleep-screen").scrollViews.firstMatch : app.scrollViews.firstMatch)
    }

    // MARK: Launch

    private var dayFixture: [String] {
        ["--loopr-metric-history-fixture", "--loopr-your-data-fixture", "--loopr-train-fixture", "--loopr-agent-day-fixture",
         "--loopr-journal-fixture=checkin", "--loopr-patterns-fixture=found"]
    }

    /// The simulator's appearance is set by the lane, so the app follows the system.
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "--loopr-appearance=system",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        if extra.contains("--loopr-your-data-fixture") {
            XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
            XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        }
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: Self.wait))
        return app
    }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func scrollView(containing target: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        for scroll in app.scrollViews.allElementsBoundByIndex where scroll.frame.contains(point) { return scroll }
        return app.scrollViews.firstMatch
    }

    /// One drag in the left gutter. `up` scrolls the content up, toward its end.
    @MainActor private func drag(_ scroll: XCUIElement, up: Bool) {
        scroll.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: up ? 0.78 : 0.34))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: up ? 0.34 : 0.78)))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "FiveTab Screen \(name)_candidate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func writeCoverage(_ slug: String, viewports: Int, lastElement: String) {
        let data = try! JSONSerialization.data(withJSONObject: ["screen": slug, "viewports": viewports,
            "reachedEnd": true, "lastElement": lastElement], options: [.sortedKeys])
        let coverage = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        coverage.name = "FiveTab Coverage \(slug)"; coverage.lifetime = .keepAlways; add(coverage)
    }

    /// Scrolls a tab or pushed screen down in overlapping viewports until `end` sits fully above the tab bar.
    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, end endID: String, scroll: XCUIElement) {
        XCTAssertTrue(scroll.waitForExistence(timeout: Self.wait))
        let end = element(app, endID)
        for index in 1...30 {
            let bottom = app.tabBars.firstMatch.exists ? min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY) : scroll.frame.maxY
            attach(app, index == 1 ? slug : "\(slug)-\(index)")
            if end.exists, end.frame.height > 0, end.frame.minY >= scroll.frame.minY, end.frame.maxY <= bottom {
                writeCoverage(slug, viewports: index, lastElement: endID)
                return
            }
            drag(scroll, up: true)
        }
        XCTFail("Did not reach the end of \(slug) after 30 overlapping viewports")
    }

    /// The Ask thread. The composer is pinned under the thread, so the thread is read down to its last card and the composer
    /// must be on screen with it.
    @MainActor private func captureThread(_ app: XCUIApplication, _ slug: String, scroll: XCUIElement, last: XCUIElement, pinned: XCUIElement) {
        for index in 1...30 {
            attach(app, index == 1 ? slug : "\(slug)-\(index)")
            let visible = last.exists && last.frame.height > 0 && last.frame.minY >= scroll.frame.minY
                && last.frame.maxY <= pinned.frame.minY
            if visible, pinned.exists, pinned.frame.height > 0 {
                writeCoverage(slug, viewports: index, lastElement: "ask-composer")
                return
            }
            drag(scroll, up: true)
        }
        XCTFail("Did not reach the end of \(slug) after 30 overlapping viewports")
    }
}
