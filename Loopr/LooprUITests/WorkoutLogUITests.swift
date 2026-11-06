import XCTest

/// The quick log, the WOD log and the interval presets on the Train fixture (Alex, Tue 2023-11-14).
final class WorkoutLogUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-deep-link=train",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Scrolls until the element can be tapped, then taps it.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, id)
        if !target.waitForExistence(timeout: wait) {
            for _ in 0..<12 where !target.exists { app.dragContent(up: true) }
        }
        XCTAssertTrue(target.exists, "\(id) did not appear", file: file, line: line)
        for _ in 0..<20 {
            if target.isHittable { target.tap(); return }
            app.dragContent(up: true)
        }
        XCTFail("Could not reach \(id)", file: file, line: line)
    }

    /// A common log: type, duration, Save. The saved workout opens in place of the log and says who logged it.
    @MainActor func testQuickLogSavesAYogaClassInFourTaps() {
        let app = launch()
        tap(app, "workouts-manual-entry")
        XCTAssertTrue(element(app, "workout-log-screen").waitForExistence(timeout: wait))
        XCTAssertFalse(element(app, "workout-log-save").isEnabled, "Nothing is chosen until a type is tapped")
        tap(app, "workout-log-type-yoga")
        tap(app, "workout-log-duration-20")
        element(app, "workout-log-save").tap()
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "workout-detail-source").label.localizedCaseInsensitiveContains("typed by you"))
        XCTAssertFalse(element(app, "workout-detail-route").exists, "A typed session has no route")
        XCTAssertFalse(element(app, "workout-detail-share").exists)
        XCTAssertTrue(element(app, "workout-detail-counts").label.contains("1 mobility session"), "The detail says what it counted")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait), "Back returns to Fitness, not the log")
    }

    /// The Garmin ride in Apple Health opens from This week with its heart rate, the zone split the dose used and what
    /// it added to the week (R2-VET-04, R2-NEW-14). It brings no route, so Route and Share stay hidden.
    @MainActor func testImportedRideShowsHeartRateZonesAndWhatItCounted() {
        let app = launch()
        tap(app, "workout-row-7A0460FE-0000-4000-8000-0000000000A1")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: wait))
        XCTAssertEqual(element(app, "workout-detail-source").label, "Garmin Connect through Apple Health")
        XCTAssertTrue(element(app, "workout-detail-heart-rate").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "workout-detail-zones").exists)
        XCTAssertTrue(element(app, "workout-detail-zone-2").label.contains("48"), element(app, "workout-detail-zone-2").label)
        XCTAssertEqual(element(app, "workout-detail-counts").label, "Added 48 Zone 2 minutes this week.")
        XCTAssertFalse(element(app, "workout-detail-route").exists, "An Apple Health import has no route in Loopr")
        XCTAssertFalse(element(app, "workout-detail-share").exists)
    }

    /// Gym in the quick log opens the set log, not a form.
    /// Gym in the quick log is a session already done: the past session logger, not a live workout (R2-LIFT-05).
    @MainActor func testGymChipOpensThePastSessionLogger() {
        let app = launch()
        tap(app, "workouts-manual-entry")
        tap(app, "workout-log-type-strength")
        XCTAssertTrue(element(app, "train-past-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "train-past-save").waitForExistence(timeout: wait))
    }

    /// A Fran beats the fixture's 4:58, so its detail carries a PR mark and the history.
    @MainActor func testWODLogFillsFranAndMarksAPR() {
        let app = launch()
        tap(app, "workouts-manual-entry")
        tap(app, "workout-log-type-crossfit")
        XCTAssertTrue(element(app, "wod-log-screen").waitForExistence(timeout: wait))
        tap(app, "wod-suggestion-fran")
        XCTAssertTrue(element(app, "wod-history").waitForExistence(timeout: wait), "Last and best show for a name done before")
        tap(app, "wod-score-time-minutes")
        app.typeText("4")
        tap(app, "wod-score-time-seconds")
        app.typeText("50")
        app.swipeDown()
        tap(app, "wod-save")
        // A new WOD shows its result first (R2-WOD-09), then Done opens the detail.
        XCTAssertTrue(element(app, "wod-result").waitForExistence(timeout: wait))
        tap(app, "wod-result-done")
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "workout-detail-wod-pr").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "workout-detail-again").exists)
    }

    /// The 4x4 preset fills 4:00 work, 3:00 rest, 4 rounds, with no rest after the last (R2-VET-05).
    @MainActor func testIntervalPresetSetsTheNorwegianFourByFour() {
        let app = launch()
        tap(app, "workouts-header-start")
        tap(app, "train-start-intervals")
        XCTAssertTrue(element(app, "interval-timer-screen").waitForExistence(timeout: wait))
        tap(app, "interval-preset-4x4")
        XCTAssertEqual(element(app, "interval-total").label, "Total 25:00. No rest after the last interval.")
        XCTAssertEqual(element(app, "interval-work").value as? String, "4 minutes")
        tap(app, "interval-work-plus")
        XCTAssertEqual(element(app, "interval-work").value as? String, "4 minutes 15 seconds")
    }
}
