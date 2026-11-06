import XCTest

/// Lab mode in the Food camera (LV-05.4), on the fixture report: `--loopr-food-lab-fixture` feeds a fixed English
/// report with one uncertain value instead of the camera and Vision.
final class FoodLabModeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLabReadsTheReportFixesTheAmberValueAndSaves() {
        let app = launch()
        defer { attach(app, "food-lab-saved") }
        openLab(app)

        XCTAssertTrue(app.descendants(matching: .any)["food-lab-header"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["food-lab-report"].waitForExistence(timeout: 30))
        let first = app.buttons["food-lab-chip-0"]
        let amber = app.buttons["food-lab-chip-review-3"]
        waitHittable(first)
        waitHittable(amber)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-lab-chip-review-")).count, 1)
        let summary = app.descendants(matching: .any)["food-lab-summary"].firstMatch
        reach(app, summary)
        XCTAssertTrue(summary.label.contains("29 values read"), summary.label)
        XCTAssertTrue(summary.label.contains("1 needs a look"), summary.label)
        XCTAssertTrue(app.descendants(matching: .any)["food-lab-blood-age-ready"].exists)
        attach(app, "food-lab-review")

        reach(app, amber)
        amber.tap()
        let field = app.textFields["food-lab-edit-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        reach(app, field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + "0.7")
        XCTAssertEqual(field.value as? String, "0.7")
        let confirm = app.buttons["food-lab-edit-confirm"]
        waitHittable(confirm)
        confirm.tap()

        XCTAssertTrue(app.buttons["food-lab-chip-3"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["food-lab-chip-review-3"].exists)
        XCTAssertTrue(app.buttons["food-lab-chip-3"].label.contains("0.7"), app.buttons["food-lab-chip-3"].label)
        reach(app, summary)
        XCTAssertTrue(summary.label.contains("None need a look"), summary.label)

        let save = app.buttons["food-lab-save"]
        waitHittable(save)
        save.tap()
        let saved = app.descendants(matching: .any)["food-lab-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        XCTAssertTrue(saved.label.contains("29 values saved"), saved.label)
        XCTAssertTrue(saved.label.contains("Nothing was uploaded"), saved.label)

        let finish = app.buttons["food-lab-done"]
        waitHittable(finish)
        finish.tap()
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
    }

    @MainActor func testSummaryAndSaveStayReachableAtTheLargestTextSize() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { attach(app, "food-lab-ax5") }
        openLab(app)
        let save = app.buttons["food-lab-save"]
        waitHittable(save, timeout: 60)
        XCTAssertTrue(app.buttons["food-lab-chip-review-3"].waitForExistence(timeout: 30))
        let summary = app.descendants(matching: .any)["food-lab-summary"].firstMatch
        reach(app, summary)
        XCTAssertTrue(summary.isHittable)
        XCTAssertTrue(summary.label.contains("29 values read"), summary.label)
        XCTAssertTrue(save.isHittable, "Save stays on screen while the read scrolls")
    }

    // MARK: Helpers

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture",
                               "--loopr-metric-history-fixture", "--loopr-food-lab-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        let foodTab = app.tabBars.buttons["Food"]
        XCTAssertTrue(foodTab.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: foodTab)], timeout: 30), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: foodTab)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        return app
    }

    /// Opens the Food camera, switches to Lab and takes the fixture report.
    @MainActor private func openLab(_ app: XCUIApplication) {
        let camera = app.buttons["food-log-meal"]
        reach(app, camera)
        camera.tapCommitting(in: app, identifier: "food-log-meal")
        let shutter = app.buttons["food-capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        waitEnabled(shutter)
        let mode = app.buttons["food-lens-mode-lab"]
        waitHittable(mode)
        XCTAssertEqual(app.buttons["food-lens-mode-food"].label, "Food")
        XCTAssertEqual(app.buttons["food-lens-mode-label"].label, "Label")
        XCTAssertEqual(mode.label, "Lab")
        mode.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: mode)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["food-lab-header"].waitForExistence(timeout: 15))
        waitEnabled(shutter)
        shutter.tap()
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "\(element) never became enabled")
    }

    @MainActor private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) never appeared")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, "\(element) never became hittable")
    }

    /// Scrolls the read until `element` can be tapped.
    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) never appeared")
        // Since iOS 27 XCTest calls a control under the sticky header hittable, and at the largest text size the
        // header covers the camera tile, so scroll until the control sits in the content between header and tab bar.
        for _ in 0..<8 where !app.showsInContent(element) { app.dragContent(up: false) }
        for _ in 0..<12 where !app.showsInContent(element) { app.dragContent(up: true) }
        XCTAssertTrue(app.showsInContent(element), "Could not reach \(element)")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
