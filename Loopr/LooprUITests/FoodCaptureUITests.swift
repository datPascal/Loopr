import XCTest

final class FoodCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testTextCaptureRequiresReviewAndSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        tap(app, "food-manual")
        let text = app.textViews["food-capture-text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 30)); text.tap(); text.typeText("150 g apricots")
        tap(app, "food-capture-review-text")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-review-item-", "apricots")).firstMatch.waitForExistence(timeout: 30))
        tap(app, "food-cancel-meal")
        tap(app, "food-capture-close")
        XCTAssertTrue(app.tabBars.buttons["Food"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["apricots"].exists)
        tap(app, "food-manual")
        XCTAssertTrue(text.waitForExistence(timeout: 30)); text.tap(); text.typeText("150 g apricots")
        tap(app, "food-capture-review-text"); tap(app, "food-save-meal")
        XCTAssertTrue(app.tabBars.buttons["Food"].waitForExistence(timeout: 15))
        let meal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "apricots")).firstMatch
        for _ in 0..<8 { if meal.exists { break }; app.swipeUp() }
        XCTAssertTrue(meal.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "food-capture-confirmed"; image.lifetime = .keepAlways; add(image)
    }
    /// Type's quick add: open it, type 600 kcal and 30 g protein, save. No name and no review screen.
    @MainActor func testQuickAddSavesTotalsWithoutReview() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        tap(app, "food-manual")
        tap(app, "food-type-mode-totals")
        let energy = app.textFields["food-quick-energy"].firstMatch
        XCTAssertTrue(energy.waitForExistence(timeout: 30)); energy.tap(); energy.typeText("600")
        let protein = app.textFields["food-quick-protein"].firstMatch
        protein.tap(); protein.typeText("30")
        tap(app, "food-quick-save")
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 15))
        let meal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Quick add")).firstMatch
        for _ in 0..<8 { if meal.exists { break }; app.swipeUp() }
        XCTAssertTrue(meal.exists)
    }
    @MainActor private func tap(_ app: XCUIApplication, _ identifier: String) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<10 {
            if element.exists && element.isHittable { element.tapCommitting(in: app, identifier: identifier); return }
            app.swipeUp()
        }
        for _ in 0..<10 {
            if element.exists && element.isHittable { element.tapCommitting(in: app, identifier: identifier); return }
            app.swipeDown()
        }
        XCTFail("Could not reach \(identifier)")
    }
}
