import XCTest

/// The Data tab's root on the seeded fixture (`--loopr-data-fixture`, `DataOverviewFixtures`): six area tiles, the age
/// ruler with its three pins in a compact card, this year against last, the star map and the More rows (Data ICP R1,
/// docs/design/2026-11-04-data-tab). `--loopr-entrance-final-state` shows final states, so no pin is mid-drop.
final class DataTabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let wait: TimeInterval = 30

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-data-fixture", "--loopr-entrance-final-state"] + extra
            + ["--loopr-deep-link=data", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch(); app.activate()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: wait))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Waits until the element's label contains `text`. The ruler draws its loading shape first and fills in.
    @MainActor private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Scrolls down until the element exists and sits in the visible content.
    @MainActor @discardableResult private func reveal(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<16 where !(target.exists && app.showsInContent(target)) { app.dragContent(up: true) }
        XCTAssertTrue(target.waitForExistence(timeout: wait), "\(id) did not appear", file: file, line: line)
        return target
    }

    @MainActor func testDataShowsTheAreasTheRulerTheSlopesTheStarsAndTheTools() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Data"].isSelected)
        XCTAssertTrue(element(app, "data-screen").waitForExistence(timeout: wait))

        // The areas lead: one tile each, carrying the identifiers the Explore rows had.
        XCTAssertTrue(element(app, "data-areas").waitForExistence(timeout: wait))
        for id in ["health-explore-sleep", "health-explore-heart", "health-explore-body", "health-explore-stress",
                   "data-area-body", "health-explore-labs"] {
            XCTAssertTrue(element(app, id).exists, id)
        }
        XCTAssertFalse(element(app, "data-setup").exists, "a person with data gets no setup card")
        XCTAssertFalse(element(app, "health-pinned-recovery").exists, "Pinned lives on Today and in All metrics")

        // The ruler fills in within a few seconds on the fixture.
        let hero = reveal(app, "data-age-hero")
        XCTAssertTrue(waitForLabel(hero, containing: "Blood age", timeout: 10), hero.label)
        let ruler = element(app, "data-age-ruler")
        XCTAssertTrue(ruler.exists)
        XCTAssertTrue(ruler.label.hasPrefix("Age ruler"), ruler.label)
        for kind in ["blood", "real", "cardio"] {
            XCTAssertTrue(element(app, "data-age-pin-\(kind)").exists, kind)
        }
        XCTAssertTrue(element(app, "data-age-not-medical").exists)

        XCTAssertTrue(reveal(app, "data-year-slopes").exists)
        XCTAssertTrue(element(app, "data-year-slopes-all").exists)
        // The star map lives in Blood tests now, with each marker's history behind it (Data ICP R3).
        XCTAssertFalse(element(app, "data-star-map").exists)
        XCTAssertFalse(element(app, "data-loopr-age-locked").exists, "no locked Loopr Age card on Data")

        // The tools close the page; the vault's storage, sources, export and backup are all in Your data.
        XCTAssertTrue(reveal(app, "data-vault").exists)
        for id in ["health-explore-metrics", "health-explore-records", "health-explore-methods", "health-explore-your-data",
                   "health-explore-publish"] {
            XCTAssertTrue(reveal(app, id).exists, id)
        }
    }

    @MainActor func testTheSleepTileOpensTheWholeNight() {
        let app = launch()
        let sleep = element(app, "health-explore-sleep")
        XCTAssertTrue(sleep.waitForExistence(timeout: wait))
        sleep.tap()
        // One tap: the full night with its stage chart and heart rate, and the range picker for the trends.
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "sleep-scope").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "sleep-stage-timeline").waitForExistence(timeout: wait))
        element(app, "sleep-scope-month").tap()
        XCTAssertTrue(element(app, "sleep-trends-screen").waitForExistence(timeout: wait))
    }

    @MainActor func testAPinOpensItsMethodPage() {
        let app = launch()
        XCTAssertTrue(element(app, "data-age-pin-blood").waitForExistence(timeout: wait))
        reveal(app, "data-age-pin-blood").tap()
        XCTAssertTrue(element(app, "method-phenoage").waitForExistence(timeout: wait))
        XCTAssertTrue(element(app, "method-value").exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "health-screen").waitForExistence(timeout: wait))
    }

    @MainActor func testALabYearRowOpensThatMarkersHistory() {
        let app = launch()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'data-year-slope-lab-'")).firstMatch
        for _ in 0..<16 where !(row.exists && app.showsInContent(row)) { app.dragContent(up: true) }
        XCTAssertTrue(row.waitForExistence(timeout: wait), "no lab row in this year against last")
        row.tap()
        // The marker page, or the plain message when the capture's lab database holds no such value.
        XCTAssertTrue(element(app, "labs-marker-chart-header").waitForExistence(timeout: wait)
            || app.staticTexts["This value is no longer saved on this iPhone."].waitForExistence(timeout: 5))
    }

    @MainActor func testANewPersonGetsTheStepsThatFillTheTab() {
        let app = launch(["--loopr-data-fixture=absent"])
        // No readings and no blood test: the setup steps instead of tiles of "No reading", no empty ruler, no empty
        // year and no empty star map (Data ICP R1-NEW-02, R1-DES-21).
        XCTAssertTrue(element(app, "data-setup").waitForExistence(timeout: wait))
        for id in ["data-setup-band", "data-setup-whoop", "data-setup-health", "data-setup-birth-year", "data-setup-blood"] {
            XCTAssertTrue(element(app, id).exists, id)
        }
        XCTAssertFalse(element(app, "data-areas").exists)
        XCTAssertFalse(element(app, "data-age-ruler").exists)
        XCTAssertFalse(element(app, "data-year-slopes").exists)
        XCTAssertFalse(element(app, "data-star-cluster-cardiovascular").exists)
        XCTAssertTrue(reveal(app, "data-vault").exists)
    }

    @MainActor func testAddABloodTestOpensTheBloodTests() {
        let app = launch(["--loopr-data-fixture=absent"])
        let blood = element(app, "data-setup-blood")
        XCTAssertTrue(blood.waitForExistence(timeout: wait))
        blood.tap()
        XCTAssertTrue(element(app, "labs-screen").waitForExistence(timeout: wait))
    }
}
