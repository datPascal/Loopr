import XCTest

/// LV-08b step 5: the weight and body composition log. Opens from the Body screen on the fixture launches, where
/// entries live in memory for the launch. The populated fixture holds two weights a Withings scale wrote to Apple
/// Health and no body fat, so the absent state shows next to a real value.
final class BodyLogUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    /// `startAt` is the `--loopr-start-at=` value: `body` opens the Body screen, `body-log` opens the log on top of it.
    private func launch(mode: String, startAt: String = "body-log") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=\(mode)", "--loopr-metric-history-fixture", "--loopr-coach-fixture",
            "--loopr-your-data-fixture", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU",
            "--loopr-start-at=\(startAt)"]
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, startAt == "body" ? "body-screen" : "body-log-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    /// Scrolls the Body screen until its log row can take a tap, then opens the log.
    @MainActor private func openLog(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(app, "body-log-open")
        for _ in 0..<14 where !(row.exists && app.showsInContent(row)) { app.dragContent(up: true) }
        XCTAssertTrue(row.waitForExistence(timeout: wait), "the Body screen has no log row", file: file, line: line)
        row.tap()
        XCTAssertTrue(element(app, "body-log-screen").waitForExistence(timeout: wait), file: file, line: line)
    }

    @MainActor private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let field = app.textFields[id].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: wait), "\(id) is missing")
        return field
    }

    @MainActor func testTheLogShowsAppleHealthWeightsWithTheirSourceAndBodyFatAsNotRecorded() {
        let app = launch(mode: "populated", startAt: "body")
        // The Body screen reads the newest weight from Apple Health, labelled, and opens the log from its row.
        let weightSource = element(app, "body-composition-source-weight")
        for _ in 0..<14 where !(weightSource.exists && app.showsInContent(weightSource)) { app.dragContent(up: true) }
        XCTAssertTrue(weightSource.exists)
        XCTAssertTrue(weightSource.label.contains("Withings"), weightSource.label)
        openLog(app)
        XCTAssertTrue(element(app, "body-log-trend").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "body-log-trend-weight").exists)
        let healthChips = elements(app, prefix: "body-log-source-health-").allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(healthChips.count, 2, "both Withings weights are listed")
        XCTAssertTrue(healthChips.allSatisfy { $0.label.contains("Withings") }, healthChips.map(\.label).joined(separator: ", "))
        // Body fat and lean mass were never logged: they read "Not recorded", not 0.
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Not recorded")).count, 2)
        // Apple Health entries say they cannot be edited here and offer no delete.
        XCTAssertTrue(app.staticTexts["Read from Apple Health. It cannot be edited here."].firstMatch.exists)
        XCTAssertEqual(elements(app, prefix: "body-log-delete-").count, 0)
    }

    @MainActor func testAnEntryIsAddedShownAsTypedInAndDeletedWithUndo() {
        let app = launch(mode: "populated")
        XCTAssertEqual(elements(app, prefix: "body-log-delete-").count, 0)

        element(app, "body-log-add").tap()
        let weight = field(app, "body-entry-weight")
        weight.tap(); weight.typeText("78.4")
        let bodyFat = field(app, "body-entry-body-fat")
        bodyFat.tap(); bodyFat.typeText("21.5")
        XCTAssertTrue(element(app, "body-entry-lean-mass").exists)
        XCTAssertTrue(element(app, "body-entry-date").exists)
        element(app, "body-entry-save").tap()
        XCTAssertTrue(element(app, "body-entry-save").waitForNonExistence(timeout: wait), "the sheet closes after a save")

        // The new entry carries the typed-in chip next to the Apple Health ones, and is the only one with a delete.
        let typedChip = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "body-log-source-", "From what you typed in")).firstMatch
        XCTAssertTrue(typedChip.waitForExistence(timeout: wait))
        XCTAssertGreaterThanOrEqual(elements(app, prefix: "body-log-source-health-").count, 2, "Apple Health entries stay")
        let delete = elements(app, prefix: "body-log-delete-").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: wait))
        XCTAssertEqual(elements(app, prefix: "body-log-delete-").count, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "78.4")).firstMatch.exists)

        delete.tap()
        XCTAssertTrue(typedChip.waitForNonExistence(timeout: wait), "the entry is gone after delete")
        let undo = element(app, "loopr-toast-action")
        XCTAssertTrue(undo.waitForExistence(timeout: wait))
        undo.tap()
        XCTAssertTrue(typedChip.waitForExistence(timeout: wait), "Undo brings the entry back")

        elements(app, prefix: "body-log-delete-").firstMatch.tap()
        XCTAssertTrue(typedChip.waitForNonExistence(timeout: wait))
        XCTAssertEqual(elements(app, prefix: "body-log-delete-").count, 0)
    }

    @MainActor func testSavingWithoutAWeightShowsTheErrorAndKeepsTheSheetOpen() {
        let app = launch(mode: "populated")
        element(app, "body-log-add").tap()
        XCTAssertTrue(element(app, "body-entry-save").waitForExistence(timeout: wait))
        element(app, "body-entry-save").tap()
        let error = element(app, "body-entry-error")
        XCTAssertTrue(error.waitForExistence(timeout: wait))
        XCTAssertTrue(error.label.contains("Enter a weight"), error.label)
        XCTAssertTrue(element(app, "body-entry-weight").exists)

        let weight = field(app, "body-entry-weight")
        weight.tap(); weight.typeText("5")
        element(app, "body-entry-save").tap()
        XCTAssertTrue(error.waitForExistence(timeout: wait))
        XCTAssertTrue(error.label.contains("between 20 and 400"), error.label)
    }

    @MainActor func testNothingLoggedAndNoAppleHealthShowsWhereValuesComeFromAndALogButton() {
        let app = launch(mode: "empty")
        let empty = element(app, "body-log-empty")
        XCTAssertTrue(empty.waitForExistence(timeout: wait))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "what you type in and from Apple Health")).firstMatch.exists)
        let log = app.buttons["body-log-empty-add"].firstMatch
        XCTAssertTrue(log.exists)
        log.tap()
        XCTAssertTrue(element(app, "body-entry-weight").waitForExistence(timeout: wait))
    }
}
