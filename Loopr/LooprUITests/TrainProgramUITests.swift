import XCTest

/// Programs from the Train tab: the Strength block on the seeded fixture (Alex, Tuesday 2023-11-14, week 3 of 8),
/// the agent draft behind `--loopr-train-draft-fixture`, the editor and Calendar export with a fake Calendar.
final class TrainProgramUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Programs sit in the Fitness tab's Plans fold; start it open.
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-coach-fixture", "--loopr-deep-link=train",
                               "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Scrolls until the element can be tapped, then taps it.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        reach(app, target, file: file, line: line)
        target.tap()
    }

    @MainActor private func reach(_ app: XCUIApplication, _ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<20 {
            if app.showsInContent(target) { return }
            if target.exists, target.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 {
            if app.showsInContent(target) { return }
            app.dragContent(up: false)
        }
        XCTFail("Could not reach \(target.identifier)", file: file, line: line)
    }

    @MainActor private func back(_ app: XCUIApplication, to id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: wait), "Back is missing", file: file, line: line)
        button.tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: wait), "Did not return to \(id)", file: file, line: line)
    }

    @MainActor private func openStrengthBlock(_ app: XCUIApplication) {
        tap(app, "train-program-strength-block")
        XCTAssertTrue(element(app, "program-screen").waitForExistence(timeout: wait))
    }

    @MainActor private func hasText(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: wait)
    }

    // MARK: Strength block

    @MainActor func testStrengthBlockShowsHeroGridRulesAndSoFar() {
        let app = launch()
        openStrengthBlock(app)

        XCTAssertTrue(element(app, "program-hero").waitForExistence(timeout: wait))
        XCTAssertTrue(hasText(app, "Built from your request"))
        XCTAssertTrue(hasText(app, "Weeks 4 and 7 are lighter"))
        let grid = element(app, "program-grid")
        XCTAssertTrue(grid.waitForExistence(timeout: wait))
        let weekThree = element(app, "program-grid-w3")
        XCTAssertTrue(weekThree.waitForExistence(timeout: wait))
        XCTAssertTrue(weekThree.label.contains("Tuesday, Upper A, strength, today"), weekThree.label)
        XCTAssertTrue(element(app, "program-grid-w8").exists)

        for id in ["program-rule-early-light", "program-rule-calendar"] {
            let toggle = app.switches[id].firstMatch
            reach(app, toggle)
            XCTAssertTrue(toggle.exists, id)
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, id)
        }
        XCTAssertEqual(app.switches["program-rule-early-light"].firstMatch.value as? String, "1")
        XCTAssertEqual(app.switches["program-rule-calendar"].firstMatch.value as? String, "0")
        let missed = element(app, "program-rule-missed")
        XCTAssertTrue(missed.waitForExistence(timeout: wait))
        XCTAssertTrue(missed.label.contains("Move the week back, never double up"), missed.label)

        let soFar = element(app, "program-so-far")
        reach(app, soFar)
        XCTAssertTrue(hasText(app, "Sessions done"))
        XCTAssertTrue(hasText(app, "3 of 12"))
        XCTAssertTrue(hasText(app, "Back squat, estimated max"))
        XCTAssertTrue(hasText(app, "127"))
        XCTAssertTrue(element(app, "program-change-plan").waitForExistence(timeout: wait))
        XCTAssertTrue(app.buttons["program-edit"].exists)
        XCTAssertFalse(element(app, "program-draft-banner").exists)
    }

    @MainActor func testEarlyLightWeekToggleSurvivesLeavingAndReopening() {
        let app = launch()
        openStrengthBlock(app)
        let toggle = app.switches["program-rule-early-light"].firstMatch
        reach(app, toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        back(app, to: "workouts-screen")
        openStrengthBlock(app)
        let reopened = app.switches["program-rule-early-light"].firstMatch
        reach(app, reopened)
        XCTAssertEqual(reopened.value as? String, "0")
    }

    @MainActor func testMissedSessionChoiceOpensChangesTheRuleAndCloses() {
        let app = launch()
        openStrengthBlock(app)
        tap(app, "program-rule-missed")
        XCTAssertTrue(element(app, "program-missed-sheet").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "program-missed-move-back").waitForExistence(timeout: wait))
        tap(app, "program-missed-skip")
        XCTAssertTrue(element(app, "program-missed-sheet").waitForNonExistence(timeout: wait))
        let row = element(app, "program-rule-missed")
        XCTAssertTrue(row.waitForExistence(timeout: wait))
        XCTAssertTrue(row.label.contains("Skip it and carry on"), row.label)
    }

    @MainActor func testChangeThisPlanOpensAskFromTheProgram() {
        let app = launch()
        openStrengthBlock(app)
        tap(app, "program-change-plan")
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "ask-origin").label.contains("Program"), element(app, "ask-origin").label)
        tap(app, "ask-close")
        XCTAssertTrue(element(app, "program-screen").waitForExistence(timeout: wait))
    }

    @MainActor func testTodaysChipShowsThePlannedTime() {
        let app = launch()
        let card = element(app, "train-today-card")
        XCTAssertTrue(card.waitForExistence(timeout: wait))
        XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "18:30")).firstMatch.waitForExistence(timeout: wait))
    }

    // MARK: Calendar

    @MainActor func testCalendarSwitchAsksOnlyWhenTurnedOnAndDeniedShowsTheSettingsMessage() {
        let app = launch(["--loopr-train-calendar=denied"])
        openStrengthBlock(app)
        XCTAssertFalse(element(app, "program-calendar-denied").exists, "Nothing asks before the switch is used")
        let toggle = app.switches["program-rule-calendar"].firstMatch
        reach(app, toggle)
        toggle.tap()
        let message = element(app, "program-calendar-denied")
        XCTAssertTrue(message.waitForExistence(timeout: wait))
        XCTAssertEqual(message.label, "Calendar access is off. Turn it on in Settings to add sessions.")
        XCTAssertEqual(app.switches["program-rule-calendar"].firstMatch.value as? String, "0")
        XCTAssertTrue(element(app, "program-calendar-settings").exists)
    }

    @MainActor func testCalendarSwitchTurnsOnAndOffWhenAccessIsGranted() {
        let app = launch(["--loopr-train-calendar=granted"])
        openStrengthBlock(app)
        let toggle = app.switches["program-rule-calendar"].firstMatch
        reach(app, toggle)
        toggle.tap()
        XCTAssertTrue(waitForValue(toggle, "1"))
        XCTAssertFalse(element(app, "program-calendar-denied").exists)
        toggle.tap()
        XCTAssertTrue(waitForValue(toggle, "0"))
    }

    @MainActor private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: wait) == .completed
    }

    // MARK: Agent draft

    @MainActor func testDraftShowsOnTheOverviewAndAcceptMovesItIntoPrograms() {
        let app = launch(["--loopr-train-draft-fixture"])
        let card = element(app, "train-draft-spring-base")
        reach(app, element(app, "train-programs-header"))
        XCTAssertTrue(card.waitForExistence(timeout: wait))
        XCTAssertTrue(hasText(app, "Draft from Ask. Nothing is scheduled until you accept it."))
        // Not in the week strip, and not an active program row yet.
        XCTAssertFalse(element(app, "train-week-strip").label.contains("Easy ride"))
        tap(app, "program-draft-accept-spring-base")
        XCTAssertTrue(card.waitForNonExistence(timeout: wait))
        let row = element(app, "train-program-spring-base")
        XCTAssertTrue(row.waitForExistence(timeout: wait))
        XCTAssertTrue(row.label.contains("starts 20 Nov"), row.label)
    }

    @MainActor func testDiscardRemovesTheDraftFromTheOverview() {
        let app = launch(["--loopr-train-draft-fixture"])
        let card = element(app, "train-draft-spring-base")
        reach(app, element(app, "train-programs-header"))
        XCTAssertTrue(card.waitForExistence(timeout: wait))
        tap(app, "program-draft-discard-spring-base")
        XCTAssertTrue(card.waitForNonExistence(timeout: wait))
        XCTAssertFalse(element(app, "train-program-spring-base").exists)
        XCTAssertTrue(element(app, "train-program-strength-block").waitForExistence(timeout: wait))
    }

    @MainActor func testDraftScreenShowsTheBannerLocksCalendarAndAcceptsInPlace() {
        let app = launch(["--loopr-train-draft-fixture"])
        reach(app, element(app, "train-programs-header"))
        tap(app, "train-program-spring-base")
        XCTAssertTrue(element(app, "program-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "program-draft-banner").waitForExistence(timeout: wait))
        XCTAssertTrue(hasText(app, "Draft from Ask. Nothing is scheduled until you accept it."))
        XCTAssertTrue(element(app, "program-grid-w4").waitForExistence(timeout: wait))
        let calendar = app.switches["program-rule-calendar"].firstMatch
        reach(app, calendar)
        XCTAssertFalse(calendar.isEnabled)
        XCTAssertFalse(element(app, "program-so-far").exists)
        tap(app, "program-draft-accept")
        XCTAssertTrue(element(app, "program-draft-banner").waitForNonExistence(timeout: wait))
        XCTAssertTrue(element(app, "program-so-far").waitForExistence(timeout: wait))
    }

    @MainActor func testDraftScreenDiscardGoesBackWithoutTheDraft() {
        let app = launch(["--loopr-train-draft-fixture"])
        reach(app, element(app, "train-programs-header"))
        tap(app, "train-program-spring-base")
        tap(app, "program-draft-discard")
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "train-draft-spring-base").waitForNonExistence(timeout: wait))
    }

    // MARK: Editor

    @MainActor func testNewProgramOpensTheEditorAndSavesAProgramThatAppearsInTheOverview() {
        let app = launch()
        tap(app, "train-program-new")
        XCTAssertTrue(element(app, "program-editor").waitForExistence(timeout: wait))
        let save = app.buttons["program-editor-save"]
        XCTAssertTrue(save.waitForExistence(timeout: wait))
        XCTAssertFalse(save.isEnabled)
        let name = app.textFields["program-editor-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: wait))
        name.tap()
        name.typeText("Alex plan\n")
        XCTAssertFalse(save.isEnabled, "A name alone is not enough")

        tap(app, "program-editor-slot-monday")
        XCTAssertTrue(element(app, "program-editor-slot-sheet").waitForExistence(timeout: wait))
        tap(app, "program-editor-slot-template-upper-a")
        tap(app, "program-editor-slot-apply")
        XCTAssertTrue(element(app, "program-editor-slot-sheet").waitForNonExistence(timeout: wait))
        XCTAssertTrue(save.isEnabled)

        tap(app, "program-editor-add-week")
        XCTAssertTrue(element(app, "program-editor-week-5").waitForExistence(timeout: wait))
        tap(app, "program-editor-save")
        let row = element(app, "train-program-alex-plan")
        reach(app, element(app, "train-programs-header"))
        XCTAssertTrue(row.waitForExistence(timeout: wait), "The new program should appear in the Train overview")
    }

    @MainActor func testEditOpensTheEditorForTheProgramAndCancelAsksBeforeDiscarding() {
        let app = launch()
        openStrengthBlock(app)
        tap(app, "program-edit")
        XCTAssertTrue(element(app, "program-editor").waitForExistence(timeout: wait))
        let name = app.textFields["program-editor-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: wait))
        XCTAssertEqual(name.value as? String, "Strength block")
        tap(app, "program-editor-rule-early-light")
        tap(app, "program-editor-cancel")
        XCTAssertTrue(element(app, "program-editor-discard-confirm").waitForExistence(timeout: wait))
        tap(app, "program-editor-discard-confirm")
        XCTAssertTrue(element(app, "program-screen").waitForExistence(timeout: wait))
        let toggle = app.switches["program-rule-early-light"].firstMatch
        reach(app, toggle)
        XCTAssertEqual(toggle.value as? String, "1", "Discarded edits must not reach the program")
    }
}
