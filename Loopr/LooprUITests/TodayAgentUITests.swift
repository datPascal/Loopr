import XCTest

/// FT-05.5: the new Today sections and the Sleep card open Ask or Patterns from where the person is. Every launch is a
/// DEBUG fixture on Alex's Tuesday 2023-11-14, and the coach fixture stands in for the provider. Nothing here sends
/// a request. Opening Ask fills the message field and sends nothing.
final class TodayAgentUITests: XCTestCase {
    private static let wait: TimeInterval = 30

    override func setUpWithError() throws { continueAfterFailure = false }

    private static let day = ["--loopr-metric-history-fixture", "--loopr-your-data-fixture", "--loopr-train-fixture",
                              "--loopr-agent-day-fixture", "--loopr-journal-fixture=checkin"]

    /// `openFolds` starts "More from today" open, so the pattern, pins and timeline inside it can be queried.
    @MainActor private func launch(_ extra: [String] = [], openFolds: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "--loopr-appearance=system",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + Self.day + extra
            + (openFolds ? ["-loopr-open-folds", "YES"] : [])
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: Self.wait))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls until the control is on screen, then taps it.
    @MainActor private func reachAndTap(_ app: XCUIApplication, _ id: String) {
        let target = app.buttons[id].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: Self.wait), id)
        // Short drags, not flings: with the note, rail and strip above it a fling carried the card past the content
        // and left the button under the header's glass, where XCTest still calls it hittable and the tap lands on the
        // header. Back down if it went past.
        for _ in 0..<20 where !app.showsInContent(target) {
            if target.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 where !app.showsInContent(target) { app.dragContent(up: false) }
        XCTAssertTrue(app.showsInContent(target), "Could not reach \(id)")
        target.tap()
    }

    @MainActor private func draft(_ app: XCUIApplication) -> String {
        let field = element(app, "coach-composer")
        XCTAssertTrue(field.waitForExistence(timeout: Self.wait))
        return (field.value as? String) ?? ""
    }

    // MARK: Ask

    /// The Ask card and its prompt chips left Today in the UX simplification (2026-11-01). The header button is the one
    /// way in, and it opens Ask with nothing typed.
    @MainActor func testTheHeaderOpensAskFromTodayWithAnEmptyMessage() {
        let app = launch()
        XCTAssertFalse(element(app, "today-ask-composer").exists)
        let ask = app.buttons["today-header-coach"]
        XCTAssertTrue(ask.waitForExistence(timeout: Self.wait))
        ask.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "ask-origin").label.contains("Today"), element(app, "ask-origin").label)
        XCTAssertFalse(draft(app).contains("?"), "Ask opens with nothing typed")
    }

    /// DEC-07 line 3. Six pins chosen in Health: Today's card shows four and ends with a row to the full list.
    @MainActor func testPinnedCardLinksToEveryPinInHealth() {
        let pins = ["rmssd", "recovery", "resting_heart_rate", "respiratory_rate", "skin_temperature_deviation", "steps"]
        let directory = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        // The runner sets the simulator's appearance and names it here; one run captures one appearance.
        let appearance = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "system"
        do {
            let app = launch(["--loopr-health-pins=" + pins.joined(separator: ",")])
            let all = app.buttons["today-numbers-all"].firstMatch
            XCTAssertTrue(all.waitForExistence(timeout: Self.wait), "more than four pins ends the card with a link")
            XCTAssertEqual(all.label, "All 6 pinned numbers")
            for _ in 0..<10 where !(all.isHittable && all.frame.maxY < app.tabBars.firstMatch.frame.minY - 8) { app.swipeUp() }
            XCTAssertGreaterThanOrEqual(all.frame.height, 44)
            if let directory {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.2))
                let shot = app.screenshot()
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("today-pins-all-\(appearance).png"))
            }
            all.tap()
            XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: Self.wait), "the row opens Health")
            XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
            app.terminate()
        }
    }

    @MainActor func testAskOnAPastDayNamesTheDay() {
        let app = launch()
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: Self.wait))
        navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "day-navigator-today").waitForExistence(timeout: Self.wait), "now on a past day")
        XCTAssertTrue(app.buttons["today-header-coach"].waitForExistence(timeout: Self.wait), "the header Ask button shows on a past day")
        app.buttons["today-header-coach"].tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: Self.wait))
        XCTAssertEqual(element(app, "ask-origin").label, "From Today · Yesterday", "the header button names the day")
    }

    // MARK: More from today and timeline

    /// The fold starts closed: the first screen ends with Up next and one row naming what the fold holds.
    @MainActor func testMoreFromTodayStartsClosedAndOpensInPlace() {
        let app = launch(["--loopr-patterns-fixture=found"], openFolds: false)
        let more = app.buttons["today-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: Self.wait))
        XCTAssertFalse(element(app, "today-timeline-end").exists, "the timeline waits in the fold")
        XCTAssertFalse(element(app, "today-your-day").exists, "Your day left Today")
        XCTAssertTrue(more.label.contains("timeline"), more.label)
        reachAndTap(app, "today-more")
        XCTAssertTrue(element(app, "today-timeline-end").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "today-pattern-card").exists)
    }

    @MainActor func testTimelineDimsWhatIsStillAheadAndEndsWithBedtime() {
        let app = launch()
        let bedtime = element(app, "today-timeline-bedtime")
        XCTAssertTrue(bedtime.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(bedtime.label.hasSuffix("upcoming"), bedtime.label)
        XCTAssertTrue(element(app, "today-timeline-workout-planned").label.hasSuffix("upcoming"))
        XCTAssertFalse(element(app, "today-timeline-wake").label.hasSuffix("upcoming"))
        XCTAssertTrue(element(app, "today-timeline-end").exists)
    }

    // MARK: Pattern card

    @MainActor func testThePatternCardIsHiddenWhenPatternsFoundNothing() {
        let app = launch()
        XCTAssertTrue(element(app, "today-timeline-end").waitForExistence(timeout: Self.wait))
        XCTAssertFalse(element(app, "today-pattern-card").exists)
        XCTAssertFalse(element(app, "today-pattern-header").exists)
    }

    @MainActor func testAllOpensPatterns() {
        let app = launch(["--loopr-patterns-fixture=found"])
        XCTAssertTrue(element(app, "today-pattern-card").waitForExistence(timeout: Self.wait))
        reachAndTap(app, "today-pattern-all")
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: Self.wait))
    }

    @MainActor func testShowTheNightsOpensPatterns() {
        let app = launch(["--loopr-patterns-fixture=found"])
        XCTAssertTrue(element(app, "today-pattern-card").waitForExistence(timeout: Self.wait))
        reachAndTap(app, "today-pattern-show")
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: Self.wait))
    }

    @MainActor func testTryFourteenDaysStartsATestAndPatternsShowsItRunning() {
        let app = launch(["--loopr-patterns-fixture=found"])
        XCTAssertTrue(element(app, "today-pattern-card").waitForExistence(timeout: Self.wait))
        reachAndTap(app, "today-pattern-try")
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: Self.wait))
        let card = element(app, "patterns-test-card")
        XCTAssertTrue(card.waitForExistence(timeout: Self.wait), "the test Today started is the one Patterns shows")
        XCTAssertEqual(element(app, "patterns-test-day").label, "Day 1 of 14")
    }

    @MainActor func testWhileATestRunsTheCardOffersOnlyShowTheNights() {
        // The fixture runs its test only beside an empty protocol: one experiment at a time (ICP R1-VET-10).
        let app = launch(["--loopr-patterns-fixture", "--loopr-protocol-fixture=empty"])
        XCTAssertTrue(element(app, "today-pattern-card").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(app.buttons["today-pattern-show"].exists)
        XCTAssertFalse(app.buttons["today-pattern-try"].exists, "one test runs at a time")
        XCTAssertTrue(element(app, "today-timeline-reminder-feedface-0000-4000-8000-000000000001").waitForExistence(timeout: Self.wait),
                      "the running test's reminder is on the timeline")
    }

    // MARK: Sleep

    @MainActor func testTheSleepCardOpensAskWithTheQuestionAboutTheNight() {
        let app = launch(["--loopr-deep-link=sleep"])
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: Self.wait))
        let card = element(app, "sleep-what-was-different")
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        XCTAssertTrue(card.label.replacingOccurrences(of: "\u{202F}", with: " ").contains("Dinner was at 7:00 pm"), card.label)
        for _ in 0..<6 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "ask-origin").label.contains("Sleep"), element(app, "ask-origin").label)
        XCTAssertEqual(draft(app), "What was different about this night?")
    }
}
