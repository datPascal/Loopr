import XCTest

/// Captures screens 10 to 13 of the five-tab design: the Train overview, the workout builder, the live
/// session and a program. Alex trains in Australia/Perth on Tuesday 2023-11-14, week 3 of the Strength block.
///
/// The live screen opens through `--loopr-train-fixture=live`, which freezes the clock: 24:10 elapsed, 142 bpm in
/// zone 3, strain 7.9, 1:45 of rest left and bench press on set 3 of 4.
final class TrainVisualUITests: XCTestCase {
    private static let wait: TimeInterval = 30
    /// Scroll drags start in the left gutter, where no control sits.
    private static let gutter: CGFloat = 0.06

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testTrainOverviewThroughEndOfPage() {
        let app = launch()
        capture(app, "10-train", end: "train-this-week-list", scrollID: "workouts-screen")
    }

    @MainActor func testWorkoutBuilderOpenedFromUpperAThroughRules() {
        let app = launch(); openBuilder(app)
        capture(app, "11-workout-builder", end: "template-rule-band-cue")
    }

    @MainActor func testLiveSessionOnTheFrozenClockThroughTheRestTimer() {
        let app = launchLive()
        let eyebrow = element(app, "train-live-eyebrow")
        XCTAssertTrue(eyebrow.waitForExistence(timeout: Self.wait))
        XCTAssertTrue(eyebrow.label.contains("set 3 of 4"), eyebrow.label)
        let rest = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", "1 minute 45 seconds")).firstMatch
        XCTAssertTrue(rest.waitForExistence(timeout: Self.wait), "The frozen rest should read 1:45")
        capture(app, "12-live-session", end: "train-rest-timer")
    }

    @MainActor func testProgramOpenedFromStrengthBlockThroughChangePlan() {
        let app = launch(); openProgram(app)
        capture(app, "13-program", end: "program-change-plan")
    }

    @MainActor func testLargestTextKeepsAllFourTrainScreensReachable() {
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let app = launch(extra: largest)
        // Overview: the end of the page and the row that opens the builder.
        let week = element(app, "train-this-week-list"); reach(app, week)
        let template = element(app, "train-template-upper-a"); XCTAssertTrue(template.waitForExistence(timeout: Self.wait))
        reach(app, template); minimumHeight(template, in: app)
        template.tapCommittingTrain(in: app, identifier: "train-template-upper-a")
        // Builder: the first and last controls.
        let describe = element(app, "template-describe"); XCTAssertTrue(describe.waitForExistence(timeout: Self.wait))
        minimumHeight(describe, in: app)
        let add = element(app, "template-add-exercise"); reach(app, add); minimumHeight(add, in: app)
        let bandCue = element(app, "template-rule-band-cue"); reach(app, bandCue)
        let cancel = element(app, "template-cancel"); scrollToTop(app); reach(app, cancel); cancel.tap()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: Self.wait))
        // Program: the hero, the grid and the last button.
        let program = element(app, "train-program-strength-block"); reach(app, program); minimumHeight(program, in: app)
        program.tapCommittingTrain(in: app, identifier: "train-program-strength-block")
        XCTAssertTrue(element(app, "program-hero").waitForExistence(timeout: Self.wait))
        reach(app, element(app, "program-grid"))
        let change = element(app, "program-change-plan"); reach(app, change); minimumHeight(change, in: app)
        // Live: a fresh launch, because the frozen screen has its own entry point.
        app.terminate()
        let live = launchLive(extra: largest)
        let log = element(live, "train-log-set"); reach(live, log); minimumHeight(log, in: live)
        let timer = element(live, "train-rest-timer"); reach(live, timer)
        let skip = element(live, "train-rest-done"); reach(live, skip); minimumHeight(skip, in: live)
    }

    // MARK: Launch

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Saved workouts and programs sit in the Plans fold; captures start every fold open.
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-deep-link=train", "--loopr-coach-fixture",
            "--loopr-train-fixture", "--loopr-appearance=system", "-loopr-open-folds", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        let tab = app.tabBars.buttons["Fitness"]
        XCTAssertTrue(tab.waitForExistence(timeout: Self.wait))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: tab)], timeout: Self.wait), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tab)], timeout: 20), .completed)
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: Self.wait))
        XCTAssertTrue(element(app, "train-today-card").waitForExistence(timeout: Self.wait))
        return app
    }

    /// `--loopr-train-fixture=live` pushes the live screen by itself. No deep link and no tap.
    @MainActor private func launchLive(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "--loopr-train-fixture=live",
            "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "train-live-screen").waitForExistence(timeout: 60))
        return app
    }

    @MainActor private func openBuilder(_ app: XCUIApplication) {
        tap(app, "train-template-upper-a")
        XCTAssertTrue(element(app, "template-describe").waitForExistence(timeout: Self.wait))
    }

    @MainActor private func openProgram(_ app: XCUIApplication) {
        tap(app, "train-program-strength-block")
        XCTAssertTrue(element(app, "program-hero").waitForExistence(timeout: Self.wait))
    }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let value = element(app, id); XCTAssertTrue(value.waitForExistence(timeout: Self.wait))
        reach(app, value); value.tapCommittingTrain(in: app, identifier: id)
    }

    /// One drag that starts in the left gutter, so it never lands on a control. `up` scrolls the content up.
    @MainActor private func drag(_ app: XCUIApplication, up: Bool) {
        let from = app.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: up ? 0.78 : 0.34))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: up ? 0.34 : 0.78)))
        // The header snaps the scroll position once the drag ends; read frames after it settles.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.6)
    }

    @MainActor private func isReachable(_ app: XCUIApplication, _ value: XCUIElement) -> Bool {
        app.showsInContent(value)
    }

    @MainActor private func reach(_ app: XCUIApplication, _ value: XCUIElement) {
        for _ in 0..<30 {
            if isReachable(app, value) { return }
            // Under the header: one drag down brings it into view.
            if value.exists, value.frame.maxY > 0, value.frame.midY <= app.tabHeaderBottom + 8 { break }
            drag(app, up: true)
        }
        for _ in 0..<30 { if isReachable(app, value) { return }; drag(app, up: false) }
        XCTFail("Could not reach \(value)")
    }

    @MainActor private func scrollToTop(_ app: XCUIApplication) { for _ in 0..<8 { drag(app, up: false) } }

    @MainActor private func minimumHeight(_ value: XCUIElement, in app: XCUIApplication) {
        let scale = CGFloat(app.screenshot().image.cgImage!.width) / app.frame.width
        XCTAssertGreaterThanOrEqual((value.frame.height * scale).rounded(), (56 * scale).rounded())
    }

    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, end endID: String, scrollID: String? = nil) {
        let scroll = scrollID.map { app.scrollViews[$0].firstMatch } ?? app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: Self.wait))
        let end = element(app, endID)
        for index in 1...30 {
            let bottom = app.tabBars.firstMatch.exists ? min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY) : scroll.frame.maxY
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
            scroll.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: Self.gutter, dy: 0.34)))
        }
        XCTFail("Did not reach the end of \(slug) after 30 overlapping viewports")
    }
}
