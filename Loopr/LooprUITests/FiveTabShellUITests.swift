import XCTest

final class FiveTabShellUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEveryTabOpensTheSameContextualAskSheet() {
        let app = launch()
        for (title, root, ask, originName) in [
            ("Today", "today-screen", "today-header-coach", "Today"),
            ("Food", "food-screen", "food-header-ask", "Food"),
            ("Fitness", "workouts-screen", "train-header-ask", "Fitness"),
            ("Protocol", "journal-screen", "journal-header-ask", "Protocol"),
            ("Data", "health-screen", "health-header-ask", "Data")
        ] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
            tap(app, ask)
            XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
            let origin = element(app, "ask-origin")
            XCTAssertTrue(origin.waitForExistence(timeout: 10))
            XCTAssertTrue(origin.label.contains(originName), origin.label)
            tap(app, "ask-close")
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
        }
    }

    @MainActor func testLegacyLaunchRoutesKeepTheirDestinations() {
        for (route, root, tab) in [
            ("sleep/detail", "sleep-screen", "Data"),
            ("heart", "heart-screen", "Data"),
            ("body/detail", "body-screen", "Data"),
            ("workouts", "workouts-screen", "Fitness")
        ] {
            let app = launch(extra: ["--loopr-deep-link=\(route)"])
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 15), route)
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, route)
            app.terminate()
        }
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture", "--loopr-appearance=system"] + extra
        app.launch()
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        for _ in 0..<10 {
            if target.exists && target.isHittable { target.tap(); return }
            app.swipeUp()
        }
        XCTFail("Could not reach \(id)")
    }
    @MainActor private func back(_ app: XCUIApplication, root: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, root: String) {
        XCTAssertTrue(element(app, root).waitForExistence(timeout: 15))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "FiveTab Screen \(slug)_candidate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
