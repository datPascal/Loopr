import XCTest

/// Captures for the longevity visual lane (LV-05): the Food tab with and without meals, and Lab mode in the camera
/// cover on the fixture report (`--loopr-food-lab-fixture`, `=de`, `=empty`). Each test is a fresh launch and one screen.
///
/// The camera cover is a full-screen cover over the tab shell, so the tab bar stays in the accessibility tree under it.
/// `captureScreen` stops at the tab bar's top edge, which is why the Lab screens end on content (the summary, the edit
/// field, the saved card) and not on the Save or Done button in the bottom bar.
final class LongevityFoodVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: Food tab

    @MainActor func testFoodTabThroughTheEndOfThePage() {
        let app = launchFood(mode: "populated")
        captureScreen(app, slug: "p-food", root: "food-screen", end: "food-week")
    }

    @MainActor func testFoodTabWithNoMealsLogged() {
        let app = launchFood(mode: "empty")
        captureScreen(app, slug: "p-food-absent", root: "food-screen", end: "food-week")
    }

    // MARK: Lab mode

    @MainActor func testLabReadsTheReportWithOneAmberValue() {
        let app = launchFood(mode: "populated", lab: "--loopr-food-lab-fixture")
        openLab(app)
        waitForReview(app)
        captureScreen(app, slug: "p-lab", root: "food-lab-header", end: "food-lab-summary")
    }

    @MainActor func testLabEditRowOpensOnTheAmberValue() {
        let app = launchFood(mode: "populated", lab: "--loopr-food-lab-fixture")
        openLab(app)
        waitForReview(app)
        let amber = app.buttons["food-lab-chip-review-3"]
        waitHittable(amber)
        amber.tap()
        let field = app.textFields["food-lab-edit-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The edit row never opened")
        waitHittable(field)
        settle(field)
        captureScreen(app, slug: "p-lab-edit", root: "food-lab-edit-value", end: "food-lab-edit-value")
    }

    @MainActor func testLabSavedAfterFixingTheAmberValue() {
        let app = launchFood(mode: "populated", lab: "--loopr-food-lab-fixture")
        openLab(app)
        waitForReview(app)
        let amber = app.buttons["food-lab-chip-review-3"]
        waitHittable(amber)
        amber.tap()
        let field = app.textFields["food-lab-edit-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The edit row never opened")
        waitHittable(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + "0.7")
        let confirm = app.buttons["food-lab-edit-confirm"]
        waitHittable(confirm)
        confirm.tap()
        XCTAssertTrue(app.buttons["food-lab-chip-3"].waitForExistence(timeout: 10), "The amber chip never turned teal")
        let save = app.buttons["food-lab-save"]
        waitHittable(save)
        save.tap()
        let saved = app.descendants(matching: .any)["food-lab-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "Save never finished")
        waitHittable(app.buttons["food-lab-done"])
        settle(saved)
        captureScreen(app, slug: "p-lab-saved", root: "food-lab-saved", end: "food-lab-saved")
    }

    @MainActor func testLabReadsTheGermanReport() {
        let app = launchFood(mode: "populated", lab: "--loopr-food-lab-fixture=de")
        openLab(app)
        waitForReview(app)
        captureScreen(app, slug: "p-lab-de", root: "food-lab-header", end: "food-lab-summary")
    }

    @MainActor func testLabShowsTheEmptyPage() {
        let app = launchFood(mode: "populated", lab: "--loopr-food-lab-fixture=empty")
        openLab(app)
        let empty = app.descendants(matching: .any)["food-lab-empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 60), "The empty page state never appeared")
        waitHittable(app.buttons["food-lab-retake"])
        settle(empty)
        captureScreen(app, slug: "p-lab-empty", root: "food-lab-header", end: "food-lab-empty")
    }

    // MARK: Helpers

    /// A fresh launch on the Food tab. `mode` is the launch mode: `populated` has the Food fixture's meals, `empty` has none.
    @MainActor private func launchFood(mode: String, lab: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=\(mode)", "--loopr-deep-link=food", "--loopr-coach-fixture",
                               "--loopr-metric-history-fixture"] + (lab.map { [$0] } ?? []) + LongevityVisualCapture.launchArguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["food-week"].firstMatch.waitForExistence(timeout: 30), "Food never finished loading")
        return app
    }

    /// Opens the Food camera, switches to Lab and takes the fixture report.
    @MainActor private func openLab(_ app: XCUIApplication) {
        let camera = app.buttons["food-log-meal"]
        waitHittable(camera)
        camera.tapCommitting(in: app, identifier: "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        waitEnabled(shutter)
        let mode = app.buttons["food-lens-mode-lab"]
        waitHittable(mode)
        mode.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: mode)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed, "Lab mode never became selected")
        XCTAssertTrue(app.descendants(matching: .any)["food-lab-header"].waitForExistence(timeout: 15))
        waitEnabled(shutter)
        shutter.tap()
    }

    /// The read is done when the first chip is on screen and one chip needs a look.
    @MainActor private func waitForReview(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["food-lab-report"].waitForExistence(timeout: 30))
        waitHittable(app.buttons["food-lab-chip-0"], timeout: 60)
        let amber = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-lab-chip-review-")).firstMatch
        waitHittable(amber, timeout: 60)
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "\(element) never became enabled")
    }

    @MainActor private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never appeared")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "\(element) never became hittable")
    }

    /// Waits until the element stops moving, so a scroll or a card transition has finished before the capture.
    @MainActor private func settle(_ element: XCUIElement) {
        var last = element.frame
        for _ in 0..<10 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.4)
            let next = element.frame
            if next == last { return }
            last = next
        }
    }
}
