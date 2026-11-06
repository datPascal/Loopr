import XCTest

/// LV-07 step 5: light and dark captures of the Protocol screens for the longevity visual lane
/// (`scripts/test-longevity-visual.py lv07`, entry "lv07" in `scripts/longevity-visual-phases.json`).
///
/// Each test is a fresh launch on the DEBUG Protocol fixture (`ProtocolTabFixture`: version 2 after the kept caffeine
/// result, magnesium running, three finished experiments) and ends with one `captureScreen` that scrolls to the screen's
/// last element. The suite changes nothing: no answer is given and no rule is saved. Pixel checks are not made here;
/// the lead reads the captures against the contract phones p-proto, p-result and p-share.
final class LongevityProtocolVisualUITests: XCTestCase {
    /// `ProtocolTabFixture.bedroomExperimentID`, in lower case: Clear, not kept yet, "Fell asleep 8 min sooner" also moved.
    private let bedroom = "0f1a0000-0000-4000-8000-000000000003"

    override func setUpWithError() throws { continueAfterFailure = false }

    /// The Protocol tab on the fixture. `startAt` is a `--loopr-start-at=` value; nil taps the Protocol tab, which opens Check-in.
    @MainActor private func launch(startAt: String? = nil, empty: Bool = false, patterns: Bool = false,
                                   extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["--loopr-launch-mode=populated"] + LongevityVisualCapture.launchArguments
        if patterns { arguments.append("--loopr-patterns-fixture") }
        if let startAt { arguments.append("--loopr-start-at=\(startAt)") }
        if empty { arguments.append("--loopr-protocol-fixture=empty") }
        arguments += extra
        app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        if startAt == nil {
            XCTAssertTrue(app.tabBars.buttons["Protocol"].waitForExistence(timeout: 30))
            app.tabBars.buttons["Protocol"].tap()
        }
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 30), "The Protocol tab did not open")
        return app
    }

    /// Waits for the screen to be filled in, so the first viewport is never a skeleton.
    @MainActor private func waitFor(_ app: XCUIApplication, _ ids: String...) {
        for id in ids { XCTAssertTrue(element(app, id).waitForExistence(timeout: 20), "\(id) did not appear") }
    }

    // MARK: Segments

    /// The check-in ends at the deck (ICP R1-DES-01). At the night clock the deck holds two cards and two rules wait.
    @MainActor func testCheckIn() {
        let app = launch(patterns: true, extra: ["--loopr-today-clock=night"])
        waitFor(app, "protocol-kept-hero", "protocol-deck-yes", "protocol-autofill", "protocol-evening-open")
        captureScreen(app, slug: "p-proto", root: "protocol-screen", end: "protocol-evening-open")
    }

    /// "How was your day?": how you feel, the questions about the day, the note and More, in one sheet.
    @MainActor func testEveningSheet() {
        let app = launch(patterns: true, extra: ["--loopr-today-clock=night"])
        tap(app, "protocol-evening-open")
        waitFor(app, "protocol-evening-sheet", "journal-edit-questions", "journal-privacy")
        captureScreen(app, slug: "p-proto-evening", root: "protocol-evening-scroll", end: "journal-privacy")
    }

    @MainActor func testExperiments() {
        let app = launch(startAt: "protocol-experiments", patterns: true)
        waitFor(app, "protocol-experiment-running", "protocol-experiment-start-github")
        captureScreen(app, slug: "p-proto-experiments", root: "protocol-screen", end: "protocol-experiment-start-github")
    }

    @MainActor func testRules() {
        let app = launch(startAt: "protocol-rules")
        waitFor(app, "protocol-rules-header", "protocol-rules-menu", "protocol-rule-add")
        captureScreen(app, slug: "p-proto-rules", root: "protocol-rules", end: "protocol-rule-add")
    }

    @MainActor func testFirstRunTemplates() {
        let app = launch(startAt: "protocol-rules", empty: true)
        waitFor(app, "protocol-templates", "protocol-template-start-here", "protocol-templates-github")
        captureScreen(app, slug: "p-proto-empty", root: "protocol-templates", end: "protocol-templates-github")
    }

    /// The preview a template opens (ICP R1-DES-03): each rule with who checks it and why, and the pinned Use button.
    @MainActor func testTemplatePreview() {
        let app = launch(startAt: "protocol-rules", empty: true)
        tap(app, "protocol-template-gentle-start")
        waitFor(app, "protocol-template-preview", "protocol-template-preview-use")
        captureScreen(app, slug: "p-proto-template-preview", root: "protocol-template-preview",
                      end: "protocol-template-preview-rule-alcohol")
    }

    // MARK: Pushed screens and the editor

    @MainActor func testResult() {
        let app = launch(startAt: "protocol-experiments", patterns: true)
        tap(app, "protocol-experiment-finished-\(bedroom)")
        waitFor(app, "experiment-result-label", "experiment-result-share")
        captureScreen(app, slug: "p-result", root: "experiment-result-screen", end: "experiment-result-share")
    }

    @MainActor func testShareProtocolPass() {
        let app = launch(startAt: "protocol-rules")
        openMenuItem(app, "protocol-share", label: "Share protocol")
        waitFor(app, "protocol-pass-card", "protocol-pass-github")
        captureScreen(app, slug: "p-share", root: "protocol-pass", end: "protocol-pass-github")
    }

    @MainActor func testRuleEditorOnAnEveningRule() {
        let app = launch(startAt: "protocol-rules")
        tap(app, "protocol-rule-screens-off")
        waitFor(app, "rule-editor", "rule-editor-more")
        // The time, the reminder and the line for the morning fold under More options (ICP R2-HAB-08).
        app.navigationBars["Edit rule"].firstMatch.swipeUp()
        let more = element(app, "rule-editor-more")
        for _ in 0..<4 where !more.isHittable { app.swipeUp() }
        more.tap()
        waitFor(app, "rule-editor-rebuttal", "rule-editor-delete")
        captureScreen(app, slug: "p-rule-editor", root: "rule-editor", end: "rule-editor-delete")
    }

    @MainActor func testVersionHistory() {
        let app = launch(startAt: "protocol-rules")
        openMenuItem(app, "protocol-versions-open", label: "Versions")
        waitFor(app, "protocol-version-2", "protocol-version-1")
        captureScreen(app, slug: "p-versions", root: "protocol-versions", end: "protocol-version-1")
    }

    /// ICP R1-VET-06: a version opens on what changed against the one before.
    @MainActor func testVersionDetail() {
        let app = launch(startAt: "protocol-rules")
        openMenuItem(app, "protocol-versions-open", label: "Versions")
        tap(app, "protocol-version-2")
        waitFor(app, "protocol-version-detail", "protocol-version-changes")
        captureScreen(app, slug: "p-version-detail", root: "protocol-version-detail", end: "protocol-version-changes")
    }

    // MARK: Helpers

    /// Opens the Rules header's menu and picks one item. A menu item keeps its identifier on iOS 26; the label is the
    /// fallback.
    @MainActor private func openMenuItem(_ app: XCUIApplication, _ id: String, label: String) {
        tap(app, "protocol-rules-menu")
        let byID = app.buttons[id].firstMatch
        let item = byID.waitForExistence(timeout: 5) ? byID : app.buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) is not in the Rules menu")
        item.tap()
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls `id` into the band between the sticky header and the tab bar, then taps it, as `ProtocolTabUITests` does.
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "\(id) did not appear")
        for _ in 0..<16 {
            let top = headerBottom(app) + 8
            let bottom = (app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY) - 8
            let frame = target.frame
            if target.isHittable, frame.minY >= top, frame.maxY <= bottom { target.tap(); return }
            let room = max(bottom - top - frame.height, 0)
            let shift: CGFloat = frame.maxY > bottom ? -(frame.maxY - bottom + room / 2) : (top - frame.minY + room / 2)
            drag(app, by: max(min(shift, 320), -320))
        }
        XCTFail("Could not bring \(id) between the header and the tab bar")
    }

    /// The bottom of the tab header: its title and its glass buttons.
    @MainActor private func headerBottom(_ app: XCUIApplication) -> CGFloat {
        ["tab-header-title", "journal-header-ask", "open-settings"]
            .map { element(app, $0) }.filter(\.exists).map(\.frame.maxY).max() ?? 0
    }

    /// A slow vertical drag along the left gutter, so it scrolls the page and never moves a card or a picker.
    @MainActor private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        guard abs(distance) > 1 else { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }
}
