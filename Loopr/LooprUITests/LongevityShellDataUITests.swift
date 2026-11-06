import XCTest

/// LV-02 step 3: Sleep, Heart, Body, Stress, Records, All metrics, metric detail and Your data open from Data
/// and return to Data. The band button reaches Your data from Data, where it is pushed on Data's stack, and from
/// the other four tabs, where it covers the tab and back returns there.
final class LongevityShellDataUITests: XCTestCase {
    private static let screens: [(row: String, root: String)] = [
        ("health-explore-sleep", "sleep-screen"),
        ("health-explore-heart", "heart-screen"),
        ("health-explore-body", "body-screen"),
        ("health-explore-stress", "stress-screen"),
        ("health-explore-records", "records-screen"),
        ("health-explore-metrics", "metric-library-screen"),
        ("data-area-body", "body-screen"),
        ("health-explore-labs", "labs-screen"),
    ]

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEveryDataScreenOpensFromDataAndReturnsToData() {
        let app = launch()
        app.tabBars.buttons["Data"].tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 15))
        for (row, root) in Self.screens {
            tap(app, row)
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 20), "\(row) did not open \(root)")
            XCTAssertTrue(app.tabBars.buttons["Data"].isSelected, "\(root) left the Data tab")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), "\(root) has no back button")
            back.tap()
            XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 10), "\(root) did not return to Data")
            XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
        }
    }

    @MainActor func testBandButtonPushesYourDataOnDataAndReturnsToData() {
        let app = launch()
        app.tabBars.buttons["Data"].tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 15))
        tap(app, "open-settings")
        XCTAssertTrue(element(app, "your-data-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
        // Pushed on Data's own stack, so the stack's back button returns to Data.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "your-data-screen").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
    }

    @MainActor func testBandButtonStillReachesYourDataFromOtherTabs() {
        let app = launch()
        for (tab, root) in [("Today", "today-screen"), ("Food", "food-screen"), ("Fitness", "workouts-screen"), ("Protocol", "journal-screen")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 15), tab)
            tap(app, "open-settings")
            XCTAssertTrue(element(app, "your-data-screen").waitForExistence(timeout: 20), "\(tab) did not reach Your data")
            let back = app.buttons["your-data-back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), tab)
            back.tap()
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 10), "Your data did not return to \(tab)")
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, tab)
        }
    }

    @MainActor func testTabRootsCarryTheirNewNames() {
        let app = launch()
        for (tab, root, ask) in [("Fitness", "workouts-screen", "train-header-ask"),
                                 ("Protocol", "journal-screen", "journal-header-ask"),
                                 ("Data", "health-screen", "health-header-ask")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 15), tab)
            let title = element(app, "tab-header-title")
            XCTAssertTrue(title.waitForExistence(timeout: 10), tab)
            XCTAssertTrue(title.label.contains(tab), "\(root) header says \(title.label)")
            XCTAssertTrue(element(app, ask).exists, "\(ask) is missing")
        }
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture",
            "--loopr-your-data-fixture", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls a third of the screen at a time, down first and then back up, until the target sits in the content
    /// between the sticky header and the tab bar, then taps it. `isHittable` alone is not enough: since iOS 27 XCTest
    /// reports a row scrolled under the header's glass as hittable, and a tap there lands on the header.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        for direction in [true, false] {
            for _ in 0..<20 {
                let button = app.buttons[id].firstMatch
                let target = button.exists ? button : element(app, id)
                if target.exists, app.showsInContent(target) { target.tap(); return }
                app.dragContent(up: direction)
            }
        }
        XCTFail("Could not reach \(id)")
    }
}
