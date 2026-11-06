import XCTest

/// LV-08b step 3: the PhenoAge and recovery method pages open from the DEBUG `--loopr-method=` launch argument on
/// Data's stack and show the formula, the code card and the limits.
final class MethodPagesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPhenoAgeMethodShowsWaterfallFormulaCodeAndLimits() {
        let app = launch("phenoage")
        XCTAssertTrue(element(app, "method-screen").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "method-phenoage").exists)
        XCTAssertTrue(element(app, "method-value").exists)
        XCTAssertTrue(element(app, "method-waterfall").exists)
        assertReaches(app, "method-formula")
        assertReaches(app, "method-code")
        XCTAssertTrue(element(app, "method-github").exists)
        assertReaches(app, "method-limits")
        assertReaches(app, "method-paper")
        assertReaches(app, "method-medical")
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
    }

    @MainActor func testRecoveryMethodShowsFormulaCodeAndLimits() {
        let app = launch("recovery")
        XCTAssertTrue(element(app, "method-screen").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "method-recovery").exists)
        XCTAssertTrue(element(app, "method-waterfall").exists)
        assertReaches(app, "method-formula")
        assertReaches(app, "method-code")
        XCTAssertTrue(element(app, "method-github").exists)
        assertReaches(app, "method-limits")
    }

    @MainActor func testBackFromAMethodReturnsToTheList() {
        let app = launch("phenoage")
        XCTAssertTrue(element(app, "method-screen").waitForExistence(timeout: 30))
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(element(app, "methods-list").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "methods-list-phenoage").exists)
    }

    @MainActor private func assertReaches(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        for _ in 0..<12 where !(target.exists && target.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(target.exists, "\(id) is not on the method page", file: file, line: line)
    }

    @MainActor private func launch(_ method: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-your-data-fixture", "--loopr-appearance=system",
                               "--loopr-entrance-final-state", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU",
                               "--loopr-method=\(method)", "--loopr-method-fixture"]
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
