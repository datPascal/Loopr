import XCTest

/// The Food tab's longevity objects on the populated Food fixture: the eating-window rail with its stickers and ghost,
/// the plants field, the four lens tiles and the stack, where a tap ticks magnesium.
final class FoodLongevityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=food", "--loopr-coach-fixture",
                               "--loopr-entrance-final-state", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["food-log-meal"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor func testTheRailPlantsLensAndStackShowAndACapsuleTicks() {
        let app = launch()
        defer { capture(app, "food-longevity-final") }
        XCTAssertTrue(app.descendants(matching: .any)["food-rings"].firstMatch.waitForExistence(timeout: 20))

        let rail = app.descendants(matching: .any)["food-window-rail"].firstMatch
        reach(app, rail)
        let stickers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "food-window-meal-"))
        XCTAssertTrue(stickers.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(stickers.count, 2, "Breakfast and lunch sit on today's rail")
        XCTAssertTrue(app.buttons["food-window-ghost"].exists, "The afternoon snack is still to come")
        capture(app, "food-longevity-rail")

        let plants = app.descendants(matching: .any)["food-plants"].firstMatch
        reach(app, plants)
        XCTAssertTrue(plants.label.contains("of 30"), plants.label)

        // The fixture has fewer than three finished days, so the longevity lens waits (UX R1-VET-17).
        for kind in ["protein", "fibre", "upf", "alcohol-free"] {
            XCTAssertFalse(app.descendants(matching: .any)["food-lens-\(kind)"].firstMatch.exists, kind)
        }

        let capsule = app.buttons["food-stack-item-supplement-mg-evening"]
        reach(app, capsule)
        XCTAssertTrue(capsule.label.contains("not taken yet"), capsule.label)
        capsule.tap()
        let taken = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mg, 300 mg, evening, taken"), object: capsule)
        XCTAssertEqual(XCTWaiter.wait(for: [taken], timeout: 15), .completed, capsule.label)
        capture(app, "food-longevity-stack")
    }

    @MainActor func testThePlantsAndTheStackEditorOpen() {
        let app = launch()
        defer { capture(app, "food-longevity-screens-final") }
        let plants = app.descendants(matching: .any)["food-plants"].firstMatch
        reach(app, plants)
        plants.tap()
        XCTAssertTrue(app.descendants(matching: .any)["food-plants-detail"].firstMatch.waitForExistence(timeout: 15))
        capture(app, "food-longevity-plants-detail")
        app.buttons["food-plants-done"].tap()

        let edit = app.buttons["food-stack-edit"]
        reach(app, edit)
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["food-stack-editor"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["food-stack-add-supplement"].waitForExistence(timeout: 10))
        capture(app, "food-longevity-stack-editor")
        app.buttons["food-stack-done"].tap()
    }

    /// Scrolls until the element is on screen below the header, down first and then back up.
    @MainActor private func reach(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<14 {
            if app.showsInContent(element) { return }
            app.dragContent(up: true)
        }
        for _ in 0..<14 {
            if app.showsInContent(element) { return }
            app.dragContent(up: false)
        }
        capture(app, "food-longevity-unreachable")
        XCTFail("Could not reach \(element)")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
