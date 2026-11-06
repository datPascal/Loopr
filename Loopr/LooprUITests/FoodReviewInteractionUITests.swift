import XCTest

final class FoodReviewInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLargePortionSliderKeepsItsRangeWhileDragging() {
        let app = launchReview()
        defer { attach(app) }
        let rice = item(app, "White rice")
        reach(app, rice); rice.press(forDuration: 1)
        tap(app, "food-edit-item")
        replace(app.textFields["food-item-amount"].firstMatch, with: "600")
        tap(app, "food-apply-item")
        XCTAssertTrue(rice.waitForExistence(timeout: 30)); reach(app, rice); rice.tap()
        let slider = app.sliders["food-item-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 30)); reach(app, slider)
        // The edited 600 g amount must stay the slider's upper bound while dragging.
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(grams(rice), 600)
        // XCTest's drag lands several percent off target, so compare grams with the thumb position XCTest reports.
        // A range collapsed to 1...500 would read about 1 + position × 499 instead.
        slider.adjust(toNormalizedSliderPosition: 0.5)
        expectAmount(rice, matches: slider, lower: 1, upper: 600)
        slider.adjust(toNormalizedSliderPosition: 0.75)
        expectAmount(rice, matches: slider, lower: 1, upper: 600)
        tap(app, "food-cancel-meal"); tap(app, "food-capture-close")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-meal-")).count, 2)
    }

    @MainActor func testMetadataCancelApplyAndConsentWithdrawal() {
        let app = launchReview()
        defer { attach(app) }
        tap(app, "food-review-metadata")
        let note = app.textFields["food-review-note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30)); replace(note, with: "Half portion")
        tap(app, "food-cancel-metadata"); tap(app, "food-review-metadata")
        XCTAssertTrue(note.waitForExistence(timeout: 30)); XCTAssertNotEqual(note.value as? String, "Half portion")
        replace(note, with: "Half portion"); tap(app, "food-apply-metadata")
        tap(app, "food-review-metadata")
        XCTAssertTrue(note.waitForExistence(timeout: 30)); XCTAssertEqual(note.value as? String, "Half portion")
        tap(app, "food-revoke-photo-consent")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["food-revoke-photo-consent"])], timeout: 30), .completed)
        tap(app, "food-cancel-metadata")
        let correction = app.descendants(matching: .any)["food-correction-text"].firstMatch
        reach(app, correction)
        // Save is pinned at the bottom of review now; lift the field above it before typing.
        for _ in 0..<4 where correction.frame.maxY > app.frame.maxY - 140 { app.swipeUp() }
        correction.tap(); correction.typeText("The rice was brown")
        tap(app, "food-send-correction")
        XCTAssertTrue(app.buttons["food-photo-consent-send"].waitForExistence(timeout: 30))
        tap(app, "food-photo-consent-cancel")
        XCTAssertFalse(item(app, "Brown rice").exists)
        tap(app, "food-cancel-meal"); tap(app, "food-capture-close")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-meal-")).count, 2)
    }

    /// The day sheet's Done for today is the tab's own: same name, and it closes the sheet into the same question.
    @MainActor func testLogCompletionStillRequiresConfirmationAndCanReopen() {
        let app = launch()
        defer { attach(app) }
        let complete = app.buttons["food-complete-day"]
        let done = app.buttons["food-done-today"]
        tap(app, "food-targets")
        XCTAssertTrue(complete.waitForExistence(timeout: 30)); XCTAssertEqual(complete.label, "Done for today")
        tap(app, "food-complete-day")
        cancelCompletion(app)
        XCTAssertFalse(done.label.contains("Reopen"))
        tap(app, "food-targets"); tap(app, "food-complete-day"); tap(app, "food-confirm-completion")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Reopen"), object: done)], timeout: 30), .completed)
        tap(app, "food-targets")
        XCTAssertTrue(complete.waitForExistence(timeout: 30)); XCTAssertEqual(complete.label, "Done for today, finished. Reopen")
        tap(app, "food-complete-day"); tap(app, "food-confirm-completion")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Done for today"), object: done)], timeout: 30), .completed)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-metric-history-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func launchReview() -> XCUIApplication {
        let app = launch(); tap(app, "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed)
        shutter.tap(); tap(app, "food-photo-consent-send")
        XCTAssertTrue(app.buttons["food-lens-edit"].waitForExistence(timeout: 30)); tap(app, "food-lens-edit")
        XCTAssertTrue(item(app, "White rice").waitForExistence(timeout: 30)); return app
    }
    /// iOS 26 presents the completion dialog as a popover, which omits the cancel-role button; outside taps cancel it.
    @MainActor private func cancelCompletion(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["food-confirm-completion"].firstMatch.waitForExistence(timeout: 30))
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists { outside.coordinate(withNormalizedOffset: .init(dx: 0.03, dy: 0.5)).tap() } else { tap(app, "food-cancel-completion") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["food-confirm-completion"].firstMatch)], timeout: 30), .completed)
    }
    @MainActor private func item(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-review-item-", name)).firstMatch
    }
    @MainActor private func expectAmount(_ element: XCUIElement, matches slider: XCUIElement, lower: Double, upper: Double) {
        let position = Double(slider.normalizedSliderPosition)
        XCTAssertTrue((0.05...0.95).contains(position), "Drag did not move the thumb: \(position)")
        // Allow one percent of the track for thumb-position rounding, 6 g on this range.
        XCTAssertEqual(grams(element), lower + position * (upper - lower), accuracy: 8)
    }
    @MainActor private func grams(_ element: XCUIElement) -> Double {
        let label = element.label
        guard let match = label.range(of: #"\d+(?:\.\d+)? g\b"#, options: .regularExpression),
              let number = Double(label[match].dropLast(2)) else { XCTFail("Missing grams: \(label)"); return -.infinity }
        return number
    }
    @MainActor private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        let old = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: .init(dx: 0.99, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let value = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 30)); reach(app, value); value.tapCommitting(in: app, identifier: id)
    }
    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<20 { if element.exists && element.isHittable { return }; app.swipeUp() }
        for _ in 0..<20 { if element.exists && element.isHittable { return }; app.swipeDown() }
        XCTFail("Could not reach \(element)")
    }
    @MainActor private func attach(_ app: XCUIApplication) {
        let frame = XCTAttachment(screenshot: app.screenshot()); frame.lifetime = .keepAlways; add(frame)
        let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways; add(tree)
    }
}
