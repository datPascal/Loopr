import XCTest

/// The Today captures for the longevity visual lane (`scripts/test-longevity-visual.py lv04`): the morning and the evening
/// dial with the note, rail and experiment strip under it, the learning state, a day the band has not filled, and
/// "What shaped it" for recovery. The fixture is Alex, Tuesday 2023-11-14 in Perth, with the clock pinned to the contract's
/// 07:12 and 19:49 (`--loopr-today-clock=`). The lock screen and Dynamic Island (`p-lock`) are not part of the app's
/// window, so the lead captures them apart from this suite.
/// Each test launches fresh, taps nothing that saves, and changes nothing the next one reads.
final class LongevityTodayVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    /// The last element on Today: the timeline card ends the page on every state the suite opens.
    private static let end = "today-timeline-end"

    /// What fills Today's rows and timeline, as the Agent suite launches it: food, a planned session, the check-in and a
    /// found pattern. None of it writes.
    private static let day = ["--loopr-train-fixture", "--loopr-agent-day-fixture", "--loopr-journal-fixture=checkin",
                              "--loopr-patterns-fixture=found"]

    /// 24-hour times, as the contract shows them (and as the Today dial and note tests read them).
    private func launch(_ clock: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=system", "--loopr-today-clock=\(clock)",
                               "--loopr-deep-link=today"]
            + Self.day + LongevityVisualCapture.launchArguments + ["-loopr-open-folds", "YES"] + extra
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The dial, the note, the rail, the strip and the timeline arrive after the first frame. Wait for all of them so the
    /// first capture is not a half-loaded page.
    @MainActor private func waitForToday(_ app: XCUIApplication, ids: [String]) {
        for id in ["today-dial", "today-note"] + ids + [Self.end] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: wait), "\(id) did not appear")
        }
    }

    // MARK: Morning

    @MainActor func testTodayInTheMorning() {
        let app = launch("morning")
        waitForToday(app, ids: ["today-note-detail", "today-rail", "today-experiment"])
        captureScreen(app, slug: "p-today", root: "today-screen", end: Self.end)
    }

    // MARK: Evening

    /// After 18:00: the bedtime countdown in the dial, the evening note and the first-evening card, which offers
    /// Start wind-down while the bedtime activity is off.
    @MainActor func testTodayInTheEvening() {
        let app = launch("evening")
        waitForToday(app, ids: ["today-first-evening", "today-rail", "today-experiment"])
        captureScreen(app, slug: "p-today-evening", root: "today-screen", end: Self.end)
    }

    // MARK: Learning

    /// Three nights behind it: the note says how many are left, the dial has no usual and no regularity, recovery counts
    /// its nights. `--loopr-today-fixture=learning` is a DEBUG launch argument; the SI morning fixture gives recovery its
    /// first night.
    @MainActor func testTodayWhileLearning() {
        let app = launch("morning", extra: ["--loopr-today-fixture=learning", "--loopr-si-morning-fixture=first-night"])
        waitForToday(app, ids: ["today-note-learning", "today-rail", "today-experiment"])
        captureScreen(app, slug: "p-today-learning", root: "today-screen", end: Self.end)
    }

    // MARK: No band data

    /// Sunday 12 November is the fixture's day with nothing recorded, two days before the fixture day. Today then shows
    /// one plain card, and the dial, the rules and Ask stay (`TodayManualDayContent`).
    @MainActor func testTodayOnADayWithoutBandData() {
        let app = launch("morning")
        let navigator = element(app, "day-navigator")
        XCTAssertTrue(navigator.waitForExistence(timeout: wait))
        for _ in 0..<2 {
            navigator.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        }
        XCTAssertTrue(element(app, "day-empty-state").waitForExistence(timeout: wait))
        for id in ["today-dial", Self.end] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: wait), "\(id) did not appear")
        }
        captureScreen(app, slug: "p-today-absent", root: "today-screen", end: Self.end)
    }

    // MARK: What shaped it

    /// The recovery readout opens "What shaped it": each signal's push against the earlier nights, the last 30 days and
    /// how the score is worked out. The page ends on the link to Recovery history.
    @MainActor func testWhatShapedRecovery() {
        let app = launch("morning")
        let recovery = element(app, "today-metric-recovery")
        XCTAssertTrue(recovery.waitForExistence(timeout: wait))
        recovery.tap()
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "today-breakdown-recovery-metric").waitForExistence(timeout: wait))
        captureScreen(app, slug: "p-today-breakdown", root: "today-recovery-breakdown-screen", end: "today-breakdown-recovery-metric")
    }
}
