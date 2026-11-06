import XCTest

/// The workout builder, from the Train tab. The Train overview and its fixture belong to the
/// overview task: these tests open `train-template-upper-a` and `train-template-new` from it.
final class TemplateBuilderUITests: XCTestCase {
    private static let launchArguments = [
        "--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-coach-fixture", "--loopr-deep-link=train",
        // Saved workouts sit in the Fitness tab's Plans fold; start it open.
        "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"
    ]

    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: Existing template

    @MainActor func testUpperAReorderEditSetsToggleBandCueSaveAndReopen() throws {
        let app = launch()
        defer { attach(app) }
        openUpperA(app)

        // Reorder through the editor's Move down button, which reaches the same model move as the row's action.
        XCTAssertTrue(app.buttons["template-exercise-0"].label.hasPrefix("Bench press"))
        tap(app, "template-exercise-0")
        tap(app, "exercise-editor-move-down")
        tap(app, "exercise-editor-apply")
        waitForLabel(app.buttons["template-exercise-0"], prefix: "Pull-up")
        waitForLabel(app.buttons["template-exercise-1"], prefix: "Bench press")
        XCTAssertTrue(app.buttons["template-exercise-1"].label.contains("4 sets"), app.buttons["template-exercise-1"].label)

        // Edit a set count.
        tap(app, "template-exercise-1")
        tap(app, "exercise-editor-sets-plus")
        tap(app, "exercise-editor-apply")
        waitForLabel(app.buttons["template-exercise-1"], contains: "5 sets")

        // The superset stays one block with its chip.
        XCTAssertTrue(app.descendants(matching: .any)["template-exercise-group-4"].firstMatch.waitForExistence(timeout: 30))

        // Band cue.
        let cue = app.switches["template-rule-band-cue"].firstMatch
        reach(app, cue)
        XCTAssertEqual(cue.value as? String, "1")
        cue.tap()
        XCTAssertEqual(cue.value as? String, "0")

        tap(app, "template-save")
        XCTAssertTrue(upperARow(app).waitForExistence(timeout: 30), "Save should pop to the Train overview")

        // Persistence inside the session: the screen reloads from storage.
        openUpperA(app)
        waitForLabel(app.buttons["template-exercise-0"], prefix: "Pull-up")
        waitForLabel(app.buttons["template-exercise-1"], contains: "5 sets")
        let reopenedCue = app.switches["template-rule-band-cue"].firstMatch
        reach(app, reopenedCue)
        XCTAssertEqual(reopenedCue.value as? String, "0")
    }

    @MainActor func testSavedEditSurvivesARelaunch() throws {
        // A store name of its own keeps the fixture database across the relaunch, and keeps this run
        // apart from every other.
        let store = "template-relaunch-\(UUID().uuidString.prefix(8))"
        var app = launch(store: store)
        openUpperA(app)
        tap(app, "template-exercise-0")
        tap(app, "exercise-editor-sets-plus")
        tap(app, "exercise-editor-apply")
        waitForLabel(app.buttons["template-exercise-0"], contains: "5 sets")
        tap(app, "template-save")
        XCTAssertTrue(upperARow(app).waitForExistence(timeout: 30))
        app.terminate()

        app = launch(store: store)
        defer { attach(app) }
        openUpperA(app)
        let first = app.buttons["template-exercise-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertTrue(first.label.contains("5 sets"), first.label)
    }

    @MainActor func testBackAsksBeforeDiscardingEditsAndLeavesACleanTemplateAtOnce() {
        let app = launch()
        defer { attach(app) }
        openUpperA(app)

        // No edits: back leaves without a prompt.
        tap(app, "template-cancel")
        XCTAssertTrue(upperARow(app).waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["template-discard-confirm"].exists)

        // With an edit: back asks first.
        openUpperA(app)
        let cue = app.switches["template-rule-band-cue"].firstMatch
        reach(app, cue)
        let before = cue.value as? String
        cue.tap()
        XCTAssertNotEqual(cue.value as? String, before)
        tap(app, "template-cancel")
        XCTAssertTrue(app.buttons["template-discard-confirm"].waitForExistence(timeout: 30))
        // iOS 26 shows the dialog as a popover from Back and hides the cancel button; tapping outside keeps editing.
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists { outside.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.9)).tap() } else { tap(app, "template-keep-editing") }
        XCTAssertTrue(app.buttons["template-discard-confirm"].waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.buttons["template-save"].waitForExistence(timeout: 30))
        tap(app, "template-cancel")
        tap(app, "template-discard-confirm")
        XCTAssertTrue(upperARow(app).waitForExistence(timeout: 30))

        // The discarded edit is gone.
        openUpperA(app)
        let reopened = app.switches["template-rule-band-cue"].firstMatch
        reach(app, reopened)
        XCTAssertEqual(reopened.value as? String, before)
    }

    @MainActor func testRulesSheetsAndTheDescribeFieldOpen() {
        let app = launch()
        defer { attach(app) }
        openUpperA(app)

        tap(app, "template-rule-progression")
        tap(app, "progression-kind-linear")
        tap(app, "progression-apply")
        let row = app.buttons["template-rule-progression"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(row.label.contains("after each session"), row.label)

        let recovery = app.switches["template-rule-recovery"].firstMatch
        reach(app, recovery)
        XCTAssertNotNil(recovery.value)

        tap(app, "template-describe")
        let origin = app.descendants(matching: .any)["ask-origin"].firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 30))
        XCTAssertTrue(origin.label.contains("Workout builder"), origin.label)
    }

    // MARK: New template

    @MainActor func testNewTemplateNeedsANameAndAnExerciseThenSavesWithLibraryAndCustomExercises() {
        let app = launch()
        defer { attach(app) }
        tap(app, "train-template-new")

        // Nothing to save yet.
        let save = app.buttons["template-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        XCTAssertFalse(save.isEnabled)

        let name = app.textFields["template-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        name.tap()
        name.typeText("Pull day\n")
        XCTAssertFalse(save.isEnabled, "A name alone is not enough")
        tap(app, "template-days-mon")

        // A library exercise.
        tap(app, "template-add-exercise")
        let search = app.textFields["exercise-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("pull")
        let first = app.buttons["exercise-result-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        let libraryName = first.label.components(separatedBy: ",").first ?? ""
        XCTAssertFalse(libraryName.isEmpty)
        first.tap()
        waitForLabel(app.buttons["template-exercise-0"], prefix: libraryName)
        XCTAssertTrue(save.isEnabled)

        // A custom exercise.
        tap(app, "template-add-exercise")
        tap(app, "exercise-custom-new")
        let customName = app.textFields["exercise-custom-name"].firstMatch
        XCTAssertTrue(customName.waitForExistence(timeout: 30))
        customName.tap()
        customName.typeText("Sled push\n")
        tap(app, "exercise-custom-save")
        waitForLabel(app.buttons["template-exercise-1"], prefix: "Sled push")

        // Pair them as a superset from the editor.
        tap(app, "template-exercise-0")
        tap(app, "exercise-editor-superset-below")
        tap(app, "exercise-editor-apply")
        XCTAssertTrue(app.descendants(matching: .any)["template-exercise-group-0"].firstMatch.waitForExistence(timeout: 30))

        tap(app, "template-save")
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "train-template-", "Pull day")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "The new template should appear in the Train overview")

        // It reloads from storage with both exercises, still paired.
        saved.tap()
        waitForLabel(app.buttons["template-exercise-0"], prefix: libraryName)
        waitForLabel(app.buttons["template-exercise-1"], prefix: "Sled push")
        XCTAssertTrue(app.descendants(matching: .any)["template-exercise-group-0"].firstMatch.exists)
    }

    @MainActor func testPickerFiltersByEquipmentAndMuscle() {
        let app = launch()
        defer { attach(app) }
        tap(app, "train-template-new")
        tap(app, "template-add-exercise")
        XCTAssertTrue(app.textFields["exercise-search"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["exercise-result-0"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["exercise-filter-equipment"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["exercise-filter-muscle"].firstMatch.exists)
        let search = app.textFields["exercise-search"].firstMatch
        search.tap()
        search.typeText("zzzzzz")
        XCTAssertTrue(app.descendants(matching: .any)["exercise-empty"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["exercise-result-0"].exists)
    }

    // MARK: Helpers

    @MainActor private func launch(store: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.launchArguments + (store.map { ["--loopr-train-fixture-store=\($0)"] } ?? [])
        app.launch()
        app.activate()
        return app
    }

    @MainActor private func upperARow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["train-template-upper-a"].firstMatch
    }

    @MainActor private func openUpperA(_ app: XCUIApplication) {
        let row = upperARow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Missing train-template-upper-a")
        reach(app, row)
        row.tap()
        XCTAssertTrue(app.buttons["template-save"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["template-exercise-0"].waitForExistence(timeout: 30))
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let element = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 30), "Missing \(id)")
        reach(app, element)
        element.tap()
    }

    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<12 { if element.exists && element.isHittable { return }; app.swipeUp() }
        for _ in 0..<12 { if element.exists && element.isHittable { return }; app.swipeDown() }
        XCTFail("Could not reach \(element)")
    }

    @MainActor private func waitForLabel(_ element: XCUIElement, prefix: String? = nil, contains: String? = nil,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = prefix.map { NSPredicate(format: "label BEGINSWITH %@", $0) }
            ?? NSPredicate(format: "label CONTAINS %@", contains ?? "")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 30)
        XCTAssertEqual(result, .completed, "Label was \(element.label)", file: file, line: line)
    }

    @MainActor private func attach(_ app: XCUIApplication) {
        let frame = XCTAttachment(screenshot: app.screenshot())
        frame.lifetime = .keepAlways
        add(frame)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.lifetime = .keepAlways
        add(tree)
    }
}
