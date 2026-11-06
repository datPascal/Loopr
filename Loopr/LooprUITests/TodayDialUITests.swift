import XCTest

/// Today's day dial on the populated fixture, pinned to the contract's two phones: 07:12 in the morning and 19:49 in
/// the evening (`--loopr-today-clock=`). `--loopr-entrance-final-state` shows final states so nothing is mid-entrance.
final class TodayDialUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    @MainActor private func launch(_ clock: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-today-clock=\(clock)",
                               "--loopr-deep-link=today", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: wait))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func testTheMorningDialShowsLastNightAndTheMorningReadouts() {
        let app = launch("morning")
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        XCTAssertTrue(dial.label.hasPrefix("Day dial, morning."), dial.label)
        let centre = element(app, "today-dial-centre")
        XCTAssertTrue(centre.waitForExistence(timeout: wait))
        XCTAssertTrue(centre.label.contains("asleep last night"), centre.label)
        for kind in ["sleepHeartRate", "regularity", "recovery"] {
            XCTAssertTrue(element(app, "today-readout-\(kind)").waitForExistence(timeout: wait), kind)
        }
        XCTAssertFalse(element(app, "today-readout-steps").exists)
        XCTAssertTrue(element(app, "today-more").waitForExistence(timeout: wait))

        let recovery = element(app, "today-metric-recovery")
        XCTAssertTrue(recovery.waitForExistence(timeout: wait))
        recovery.tap()
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: wait))
    }

    @MainActor func testTheEveningDialCountsDownToBed() {
        let app = launch("evening")
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        XCTAssertTrue(dial.label.hasPrefix("Day dial, evening."), dial.label)
        let centre = element(app, "today-dial-centre")
        XCTAssertTrue(centre.waitForExistence(timeout: wait))
        XCTAssertTrue(centre.label.contains("until bed at") || centre.label.contains("past bed at"), centre.label)
        for kind in ["lastMeal", "zone2", "steps"] {
            XCTAssertTrue(element(app, "today-readout-\(kind)").waitForExistence(timeout: wait), kind)
        }
        XCTAssertFalse(element(app, "today-readout-recovery").exists)
        // The Zone 2 readout and the rail's Zone 2 rule read the same 48 minutes (R1-OPT-17).
        let zone2 = element(app, "today-readout-zone2").descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Zone 2, 48'")).firstMatch
        XCTAssertTrue(zone2.waitForExistence(timeout: wait))

        // Recovery stays one tap away after 18:00, as a row under the evening readouts.
        let recovery = element(app, "today-metric-recovery")
        XCTAssertTrue(recovery.waitForExistence(timeout: wait))
        recovery.tap()
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: wait))
    }

    /// VoiceOver reads the hour in focus as the dial's value: the hand's hour, with what happened then.
    @MainActor func testTheDialReadsTheHourInFocusForVoiceOver() {
        let app = launch("morning")
        let dial = element(app, "today-dial")
        XCTAssertTrue(dial.waitForExistence(timeout: wait))
        let value = dial.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("07:00."), value)
    }
}
