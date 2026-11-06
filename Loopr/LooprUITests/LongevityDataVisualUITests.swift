import XCTest

/// Longevity visual lane, LV-08b step 6: the Data screens of the contract (`design/longevity-vision/index.html`, phones
/// p-data and p-method) and the screens that hang off them, each captured from the top to its last element in the
/// light and dark runs of `scripts/test-longevity-visual.py lv08b`.
///
/// Every test is its own launch. The blood test screens use a scratch database that starts empty on each launch, so the
/// tests that need a report type one in through the screens, as `LabsUITests` does; nothing else is saved.
final class LongevityDataVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    // MARK: Launch

    /// `extra` carries the screen's own launch arguments. The capture arguments, the system appearance and the English
    /// locale are the same everywhere, so light and dark come from the simulator.
    @MainActor private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = LongevityVisualCapture.launchArguments
            + ["--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        return app
    }

    /// The Data root, deep-linked, on the seeded Data fixture or its absent variant.
    @MainActor private func launchData(_ fixture: String) -> XCUIApplication {
        let app = launch(["--loopr-launch-mode=populated", fixture, "--loopr-deep-link=data"])
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: wait), "the Data root did not open")
        XCTAssertTrue(element(app, "data-screen").waitForExistence(timeout: wait))
        // The ruler draws its loading shape first, and the slopes and the star map follow.
        XCTAssertTrue(element(app, "data-age-hero").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "data-overview-loading").waitForNonExistence(timeout: wait), "the overview kept loading")
        return app
    }

    @MainActor private func launchMethod(_ method: String) -> XCUIApplication {
        let app = launch(["--loopr-launch-mode=populated", "--loopr-your-data-fixture", "--loopr-method=\(method)",
                          "--loopr-method-fixture"])
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: wait))
        return app
    }

    @MainActor private func launchLabs() -> XCUIApplication {
        let app = launch(["--loopr-launch-mode=populated", "--loopr-start-at=labs"])
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: 60), "the blood tests list did not open")
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // MARK: Moves

    /// Drags in the left gutter, where no chart or field takes the scroll, until the top of the screen shows again.
    @MainActor private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.78)))
        }
    }

    /// Puts the keyboard away so a button under it can be tapped. The decimal pad has no return key.
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        app.scrollViews.firstMatch.swipeDown()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 10)
    }

    /// Scrolls until the element is on screen, then taps it.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        for _ in 0..<8 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable, "\(id) is not reachable", file: file, line: line)
        target.tap()
    }

    @MainActor private func type(_ app: XCUIApplication, _ text: String, into id: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[id].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        for _ in 0..<8 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(text)
    }

    /// Opens a menu picker row and chooses one of its options.
    @MainActor private func pick(_ app: XCUIApplication, _ option: String, in id: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        dismissKeyboard(app)
        let menu = app.buttons[id].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        for _ in 0..<8 where !menu.isHittable { app.swipeUp() }
        menu.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: wait), "\(id) does not offer \(option)", file: file, line: line)
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: wait), "the \(id) menu stayed open", file: file, line: line)
    }

    @MainActor private func addMarker(_ app: XCUIApplication, search: String, key: String) {
        dismissKeyboard(app)
        tap(app, "labs-entry-add-value")
        let searchField = app.textFields["labs-entry-marker-search"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: wait))
        searchField.tap()
        searchField.typeText(search)
        let row = element(app, "labs-entry-marker-\(key)")
        XCTAssertTrue(row.waitForExistence(timeout: wait), "\(key) is not in the search results")
        row.tap()
        XCTAssertTrue(element(app, "labs-entry-screen").waitForExistence(timeout: wait))
    }

    /// Opens typed entry from the list and fills in a lab with two values, leaving the keyboard down.
    @MainActor private func fillInAReport(_ app: XCUIApplication) {
        tap(app, "labs-add")
        tap(app, "labs-add-typed")
        XCTAssertTrue(element(app, "labs-entry-screen").waitForExistence(timeout: wait))
        // Return ends editing, so the keyboard's next suggestion or keystroke cannot land in the lab name.
        type(app, "Labor Berlin\n", into: "labs-entry-lab")
        XCTAssertEqual(app.textFields["labs-entry-lab"].firstMatch.value as? String, "Labor Berlin")
        addMarker(app, search: "albumin", key: "albumin")
        addMarker(app, search: "HbA1c", key: "hba1c")
        // Albumin offers g/dL first. 46 is a g/L value, so pick g/L before typing it.
        pick(app, "g/L", in: "labs-entry-value-0-unit")
        type(app, "46", into: "labs-entry-value-0-number")
        type(app, "5,4", into: "labs-entry-value-1-number")
        dismissKeyboard(app)
    }

    /// Fills in a report and saves it, so the list shows it.
    @MainActor private func saveAReport(_ app: XCUIApplication) -> XCUIElement {
        fillInAReport(app)
        tap(app, "labs-entry-save")
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs-report-'")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: wait), "the saved report is not in the list")
        return report
    }

    // MARK: Data

    @MainActor func testDataRootFromTheRulerToTheLastExploreRow() {
        let app = launchData("--loopr-data-fixture")
        XCTAssertTrue(element(app, "data-age-pin-blood").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-data", root: "data-screen", end: "data-vault")
    }

    @MainActor func testDataRootWithNoBloodTestsAndNoVO2Max() {
        let app = launchData("--loopr-data-fixture=absent")
        XCTAssertTrue(element(app, "data-age-pin-blood").label.contains("not on the ruler"), element(app, "data-age-pin-blood").label)
        captureScreen(app, slug: "p-data-absent", root: "data-screen", end: "data-vault")
    }

    // MARK: Methods

    @MainActor func testPhenoAgeMethodPageWithItsWaterfall() {
        let app = launchMethod("phenoage")
        XCTAssertTrue(element(app, "method-waterfall").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-method", root: "method-screen", end: "method-medical")
    }

    @MainActor func testRecoveryMethodPage() {
        let app = launchMethod("recovery")
        XCTAssertTrue(element(app, "method-waterfall").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-method-recovery", root: "method-screen", end: "method-medical")
    }

    @MainActor func testHowTheNumbersWorkList() {
        let app = launchMethod("list")
        XCTAssertTrue(element(app, "methods-list-phenoage").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-methods", root: "methods-list", end: "methods-list-lab-unit-conversion")
    }

    // MARK: Blood tests

    @MainActor func testBloodTestsListWithOneReport() {
        let app = launchLabs()
        _ = saveAReport(app)
        XCTAssertTrue(element(app, "labs-disclaimer").waitForExistence(timeout: wait))
        scrollToTop(app)
        captureScreen(app, slug: "p-labs", root: "labs-screen", end: "labs-disclaimer")
    }

    @MainActor func testLabReportDetail() {
        let app = launchLabs()
        saveAReport(app).tap()
        XCTAssertTrue(element(app, "labs-report-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "labs-report-header").waitForExistence(timeout: wait), "the report did not load")
        XCTAssertTrue(element(app, "labs-report-delete").waitForExistence(timeout: wait))
        scrollToTop(app)
        captureScreen(app, slug: "p-lab-report", root: "labs-report-screen", end: "labs-report-delete")
    }

    @MainActor func testTypedEntryWithTwoValues() {
        let app = launchLabs()
        fillInAReport(app)
        scrollToTop(app)
        captureScreen(app, slug: "p-lab-entry", root: "labs-entry-screen", end: "labs-entry-add-value")
    }

    @MainActor func testLabClockEntry() {
        let app = launchLabs()
        tap(app, "labs-add")
        tap(app, "labs-add-clock")
        XCTAssertTrue(element(app, "labs-clock-entry-screen").waitForExistence(timeout: wait))
        type(app, "0,92", into: "labs-clock-value")
        type(app, "TruDiagnostic", into: "labs-clock-lab")
        dismissKeyboard(app)
        scrollToTop(app)
        captureScreen(app, slug: "p-lab-clock", root: "labs-clock-entry-screen", end: "labs-clock-note")
    }

    // MARK: Publish and the body log

    @MainActor func testPublishWithTwoMetricsPickedAndThePreviewShown() {
        let app = launch(["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-start-at=publish"])
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "publish-screen").waitForExistence(timeout: 20))
        tap(app, "publish-metric-rmssd")
        tap(app, "publish-metric-resting_heart_rate")
        XCTAssertTrue(element(app, "publish-preview-web").waitForExistence(timeout: wait), "the preview did not build")
        XCTAssertTrue(element(app, "publish-save").waitForExistence(timeout: wait))
        // The preview is a web view: give it a moment to draw before the first still.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "preview draws")], timeout: 2)
        scrollToTop(app)
        captureScreen(app, slug: "p-publish", root: "publish-screen", end: "publish-save")
    }

    @MainActor func testBodyLogWithTheAppleHealthWeights() {
        let app = launch(["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture",
                          "--loopr-your-data-fixture", "--loopr-start-at=body-log"])
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "body-log-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "body-log-trend-weight").waitForExistence(timeout: wait), "the log did not load")
        captureScreen(app, slug: "p-body-log", root: "body-log-screen", end: "body-log-health-footnote")
    }
}
