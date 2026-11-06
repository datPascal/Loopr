import XCTest

/// A strength session from the Train overview to the summary: template, prefilled sets, RPE, rest,
/// skip, swap, finish and personal bests. Alex trains in Australia/Perth on the fixture day,
/// Tuesday 2023-11-14, so today is Upper A. The fixture shortens every rest to two seconds.
final class TrainSessionFlowUITests: XCTestCase {
    private static let wait: TimeInterval = 30

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testUpperAFromTemplateToSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-train-fixture-rest-seconds=2",
            "--loopr-deep-link=train", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"
        ]
        app.launch()
        app.activate()
        defer { attach(app) }

        // Today's card names the template and the recovery check.
        let today = element(app, "train-today-summary")
        XCTAssertTrue(today.waitForExistence(timeout: Self.wait), "Missing train-today-summary")
        XCTAssertTrue(today.label.contains("Upper A"), today.label)
        XCTAssertTrue(today.label.contains("Recovery is 79"), today.label)
        tap(app, "train-start")

        // The set screen opens at set 1 of 4 with last time's load.
        XCTAssertTrue(element(app, "train-live-screen").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-live-eyebrow").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-live-eyebrow").label.contains("set 1 of 4"), element(app, "train-live-eyebrow").label)
        XCTAssertTrue(element(app, "train-live-exercise").label.contains("Bench press"))
        XCTAssertTrue(element(app, "train-live-last-time").label.contains("80 kg × 7, 7, 6, 6"), element(app, "train-live-last-time").label)
        XCTAssertEqual(stepperValue(app, label: "Weight"), "80 kilograms")
        XCTAssertEqual(stepperValue(app, label: "Reps"), "7 reps")
        XCTAssertTrue(element(app, "workout-live-heart-rate").waitForExistence(timeout: Self.wait))

        // Every control on the set screen is at least 56 pt tall.
        for id in ["train-log-set", "train-kg-minus", "train-kg-plus", "train-reps-7", "train-reps-8"] {
            let frame = element(app, id).frame
            XCTAssertGreaterThanOrEqual(frame.height, 55.5, "\(id) is \(frame.height) pt tall")
        }

        // One more rep than last time, then log the set.
        tap(app, "train-reps-8")
        XCTAssertEqual(stepperValue(app, label: "Reps"), "8 reps")
        tap(app, "train-log-set")
        let row = element(app, "train-set-row-1")
        XCTAssertTrue(row.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(row.label.contains("80 kilograms") && row.label.contains("8 reps") && row.label.contains("logged"), row.label)
        XCTAssertTrue(element(app, "train-rest-timer").waitForExistence(timeout: Self.wait))
        XCTAssertGreaterThanOrEqual(element(app, "train-set-row-1").frame.height, 55.5)
        XCTAssertGreaterThanOrEqual(element(app, "train-set-rpe-1").frame.height, 55.5)
        // Accessibility frames are clipped at the screen edge, so measure the rest controls once they are above the tab bar.
        reachAboveTabBar(app, element(app, "train-rest-done"))
        XCTAssertGreaterThanOrEqual(element(app, "train-rest-add").frame.height, 55.5)
        XCTAssertGreaterThanOrEqual(element(app, "train-rest-done").frame.height, 55.5)

        // RPE 8 on the first set.
        tap(app, "train-set-rpe-1")
        tap(app, "train-rpe-option-8")
        let rpe = element(app, "train-set-rpe-1")
        XCTAssertTrue(waitForLabel(rpe, contains: "RPE for set 1, 8"), rpe.label)

        // Adding thirty seconds grows the countdown, even when the two-second rest has already ended.
        let before = restSeconds(app)
        tap(app, "train-rest-add")
        let after = restSeconds(app)
        XCTAssertGreaterThan(after, before, "Rest went from \(before) s to \(after) s")
        XCTAssertGreaterThanOrEqual(after, 25)
        tap(app, "train-rest-done")
        XCTAssertTrue(waitForGone(element(app, "train-rest-timer")))

        // Finish the bench: three more sets keep the 8 reps.
        for number in 2...4 {
            tap(app, "train-log-set")
            XCTAssertTrue(element(app, "train-set-row-\(number)").waitForExistence(timeout: Self.wait))
        }

        // Exercise 2 is skipped from the menu.
        XCTAssertTrue(waitForLabel(element(app, "train-live-eyebrow"), contains: "Exercise 2 of 6"))
        tap(app, "train-exercise-menu")
        tap(app, "train-skip-exercise")
        XCTAssertTrue(waitForLabel(element(app, "train-live-eyebrow"), contains: "Exercise 3 of 6"))

        // Exercise 3 is swapped for the first alternative.
        tap(app, "train-exercise-menu")
        tap(app, "train-swap-exercise")
        tap(app, "train-swap-option-0")
        XCTAssertTrue(app.staticTexts["Swapped from Barbell row."].waitForExistence(timeout: Self.wait))

        // Finish with sets still open. The dialog says so.
        tap(app, "train-finish")
        tap(app, "train-finish-confirm")

        // The summary shows volume, sets and the bests with their labels.
        XCTAssertTrue(element(app, "train-summary-screen").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-summary-volume").label.contains("2,560"), element(app, "train-summary-volume").label)
        XCTAssertTrue(element(app, "train-summary-sets").label.contains("4"), element(app, "train-summary-sets").label)
        let best = element(app, "train-summary-pb-0")
        XCTAssertTrue(best.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(best.label.lowercased().contains("new best"), best.label)
        XCTAssertTrue(best.label.lowercased().contains("estimated"), best.label)
        XCTAssertTrue(best.label.contains("Bench press"), best.label)

        // Done opens the workout. Back returns to Train, where Upper A is listed as completed.
        tap(app, "train-summary-done")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: Self.wait))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let list = element(app, "train-this-week-list")
        XCTAssertTrue(list.waitForExistence(timeout: Self.wait))
        reach(app, list)
        let upper = list.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Upper A")).firstMatch
        XCTAssertTrue(upper.waitForExistence(timeout: Self.wait), "Upper A is not in This week: \(list.debugDescription)")
        XCTAssertTrue(upper.label.contains("Completed") || list.descendants(matching: .any)["Completed"].exists
                      || list.staticTexts["COMPLETED"].exists, upper.label)
    }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: Self.wait), "Missing \(id)")
        reach(app, target)
        target.tap()
    }

    @MainActor private func reach(_ app: XCUIApplication, _ target: XCUIElement) {
        for _ in 0..<10 { if target.exists && target.isHittable { return }; app.swipeUp() }
        for _ in 0..<10 { if target.exists && target.isHittable { return }; app.swipeDown() }
    }

    @MainActor private func reachAboveTabBar(_ app: XCUIApplication, _ target: XCUIElement) {
        func above() -> Bool {
            let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            return target.exists && target.isHittable && target.frame.maxY <= tabBarTop
        }
        for _ in 0..<10 { if above() { return }; app.swipeUp() }
        XCTAssertTrue(above(), "\(target) never cleared the tab bar")
    }

    /// The spoken value of a stepper, such as "80 kilograms".
    @MainActor private func stepperValue(_ app: XCUIApplication, label: String) -> String? {
        let value = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: Self.wait), "Missing the \(label) value")
        return value.value as? String
    }

    /// Whole seconds left on the rest card, read from its spoken value ("1 minute 45 seconds left. ...").
    @MainActor private func restSeconds(_ app: XCUIApplication) -> Int {
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Rest timer")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: Self.wait), "Missing the rest timer")
        let text = (card.value as? String) ?? ""
        func number(before word: String) -> Int {
            guard let range = text.range(of: #"(\d+) \#(word)"#, options: .regularExpression) else { return 0 }
            return Int(text[range].split(separator: " ").first ?? "") ?? 0
        }
        return number(before: "minute") * 60 + number(before: "second")
    }

    @MainActor private func waitForLabel(_ element: XCUIElement, contains text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: Self.wait) == .completed
    }

    @MainActor private func waitForGone(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: Self.wait) == .completed
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
