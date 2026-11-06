import XCTest

/// LV-08b integration, on the Data fixture (`--loopr-data-fixture`): every route is reachable from the Data root. The
/// blood pin opens the real PhenoAge page with its waterfall, "How the numbers work" opens from an Explore row, the
/// vault opens Publish a page and the sources row opens the blood tests.
final class DataIntegrationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-data-fixture", "--loopr-entrance-final-state",
            "--loopr-deep-link=data", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: wait))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls down until the element exists and sits in the visible content.
    @MainActor @discardableResult private func reveal(_ app: XCUIApplication, _ id: String,
                                                      file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<20 where !(target.exists && app.showsInContent(target)) { app.dragContent(up: true) }
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        return target
    }

    /// The tab's Back button, then the Data root again.
    @MainActor private func goBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: wait), "no Back button", file: file, line: line)
        back.tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: wait), "Data did not come back", file: file, line: line)
    }

    @MainActor func testTheBloodPinOpensTheRealMethodPageWithItsWaterfall() {
        let app = launch()
        let pin = element(app, "data-age-pin-blood")
        XCTAssertTrue(pin.waitForExistence(timeout: wait))
        reveal(app, "data-age-pin-blood").tap()
        XCTAssertTrue(element(app, "method-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "method-phenoage").exists)
        XCTAssertTrue(element(app, "method-value").exists)
        XCTAssertTrue(element(app, "method-waterfall").exists)
        goBack(app)
    }

    @MainActor func testHowTheNumbersWorkOpensFromAnExploreRow() {
        let app = launch()
        reveal(app, "health-explore-methods").tap()
        XCTAssertTrue(element(app, "methods-list").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "methods-list-phenoage").exists)
        goBack(app)
    }

    @MainActor func testMoreOpensPublishAPage() {
        let app = launch()
        reveal(app, "health-explore-publish").tap()
        XCTAssertTrue(element(app, "publish-screen").waitForExistence(timeout: wait))
        goBack(app)
    }

    @MainActor func testTheBloodTestsTileOpensTheBloodTests() {
        let app = launch()
        reveal(app, "health-explore-labs").tap()
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
        goBack(app)
    }
}
