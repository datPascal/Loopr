import XCTest

/// The Fitness captures for the longevity visual lane (`scripts/test-longevity-visual.py lv06`): the tab
/// root, the tab with every source taken away, and each capacity test as it opens. The seeded fixture is
/// Alex, Tuesday 2023-11-14 in Perth. No timer runs here: a timed test is captured at its Start state.
/// Each test launches fresh and changes nothing the next one reads.
final class LongevityFitnessVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    /// The last row on the tab: heart rate recovery closes the open Fitness checks fold on both fixtures.
    private static let tabEnd = "fitness-capacity-heart-rate-recovery"
    /// Every test screen ends on its instructions card, above the pinned action.
    private static let testEnd = "fitness-test-instructions"

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-train-fixture"]
            + LongevityVisualCapture.launchArguments + extra
            + ["--loopr-deep-link=train", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-dose").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-vo2max").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, Self.tabEnd).waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let button = app.buttons[id].firstMatch
        return button.exists || button.waitForExistence(timeout: 5) ? button : element(app, id)
    }

    /// Scrolls down until the element exists and sits in the visible content.
    @MainActor private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<12 where !(target.exists && app.showsInContent(target)) { app.dragContent(up: true) }
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        return target
    }

    /// Opens a test from its tile and waits until the whole screen has drawn.
    @MainActor private func openTest(_ app: XCUIApplication, _ kind: String, file: StaticString = #filePath, line: UInt = #line) {
        reveal(app, "fitness-capacity-\(kind)", file: file, line: line).tap()
        XCTAssertTrue(element(app, "fitness-test-\(kind)").waitForExistence(timeout: wait), file: file, line: line)
        XCTAssertTrue(element(app, Self.testEnd).waitForExistence(timeout: wait), file: file, line: line)
    }

    // MARK: Tab

    @MainActor func testFitnessTab() {
        let app = launch()
        captureScreen(app, slug: "p-fit", root: "workouts-screen", end: Self.tabEnd)
    }

    @MainActor func testFitnessTabWithoutData() {
        let app = launch([FitnessFixtureArgument.absent])
        captureScreen(app, slug: "p-fit-absent", root: "workouts-screen", end: Self.tabEnd)
    }

    // MARK: Capacity tests

    @MainActor func testGripTestIntro() {
        let app = launch()
        openTest(app, "grip")
        captureScreen(app, slug: "p-fit-test-grip", root: "fitness-test-grip", end: Self.testEnd)
    }

    @MainActor func testGripTestAfterOneTrial() {
        let app = launch()
        openTest(app, "grip")
        button(app, "fitness-test-side-right").tap()
        // The dial's 40 kg is a starting place, not a reading: a trial can only be added once it is set.
        XCTAssertFalse(button(app, "fitness-grip-add-trial").isEnabled)
        button(app, "fitness-grip-plus").tap()
        button(app, "fitness-grip-add-trial").tap()
        XCTAssertTrue(element(app, "fitness-grip-trial-right-0").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-fit-test-grip-trial", root: "fitness-test-grip", end: Self.testEnd)
    }

    @MainActor func testDeadHangTestAtStart() {
        let app = launch()
        openTest(app, "dead-hang")
        XCTAssertTrue(button(app, "fitness-test-start").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-fit-test-dead-hang", root: "fitness-test-dead-hang", end: Self.testEnd)
    }

    @MainActor func testSitToStandTest() {
        let app = launch()
        openTest(app, "sit-to-stand")
        captureScreen(app, slug: "p-fit-test-sit-to-stand", root: "fitness-test-sit-to-stand", end: Self.testEnd)
    }

    @MainActor func testOneLegBalanceTestAtStart() {
        let app = launch()
        openTest(app, "one-leg-balance")
        XCTAssertTrue(button(app, "fitness-test-start").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-fit-test-balance", root: "fitness-test-one-leg-balance", end: Self.testEnd)
    }

    /// The saved results of one test: today's best, the goal for 85 and the dated rows.
    @MainActor func testSavedResultHistory() {
        let app = launch()
        openTest(app, "dead-hang")
        button(app, "fitness-test-history").tap()
        XCTAssertTrue(element(app, "fitness-capacity-history").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-capacity-history-row-0").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-fit-test-result", root: "fitness-capacity-history", end: "fitness-capacity-history-row-0")
    }
}

/// The Fitness fixture's launch argument, spelled as the app reads it (`FitnessFixtures.absentArgument`).
private enum FitnessFixtureArgument {
    static let absent = "--loopr-fitness-fixture=absent"
}
