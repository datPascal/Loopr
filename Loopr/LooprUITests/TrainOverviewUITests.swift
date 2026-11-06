import XCTest

/// The Fitness tab on the seeded fixture: Alex, Tuesday 2023-11-14, week 3 of the Strength block. The order is round
/// 1's (R1-DES-06): week strip, today, dose, the band's pending row, the start rail, This week, Plans, Fitness checks.
final class TrainOverviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch(fixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"] + (fixture ? ["--loopr-train-fixture"] : [])
            + ["--loopr-deep-link=train", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Scrolls until the element can be tapped, then taps it.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        // The tab builds rows lazily, so one far below the fold exists only once it is scrolled near.
        if !target.waitForExistence(timeout: wait) {
            for _ in 0..<12 where !target.exists { app.dragContent(up: true) }
        }
        XCTAssertTrue(target.exists, "\(id) did not appear", file: file, line: line)
        for _ in 0..<20 {
            if app.showsInContent(target) { target.tap(); return }
            if target.exists, target.frame.midY <= app.tabHeaderBottom + 8 { break }
            app.dragContent(up: true)
        }
        for _ in 0..<20 {
            if app.showsInContent(target) { target.tap(); return }
            app.dragContent(up: false)
        }
        XCTFail("Could not reach \(id)", file: file, line: line)
    }

    @MainActor private func back(_ app: XCUIApplication, to id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: wait), "Back is missing", file: file, line: line)
        button.tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: wait), "Did not return to \(id)", file: file, line: line)
    }

    /// True when some descendant of `container` carries `text` in its label.
    @MainActor private func contains(_ container: XCUIElement, _ text: String) -> Bool {
        container.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: wait)
    }

    private func scrollTop(_ app: XCUIApplication) { for _ in 0..<4 { app.swipeDown() } }

    /// Opens the Plans fold, where saved workouts and programs live.
    @MainActor private func openPlans(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app, "train-plans", file: file, line: line)
        XCTAssertTrue(element(app, "train-templates-header").waitForExistence(timeout: wait), "Plans did not open", file: file, line: line)
    }

    // MARK: Order

    /// The first screen answers "what today, and did this week give me enough": the strip, today's card, the dose and
    /// the band's pending row come before the starts, the log and the two folds.
    @MainActor func testTheTabRunsInTheRoundOneOrder() {
        let app = launch()
        let order = ["train-week-strip", "train-today-card", "fitness-dose", "workout-detected-row-fixture-detected-run",
                     "train-rail", "train-this-week-list", "train-plans", "fitness-checks"]
        for id in order { XCTAssertTrue(element(app, id).waitForExistence(timeout: wait), id) }
        for (upper, lower) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(element(app, upper).frame.minY, element(app, lower).frame.minY, "\(upper) should sit above \(lower)")
        }
        // Templates and programs wait behind the Plans row.
        XCTAssertFalse(element(app, "train-template-upper-a").exists)
        XCTAssertTrue(element(app, "train-plans").label.contains("saved workouts"), element(app, "train-plans").label)
        // The band's guess is one slim row.
        let pending = element(app, "workout-detected-row-fixture-detected-run")
        XCTAssertTrue(pending.label.contains("Band saw a 10 min run"), pending.label)
        XCTAssertLessThan(pending.frame.height, 90)
        // The header meta counts the days left, with no week number (R1-NEW-13).
        XCTAssertTrue(app.staticTexts["6 days left this week"].firstMatch.waitForExistence(timeout: wait)
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "6 days left this week"))
                        .firstMatch.exists)
    }

    /// One rail of starts with Gym first; WOD and Mobility sit beside Run and Ride (R1-WOD-12, R1-LIFT-12).
    @MainActor func testTheRailStartsEveryKindOfSessionWithGymFirst() {
        let app = launch()
        let ids = ["train-rail-gym", "train-rail-run", "train-rail-cycle", "train-rail-crossfit", "train-rail-mobility",
                   "train-rail-log", "train-rail-more"]
        for id in ids {
            let chip = element(app, id)
            XCTAssertTrue(chip.waitForExistence(timeout: wait), id)
            XCTAssertGreaterThanOrEqual(chip.frame.height, 56, id)
        }
        let gym = element(app, "train-rail-gym").frame
        for id in ids.dropFirst() {
            let frame = element(app, id).frame
            XCTAssertTrue(frame.minY > gym.minY + 1 || frame.minX > gym.minX, "\(id) should follow Gym")
        }
        XCTAssertFalse(element(app, "workouts-interval-timer").exists, "The timer moved into the start sheet")
        tap(app, "train-rail-gym")
        XCTAssertTrue(element(app, "train-start-sheet").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "train-start-empty").waitForExistence(timeout: wait))
        tap(app, "train-start-cancel")
        XCTAssertTrue(element(app, "train-start-sheet").waitForNonExistence(timeout: wait))
        tap(app, "train-rail-mobility")
        XCTAssertTrue(element(app, "workout-start-picker-screen").waitForExistence(timeout: wait))
    }

    // MARK: Overview

    @MainActor func testTrainTabShowsTodayWeekProgramsAndTemplates() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Fitness"].isSelected)

        let strip = element(app, "train-week-strip")
        XCTAssertTrue(strip.waitForExistence(timeout: wait))
        let today = element(app, "train-day-2023-11-14")
        XCTAssertTrue(today.waitForExistence(timeout: wait))
        XCTAssertTrue(today.label.contains("Upper A") && today.label.contains("today"), today.label)
        XCTAssertTrue(element(app, "train-day-2023-11-13").label.contains("done"))
        XCTAssertGreaterThanOrEqual(today.frame.height, 56)

        let card = element(app, "train-today-card")
        XCTAssertTrue(card.waitForExistence(timeout: wait))
        XCTAssertTrue(contains(card, "Upper A"))
        XCTAssertTrue(contains(card, "Recovery is 79"))
        // One line, no strain and no prose about recovery when nothing changes (R1-NEW-09).
        XCTAssertTrue(contains(card, "6 exercises · about 55 min"))
        XCTAssertFalse(card.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "expected strain")).firstMatch.exists)
        for id in ["train-start", "train-swap"] {
            let button = element(app, id)
            XCTAssertTrue(button.waitForExistence(timeout: wait), id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 56, id)
        }

        openPlans(app)
        tap(app, "train-program-strength-block")
        back(app, to: "workouts-screen")
        XCTAssertTrue(element(app, "train-program-strength-block").label.contains("week 3 of 8"))
        XCTAssertTrue(element(app, "train-program-half-marathon").label.contains("paused"))
        for id in ["train-template-lower-a", "train-template-upper-a", "train-template-zone-2", "train-program-new", "train-template-new"] {
            XCTAssertTrue(element(app, id).exists || { app.swipeUp(); return element(app, id).waitForExistence(timeout: 5) }(), id)
        }
        XCTAssertTrue(element(app, "train-template-upper-a").label.contains("6 exercises"))
    }

    @MainActor func testThisWeekListShowsTheFinishedSessionWithTonnage() {
        let app = launch()
        let list = element(app, "train-this-week-list")
        for _ in 0..<8 where !list.exists { app.swipeUp() }
        XCTAssertTrue(list.waitForExistence(timeout: wait))
        XCTAssertTrue(contains(list, "Lower A"))
        XCTAssertTrue(contains(list, "62 minutes"))
        XCTAssertTrue(contains(list, "8,420 kilograms lifted"))
        // Flat rows: a date instead of a "Completed" pill on every row (R1-DES-16, R1-LIFT-13).
        XCTAssertTrue(contains(list, "Mon 13 Nov"))
        XCTAssertFalse(list.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Completed")).firstMatch.exists)
        // The unsaved ride says on its own row why it is not counted.
        XCTAssertTrue(contains(list, "Not counted until you finish saving it."))
    }

    @MainActor func testSwapChoosesAnotherSessionForToday() {
        let app = launch()
        tap(app, "train-swap")
        XCTAssertTrue(element(app, "train-swap-sheet").waitForExistence(timeout: wait))
        XCTAssertFalse(element(app, "train-swap-option-upper-a").exists)
        tap(app, "train-swap-option-lower-b")
        XCTAssertTrue(element(app, "train-swap-sheet").waitForNonExistence(timeout: wait))
        let card = element(app, "train-today-card")
        XCTAssertTrue(contains(card, "Lower B"))
    }

    @MainActor func testStartOpensTheLiveStrengthWorkout() {
        let app = launch()
        tap(app, "train-start")
        XCTAssertTrue(element(app, "train-live-screen").waitForExistence(timeout: wait))
    }

    // MARK: Existing Workouts paths

    @MainActor func testEveryExistingWorkoutsEntryStillOpens() {
        let app = launch()

        tap(app, "workouts-start")
        XCTAssertTrue(element(app, "workout-start-picker-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "train-rail-more")
        tap(app, "train-start-intervals")
        XCTAssertTrue(element(app, "interval-timer-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "workouts-manual-entry")
        XCTAssertTrue(element(app, "workout-log-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        scrollTop(app)
        let plus = element(app, "workouts-header-start")
        XCTAssertTrue(plus.waitForExistence(timeout: wait))
        XCTAssertGreaterThanOrEqual(plus.frame.height, 56)
        plus.tap()
        XCTAssertTrue(element(app, "train-start-sheet").waitForExistence(timeout: wait))
        tap(app, "train-start-cancel")
        XCTAssertTrue(element(app, "train-start-sheet").waitForNonExistence(timeout: wait))

        tap(app, "workout-detected-row-fixture-detected-run")
        XCTAssertTrue(element(app, "workout-detected-review-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "workout-row-00000000-0000-0000-0000-000000000701")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "workout-row-00000000-0000-0000-0000-000000000702")
        XCTAssertTrue(element(app, "workout-recovery-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        // A saved gym session opens its sets, not the bare workout record (R1-LIFT-03, R1-NEW-11); Done comes back.
        tap(app, "workout-row-00000000-0000-0000-0000-000000000711")
        XCTAssertTrue(element(app, "train-summary-screen").waitForExistence(timeout: wait))
        // An older session opens as a record with no pinned Done (R2-NEW-07); Back returns.
        back(app, to: "workouts-screen")
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        XCTAssertFalse(element(app, "workout-detail-screen").exists)
    }

    /// One sheet starts every kind of training: the gym, each recorded activity, intervals and a past session.
    @MainActor func testStartSheetReachesEveryKindOfTraining() {
        let app = launch()
        tap(app, "train-start-more")
        XCTAssertTrue(element(app, "train-start-sheet").waitForExistence(timeout: wait))
        for id in ["train-start-empty", "train-start-template-upper-a", "train-start-activity-run", "train-start-activity-swim",
                   "train-start-activity-yoga", "train-start-activity-pilates", "train-start-activity-mobility",
                   "train-start-activity-crossfit", "train-start-intervals", "train-start-log"] {
            XCTAssertTrue(element(app, id).exists || { app.swipeUp(); return element(app, id).waitForExistence(timeout: 5) }(), id)
        }
        XCTAssertFalse(element(app, "train-start-activity-strength").exists, "The gym starts from the set log, not a bare recording")
        element(app, "train-start-activity-swim").tap()
        XCTAssertTrue(element(app, "workout-start-picker-screen").waitForExistence(timeout: wait))
        XCTAssertEqual(element(app, "workout-start-activity").label, "Swimming")
        XCTAssertTrue(element(app, "workout-start-confirm").label.lowercased().contains("swim"), element(app, "workout-start-confirm").label)
        XCTAssertTrue(element(app, "workout-start-log").exists, "Log it sits beside Start")
        // The Change menu changes the activity in place (R1-DES-11).
        tap(app, "workout-start-change")
        let hiking = app.buttons["Hiking"].firstMatch
        XCTAssertTrue(hiking.waitForExistence(timeout: wait))
        hiking.tap()
        XCTAssertTrue(element(app, "workout-start-confirm").label.contains("hike"), element(app, "workout-start-confirm").label)
        back(app, to: "workouts-screen")

        // The Ride chip keeps the old tile's identifier.
        tap(app, "train-start-cycle")
        XCTAssertTrue(element(app, "workout-start-activity").waitForExistence(timeout: wait))
        XCTAssertEqual(element(app, "workout-start-activity").label, "Cycling")
    }

    /// The play button on a saved workout starts it without opening the editor.
    @MainActor func testPlayStartsASavedWorkout() {
        let app = launch()
        openPlans(app)
        tap(app, "train-play-lower-a")
        XCTAssertTrue(element(app, "train-live-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "train-log-set").waitForExistence(timeout: wait))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The set log hides the tabs")
    }

    @MainActor func testEmptyTrainKeepsEveryStartAndExplainsItself() {
        let app = launch(fixture: false)
        // Nothing planned: no "Nothing planned yet" card, the start rail leads after the dose (UX R1-DES-03).
        XCTAssertTrue(element(app, "train-start-header").waitForExistence(timeout: wait))
        XCTAssertFalse(element(app, "train-empty").exists)
        // Nothing planned, so no plan's Start. A run done today still gets the short "Done today" card.
        XCTAssertFalse(element(app, "train-start").exists)
        // Gym stays first on the rail when nothing is planned too (R1-LIFT-12).
        for id in ["train-rail-gym", "workouts-start", "train-rail-crossfit", "train-rail-mobility", "workouts-manual-entry", "train-rail-more"] {
            for _ in 0..<8 where !element(app, id).exists { app.swipeUp() }
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), id)
        }
        openPlans(app)
        for id in ["train-program-new", "train-template-new"] {
            for _ in 0..<8 where !element(app, id).exists { app.swipeUp() }
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), id)
        }
        tap(app, "workouts-start")
        XCTAssertTrue(element(app, "workout-start-picker-screen").waitForExistence(timeout: wait))
    }

    // MARK: Program and template routes

    @MainActor func testTemplateAndProgramRowsOpenTheirRoutes() {
        let app = launch()
        openPlans(app)
        tap(app, "train-template-upper-a")
        XCTAssertTrue(element(app, "template-builder").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "train-template-new")
        XCTAssertTrue(element(app, "template-builder").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "train-program-strength-block")
        XCTAssertTrue(element(app, "program-screen").waitForExistence(timeout: wait))
        back(app, to: "workouts-screen")

        tap(app, "train-program-new")
        XCTAssertTrue(element(app, "program-editor").waitForExistence(timeout: wait))
        tap(app, "program-editor-cancel")
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
    }

    /// A tap selects a day; its caption sits under the strip at full width and opens that day's template (R1-DES-15).
    @MainActor func testWeekStripDayOpensItsTemplate() {
        let app = launch()
        let caption = element(app, "train-week-caption")
        XCTAssertTrue(caption.waitForExistence(timeout: wait))
        XCTAssertTrue(caption.label.localizedCaseInsensitiveContains("today"), caption.label)
        let lowerB = element(app, "train-day-2023-11-16")
        XCTAssertTrue(lowerB.waitForExistence(timeout: wait))
        XCTAssertTrue(lowerB.label.contains("Lower B"))
        lowerB.tap()
        XCTAssertTrue(lowerB.isSelected)
        XCTAssertTrue(contains(caption, "Lower B") || caption.label.contains("Lower B"), caption.label)
        XCTAssertTrue(caption.label.contains("Thu 16 Nov"), caption.label)
        caption.tap()
        XCTAssertTrue(element(app, "template-builder").waitForExistence(timeout: wait))
    }
}
