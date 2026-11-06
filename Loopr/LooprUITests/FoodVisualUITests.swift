import XCTest

final class FoodVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testFoodOverviewThroughEndOfPage() {
        let app = launch()
        capture(app, "06-food", end: "food-week", scrollID: "food-screen")
    }
    @MainActor func testSeededCaptureThroughNote() {
        let app = launch(); tap(app, "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed)
        XCTAssertTrue(app.staticTexts["Chicken"].exists)
        // The camera is one full-screen viewport with nothing to scroll.
        single(app, "07-capture", end: "food-lens-hint")
    }
    @MainActor func testEstimatedReviewWithRiceExpandedThroughSources() {
        let app = launch(); openReview(app)
        let rice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "food-review-item-", "White rice")).firstMatch
        XCTAssertTrue(rice.waitForExistence(timeout: 30)); reach(app, rice); rice.tap()
        scrollToTop(app)
        capture(app, "08-ai-review", end: "food-review-source", scrollID: "food-review-scroll", overCover: true)
    }
    @MainActor func testCalculatedFoodAndBodyThroughEndOfPage() {
        let app = launch(); tap(app, "food-week"); tap(app, "food-associations")
        let row = app.buttons["food-association-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 180))
        XCTAssertFalse(row.label.contains("Collecting"), row.label)
        capture(app, "09-food-and-body", end: "food-association-1")
    }
    @MainActor func testLargestTextKeepsAllFourFoodScreensReachable() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let log = app.buttons["food-log-meal"]; reach(app, log); minimumHeight(log, in: app); log.tapCommitting(in: app, identifier: "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30)); reach(app, shutter); minimumHeight(shutter, in: app)
        shutter.tap(); tap(app, "food-photo-consent-send")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-lens-item-")).firstMatch.waitForExistence(timeout: 20))
        let add = app.buttons["food-lens-add"]; XCTAssertTrue(add.waitForExistence(timeout: 20)); minimumHeight(add, in: app)
        tap(app, "food-lens-edit")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-review-item-")).firstMatch.waitForExistence(timeout: 20))
        let save = app.buttons["food-save-meal"]; reach(app, save); minimumHeight(save, in: app)
        tap(app, "food-cancel-meal"); tap(app, "food-capture-close"); tap(app, "food-week"); tap(app, "food-associations")
        let row = app.buttons["food-association-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 180)); reach(app, row); minimumHeight(row, in: app)
    }
    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture", "--loopr-food-associations-fixture",
            "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        let tab = app.tabBars.buttons["Food"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: tab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func openReview(_ app: XCUIApplication) {
        tap(app, "food-log-meal"); tap(app, "food-capture-shutter")
        tap(app, "food-photo-consent-send"); tap(app, "food-lens-edit")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-review-item-")).firstMatch.waitForExistence(timeout: 20))
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let value = element(app, id); XCTAssertTrue(value.waitForExistence(timeout: 30)); reach(app, value); value.tapCommitting(in: app, identifier: id)
    }
    @MainActor private func reach(_ app: XCUIApplication, _ value: XCUIElement) {
        for _ in 0..<30 { if value.exists && value.isHittable { return }; app.swipeUp() }
        for _ in 0..<30 { if value.exists && value.isHittable { return }; app.swipeDown() }
        XCTFail("Could not reach \(value)")
    }
    @MainActor private func scrollToTop(_ app: XCUIApplication) { for _ in 0..<8 { app.swipeDown() } }
    @MainActor private func minimumHeight(_ value: XCUIElement, in app: XCUIApplication) {
        let scale = CGFloat(app.screenshot().image.cgImage!.width) / app.frame.width
        XCTAssertGreaterThanOrEqual((value.frame.height * scale).rounded(), (56 * scale).rounded())
    }
    /// A screen that fits one viewport: one screenshot and its coverage note.
    @MainActor private func single(_ app: XCUIApplication, _ slug: String, end endID: String) {
        let end = element(app, endID)
        XCTAssertTrue(end.waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "FiveTab Screen \(slug)_candidate"; attachment.lifetime = .keepAlways; add(attachment)
        let data = try! JSONSerialization.data(withJSONObject: ["screen": slug, "viewports": 1, "reachedEnd": true, "lastElement": endID], options: [.sortedKeys])
        let coverage = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        coverage.name = "FiveTab Coverage \(slug)"; coverage.lifetime = .keepAlways; add(coverage)
    }
    /// - Parameter overCover: The screen sits in the full-screen camera, whose tab bar stays in the
    ///   accessibility tree underneath; it does not cover the screen's bottom.
    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, end endID: String, scrollID: String? = nil, overCover: Bool = false) {
        let scroll = scrollID.map { app.scrollViews[$0].firstMatch } ?? app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 30))
        let end = element(app, endID)
        for index in 1...30 {
            let bottom = app.tabBars.firstMatch.exists && !overCover ? min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY) : scroll.frame.maxY
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "FiveTab Screen \(index == 1 ? slug : "\(slug)-\(index)")_candidate"
            attachment.lifetime = .keepAlways; add(attachment)
            if end.exists, end.frame.height > 0, end.frame.minY >= scroll.frame.minY, end.frame.maxY <= bottom {
                let data = try! JSONSerialization.data(withJSONObject: ["screen": slug, "viewports": index,
                    "reachedEnd": true, "lastElement": endID], options: [.sortedKeys])
                let coverage = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                coverage.name = "FiveTab Coverage \(slug)"; coverage.lifetime = .keepAlways; add(coverage)
                return
            }
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.34)))
        }
        XCTFail("Did not reach the end of \(slug) after 30 overlapping viewports")
    }
}
