import XCTest

/// LV-10 integration: the weekly review sheet on the DEBUG fixture story (`WeeklyReviewFixture`, the week of 19 October
/// 2026, five pages with a proposal on page 4), and Today's experiment strip opening Protocol on Experiments.
final class WeeklyReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func testTheLaunchArgumentOpensTheSheetAndNotNowClosesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-weekly-review=open",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        let sheet = element(app, "weekly-review-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: wait), "The launch argument opens the sheet")

        // Tap the right of the page to go on.
        for number in 1...5 {
            let page = element(app, "weekly-review-page-\(number)")
            XCTAssertTrue(page.waitForExistence(timeout: wait), "Page \(number)")
            XCTAssertTrue(page.label.contains("Week of 19 to 25 Oct"), "Read \"\(page.label)\"")
            if number == 4 {
                XCTAssertTrue(element(app, "weekly-review-start-experiment").exists, "The proposal offers Start")
                XCTAssertTrue(element(app, "weekly-review-not-now").exists, "The proposal offers Not now")
            }
            if number < 5 { page.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3)).tap() }
        }
        XCTAssertFalse(element(app, "weekly-review-not-now").exists, "The buttons stay on the proposal page")

        // The left third goes back to the proposal.
        element(app, "weekly-review-page-5").coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        XCTAssertTrue(element(app, "weekly-review-page-4").waitForExistence(timeout: wait))
        let notNow = element(app, "weekly-review-not-now")
        XCTAssertTrue(notNow.waitForExistence(timeout: wait))
        notNow.tap()

        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheet)
        wait(for: [gone], timeout: wait)
        XCTAssertTrue(element(app, "main-tab-shell").exists)
    }

    @MainActor func testTheTodayExperimentStripOpensProtocolOnExperiments() {
        let app = XCUIApplication()
        // The strip sits in "More from today", started open here.
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-today-clock=morning",
                               "--loopr-deep-link=today", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB",
                               "-loopr-open-folds", "YES"]
        app.launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: wait))
        let strip = element(app, "today-experiment")
        XCTAssertTrue(strip.waitForExistence(timeout: wait))
        // Short drags, then back down if the strip went under the header (`FiveTabNavigationHelpers`).
        for _ in 0..<20 where !app.showsInContent(strip) {
            if strip.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 where !app.showsInContent(strip) { app.dragContent(up: false) }
        strip.tap()

        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: wait), "The strip opens Protocol")
        XCTAssertTrue(element(app, "protocol-experiment-running").waitForExistence(timeout: wait),
                      "Protocol opens on the Experiments segment")
        XCTAssertFalse(element(app, "protocol-deck-progress").exists, "Not on the Check-in segment")
    }

    /// ICP R3-DES-05, R3-SEN-07, R3-HAB-07, R3-VET-02: last week's review from the Protocol tab draws the rosette's marks
    /// with a key ("Fri and Sat: a rule not kept"), and its page scrolls from the screen's edge, so no rule is cut off.
    @MainActor func testTheProtocolReviewHasAKeyAndItsListScrolls() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-today-clock=evening",
                               "--loopr-deep-link=protocol", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        let row = element(app, "protocol-weekly-review")
        XCTAssertTrue(row.waitForExistence(timeout: wait))
        for _ in 0..<20 where !app.showsInContent(row) {
            if row.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 where !app.showsInContent(row) { app.dragContent(up: false) }
        row.tap()
        let page = element(app, "weekly-review-page-1")
        XCTAssertTrue(page.waitForExistence(timeout: wait))
        XCTAssertTrue(page.label.contains("Fri and Sat: a rule not kept"), "Read \"\(page.label)\"")
        XCTAssertTrue(page.label.contains("All kept"), "Read \"\(page.label)\"")

        // A drag at the screen's left edge moves the page: the list scrolls instead of stopping at the card's edge.
        let top = page.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)), withVelocity: .slow,
                    thenHoldForDuration: 0.3)
        XCTAssertLessThan(page.frame.minY, top - 40, "The page scrolled")
        XCTAssertTrue(element(app, "weekly-review-page-1").exists, "A vertical drag stays on the page")
    }
}
