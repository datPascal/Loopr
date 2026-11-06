import XCTest

/// LV-07.3: the Experiments segment and the result screen on the DEBUG fixture (`ProtocolTabFixture`): magnesium running
/// at night 9 of 14, and three finished experiments. "Bedroom at 18 °C" is Clear and not kept yet. ICP round 1: the
/// verdict leads, the range rides with every effect, and a new person sees one line and one button.
final class ProtocolExperimentUITests: XCTestCase {
    /// `ProtocolTabFixture.bedroomExperimentID`, in lower case.
    private let bedroom = "0f1a0000-0000-4000-8000-000000000003"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-patterns-fixture", "--loopr-entrance-final-state",
                               "--loopr-start-at=protocol-experiments", "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 30), "The launch opens the Protocol tab")
        return app
    }

    @MainActor func testTheRunningStripTheResultAndKeep() {
        let app = launch()
        let running = element(app, "protocol-experiment-running")
        XCTAssertTrue(running.waitForExistence(timeout: 15), "The launch opens the Experiments segment")
        let strip = element(app, "protocol-experiment-strip")
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        XCTAssertTrue(strip.label.contains("Magnesium: 4 nights"), "Read \"\(strip.label)\"")
        XCTAssertTrue(strip.label.contains("inside your usual spread of 9 min"), "Read \"\(strip.label)\"")
        // ICP R1-NEW-12, R1-SEN-19: one sentence on what an experiment is, the verdict first, what the strip measures and
        // who started it. The statistics wait behind How this works.
        XCTAssertTrue(element(app, "protocol-experiments-intro").exists)
        let call = element(app, "protocol-experiment-call")
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertEqual(call.label, "Too early to say. Night 9 of 14.")
        XCTAssertEqual(element(app, "protocol-experiment-measures").label, "Minutes of deep sleep")
        XCTAssertTrue(element(app, "protocol-experiment-started").label.hasPrefix("You started this on "))
        XCTAssertFalse(element(app, "protocol-experiment-how-detail").exists, "How this works starts closed")
        tap(app, "protocol-experiment-how")
        let how = element(app, "protocol-experiment-how-detail")
        XCTAssertTrue(how.waitForExistence(timeout: 10))
        let detail = how.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(detail.contains("Magnesium nights are 6 minutes ahead"), "Read \"\(detail)\"")
        XCTAssertTrue(detail.contains("one standard deviation of a single night"), "Read \"\(detail)\"")
        // One experiment at a time: the populated protocol runs magnesium, so no pattern test runs beside it.
        XCTAssertFalse(element(app, "protocol-pattern-test-running").exists)
        XCTAssertTrue(element(app, "protocol-experiment-start-pattern").exists)
        attach(app, "protocol-experiments")

        let row = element(app, "protocol-experiment-finished-\(bedroom)")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(row.label.contains("kept"), "Read \"\(row.label)\"")
        XCTAssertTrue(row.label.contains("95% range") && row.label.contains("7 nights each"), "Read \"\(row.label)\"")
        tap(app, "protocol-experiment-finished-\(bedroom)")

        XCTAssertTrue(element(app, "experiment-result-screen").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "experiment-result-label").label, "Clear")
        XCTAssertTrue(element(app, "experiment-result-effect").exists)
        let range = element(app, "experiment-result-range")
        XCTAssertTrue(range.exists && range.label.hasPrefix("95% range minus") && range.label.hasSuffix("7 nights each"), "Read \"\(range.label)\"")
        XCTAssertTrue(element(app, "experiment-result-groups").exists)
        XCTAssertTrue(element(app, "experiment-result-design").exists)
        XCTAssertTrue(element(app, "experiment-result-outcome").exists)
        let alsoMoved = element(app, "experiment-result-also-moved")
        XCTAssertTrue(reveal(app, alsoMoved))
        XCTAssertTrue(alsoMoved.label.contains("Fell asleep 8 min sooner. Not the outcome, so shown, not claimed."),
                      "Read \"\(alsoMoved.label)\"")
        attach(app, "experiment-result")

        let keep = element(app, "experiment-result-keep")
        XCTAssertTrue(reveal(app, keep))
        keep.tap()
        let kept = element(app, "experiment-result-kept")
        XCTAssertTrue(kept.waitForExistence(timeout: 10), "Keep turns into kept")
        XCTAssertTrue(kept.label.contains("Kept in version 4"), "Read \"\(kept.label)\"")
        XCTAssertFalse(element(app, "experiment-result-keep").exists)
        XCTAssertTrue(reveal(app, element(app, "experiment-result-share")), "The result file shares")
        attach(app, "experiment-result-kept")

        app.navigationBars.buttons.firstMatch.tap()
        let keptRow = element(app, "protocol-experiment-finished-\(bedroom)")
        XCTAssertTrue(keptRow.waitForExistence(timeout: 10))
        let predicate = NSPredicate(format: "label CONTAINS %@", "kept")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: keptRow)], timeout: 10),
                       .completed, "The row says kept, read \"\(keptRow.label)\"")
    }

    /// ICP R1-DES-19, R1-SEN-23: with no protocol, Experiments is one line and one button, and no pattern test shows even
    /// though the Patterns fixture runs one.
    @MainActor func testANewPersonSeesOneLineAndOneButton() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-patterns-fixture", "--loopr-protocol-fixture=empty",
                               "--loopr-entrance-final-state", "--loopr-start-at=protocol-experiments",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 30))
        let segment = element(app, "protocol-segment-experiments")
        if segment.waitForExistence(timeout: 5), !element(app, "protocol-experiment-empty").exists { segment.tap() }
        guard element(app, "protocol-experiment-empty").waitForExistence(timeout: 10) else {
            // The first-run start screen may hide the segments for a person with no protocol (round 1, W1).
            XCTAssertFalse(element(app, "protocol-pattern-test-running").exists)
            return
        }
        XCTAssertTrue(app.buttons["protocol-experiment-find"].exists)
        XCTAssertFalse(element(app, "protocol-pattern-test-running").exists)
        XCTAssertFalse(element(app, "protocol-experiment-none-running").exists, "no second empty card")
        XCTAssertFalse(element(app, "protocol-experiment-start-github").exists)
        attach(app, "protocol-experiments-empty")
    }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls a pushed screen until `target` is on screen.
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        guard target.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<8 {
            if target.isHittable, app.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)) { return true }
            app.swipeUp()
        }
        return target.isHittable
    }

    /// Scrolls `id` into the band between the sticky header and the tab bar, then taps it, as `ProtocolTabUITests` does.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
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

    @MainActor private func headerBottom(_ app: XCUIApplication) -> CGFloat {
        ["tab-header-title", "journal-header-ask", "open-settings"]
            .map { element(app, $0) }.filter(\.exists).map(\.frame.maxY).max() ?? 0
    }

    @MainActor private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        guard abs(distance) > 1 else { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
