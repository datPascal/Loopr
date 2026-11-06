import XCTest

final class FoodReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testPhotoConsentCorrectionFavoriteAndConfirmedSave() {
        let app = launch()
        defer { attach(app, "food-review-final-state") }
        tap(app, "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        // The camera estimates as soon as the photo is taken; only the first photo for a provider asks.
        tap(app, "food-capture-shutter")
        tap(app, "food-photo-consent-cancel")
        XCTAssertTrue(app.buttons["food-lens-manual"].waitForExistence(timeout: 30))
        XCTAssertFalse(lensItem(app, "Grilled chicken breast").exists)
        tap(app, "food-lens-retake")
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 30), .completed)
        tap(app, "food-capture-shutter")
        tap(app, "food-photo-consent-send")
        XCTAssertTrue(lensItem(app, "Grilled chicken breast").waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["food-lens-add"].label.contains("Add to"))
        tap(app, "food-lens-edit")
        XCTAssertTrue(reviewItem(app, "Grilled chicken breast").waitForExistence(timeout: 30))
        tap(app, "food-save-favorite")
        let saved = app.buttons["food-save-favorite"]
        let savedState = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Favourite saved"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [savedState], timeout: 30), .completed)
        let correction = app.descendants(matching: .any)["food-correction-text"].firstMatch
        reach(app, correction)
        // Save is pinned at the bottom of review now; lift the field above it before typing.
        for _ in 0..<4 where correction.frame.maxY > app.frame.maxY - 140 { app.swipeUp() }
        correction.tap(); correction.typeText("The rice was brown")
        tap(app, "food-send-correction")
        XCTAssertTrue(reviewItem(app, "Brown rice").waitForExistence(timeout: 30))
        // Saving from review hands the meal back to the camera, which plays the burst and closes.
        tap(app, "food-save-meal")
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        let meal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-meal-", "Brown rice")).firstMatch
        XCTAssertTrue(meal.waitForExistence(timeout: 30))
        tap(app, "food-manual")
        tap(app, "food-repeat")
        let favorite = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-favorite-")).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 30)); reach(app, favorite); favorite.tap()
        XCTAssertTrue(reviewItem(app, "White rice").waitForExistence(timeout: 30))
        tap(app, "food-cancel-meal")
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-meal-")).count, 3)
    }
    @MainActor func testPhotoWithoutKeyAllowsLocalManualReview() {
        let app = launch(extra: ["--loopr-food-fixture-no-provider"])
        defer { attach(app, "food-review-no-key") }
        tap(app, "food-log-meal"); tap(app, "food-capture-shutter")
        XCTAssertTrue(app.buttons["food-lens-manual"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["food-photo-consent-send"].exists)
        tap(app, "food-lens-manual")
        XCTAssertTrue(app.buttons["food-add-item"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["food-estimate-photo"].exists)
        tap(app, "food-add-item")
        let name = app.textFields["food-item-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 30)); name.tap(); name.typeText("Pear")
        tap(app, "food-apply-item")
        XCTAssertTrue(reviewItem(app, "Pear").waitForExistence(timeout: 30))
        tap(app, "food-cancel-meal"); tap(app, "food-capture-close")
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-meal-")).count, 2)
    }
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func lensItem(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-lens-item-", name)).firstMatch
    }
    @MainActor private func reviewItem(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-review-item-", name)).firstMatch
    }
    @MainActor private func tap(_ app: XCUIApplication, _ identifier: String) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 30), identifier)
        reach(app, element); element.tapCommitting(in: app, identifier: identifier)
    }
    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<16 { if element.exists && element.isHittable { return }; app.swipeUp() }
        for _ in 0..<16 { if element.exists && element.isHittable { return }; app.swipeDown() }
        XCTFail("Could not reach \(element)")
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
