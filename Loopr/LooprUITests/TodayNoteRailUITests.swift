import XCTest

/// Today's coach note, protocol rail and experiment strip on the populated fixture (LV-04 step 3), pinned to the
/// contract's morning (07:12) and evening (19:49) with `--loopr-today-clock=`. The rail runs on the Today fixture's
/// real routine store, so a tick writes through RoutineKit.
final class TodayNoteRailUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func launch(_ clock: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-today-clock=\(clock)",
                               "--loopr-deep-link=today", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"] + extra
        app.launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: wait))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls Today until the element is on screen.
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: wait), target.debugDescription)
        // Short drags, then back down if the target went under the header (`FiveTabNavigationHelpers`).
        for _ in 0..<20 where !app.showsInContent(target) {
            if target.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 where !app.showsInContent(target) { app.dragContent(up: false) }
    }

    /// UX simplification (2026-11-01): the receipt waits behind "See the nights", the rail is "Up next" with the next
    /// three open rules (the ones the person ticks first) and a row to all ten, and the strip sits in "More from today".
    @MainActor func testTheMorningShowsTheNoteWithItsReceiptAndTheRail() {
        let app = launch("morning", extra: ["-loopr-open-folds", "YES"])
        let note = element(app, "today-note")
        XCTAssertTrue(note.waitForExistence(timeout: wait))
        let text = element(app, "today-note-text")
        XCTAssertTrue(text.waitForExistence(timeout: wait))
        XCTAssertTrue(text.label.hasPrefix("Sleep heart rate was"), text.label)
        XCTAssertTrue(text.label.contains("before bed"), text.label)
        XCTAssertFalse(element(app, "today-note-receipt").exists, "the receipt waits behind See the nights")
        let detail = element(app, "today-note-detail")
        reveal(app, detail)
        detail.tap()
        let receipt = element(app, "today-note-receipt")
        XCTAssertTrue(receipt.waitForExistence(timeout: wait))
        XCTAssertTrue(receipt.label.hasPrefix("Receipt chart for sleep heart rate."), receipt.label)
        XCTAssertTrue(element(app, "today-note-why").exists)
        XCTAssertFalse(element(app, "today-note-learning").exists)

        XCTAssertTrue(element(app, "today-rail").waitForExistence(timeout: wait))
        // Rules the person ticks come first; Food's own checks wait behind "All 10 rules".
        for key in ["magnesium", "screens-off"] {
            XCTAssertTrue(element(app, "today-rail-rule-\(key)").waitForExistence(timeout: wait), key)
        }
        XCTAssertFalse(element(app, "today-rail-rule-protein").exists)
        XCTAssertFalse(element(app, "today-rail-chip-morning-light").exists, "a kept chip belongs in the full list")
        XCTAssertEqual(element(app, "today-rail-all").label, "All 10 rules")
        // The rail counts the Protocol tab's rules due today (ICP R2-UPG-4, R3-NEW-07): eleven less the blood panel, done
        // 12 days ago and due again in three months, which is never "Tap to tick" here. It says what its ring means
        // (R2-UPG-22).
        XCTAssertTrue(element(app, "today-rail-count").label.hasSuffix("of 10 rules kept"), element(app, "today-rail-count").label)
        XCTAssertFalse(element(app, "today-rail-rule-blood-panel").exists, "The quarterly panel is not due today")
        XCTAssertTrue(element(app, "today-rail-tick-screens-off").exists)
        XCTAssertFalse(element(app, "today-rail-empty").exists)

        let experiment = element(app, "today-experiment")
        XCTAssertTrue(experiment.waitForExistence(timeout: wait))
        XCTAssertTrue(experiment.label.contains("night 9 of 14"), experiment.label)
        XCTAssertTrue(experiment.label.contains("Tonight is a magnesium night."), experiment.label)
    }

    @MainActor func testHoldingTheManualRuleTicksItAndTheRowShowsItKept() {
        let app = launch("morning")
        let tick = element(app, "today-rail-tick-screens-off")
        reveal(app, tick)
        tick.press(forDuration: 1.4)
        let row = element(app, "today-rail-rule-screens-off")
        let kept = row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'kept'")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: wait))
        // Kept, so there is nothing left to hold.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: tick)
        wait(for: [gone], timeout: wait)
    }

    /// A plain tap on the row ticks it (R1-UPG-4), the hint says so in the morning too, and Undo takes the tick back.
    @MainActor func testTappingTheManualRowTicksItAndUndoTakesItBack() {
        let app = launch("morning")
        let row = element(app, "today-rail-rule-screens-off")
        reveal(app, row)
        let hint = row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tap to tick'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: wait))
        hint.tap()
        let kept = row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'kept'")).firstMatch
        XCTAssertTrue(kept.waitForExistence(timeout: wait))
        let undo = element(app, "today-rail-undo")
        XCTAssertTrue(undo.waitForExistence(timeout: wait))
        undo.tap()
        XCTAssertTrue(element(app, "today-rail-tick-screens-off").waitForExistence(timeout: wait))
        XCTAssertTrue(hint.waitForExistence(timeout: wait))
    }

    @MainActor func testTheEveningShowsTheEveningNoteAndStartWindDown() {
        let app = launch("evening")
        let text = element(app, "today-note-text")
        XCTAssertTrue(text.waitForExistence(timeout: wait))
        XCTAssertTrue(text.label.hasPrefix("Kitchen closed at 12:30."), text.label)
        XCTAssertTrue(text.label.contains("Still to come before bed: "), text.label)
        XCTAssertFalse(text.label.contains("news"), "The rebuttal belongs to the reminder, not Today.")
        // Ask lives in the header and the Ask card, not on the note too (R1-UPG-18).
        XCTAssertFalse(element(app, "today-note-ask").exists)
        XCTAssertFalse(element(app, "today-note-receipt").exists)

        // The bedtime activity is off, so the first-evening card offers it. Starting it moves Start wind-down into the note.
        let card = element(app, "today-first-evening")
        XCTAssertTrue(card.waitForExistence(timeout: wait))
        let start = element(app, "today-first-evening-start")
        XCTAssertTrue(start.exists)
        XCTAssertEqual(start.label, "Start wind-down")
        reveal(app, start)
        start.tap()
        XCTAssertTrue(element(app, "today-note-wind-down").waitForExistence(timeout: wait))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        wait(for: [gone], timeout: wait)

        // Kitchen closed is kept, so Up next leaves it to the full list behind "All 10 rules".
        XCTAssertFalse(element(app, "today-rail-rule-kitchen-closed").exists)
        XCTAssertTrue(element(app, "today-rail-all").exists)
    }

    /// At the largest accessibility text size the note, the rail and the strip stay inside the screen's width.
    @MainActor func testAtTheLargestTextSizeTheNoteRailAndStripFitTheScreen() {
        let app = launch("morning", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                            "-loopr-open-folds", "YES"])
        let width = app.windows.firstMatch.frame.width
        for id in ["today-note", "today-note-text", "today-rail", "today-rail-rule-magnesium", "today-rail-rule-screens-off",
                   "today-experiment"] {
            // Today's content is not lazy, so every card reports its frame without scrolling to it.
            let target = element(app, id)
            XCTAssertTrue(target.waitForExistence(timeout: wait), id)
            let frame = target.frame
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(id) starts left of the screen: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(id) runs past the screen: \(frame)")
        }
    }
}
