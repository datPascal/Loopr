import XCTest

final class FoodOverviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testDrinkAndTargetChangesWaitForSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        defer { capture(app, "food-overview-final") }
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["food-energy-hero"].firstMatch.waitForExistence(timeout: 20))
        capture(app, "food-overview-top")
        tap(app, "food-drink-water")
        let amount = app.textFields["food-drink-amount"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 30))
        amount.tap(); amount.typeText("300")
        tap(app, "food-cancel-drink")
        XCTAssertTrue(app.buttons["food-drink-water"].label.contains("1.2"))
        tap(app, "food-drink-water")
        amount.tap(); amount.typeText("300")
        tap(app, "food-save-drink")
        capture(app, "food-after-water-save")
        XCTAssertFalse(app.staticTexts["food-editor-error"].exists)
        expect(app.buttons["food-drink-water"], contains: "1.5")
        select(app, "Data"); select(app, "Food")
        expect(app.buttons["food-drink-water"], contains: "1.5")

        // Targets are set in the goal planner, opened from this day's sheet, the one door to targets.
        tap(app, "food-targets"); tap(app, "food-day-open-plan")
        let base = app.textFields["food-target-base"].firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 30))
        tap(app, "food-target-base")
        replace(base, with: "2500")
        tap(app, "food-cancel-plan")
        tap(app, "food-targets"); tap(app, "food-day-open-plan")
        XCTAssertTrue(base.waitForExistence(timeout: 30))
        tap(app, "food-target-base")
        XCTAssertEqual(base.value as? String, "2270")
        replace(base, with: "2500")
        tap(app, "food-save-targets")
        capture(app, "food-after-target-save")
        expect(app.descendants(matching: .any)["food-targets"].firstMatch, contains: "2,680")
    }

    /// The planner works out a target from the person and their goal, saves it with the weight, and the
    /// Goal card follows the weight from there.
    @MainActor func testPlannerSetsTargetsAndTheWeightLogFollowsTheGoal() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        defer { capture(app, "food-planner-final") }
        XCTAssertTrue(app.descendants(matching: .any)["food-energy-hero"].firstMatch.waitForExistence(timeout: 30))

        tap(app, "food-targets"); tap(app, "food-day-open-plan")
        XCTAssertTrue(app.descendants(matching: .any)["food-planner"].firstMatch.waitForExistence(timeout: 30))
        choose(app, "Goal, Lose weight")
        for (id, value) in [("age", "34"), ("height", "180"), ("weight", "84")] {
            tap(app, "food-target-\(id)")
            replace(app.textFields["food-target-\(id)"].firstMatch, with: value)
        }
        choose(app, "Sex, Male")
        tap(app, "food-target-goal-weight")
        replace(app.textFields["food-target-goal-weight"].firstMatch, with: "78")
        // 10 × 84 + 6.25 × 180 − 5 × 34 + 5 = 1,800 at rest, × 1.2 = 2,160, less 550 for 0.5 kg a week.
        expect(app.descendants(matching: .any)["food-plan-energy"].firstMatch, contains: "1,610")
        XCTAssertTrue(app.descendants(matching: .any)["food-plan-date"].firstMatch.waitForExistence(timeout: 15))
        capture(app, "food-planner-result")
        // The fixture's saved numbers were typed by hand, so they stay until the plan's are chosen.
        tap(app, "food-use-suggestion")
        XCTAssertEqual(app.textFields["food-target-base"].firstMatch.value as? String, "1610")
        tap(app, "food-save-targets")

        expect(app.descendants(matching: .any)["food-targets"].firstMatch, contains: "1,790")
        expect(app.descendants(matching: .any)["food-goal-headline"].firstMatch, contains: "Losing 0.5 kg a week")
        expect(app.descendants(matching: .any)["food-weight-average"].firstMatch, contains: "84")

        tap(app, "food-log-weight")
        let value = app.textFields["food-weight-value"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 30))
        replace(value, with: "83.6")
        tap(app, "food-save-weight")
        expect(app.descendants(matching: .any)["food-weight-average"].firstMatch, contains: "83.8")
        capture(app, "food-goal-card")
    }

    /// Water logged says nothing about alcohol: the row stays "not logged" until the person finishes the day with
    /// "Done, no alcohol today". The finished row shows the day's summary. Reopening the day keeps that answer.
    @MainActor func testNoneTodayIsAnAnswerAndAnEmptyLogIsNot() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        defer { capture(app, "food-no-alcohol-final") }
        XCTAssertTrue(app.descendants(matching: .any)["food-energy-hero"].firstMatch.waitForExistence(timeout: 30))
        let alcohol = app.buttons["food-drink-alcohol"]
        expect(alcohol, contains: "not logged")
        tap(app, "food-done-today"); tap(app, "food-confirm-no-alcohol")
        expect(alcohol, contains: "0 units")
        expect(app.buttons["food-done-today"], contains: "Reopen")
        expect(app.descendants(matching: .any)["food-day-summary"].firstMatch, contains: "no alcohol")
        tap(app, "food-done-today"); tap(app, "food-confirm-completion")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND NOT (label CONTAINS %@)", "Reopen"),
                                             object: app.buttons["food-done-today"])
        XCTAssertEqual(XCTWaiter.wait(for: [open], timeout: 15), .completed)
        expect(app.buttons["food-done-today"], contains: "Done for today")
        expect(alcohol, contains: "0 units")
        // Alcohol is answered now, so Done finishes at once with an Undo that reopens.
        tap(app, "food-done-today")
        expect(app.buttons["food-done-today"], contains: "Reopen")
        XCTAssertFalse(app.buttons["food-confirm-completion"].exists)
    }

    @MainActor private func choose(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing \(label)")
        // A focused field keeps the form scrolled to itself. Drag the form down into the keypad to put it away,
        // as the forms dismiss the keyboard interactively.
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        }
        // Look below first, then above: after typing, the keyboard can leave the choice either side of the view.
        for _ in 0..<8 where !app.showsInContent(button) { app.dragContent(up: true) }
        for _ in 0..<12 where !app.showsInContent(button) { app.dragContent(up: false) }
        button.tap()
    }

    @MainActor private func select(_ app: XCUIApplication, _ tab: String) {
        let button = app.tabBars.buttons[tab]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)], timeout: 15), .completed)
        // Under load XCTest's synthesized tap can lift the iOS 26 tab lens without committing; tap again once.
        button.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: button)
        if XCTWaiter.wait(for: [selected], timeout: 5) != .completed { button.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: button)], timeout: 15), .completed)
    }
    @MainActor private func replace(_ field: XCUIElement, with value: String) {
        let old = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
        XCTAssertEqual(field.value as? String, value)
    }
    @MainActor private func expect(_ element: XCUIElement, contains text: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.descendants(matching: .any)[id].firstMatch
        // A row under the header counts as hittable, but the tap lands on the header's day buttons.
        for _ in 0..<12 {
            if app.showsInContent(button) { button.tap(); return }
            if button.exists, button.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<12 {
            if app.showsInContent(button) { button.tap(); return }
            app.dragContent(up: false)
        }
        capture(app, id + "-unreachable")
        XCTFail("Could not reach \(id)")
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
