import XCTest

final class CoachChatUITests: XCTestCase {
    @MainActor
    func testCoachConsentStreamingHistoryAndProviderSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture"]
        app.launch()
        // The Coach card left Today with its More grid (FT-05.5). The header button opens the same Ask sheet.
        let coach = app.buttons["today-header-coach"]
        XCTAssertTrue(coach.waitForExistence(timeout: 10)); coach.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        capture("coach-empty")
        composer.tap(); composer.typeText("How should I train today?")
        app.buttons["coach-send"].tap()
        let consent = app.buttons["coach-confirm-consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        capture("coach-consent")
        for _ in 0..<5 { if consent.isHittable { break }; app.swipeUp() }
        consent.tap()
        let saved = app.buttons["Save to notes"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        capture("coach-reply")
        saved.tap(); app.sheets.buttons["Save to notes"].tap()
        XCTAssertTrue(app.buttons["Saved to notes"].waitForExistence(timeout: 5))
        app.buttons["ask-history"].tap(); app.buttons["ask-history-new"].tap()
        XCTAssertTrue(app.staticTexts["What do you want to know?"].waitForExistence(timeout: 5))
        app.buttons["ask-history"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "How should I train today?").firstMatch.waitForExistence(timeout: 5))
        app.buttons["ask-sheet-done"].tap()
        app.buttons["ask-history"].tap(); app.buttons["ask-history-providers"].tap()
        XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 5))
        app.buttons["Claude"].tap()
        app.secureTextFields["settings-ai-api-key"].tap()
        app.secureTextFields["settings-ai-api-key"].typeText("fixture-claude-key")
        // Saving closes the sheet, so tap by coordinate: a normal tap re-resolves the button afterwards.
        let save = app.buttons["settings-ai-save-provider"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Saving a key closes the sheet and returns to the chat.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.secureTextFields["settings-ai-api-key"].exists)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

}

/// One test per coach state. The fixture launch arguments are documented in CoachUITestFixtures.
final class CoachChatStateUITests: XCTestCase {
    @MainActor private func launch(_ flags: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture"] + flags.map { "--loopr-coach-fixture-" + $0 }
        app.launch()
        let header = app.buttons["today-header-coach"]
        if header.waitForExistence(timeout: 5) { header.tap(); return app }
        let coach = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Coach")).firstMatch
        for _ in 0..<8 { if coach.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(coach.waitForExistence(timeout: 10)); coach.tap()
        return app
    }
    @MainActor private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// The Shared data button scrolls away in a long chat, so the menu is the reliable way in.
    @MainActor private func openConsentFromMenu(_ app: XCUIApplication) {
        app.buttons["ask-history"].tap()
        app.buttons["ask-history-review"].tap()
    }
    @MainActor private func journalSwitch(_ app: XCUIApplication) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Check-ins and notes")).firstMatch
    }
    @MainActor private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText(text)
        app.buttons["coach-send"].tap()
    }

    @MainActor func testNoProviderShowsConnectCardAndOpensProviders() throws {
        let app = launch(["no-provider"])
        let connect = app.buttons["coach-connect-provider"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch.exists)
        capture("state-no-provider")
        connect.tap()
        XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 5))
    }
    @MainActor func testSlowLoadNeverShowsConnectCard() throws {
        let app = launch(["slow-load"])
        XCTAssertFalse(app.buttons["coach-connect-provider"].exists)
        capture("state-loading")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["coach-connect-provider"].exists)
    }
    @MainActor func testStarterFillsDraftAndNeverSends() throws {
        let app = launch(["consented"])
        let starter = app.buttons["How should I train today?"]
        XCTAssertTrue(starter.waitForExistence(timeout: 10))
        starter.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "coach-composer").firstMatch
        XCTAssertEqual(composer.value as? String, "How should I train today?")
        XCTAssertFalse(app.buttons["Save to notes"].exists)
        XCTAssertFalse(starter.exists, "starters collapse once a draft exists")
        capture("state-starter-filled")
    }
    @MainActor func testFailedReplyShowsCardWithRetry() throws {
        let app = launch(["consented", "failed"])
        send(app, "How should I train today?")
        XCTAssertTrue(app.buttons["coach-retry-reply"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["coach-error"].exists)
        capture("state-failed")
    }
    @MainActor func testInterruptedReplyKeepsPartialTextAndOffersRetry() throws {
        let app = launch(["consented", "interrupted"])
        send(app, "How should I train today?")
        XCTAssertTrue(app.buttons["coach-retry-reply"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connection dropped"].exists)
        XCTAssertTrue(app.otherElements["coach-assistant-message"].exists, "the partial reply stays on screen")
        capture("state-interrupted")
    }
    @MainActor func testOfflineShowsNoConnection() throws {
        let app = launch(["consented", "fail=offline"])
        send(app, "How should I train today?")
        XCTAssertTrue(app.staticTexts["No connection"].waitForExistence(timeout: 10))
        capture("state-offline")
    }
    @MainActor func testRejectedKeyOffersProviders() throws {
        let app = launch(["consented", "fail=invalid-key"])
        send(app, "How should I train today?")
        let action = app.buttons["coach-problem-action-0"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        capture("state-invalid-key")
        action.tap()
        XCTAssertTrue(app.secureTextFields["settings-ai-api-key"].waitForExistence(timeout: 5))
    }
    @MainActor func testSeededThreadHistoryAndConsent() throws {
        let app = launch(["seed"])
        XCTAssertTrue(app.otherElements["coach-assistant-message"].waitForExistence(timeout: 10))
        capture("thread-markdown")
        app.buttons["ask-history"].tap()
        XCTAssertTrue(app.buttons["coach-history-row"].firstMatch.waitForExistence(timeout: 5))
        capture("history")
        app.buttons.matching(identifier: "coach-history-row").element(boundBy: 1).swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.sheets.buttons["Delete chat"].waitForExistence(timeout: 3), "the confirmation appears inside the sheet")
        capture("history-delete")
        app.sheets.buttons["Delete chat"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "coach-history-row").firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "coach-history-row").count, 1)
        app.buttons["ask-sheet-done"].tap()
        openConsentFromMenu(app)
        XCTAssertTrue(app.buttons["coach-confirm-consent"].waitForExistence(timeout: 8))
        capture("consent")
    }
    @MainActor func testConsentCancelThenAllowStillWorks() throws {
        let app = launch(["seed"])
        openConsentFromMenu(app)
        let journal = journalSwitch(app)
        XCTAssertTrue(journal.waitForExistence(timeout: 5))
        journal.tap()
        app.buttons["coach-cancel-consent"].tap()
        XCTAssertFalse(app.buttons["coach-confirm-consent"].waitForExistence(timeout: 2))
        openConsentFromMenu(app)
        XCTAssertEqual(journalSwitch(app).value as? String, "0")
        let allow = app.buttons["coach-confirm-consent"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertFalse(allow.waitForExistence(timeout: 2), "Allow closes the sheet")
    }
    @MainActor func testEmptyDataWarnsInConsent() throws {
        let app = launch(["empty-data"])
        send(app, "How should I train today?")
        XCTAssertTrue(app.buttons["coach-confirm-consent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Loopr found no saved measurements for the last 30 days. Ask can still answer general questions."].waitForExistence(timeout: 5))
        capture("consent-no-data")
    }
}
