import XCTest

/// FT-05.3: an Ask answer carries a chart, a source strip and a confirmation card, and a source button
/// leaves Ask for the record behind it. `--loopr-agent-fixture` (AgentUITestFixtures) scripts the model,
/// so nothing here reaches a provider or a network. W7 extends the same fixture for the visual lane.
final class AgentSourcesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-agent-fixture",
            "--loopr-your-data-fixture", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + flags
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Opens Ask from Today, sends a question and waits for the scripted answer.
    @MainActor private func askAndWaitForAnswer(_ app: XCUIApplication) {
        let ask = app.buttons["today-header-coach"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))
        ask.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
        let chip = app.buttons["ask-prompt-0"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let send = app.buttons["coach-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let consent = app.buttons["coach-confirm-consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 15))
        for _ in 0..<5 where !consent.isHittable { app.swipeUp() }
        consent.tap()
        XCTAssertTrue(element(app, "agent-source-strip").waitForExistence(timeout: 30), "the scripted answer arrives with its sources")
    }

    @MainActor func testAnswerShowsChartSourcesAndAConfirmationCard() {
        let app = launch()
        askAndWaitForAnswer(app)
        XCTAssertTrue(element(app, "agent-chart-card").exists)
        XCTAssertTrue(element(app, "agent-chart-bars").exists, "deep sleep is a nightly total, so it draws as bars")
        for id in ["metrics.deep_sleep.2026-10-10.2026-10-16", "food.2026-10-10.2026-10-16", "patterns"] {
            let source = app.buttons["agent-source-\(id)"]
            XCTAssertTrue(source.exists, id)
            XCTAssertGreaterThanOrEqual(source.frame.height, 44, id)
        }
        let card = element(app, "agent-proposal-card")
        XCTAssertTrue(card.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-confirm-'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-dismiss-'")).firstMatch.exists)
    }

    @MainActor func testSleepSourceLeavesAskAndOpensTheNight() {
        let app = launch()
        askAndWaitForAnswer(app)
        app.buttons["agent-source-metrics.deep_sleep.2026-10-10.2026-10-16"].tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10), "Ask closes")
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
    }

    @MainActor func testFoodSourceLeavesAskAndOpensTheFoodTab() {
        let app = launch()
        askAndWaitForAnswer(app)
        app.buttons["agent-source-food.2026-10-10.2026-10-16"].tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10), "Ask closes")
        XCTAssertTrue(element(app, "food-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Food"].isSelected)
    }

    @MainActor func testPatternsSourceLeavesAskAndOpensThePatternsRoute() {
        let app = launch()
        askAndWaitForAnswer(app)
        app.buttons["agent-source-patterns"].tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10), "Ask closes")
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: 20), "the source opens the Patterns screen")
        XCTAssertTrue(app.tabBars.buttons["Today"].isSelected)
    }

    @MainActor func testSavedAnswerComesBackWithItsChartSourcesAndPendingCard() {
        let app = launch(["--loopr-agent-fixture-seed"])
        let ask = app.buttons["today-header-coach"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))
        ask.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "agent-chart-card").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["agent-source-journal.2026-10-10.2026-10-16"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent-confirm-'")).firstMatch.exists)
    }
}
