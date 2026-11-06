import XCTest

/// The capacity tests on the seeded fixture (Alex, Tuesday 2023-11-14 in Perth). The fixture's clock
/// starts at the fixture's morning and runs in real time, so a timed test takes real seconds; results
/// save in memory for the launch.
final class FitnessCapacityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-entrance-final-state",
                               "--loopr-deep-link=train", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let button = app.buttons[id].firstMatch
        return button.exists || button.waitForExistence(timeout: 5) ? button : element(app, id)
    }

    @MainActor private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<12 where !(target.exists && app.showsInContent(target)) { app.dragContent(up: true) }
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        return target
    }

    /// Waits until `element`'s label satisfies `format`, without a fixed sleep.
    @MainActor private func waitForLabel(_ element: XCUIElement, _ format: String, _ args: CVarArg...,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: wait), .completed,
                       "label stayed \(element.label)", file: file, line: line)
    }

    @MainActor func testADeadHangIsTimedSavedAndLandsInItsTile() {
        let app = launch()
        let tile = reveal(app, "fitness-capacity-dead-hang")
        XCTAssertTrue(tile.label.contains("1 minute 24 seconds"), tile.label)
        tile.tap()
        XCTAssertTrue(element(app, "fitness-test-dead-hang").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-test-instructions").exists)

        let start = button(app, "fitness-test-start")
        XCTAssertTrue(start.waitForExistence(timeout: wait))
        XCTAssertGreaterThanOrEqual(start.frame.height, 56)
        start.tap()
        let hero = element(app, "fitness-test-hero")
        // The 3-2-1 lead-in, then the run: wait until two seconds have passed on the clock.
        waitForLabel(hero, "label CONTAINS %@", "Tap Stop when you let go")
        waitForLabel(hero, "label MATCHES %@", "^([2-9]|[1-9][0-9])\\.[0-9] seconds.*")
        button(app, "fitness-test-stop").tap()

        let save = button(app, "fitness-test-save")
        XCTAssertTrue(save.waitForExistence(timeout: wait))
        save.tap()
        XCTAssertTrue(element(app, "fitness-test-dead-hang").waitForNonExistence(timeout: wait))
        let updated = element(app, "fitness-capacity-dead-hang")
        waitForLabel(updated, "NOT (label CONTAINS %@)", "1 minute 24 seconds")
        XCTAssertTrue(updated.label.contains("seconds"), updated.label)
    }

    @MainActor func testStoppingTheCountdownAndCancellingLeaveTheTileAlone() {
        let app = launch()
        reveal(app, "fitness-capacity-one-leg-balance").tap()
        XCTAssertTrue(element(app, "fitness-test-one-leg-balance").waitForExistence(timeout: wait))
        XCTAssertTrue(button(app, "fitness-test-side-right").exists)
        button(app, "fitness-test-side-right").tap()
        button(app, "fitness-test-start").tap()
        // A stop inside the countdown goes back to Start.
        button(app, "fitness-test-stop").tap()
        XCTAssertTrue(button(app, "fitness-test-start").waitForExistence(timeout: wait))
        button(app, "fitness-test-cancel").tap()
        XCTAssertTrue(element(app, "fitness-test-one-leg-balance").waitForNonExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-capacity-one-leg-balance").label.contains("18 seconds"))
    }

    @MainActor func testGripForBothHandsSavesTheBestOfEach() {
        let app = launch()
        reveal(app, "fitness-capacity-grip").tap()
        XCTAssertTrue(element(app, "fitness-test-grip").waitForExistence(timeout: wait))

        button(app, "fitness-test-side-right").tap()
        let plus = button(app, "fitness-grip-plus")
        XCTAssertTrue(plus.waitForExistence(timeout: wait))
        for _ in 0..<4 { plus.tap() }
        button(app, "fitness-grip-add-trial").tap()
        XCTAssertTrue(element(app, "fitness-grip-trial-right-0").waitForExistence(timeout: wait))

        button(app, "fitness-test-side-left").tap()
        button(app, "fitness-grip-minus").tap()
        button(app, "fitness-grip-add-trial").tap()
        XCTAssertTrue(element(app, "fitness-grip-trial-left-0").waitForExistence(timeout: wait))

        button(app, "fitness-test-save").tap()
        XCTAssertTrue(element(app, "fitness-test-grip").waitForNonExistence(timeout: wait))
        let tile = element(app, "fitness-capacity-grip")
        waitForLabel(tile, "label CONTAINS %@", "42 kilograms")
    }

    @MainActor func testAGoalFor85IsSetFromTheResults() {
        let app = launch()
        reveal(app, "fitness-capacity-dead-hang").tap()
        button(app, "fitness-test-history").tap()
        XCTAssertTrue(element(app, "fitness-capacity-history").waitForExistence(timeout: wait))
        let setGoal = button(app, "fitness-goal-dead-hang")
        XCTAssertTrue(setGoal.waitForExistence(timeout: wait))
        setGoal.tap()
        XCTAssertTrue(element(app, "fitness-goal-trajectory").waitForExistence(timeout: wait))
    }
}
