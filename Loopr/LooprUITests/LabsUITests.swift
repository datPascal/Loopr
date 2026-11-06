import XCTest

/// LV-08b step 2: a person types a lab report with two values, finds it in the blood tests list, opens it, and adds
/// a lab clock result. `--loopr-start-at=labs` opens the list on Data's stack in a fixture launch, and the fixture
/// gives the screens a scratch database, so every run starts with no reports.
final class LabsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-start-at=labs",
            "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: 60), "The blood tests list did not open")
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Puts the keyboard away so a button under it can be tapped. The decimal pad has no return key.
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        app.scrollViews.firstMatch.swipeDown()
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

    @MainActor private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: wait))
        back.tap()
    }

    @MainActor func testTypeAReportSeeItInTheListOpenItAndAddALabClockResult() {
        let app = launch()
        XCTAssertTrue(element(app, "labs-empty").waitForExistence(timeout: wait), "An empty list says what the screen holds")

        // Type in a report with two values.
        tap(app, "labs-add")
        tap(app, "labs-add-typed")
        XCTAssertTrue(element(app, "labs-entry-screen").waitForExistence(timeout: wait))
        type(app, "Labor Berlin", into: "labs-entry-lab")
        addMarker(app, search: "albumin", key: "albumin")
        addMarker(app, search: "HbA1c", key: "hba1c")
        type(app, "46", into: "labs-entry-value-0-number")
        type(app, "5,4", into: "labs-entry-value-1-number")
        dismissKeyboard(app)
        tap(app, "labs-entry-save")

        // The report is in the list with its lab and its two values.
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
        let report = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'labs-report-'")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: wait), "The saved report is not in the list")
        XCTAssertTrue(report.label.contains("Labor Berlin"), report.label)
        XCTAssertTrue(report.label.contains("2 values"), report.label)
        XCTAssertTrue(element(app, "labs-empty").waitForNonExistence(timeout: wait))

        // Open it: the printed digits, the lab's name and the disclaimer show.
        report.tap()
        XCTAssertTrue(element(app, "labs-report-screen").waitForExistence(timeout: wait))
        let albumin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Albumin 46'")).firstMatch
        XCTAssertTrue(albumin.waitForExistence(timeout: wait), "The albumin row is missing")
        XCTAssertTrue(albumin.label.contains("Labor Berlin"), albumin.label)
        let hba1c = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'HbA1c 5'")).firstMatch
        XCTAssertTrue(hba1c.waitForExistence(timeout: wait), "The HbA1c row is missing")
        XCTAssertTrue(hba1c.label.contains("5.4") || hba1c.label.contains("5,4"), hba1c.label)

        // A value opens its marker page: every draw on a chart, and editing one tap away.
        albumin.tap()
        XCTAssertTrue(element(app, "labs-marker-screen").waitForExistence(timeout: wait), "The marker page did not open")
        XCTAssertTrue(element(app, "labs-marker-value").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "labs-marker-edit").waitForExistence(timeout: wait))
        goBack(app)
        XCTAssertTrue(element(app, "labs-report-screen").waitForExistence(timeout: wait))
        if !element(app, "labs-report-disclaimer").exists { app.swipeUp() }
        XCTAssertTrue(element(app, "labs-report-disclaimer").waitForExistence(timeout: wait))
        goBack(app)

        // Add a lab clock result.
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
        tap(app, "labs-add")
        tap(app, "labs-add-clock")
        XCTAssertTrue(element(app, "labs-clock-entry-screen").waitForExistence(timeout: wait))
        type(app, "0,92", into: "labs-clock-value")
        type(app, "TruDiagnostic", into: "labs-clock-lab")
        dismissKeyboard(app)
        tap(app, "labs-clock-entry-save")
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
        let clock = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'labs-clock-' AND NOT identifier BEGINSWITH 'labs-clock-source-' AND NOT identifier BEGINSWITH 'labs-clock-delete'")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: wait), "The lab clock result is not in the list")
        XCTAssertTrue(app.staticTexts["DunedinPACE"].waitForExistence(timeout: wait))
    }

    @MainActor func testALabClockWithoutALabNameIsRefused() {
        let app = launch()
        tap(app, "labs-add")
        tap(app, "labs-add-clock")
        XCTAssertTrue(element(app, "labs-clock-entry-screen").waitForExistence(timeout: wait))
        type(app, "0,92", into: "labs-clock-value")
        dismissKeyboard(app)
        tap(app, "labs-clock-entry-save")
        XCTAssertTrue(element(app, "labs-clock-entry-error").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "labs-clock-entry-screen").exists)
    }
}
