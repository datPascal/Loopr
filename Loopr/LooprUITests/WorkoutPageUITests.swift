import XCTest

/// The workout page per type, and fixing a gym session's sets, through the fixture sessions.
final class WorkoutPageUITests: XCTestCase {
    private static let wait: TimeInterval = 30
    private static let lowerASession = "7A0460FE-0000-4000-8000-000000000021"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(_ link: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-train-fixture", "--loopr-workout-page-fixture",
                               "--loopr-deep-link=\(link)", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        return app
    }

    /// `...0730` and up, in the order of `WorkoutPageFixtures.Kind`.
    private func page(_ number: Int) -> String { String(format: "workouts/page/00000000-0000-0000-0000-%012d", number) }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls until the element can be tapped. A page is several screens long.
    @MainActor @discardableResult private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.wait))
        for _ in 0..<14 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing \(id)")
        return target
    }

    @MainActor private func assertAbsent(_ app: XCUIApplication, _ id: String) {
        XCTAssertFalse(element(app, id).exists, "\(id) should not be on this page")
    }

    @MainActor func testARunShowsItsRouteHeartRateAndSplits() {
        let app = launch(page(730))
        XCTAssertTrue(element(app, "workout-detail-metric-face").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "workout-page-headline").label.contains("7.4"), element(app, "workout-page-headline").label)
        XCTAssertTrue(element(app, "workout-page-comparison").waitForExistence(timeout: Self.wait), "A run has an earlier one like it")
        XCTAssertTrue(element(app, "workout-detail-heart-rate-chart").waitForExistence(timeout: Self.wait))
        reveal(app, "workout-page-map")
        reveal(app, "workout-page-split-1")
        reveal(app, "workout-page-elevation")
        XCTAssertTrue(reveal(app, "workout-detail-route").isHittable)
        reveal(app, "workout-share-heart-csv")
    }

    @MainActor func testAGpsGapIsSaidOutLoud() {
        let app = launch(page(742))
        reveal(app, "workout-page-gps-gap")
    }

    @MainActor func testASwimHasLengthsBandHistoryAndNoRoute() {
        let app = launch(page(735))
        XCTAssertTrue(element(app, "workout-page-headline").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "workout-page-headline").label.contains("1.2"), element(app, "workout-page-headline").label)
        XCTAssertTrue(element(app, "workout-detail-heart-rate-chart").waitForExistence(timeout: Self.wait), "Band history fills in a logged swim")
        reveal(app, "workout-page-effort")
        assertAbsent(app, "workout-page-map")
        assertAbsent(app, "workout-detail-route")
    }

    @MainActor func testATimerSessionListsItsEfforts() {
        let app = launch(page(737))
        XCTAssertTrue(element(app, "workout-detail-metric-face").waitForExistence(timeout: Self.wait))
        reveal(app, "workout-page-effort-1")
        reveal(app, "workout-page-effort-4")
    }

    @MainActor func testASessionWithNoHeartRateSaysSoAndDrawsNothing() {
        let app = launch(page(741))
        XCTAssertTrue(element(app, "workout-page-sentence").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "workout-page-sentence").label.contains("No heart rate"), element(app, "workout-page-sentence").label)
        assertAbsent(app, "workout-detail-heart-rate-chart")
        assertAbsent(app, "workout-detail-zones")
        assertAbsent(app, "workout-page-map")
    }

    @MainActor func testAWalkOffersWhatItCanAdd() {
        let app = launch(page(733))
        XCTAssertTrue(element(app, "workout-detail-metric-face").waitForExistence(timeout: Self.wait))
        let picker = reveal(app, "workout-page-add")
        XCTAssertTrue(picker.exists)
    }

    @MainActor func testAGymSessionShowsLastTimeAndItsSetsCanBeFixed() {
        let app = launch("workouts/session/\(Self.lowerASession)")
        XCTAssertTrue(element(app, "train-summary-screen").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-detail-last-time-0").waitForExistence(timeout: Self.wait), "Lower A has an earlier session")
        XCTAssertTrue(element(app, "train-detail-change-0").exists)
        XCTAssertTrue(element(app, "train-detail-1rm-0").label.contains("Estimated 1RM"), element(app, "train-detail-1rm-0").label)
        XCTAssertTrue(element(app, "train-detail-rest-0").exists)

        // Fix a set: the sheet offers RPE, and saving closes it.
        element(app, "train-detail-set-0-1").tap()
        XCTAssertTrue(element(app, "train-edit-sheet").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-edit-rpe").exists, "RPE is fixed in the same sheet")
        element(app, "train-edit-save").tap()
        XCTAssertTrue(element(app, "train-detail-set-0-1").waitForExistence(timeout: Self.wait))
        XCTAssertFalse(element(app, "train-detail-save-error").exists)

        // Add the set forgotten in the gym.
        let setCount = (1...12).filter { element(app, "train-detail-set-0-\($0)").exists }.count
        reveal(app, "train-detail-add-set-0").tap()
        XCTAssertTrue(element(app, "train-edit-save").waitForExistence(timeout: Self.wait))
        element(app, "train-edit-save").tap()
        let added = element(app, "train-detail-set-0-\(setCount + 1)")
        XCTAssertTrue(added.waitForExistence(timeout: Self.wait), "The new set joins the table")

        // Delete asks first.
        added.tap()
        XCTAssertTrue(element(app, "train-edit-sheet").waitForExistence(timeout: Self.wait))
        let delete = element(app, "train-edit-delete")
        for _ in 0..<3 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons["Delete set"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: Self.wait), "Delete asks before it deletes")
        XCTAssertTrue(added.exists, "Nothing is gone until the answer")
        confirm.tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: added)], timeout: Self.wait)
    }
}
