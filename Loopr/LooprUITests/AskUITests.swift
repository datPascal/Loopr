import XCTest

/// The Ask sheet: one sheet from every tab and from Sleep and metric detail, its prompt chips,
/// its history menu and dictation. The coach fixture stands in for the provider, so no test here
/// sends a network request. Dictation uses a scripted transcript, not the microphone.
final class AskUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private static let tabs: [(title: String, root: String, ask: String, origin: String)] = [
        ("Today", "today-screen", "today-header-coach", "Today"),
        ("Food", "food-screen", "food-header-ask", "Food"),
        ("Fitness", "workouts-screen", "train-header-ask", "Fitness"),
        ("Protocol", "journal-screen", "journal-header-ask", "Protocol"),
        ("Data", "health-screen", "health-header-ask", "Data"),
    ]

    @MainActor private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture",
            "--loopr-your-data-fixture", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
            + flags.map { "--loopr-coach-fixture-" + $0 }
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// iOS 26 toolbar hosts repeat their child's identifier on an Other, so taps go to the button.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id].firstMatch
        let target = button.exists || button.waitForExistence(timeout: 10) ? button : element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), id)
        target.tap()
    }

    @MainActor private func openAskFromTab(_ app: XCUIApplication, _ index: Int) {
        let tab = Self.tabs[index]
        app.tabBars.buttons[tab.title].tap()
        XCTAssertTrue(element(app, tab.root).waitForExistence(timeout: 10))
        tap(app, tab.ask)
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
    }

    @MainActor private func closeAsk(_ app: XCUIApplication) {
        tap(app, "ask-close")
        XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10))
    }

    @MainActor private func composer(_ app: XCUIApplication) -> XCUIElement { element(app, "coach-composer") }

    // MARK: Entry points

    @MainActor func testEveryTabOpensAskWithItsOriginProviderAndControls() {
        let app = launch()
        for index in Self.tabs.indices {
            let tab = Self.tabs[index]
            openAskFromTab(app, index)
            let origin = element(app, "ask-origin")
            XCTAssertTrue(origin.waitForExistence(timeout: 10), tab.title)
            XCTAssertTrue(origin.label.hasPrefix("From \(tab.origin)"), origin.label)
            let provider = element(app, "ask-provider")
            XCTAssertTrue(provider.waitForExistence(timeout: 10), tab.title)
            XCTAssertEqual(provider.label.contains("OpenAI"), true, provider.label)
            XCTAssertGreaterThanOrEqual(provider.frame.height, 44)
            XCTAssertTrue(app.buttons["ask-history"].exists, tab.title)
            XCTAssertTrue(app.buttons["ask-close"].exists, tab.title)
            XCTAssertTrue(composer(app).waitForExistence(timeout: 10), tab.title)
            XCTAssertTrue(element(app, "ask-composer").exists, tab.title)
            XCTAssertTrue(app.buttons["ask-photo"].exists, tab.title)
            XCTAssertTrue(app.buttons["coach-dictate"].exists, tab.title)
            XCTAssertFalse(app.buttons["coach-send"].exists, "Send waits for text")
            closeAsk(app)
            XCTAssertTrue(element(app, tab.root).waitForExistence(timeout: 10), tab.title)
        }
    }

    @MainActor func testOpeningAskNeverSendsOrAsksForConsent() {
        let app = launch()
        openAskFromTab(app, 0)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["coach-confirm-consent"].exists)
        XCTAssertFalse(element(app, "coach-assistant-message").exists)
        XCTAssertFalse(element(app, "coach-user-message").exists)
    }

    @MainActor func testSleepAndMetricDetailKeepTheirOrigin() {
        let app = launch()
        XCTAssertTrue(app.openLooprArea("Sleep"))
        tap(app, "screen-ask")
        let sleep = element(app, "ask-origin")
        XCTAssertTrue(sleep.waitForExistence(timeout: 10))
        XCTAssertTrue(sleep.label.hasPrefix("From Sleep"), sleep.label)
        XCTAssertTrue(sleep.label.contains("night"), sleep.label)
        closeAsk(app)
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 10))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 10))
        // HRV sits on Recovery's last night now that Pinned left Data's root (Data ICP R1).
        element(app, "health-explore-heart").tap()
        let tile = element(app, "data-last-night-rmssd")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "data-last-night-rmssd")
        for _ in 0..<10 where !tile.isHittable { app.swipeUp() }
        XCTAssertTrue(tile.isHittable, "data-last-night-rmssd")
        tile.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 20))
        tap(app, "metric-detail-ask")
        let metric = element(app, "ask-origin")
        XCTAssertTrue(metric.waitForExistence(timeout: 10))
        XCTAssertTrue(metric.label.contains("HRV"), metric.label)
        closeAsk(app)
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
    }

    // MARK: Prompt chips

    @MainActor func testPromptChipFillsTheFieldAndNeverSends() {
        let app = launch()
        openAskFromTab(app, 0)
        let chip = app.buttons["ask-prompt-0"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertEqual(chip.label, "How should I train today?")
        chip.tap()
        XCTAssertEqual(composer(app).value as? String, "How should I train today?")
        XCTAssertFalse(app.buttons["coach-confirm-consent"].exists)
        XCTAssertFalse(element(app, "coach-user-message").exists)
        XCTAssertTrue(app.buttons["coach-send"].waitForExistence(timeout: 5), "Send appears with text")
        XCTAssertFalse(chip.exists, "chips collapse once the field has text")
    }

    @MainActor func testChipsFollowTheScreenAskOpenedFrom() {
        let app = launch()
        openAskFromTab(app, 1)
        let chip = app.buttons["ask-prompt-0"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertEqual(chip.label, "Did late dinners change my sleep?")
    }

    // MARK: History

    @MainActor func testHistoryHoldsTheMenuRowsAndPastChats() {
        let app = launch(["seed"])
        openAskFromTab(app, 0)
        tap(app, "ask-history")
        for id in ["ask-history-new", "ask-history-preferences", "ask-history-providers"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), id)
        }
        XCTAssertTrue(app.buttons["coach-history-row"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "coach-history-row").count, 2)
        app.buttons["coach-history-row"].firstMatch.tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "coach-assistant-message").waitForExistence(timeout: 10), "an earlier chat opens in the sheet")
        XCTAssertFalse(app.buttons["ask-history-new"].exists, "the history sheet closes")
    }

    @MainActor func testNewChatFromHistoryStartsEmptyAndPreferencesAndProvidersPush() {
        let app = launch(["seed"])
        openAskFromTab(app, 0)
        tap(app, "ask-history")
        tap(app, "ask-history-preferences")
        XCTAssertTrue(app.buttons["coach-instructions-save"].waitForExistence(timeout: 10))
        app.navigationBars["Coach preferences"].buttons.firstMatch.tap()
        tap(app, "ask-history-providers")
        XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 10))
        tap(app, "ask-sheet-done")
        XCTAssertTrue(app.buttons["ask-history"].waitForExistence(timeout: 10))
        tap(app, "ask-history")
        tap(app, "ask-history-new")
        XCTAssertTrue(app.staticTexts["What do you want to know?"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "ask-origin").exists, "a new chat keeps the origin")
    }

    @MainActor func testProviderChipOpensAIProviders() {
        let app = launch()
        openAskFromTab(app, 0)
        tap(app, "ask-provider")
        XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 10))
    }

    @MainActor func testSharedDataReviewOpensFromHistory() {
        let app = launch(["consented"])
        openAskFromTab(app, 0)
        tap(app, "ask-history")
        tap(app, "ask-history-review")
        XCTAssertTrue(app.buttons["coach-confirm-consent"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.switches["coach-share-metrics"].exists || element(app, "coach-share-metrics").exists)
        XCTAssertTrue(element(app, "coach-share-journalAnswers+journalNotes").exists)
        XCTAssertTrue(element(app, "coach-share-cycle").exists)
    }

    // MARK: Dictation

    @MainActor func testDictationFillsTheFieldAndStopsOnSecondTap() {
        let app = launch(["dictation"])
        openAskFromTab(app, 0)
        let mic = app.buttons["coach-dictate"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertEqual(mic.label, "Dictate message")
        mic.tap()
        XCTAssertEqual(mic.label, "Stop dictation")
        XCTAssertEqual(composer(app).value as? String, "Why did I sleep worse this week?")
        XCTAssertTrue(app.staticTexts["Listening on this iPhone. Review your draft before sending."].exists)
        XCTAssertFalse(element(app, "coach-user-message").exists, "dictation never sends")
        mic.tap()
        XCTAssertEqual(mic.label, "Dictate message")
        XCTAssertTrue(app.buttons["coach-send"].exists)
    }

    // MARK: Camera

    @MainActor func testCameraButtonClosesAskAndOpensFoodCapture() {
        let app = launch()
        openAskFromTab(app, 0)
        tap(app, "ask-photo")
        XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10))
        // The tab changes as the sheet finishes closing.
        let food = app.tabBars.buttons["Food"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: food)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["food-capture-close"].waitForExistence(timeout: 15))
    }
}
