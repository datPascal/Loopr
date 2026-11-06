import XCTest

/// LV-07.1: the Protocol tab's check-in on the DEBUG fixture protocol (`ProtocolTabFixture`): Tuesday 14 Nov 2023 with
/// Magnesium (21:30), Screens off (21:45), Read before bed (22:00) and In bed (22:30) still open. At the night clock
/// (21:50, `--loopr-today-clock=night`, the clock Today reads too) the deck holds Magnesium and Screens off and the
/// other two wait in the later line; at the evening clock (19:49) every one of them waits (ICP R1-SEN-02). Patterns come
/// from `--loopr-patterns-fixture`.
final class ProtocolTabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(clock: String = "night", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-patterns-fixture", "--loopr-entrance-final-state",
                               "--loopr-today-clock=\(clock)", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Protocol"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Protocol"].tap()
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "journal-screen").exists, "The tab root keeps the Journal identifier")
        return app
    }

    @MainActor func testAnsweringACardFillsTodaysRosetteAndUndoTakesItBack() {
        let app = launch()
        for id in ["protocol-segment-checkin", "protocol-segment-experiments", "protocol-segment-rules", "protocol-kept-hero",
                   "protocol-rosette-monday", "protocol-rosette-sunday"] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 10), id)
        }
        let today = element(app, "protocol-rosette-tuesday")
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        expect(today, label: "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")

        let card = element(app, "protocol-deck-card-magnesium")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The earliest open rule leads the deck")
        tap(app, "protocol-deck-yes")
        expect(today, label: "Today, Tuesday, 4 of 10 rules kept, 5 pending, 1 not known")
        XCTAssertTrue(element(app, "protocol-deck-card-screens-off").waitForExistence(timeout: 10))

        tap(app, "protocol-deck-undo")
        expect(today, label: "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
        XCTAssertTrue(element(app, "protocol-deck-card-magnesium").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-deck-later").exists, "Read before bed waits in the later list")
        XCTAssertFalse(element(app, "protocol-deck-later-in-bed").exists, "The band checks In bed, so it is not listed")
        attach(app, "protocol-check-in")
    }

    /// ICP R1-HAB-01: Skip today is a third answer. The skipped rule is its own dot, not kept and not open, and Undo
    /// takes it back.
    @MainActor func testSkipTodayIsItsOwnAnswerAndUndoTakesItBack() {
        let app = launch()
        let today = element(app, "protocol-rosette-tuesday")
        XCTAssertTrue(element(app, "protocol-deck-card-magnesium").waitForExistence(timeout: 10))
        tap(app, "protocol-deck-skip")
        expect(today, label: "Today, Tuesday, 3 of 10 rules kept, 5 pending, 1 skipped, 1 not known")
        XCTAssertTrue(element(app, "protocol-deck-card-screens-off").waitForExistence(timeout: 10))
        tap(app, "protocol-deck-undo")
        expect(today, label: "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
    }

    /// ICP R2-HAB-02, R2-DES-11, R2-VET-03, R3-DES-04, R3-VET-06: "Skip the rest of today" skips only the three open
    /// rules the person answers (Magnesium, Screens off, Read before bed) with one confirm that says Food and the band
    /// keep checking theirs. Protein, No alcohol and In bed stay open for their source; Undo opens the three again.
    /// Today's day sheet starts with the same action.
    @MainActor func testSkipTheRestOfTodaySkipsOnlyTheRulesThePersonAnswersAndUndoOpensThem() {
        let app = launch()
        let today = element(app, "protocol-rosette-tuesday")
        XCTAssertTrue(element(app, "protocol-deck-card-magnesium").waitForExistence(timeout: 10))
        tap(app, "protocol-skip-day-deck")
        XCTAssertTrue(app.staticTexts["Skip 3 rules you answer?"].waitForExistence(timeout: 10), "The confirm names what it skips")
        XCTAssertTrue(app.staticTexts["Food and the band keep checking their rules. Skipped rules don't count against your week."].exists)
        let confirm = app.buttons["Skip 3 rules"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "One confirm with the count the deck shows")
        attach(app, "protocol-skip-day-confirm")
        confirm.tap()
        let skipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '3 skipped'"), object: today)
        XCTAssertEqual(XCTWaiter.wait(for: [skipped], timeout: 10), .completed, "Read \"\(today.label)\"")
        XCTAssertTrue(today.label.contains("3 of 10 rules kept"), "What a source checked stays")
        XCTAssertTrue(today.label.contains("3 pending"), "Protein, No alcohol and In bed stay open for their source: \(today.label)")
        XCTAssertTrue(element(app, "protocol-skip-day-deck-done").waitForExistence(timeout: 10))
        attach(app, "protocol-skip-day-done")
        tap(app, "protocol-skip-day-deck-undo")
        expect(today, label: "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")

        tap(app, "protocol-autofill")
        XCTAssertTrue(element(app, "protocol-day-sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-skip-day-day-sheet").waitForExistence(timeout: 10), "Today's sheet starts with it")
        element(app, "protocol-day-done").tap()
    }

    /// ICP R3-VET-01, R3-VET-02: a tap on the hero's number opens "This week", one row per rule with its count and who
    /// checks it, the weekly and quarterly rules with their progress, and how many answers the person changed. The words
    /// that name the rule not kept still open that day.
    @MainActor func testTheHeroOpensThisWeekAndTheSlipOpensItsDay() {
        let app = launch()
        tap(app, "protocol-kept-week")
        XCTAssertTrue(element(app, "protocol-this-week-sheet").waitForExistence(timeout: 10))
        let inBed = element(app, "protocol-this-week-rule-in-bed")
        XCTAssertTrue(inBed.waitForExistence(timeout: 10))
        XCTAssertTrue(inBed.label.contains("0 of 1 kept"), inBed.label)
        XCTAssertTrue(inBed.label.contains("Checked by the band"), inBed.label)
        let panel = element(app, "protocol-this-week-rule-blood-panel")
        XCTAssertTrue(panel.exists)
        XCTAssertTrue(panel.label.contains("Every 3 months"), panel.label)
        XCTAssertTrue(element(app, "protocol-this-week-lead").label.hasSuffix("kept so far."), element(app, "protocol-this-week-lead").label)
        XCTAssertTrue(element(app, "protocol-this-week-changes").exists)
        attach(app, "protocol-this-week")
        element(app, "protocol-this-week-done").tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: element(app, "protocol-this-week-sheet"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)

        tap(app, "protocol-kept-slip")
        XCTAssertTrue(element(app, "protocol-day-sheet").waitForExistence(timeout: 10), "The slip opens Monday")
        // ICP round 4, SEN and VET: Monday's "Screens off" was ticked with Done on its reminder, and the sheet says so.
        let fromReminder = element(app, "protocol-day-rule-screens-off-label")
        XCTAssertTrue(fromReminder.waitForExistence(timeout: 10))
        XCTAssertTrue(fromReminder.label.contains("Answered from your reminder"), fromReminder.label)
        // Monday keeps the list it had, with the daily Zone 2, and says why it is not today's (ICP R4 Q6).
        let change = element(app, "protocol-day-list-change")
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        XCTAssertEqual(change.label, "You changed your rules on 2 Nov. This day shows the list you had then.")
        XCTAssertTrue(element(app, "protocol-day-rule-zone-2").exists, "Monday's own Zone 2, 45 min")
        attach(app, "protocol-day-sheet-old-list")
        element(app, "protocol-day-done").tap()
    }

    /// ICP R1-SEN-02, R2-DES-05, R2-VET-04: at 19:49 nothing due later tonight is asked. The deck is one quiet line, the
    /// rules wait in a list under it, and a tap on one brings its card up to answer now.
    @MainActor func testAtTheEveningClockLaterRulesWaitAndOneCanBeAnsweredNow() {
        let app = launch(clock: "evening")
        XCTAssertTrue(element(app, "protocol-deck-later").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "protocol-deck-card-magnesium").exists, "Magnesium at 21:30 is not asked at 19:49")
        let waiting = element(app, "protocol-deck-empty")
        XCTAssertTrue(waiting.exists)
        // The later list names each rule and its time, so the quiet line does not say "Next" again (ICP R3-SEN-02).
        XCTAssertTrue(["Nothing yet.", "Done for now."].contains(waiting.label), waiting.label)
        XCTAssertEqual(element(app, "protocol-deck-later-title").label, "Later tonight")
        attach(app, "protocol-check-in-evening")
        tap(app, "protocol-deck-later-magnesium")
        XCTAssertTrue(element(app, "protocol-deck-card-magnesium").waitForExistence(timeout: 10), "Answer now brings the card up")
        XCTAssertFalse(element(app, "protocol-deck-later-magnesium").exists)
        attach(app, "protocol-check-in-answer-now")
    }

    /// ICP R1-VET-02: on an off night of the magnesium test the rule is skipped by design and the check-in says so.
    @MainActor func testAnOffNightSkipsTheRuleUnderTest() {
        let app = launch(extra: ["--loopr-protocol-fixture=off-night"])
        XCTAssertTrue(element(app, "protocol-deck-off-night").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-deck-card-screens-off").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "protocol-deck-card-magnesium").exists)
        attach(app, "protocol-off-night")
    }

    /// ICP R1-DES-04, R1-VET-04: "checked for you" opens today's day sheet, a change there is marked "Changed by you",
    /// and the way back undoes it.
    @MainActor func testTheDaySheetChangesASourcesAnswerAndMarksIt() {
        let app = launch()
        tap(app, "protocol-autofill")
        XCTAssertTrue(element(app, "protocol-day-sheet").waitForExistence(timeout: 10))
        // Today lists the 10 rules due, as Today does, and names the one that is not (ICP R4 Q3).
        XCTAssertFalse(element(app, "protocol-day-rule-blood-panel").exists, "The blood panel is not due until February")
        XCTAssertEqual(element(app, "protocol-day-not-due").label, "Not due today: Blood panel, next in February.")
        XCTAssertFalse(element(app, "protocol-day-list-change").exists, "Today's list is today's")
        let notKept = element(app, "protocol-day-rule-caffeine-cutoff-answer-missed")
        XCTAssertTrue(notKept.waitForExistence(timeout: 10))
        notKept.tap()
        XCTAssertTrue(element(app, "protocol-day-rule-caffeine-cutoff-changed").waitForExistence(timeout: 10))
        attach(app, "protocol-day-sheet-changed")
        element(app, "protocol-day-rule-caffeine-cutoff-reset").tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: element(app, "protocol-day-rule-caffeine-cutoff-changed"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
        element(app, "protocol-day-done").tap()
    }

    /// ICP R3-NEW-01, R3-SEN-01, R3-VET-04, R3-HAB-01, R3-DES-01: at 21:50 on a 6.3 inch phone Yes and No sit fully
    /// above the tab bar with no scroll. The pattern line waits under the deck, the swipe hint is gone for a person with
    /// weeks of answers, and "See all" opens today's day sheet (R3-HAB-03).
    @MainActor func testAtTheNightClockYesAndNoSitAboveTheTabBarWithoutAScroll() {
        let app = launch()
        let card = element(app, "protocol-deck-card-magnesium")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let yes = card.descendants(matching: .any)["protocol-deck-yes"].firstMatch
        let no = card.descendants(matching: .any)["protocol-deck-no"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.exists)
        attach(app, "protocol-night-yes-above-tab-bar")
        XCTAssertLessThanOrEqual(yes.frame.maxY, bar.frame.minY, "Yes \(yes.frame) against the tab bar \(bar.frame)")
        XCTAssertLessThanOrEqual(no.frame.maxY, bar.frame.minY, "No \(no.frame) against the tab bar \(bar.frame)")
        XCTAssertGreaterThanOrEqual(yes.frame.minY, headerBottom(app), "Yes is not under the header")
        XCTAssertTrue(yes.isHittable)
        XCTAssertFalse(element(app, "protocol-deck-hint").exists, "This person has answered for weeks")
        XCTAssertTrue(element(app, "protocol-rosette-tuesday").frame.maxY < card.frame.minY, "Today's rosette is in view")

        let pattern = element(app, "protocol-pattern-line")
        XCTAssertTrue(pattern.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(pattern.frame.minY, yes.frame.maxY, "The pattern line waits under the deck")
        XCTAssertTrue(pattern.label.contains("Not proof of cause."), pattern.label)
        XCTAssertTrue(pattern.label.contains(" nights against "), "The counts stay on the line: \(pattern.label)")
        XCTAssertFalse(pattern.label.contains("Your rule: "), "The rule moved to Patterns, behind the tap (R4 Q7): \(pattern.label)")

        tap(app, "protocol-deck-see-all")
        XCTAssertTrue(element(app, "protocol-day-sheet").waitForExistence(timeout: 10), "See all opens today's day sheet")
        attach(app, "protocol-see-all-day-sheet")
        element(app, "protocol-day-done").tap()
    }

    /// The same at the XL text size: Yes and No show after at most one short scroll (ICP R3-SEN-01).
    @MainActor func testAtTheXLTextSizeYesShowsAfterOneShortScrollAtMost() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"])
        let card = element(app, "protocol-deck-card-magnesium")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let yes = card.descendants(matching: .any)["protocol-deck-yes"].firstMatch
        let no = card.descendants(matching: .any)["protocol-deck-no"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        let bar = app.tabBars.firstMatch
        attach(app, "protocol-night-xl")
        let overshoot = max(yes.frame.maxY, no.frame.maxY) - bar.frame.minY
        XCTAssertLessThanOrEqual(overshoot, 200, "Yes \(yes.frame) is more than one short scroll under the tab bar \(bar.frame)")
        if overshoot > 0 {
            drag(app, by: -(overshoot + 16))
            attach(app, "protocol-night-xl-scrolled")
        }
        XCTAssertLessThanOrEqual(yes.frame.maxY, bar.frame.minY, "Yes \(yes.frame) against the tab bar \(bar.frame)")
        XCTAssertGreaterThanOrEqual(yes.frame.minY, headerBottom(app), "Yes is not under the header")
    }

    /// ICP R3-NEW-08, R3-VET-11, R3-HAB-05, R3-DES-11, R3-SEN-02: the deck slot closes as the last card goes, so no empty
    /// frame over 200 pt stays. The quiet line then says "Done for now." without repeating the later list, and once the
    /// last rule is answered the closing card says what tomorrow holds.
    @MainActor func testTheDeckClosesAfterTheLastCardAndTheClosingCardSaysTomorrow() {
        let app = launch()
        for key in ["magnesium", "screens-off"] {
            let card = element(app, "protocol-deck-card-\(key)")
            XCTAssertTrue(card.waitForExistence(timeout: 10), key)
            tap(app, card.descendants(matching: .any)["protocol-deck-yes"].firstMatch, "\(key) yes")
        }
        let quiet = element(app, "protocol-deck-empty")
        XCTAssertTrue(quiet.waitForExistence(timeout: 10))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: element(app, "protocol-deck-card-screens-off"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "The last card leaves the deck")
        let title = element(app, "protocol-deck-title")
        XCTAssertLessThan(quiet.frame.minY - title.frame.maxY, 200, "No empty card frame between \(title.frame) and \(quiet.frame)")
        XCTAssertEqual(quiet.label, "Done for now.")
        attach(app, "protocol-deck-done-for-now")

        tap(app, "protocol-deck-later-read-before-bed")
        let read = element(app, "protocol-deck-card-read-before-bed")
        XCTAssertTrue(read.waitForExistence(timeout: 10), "Answer now brings the card up")
        tap(app, read.descendants(matching: .any)["protocol-deck-yes"].firstMatch, "read-before-bed yes")
        let closing = element(app, "protocol-deck-closing")
        XCTAssertTrue(closing.waitForExistence(timeout: 10), "Nothing is left, so the closing card takes the deck's place")
        let above = ["protocol-kept-hero", "protocol-rosette-tap-hint", "protocol-pattern-line", "protocol-weekly-review"]
            .map { element(app, $0) }.filter { $0.exists && $0.frame.maxY <= closing.frame.minY + 1 }.map(\.frame.maxY).max() ?? 0
        XCTAssertLessThan(closing.frame.minY - above, 200, "No empty frame above the closing card at \(closing.frame)")
        let tomorrow = element(app, "protocol-deck-closing-tomorrow")
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 10))
        XCTAssertTrue(tomorrow.label.hasPrefix("Tomorrow: "), tomorrow.label)
        attach(app, "protocol-closing-night")
    }

    @MainActor func testNotesAndPatternsAreOneTapAway() {
        let app = launch()
        XCTAssertTrue(element(app, "protocol-autofill").waitForExistence(timeout: 10))
        // How you feel, the questions and the note live behind "How was your day?" (ICP R1-DES-01).
        tap(app, "protocol-evening-open")
        XCTAssertTrue(element(app, "protocol-evening-sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "journal-check-in").exists)
        tapInEveningSheet(app, "protocol-notes")
        XCTAssertTrue(element(app, "journal-history-screen").waitForExistence(timeout: 10), "All notes opens every note")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 15))

        // Patterns left the check-in; its one home is under Experiments (UX R1-DES-15).
        XCTAssertFalse(element(app, "protocol-patterns-all").exists)
        tap(app, "protocol-segment-rules")
        XCTAssertTrue(element(app, "protocol-rules-list").waitForExistence(timeout: 10))
        tap(app, "protocol-segment-experiments")
        // One way into Patterns from Experiments: "From a pattern" (ICP R1-NEW-13).
        XCTAssertTrue(element(app, "protocol-experiment-start-pattern").waitForExistence(timeout: 10))
        tap(app, "protocol-experiment-start-pattern")
        XCTAssertTrue(element(app, "patterns-screen").waitForExistence(timeout: 30))
        attach(app, "protocol-segments")
    }

    // MARK: Helpers

    /// Drags the evening sheet until `id` sits below the sheet's own navigation bar, then taps it. A control scrolled
    /// under that bar counts as hittable, but the tap lands on the bar.
    @MainActor private func tapInEveningSheet(_ app: XCUIApplication, _ id: String) {
        let target = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(id) did not appear")
        let done = app.descendants(matching: .any)["protocol-evening-done"].firstMatch
        for _ in 0..<16 {
            let top = (done.exists ? done.frame.maxY : 120) + 16
            let bottom = app.frame.maxY - 40
            let frame = target.frame
            if target.isHittable, frame.minY >= top, frame.maxY <= bottom { target.tap(); return }
            let room = max(bottom - top - frame.height, 0)
            let shift: CGFloat = frame.maxY > bottom ? -(frame.maxY - bottom + room / 2) : (top - frame.minY + room / 2)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: max(min(shift, 300), -300))),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Could not bring \(id) below the evening sheet's bar")
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls `id` into the band between the sticky header and the tab bar, then taps it. The collapsed header bar is
    /// hidden from accessibility, so XCUITest calls a control under it hittable while the tap lands on the bar. A plain
    /// `swipeUp` moves the page about 680 pt, which can park the target under the header, so this drags by the distance
    /// the target is off.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        tap(app, element(app, id), id)
    }

    /// The same for an element found inside another, such as the Yes of one card.
    @MainActor private func tap(_ app: XCUIApplication, _ target: XCUIElement, _ id: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(id) did not appear")
        for _ in 0..<16 {
            let top = headerBottom(app) + 8
            let bottom = (app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY) - 8
            let frame = target.frame
            if target.isHittable, frame.minY >= top, frame.maxY <= bottom { target.tap(); return }
            let room = max(bottom - top - frame.height, 0)
            let shift: CGFloat = frame.maxY > bottom ? -(frame.maxY - bottom + room / 2) : (top - frame.minY + room / 2)
            drag(app, by: max(min(shift, 320), -320))
        }
        attach(app, id + "-unreachable")
        XCTFail("Could not bring \(id) between the header and the tab bar")
    }

    /// The bottom of the tab header: its title and its glass buttons.
    @MainActor private func headerBottom(_ app: XCUIApplication) -> CGFloat {
        ["tab-header-title", "journal-header-ask", "open-settings"]
            .map { element(app, $0) }.filter(\.exists).map(\.frame.maxY).max() ?? 0
    }

    /// A slow vertical drag along the left gutter, outside the deck card, so it scrolls the page and never swipes a card.
    @MainActor private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        guard abs(distance) > 1 else { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor private func expect(_ element: XCUIElement, label: String) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [condition], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected \"\(label)\", read \"\(element.label)\"")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
