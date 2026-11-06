import XCTest

/// The Fitness tab's signature objects on the seeded fixture: Alex, 38, Tuesday 2023-11-14 in Perth,
/// week 46. `--loopr-train-fixture` brings the Fitness fixture with it (`FitnessFixtures`), and
/// `--loopr-entrance-final-state` shows final states so nothing is mid-animation.
final class FitnessTabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-train-fixture", "--loopr-entrance-final-state"] + extra
            + ["--loopr-deep-link=train", "-loopr-open-folds", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Scrolls down until the element exists and sits in the visible content.
    @MainActor private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<12 where !(target.exists && app.showsInContent(target)) { app.dragContent(up: true) }
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        return target
    }

    @MainActor func testFitnessShowsTheDoseTheGaugeAndTheCapacityInstruments() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Fitness"].isSelected)
        XCTAssertEqual(element(app, "tab-header-title").label, "Fitness")
        XCTAssertTrue(element(app, "train-header-ask").exists || element(app, "workouts-header-start").exists)

        let dose = element(app, "fitness-dose")
        XCTAssertTrue(dose.waitForExistence(timeout: wait))
        let zone2 = element(app, "fitness-dose-zone2")
        XCTAssertTrue(zone2.waitForExistence(timeout: wait))
        // The Protocol tab's "Zone 2, 150 min a week" sets the week, so both tabs read 112 of 150 (R2-OPT-16, ICP R3-VET-05).
        XCTAssertTrue(zone2.label.contains("112 of 150 minutes"), zone2.label)
        XCTAssertTrue(element(app, "fitness-dose-hard").label.contains("16 of 20 minutes"))
        XCTAssertTrue(element(app, "fitness-dose-strength").label.contains("of 3 sessions"))
        XCTAssertTrue(element(app, "fitness-dose-mobility").label.contains("of 3 sessions"))
        // One verdict from the targets, no score (R1-NEW-05), and where the targets come from.
        let verdict = element(app, "fitness-dose-verdict")
        XCTAssertTrue(verdict.waitForExistence(timeout: wait))
        XCTAssertTrue(verdict.label.contains("on pace"), verdict.label)
        XCTAssertTrue(verdict.label.contains("days in"), verdict.label)
        XCTAssertEqual(element(app, "fitness-dose-target-source").label, "Targets from your protocol.")
        XCTAssertTrue(element(app, "fitness-dose-hard").label.hasPrefix("Hard minutes"))

        let gauge = reveal(app, "fitness-vo2max")
        XCTAssertTrue(gauge.exists)
        let chip = element(app, "fitness-vo2max-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: wait))
        XCTAssertTrue(chip.label.contains("Apple Watch") && chip.label.contains("42-day median"), chip.label)
        let dial = element(app, "fitness-vo2max-gauge")
        XCTAssertTrue(dial.label.contains("44.1") && dial.label.contains("Top half for men aged 30 to 39"), dial.label)
        XCTAssertTrue(element(app, "fitness-vo2max-age-bar").label.contains("Your age 38"))

        for kind in ["grip", "dead-hang", "sit-to-stand", "one-leg-balance"] {
            let tile = reveal(app, "fitness-capacity-\(kind)")
            XCTAssertGreaterThanOrEqual(tile.frame.height, 56, kind)
        }
        XCTAssertTrue(element(app, "fitness-capacity-one-leg-balance").label.contains("Under the goal you set for age 85"))
        XCTAssertTrue(element(app, "fitness-capacity-grip").label.contains("Retest 16 Nov"))

        // The start rail sits under the dose, and Gym stays on it with a session planned (R1-LIFT-12).
        let run = element(app, "workouts-start")
        for _ in 0..<12 where !(run.exists && app.showsInContent(run)) { app.dragContent(up: false) }
        XCTAssertTrue(run.waitForExistence(timeout: wait), "workouts-start did not appear")
        XCTAssertTrue(element(app, "train-start-gym").exists)
        XCTAssertLessThan(dose.frame.minY, run.frame.minY)
    }

    /// A tile opens its test; the test's Results button opens the history.
    @MainActor func testACapacityTileOpensItsResults() {
        let app = launch()
        let grip = reveal(app, "fitness-capacity-grip")
        grip.tap()
        XCTAssertTrue(element(app, "fitness-test-grip").waitForExistence(timeout: wait))
        let results = app.buttons["fitness-test-history"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: wait))
        results.tap()
        XCTAssertTrue(element(app, "fitness-capacity-history").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-capacity-history-row-0").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "fitness-capacity-history-row-1").exists)
        let done = app.buttons["fitness-capacity-history-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: wait))
        done.tap()
        XCTAssertTrue(element(app, "fitness-capacity-history").waitForNonExistence(timeout: wait))
        let cancel = app.buttons["fitness-test-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: wait))
        cancel.tap()
        XCTAssertTrue(element(app, "fitness-test-grip").waitForNonExistence(timeout: wait))
    }

    @MainActor func testWithoutDataEachObjectSaysWhatIsMissing() {
        let app = launch(["--loopr-fitness-fixture=absent"])
        let note = element(app, "fitness-dose-band-note")
        XCTAssertTrue(note.waitForExistence(timeout: wait))
        XCTAssertEqual(note.label, "Zone minutes come from a band. There are none this week yet.")
        XCTAssertTrue(element(app, "fitness-dose-zone2").label.contains("not measured"))
        // No targets: no verdict, and the field says where targets would come from. No "Not measured" pill (R1-DES-18).
        XCTAssertFalse(element(app, "fitness-dose-verdict").exists)
        XCTAssertEqual(element(app, "fitness-dose-target-source").label, "No weekly targets set. They come from rules in Protocol.")
        let absent = reveal(app, "fitness-vo2max-absent")
        XCTAssertTrue(absent.label.contains("birth year"), absent.label)
        XCTAssertFalse(element(app, "fitness-vo2max-chip").exists)
        XCTAssertTrue(reveal(app, "fitness-capacity-grip").label.contains("Needs a dynamometer"))
        XCTAssertTrue(reveal(app, "fitness-capacity-intro").label.contains("no gear"))
        XCTAssertTrue(reveal(app, "fitness-capacity-sit-to-stand").label.contains("Try it"))
        XCTAssertTrue(reveal(app, "fitness-capacity-heart-rate-recovery").label.contains("Not read yet"))
    }

    /// What to do today comes before the dose, the VO2 max gauge and the capacity tests.
    @MainActor func testTodaysSessionComesBeforeTheDose() {
        let app = launch()
        let start = element(app, "train-start")
        let dose = element(app, "fitness-dose")
        XCTAssertTrue(start.waitForExistence(timeout: wait) && dose.waitForExistence(timeout: wait))
        XCTAssertLessThan(start.frame.minY, dose.frame.minY)
        XCTAssertTrue(app.showsInContent(start), "Start is on the first screen")
    }

    /// A sit to stand score of 10 is not assumed: both halves are scored before Save can be tapped.
    @MainActor func testSitToStandStartsEmptyAndSavesOnlyAfterBothHalvesAreScored() {
        let app = launch()
        reveal(app, "fitness-capacity-sit-to-stand").tap()
        XCTAssertTrue(element(app, "fitness-test-sit-to-stand").waitForExistence(timeout: wait))
        let save = app.buttons["fitness-test-save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: wait))
        XCTAssertFalse(save.isEnabled)
        app.buttons["fitness-sit-sitting-start"].firstMatch.tap()
        XCTAssertFalse(save.isEnabled)
        app.buttons["fitness-sit-rising-start"].firstMatch.tap()
        XCTAssertTrue(save.isEnabled)
    }
}
