import XCTest

/// LV-02 step 2: every route build 21 shipped lands on the same screen under the new tab names, and the
/// new tab names open their tabs. The DEBUG `--loopr-deep-link=` launch argument runs the same `ShellDeepLink`
/// that `loopr://` URLs, notifications and quick actions use.
final class LongevityShellRoutesUITests: XCTestCase {
    private struct Route {
        let link: String
        let roots: [String]
        let tab: String
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    /// Links build 21 accepted, with the screen each one opened and the tab it selected.
    private static let oldRoutes: [Route] = [
        .init(link: "today", roots: ["today-screen"], tab: "Today"),
        .init(link: "food", roots: ["food-screen"], tab: "Food"),
        .init(link: "train", roots: ["workouts-screen"], tab: "Fitness"),
        .init(link: "workouts", roots: ["workouts-screen"], tab: "Fitness"),
        .init(link: "workouts/detail", roots: ["workout-detail-screen"], tab: "Fitness"),
        .init(link: "workouts/intervals", roots: ["interval-timer-screen"], tab: "Fitness"),
        .init(link: "journal", roots: ["journal-screen"], tab: "Protocol"),
        .init(link: "journal/habit-setup", roots: ["habit-setup-screen"], tab: "Protocol"),
        .init(link: "journal/habit-management", roots: ["habit-management-screen"], tab: "Protocol"),
        .init(link: "journal/habit-check-in", roots: ["habit-check-in-screen"], tab: "Protocol"),
        .init(link: "journal/habit-history", roots: ["habit-history-screen"], tab: "Protocol"),
        .init(link: "journal/habit-insights", roots: ["habit-insights-screen"], tab: "Protocol"),
        .init(link: "journal/habit-detail", roots: ["habit-detail-screen"], tab: "Protocol"),
        .init(link: "health", roots: ["health-screen"], tab: "Data"),
        .init(link: "sleep", roots: ["sleep-screen"], tab: "Data"),
        .init(link: "sleep/detail", roots: ["sleep-screen"], tab: "Data"),
        .init(link: "heart", roots: ["heart-screen"], tab: "Data"),
        .init(link: "heart/detail", roots: ["heart-detail-screen"], tab: "Data"),
        .init(link: "body", roots: ["body-screen"], tab: "Data"),
        .init(link: "body/detail", roots: ["body-screen"], tab: "Data"),
    ]

    /// The names DEC-12.1 adds. Each opens its tab at the root.
    private static let newRoutes: [Route] = [
        .init(link: "fitness", roots: ["workouts-screen"], tab: "Fitness"),
        .init(link: "protocol", roots: ["journal-screen"], tab: "Protocol"),
        .init(link: "data", roots: ["health-screen"], tab: "Data"),
    ]

    @MainActor func testEveryOldRouteLandsOnItsScreenUnderTheNewTab() {
        for route in Self.oldRoutes { assertLands(route) }
    }

    @MainActor func testTheNewTabNamesOpenTheirTabs() {
        for route in Self.newRoutes { assertLands(route) }
    }

    @MainActor func testDataPushesSleepHeartAndBodyOnItsOwnStack() {
        // The three screens the saved selections "sleep", "heart" and "body" opened sit on Data's stack, so back
        // returns to Data's home.
        for route in Self.oldRoutes where ["sleep", "heart", "body"].contains(route.link) {
            let app = launch(route.link)
            XCTAssertTrue(element(app, route.roots[0]).waitForExistence(timeout: 15), route.link)
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), "\(route.link) has no back button")
            back.tap()
            XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: 10), route.link)
            XCTAssertTrue(app.tabBars.buttons["Data"].isSelected, route.link)
            app.terminate()
        }
    }

    @MainActor private func assertLands(_ route: Route) {
        let app = launch(route.link)
        let found = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", route.roots))
            .firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 15), "loopr://\(route.link) did not open \(route.roots)")
        XCTAssertTrue(app.tabBars.buttons[route.tab].isSelected, "loopr://\(route.link) did not select \(route.tab)")
        app.terminate()
    }

    @MainActor private func launch(_ link: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture",
            "--loopr-your-data-fixture", "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU",
            "--loopr-deep-link=\(link)"]
        if link.hasPrefix("journal/habit") { app.launchArguments.append("--loopr-habit-insight-state=clearAssociation") }
        app.launch()
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30), link)
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
