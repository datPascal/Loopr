import XCTest

/// A gym workout built while training: start empty, add exercises from the library, log, add and delete
/// sets, finish, then find the lift under Exercises. Alex trains in Australia/Perth on the fixture day.
final class TrainFreeformUITests: XCTestCase {
    private static let wait: TimeInterval = 30

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEmptyWorkoutToExerciseHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-train-fixture-rest-seconds=2",
            "--loopr-deep-link=train", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"
        ]
        app.launch()
        app.activate()
        defer { attach(app) }

        tap(app, "train-start-gym")
        XCTAssertTrue(element(app, "train-start-sheet").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-start-template-upper-a").exists, "Templates start from the same sheet")
        tap(app, "train-start-empty")

        // A blank workout asks for its first exercise.
        XCTAssertTrue(element(app, "train-live-empty").waitForExistence(timeout: Self.wait))
        shot(app, "train-free-empty")
        tap(app, "train-add-first-exercise")
        pick(app, "Barbell Bench Press - Medium")

        // The bench press picks up last time's 80 kg and four sets.
        let eyebrow = element(app, "train-live-eyebrow")
        XCTAssertTrue(eyebrow.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(eyebrow.label.contains("set 1 of 4"), eyebrow.label)
        XCTAssertTrue(element(app, "train-live-last-time").label.contains("80 kg × 7, 7, 6, 6"), element(app, "train-live-last-time").label)
        tap(app, "train-log-set")
        XCTAssertTrue(element(app, "train-set-row-1").waitForExistence(timeout: Self.wait))
        tap(app, "train-log-set")
        XCTAssertTrue(element(app, "train-set-row-2").waitForExistence(timeout: Self.wait))

        // One more set from the menu: set 3 of 5.
        tap(app, "train-exercise-menu")
        tap(app, "train-add-set")
        XCTAssertTrue(waitForLabel(eyebrow, contains: "set 3 of 5"), eyebrow.label)

        // Deleting the first logged set moves the second up.
        tap(app, "train-set-row-1")
        // The edit sheet carries the tag chips above Delete now (R2-LIFT-11), so Delete can sit below its fold.
        let delete = element(app, "train-edit-delete")
        for _ in 0..<3 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        tap(app, "train-edit-delete")
        XCTAssertTrue(waitForLabel(eyebrow, contains: "set 2 of 4"), eyebrow.label)

        // A second exercise joins the list under the set table.
        tap(app, "train-add-exercise")
        pick(app, "Pullups")
        XCTAssertTrue(element(app, "train-exercise-row-1").waitForExistence(timeout: Self.wait))
        shot(app, "train-free-live")
        app.dragContent(up: true)
        shot(app, "train-free-list")
        tap(app, "train-log-set")

        tap(app, "train-finish")
        tap(app, "train-finish-confirm")
        XCTAssertTrue(element(app, "train-summary-screen").waitForExistence(timeout: Self.wait))
        tap(app, "train-summary-done")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: Self.wait))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Exercises lists the bench press with today's sets.
        tap(app, "train-exercises")
        tap(app, "exercise-history-row-Barbell_Bench_Press_-_Medium_Grip")
        XCTAssertTrue(element(app, "exercise-detail-screen").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "exercise-stat-e1rm").waitForExistence(timeout: Self.wait))
        let latest = element(app, "exercise-history-entry-0")
        XCTAssertTrue(latest.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(latest.label.contains("80 kg × 7"), latest.label)
    }

    // MARK: Helpers

    @MainActor private func pick(_ app: XCUIApplication, _ query: String) {
        let search = element(app, "exercise-search")
        XCTAssertTrue(search.waitForExistence(timeout: Self.wait), "Missing the exercise search")
        search.tap()
        search.typeText(query)
        tap(app, "exercise-result-0")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: Self.wait), "Missing \(id)")
        for _ in 0..<12 {
            if app.showsInContent(target) { target.tap(); return }
            app.dragContent(up: true)
        }
        for _ in 0..<12 {
            if app.showsInContent(target) { target.tap(); return }
            app.dragContent(up: false)
        }
        target.tap()
    }

    @MainActor private func waitForLabel(_ element: XCUIElement, contains text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: Self.wait) == .completed
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
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
