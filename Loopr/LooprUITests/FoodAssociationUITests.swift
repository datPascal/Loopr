import XCTest

final class FoodAssociationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testPopulatedFoodAssociationsOpenTheExistingDetailScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-food-associations-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        let week = app.buttons["food-week"]
        XCTAssertTrue(week.waitForExistence(timeout: 30)); reach(app, week); week.tap()
        let route = app.buttons["food-associations"]
        XCTAssertTrue(route.waitForExistence(timeout: 30)); reach(app, route); route.tap()
        let chart = app.descendants(matching: .any)["food-body-scatter"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 30))
        let comparison = app.buttons["food-association-0"]
        XCTAssertTrue(comparison.waitForExistence(timeout: 30)); reach(app, comparison)
        XCTAssertFalse(comparison.label.contains("Collecting"))
        comparison.tap()
        XCTAssertTrue(app.descendants(matching: .any)["habit-detail-screen"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Last meal after 21:00"].firstMatch.waitForExistence(timeout: 30))
    }
    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<16 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTFail("Could not reach \(element)")
    }
}
