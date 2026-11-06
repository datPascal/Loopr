import XCTest

/// LV-07.4: the Rules segment on the DEBUG fixture protocol (`ProtocolTabFixture`, version 3, which swapped the daily zone 2
/// for a weekly one and added the blood panel): edit an evening rule's time and reason under More options, save, see "Saved as version 4." with
/// Undo, find version 4 and what it changed under Versions in the header's menu, then open Share protocol from the same
/// menu. Another test adds a rule on
/// chosen days and removes it after the confirm. The last starts from the empty fixture (`--loopr-protocol-fixture=empty`),
/// previews a template and uses it.
final class ProtocolRulesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(empty: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-entrance-final-state", "--loopr-start-at=protocol-rules",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_GB"] + (empty ? ["--loopr-protocol-fixture=empty"] : [])
        app.launch()
        XCTAssertTrue(element(app, "protocol-screen").waitForExistence(timeout: 30), "The launch opens the Protocol tab")
        // With no protocol there are no segments: Rules and Check-in show the same start screen, and the screen's one
        // child shares its accessibility node, so the start screen's own container is the one to wait for.
        let opened = empty ? "protocol-templates" : "protocol-rules"
        XCTAssertTrue(element(app, opened).waitForExistence(timeout: 15), "The launch opens the Rules segment")
        return app
    }

    @MainActor func testEditingAnEveningRuleSavesANewVersionAndShareShowsThePass() {
        let app = launch()
        let header = element(app, "protocol-rules-header")
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        XCTAssertFalse(header.label.contains("Day "), "the day and count show once, in the tab header (ICP R3-DES-03)")
        XCTAssertFalse(header.label.contains("Version"), "the version shows under Versions only (ICP R1-NEW-17)")
        XCTAssertTrue(element(app, "protocol-rule-add").exists)
        XCTAssertTrue(element(app, "protocol-rules-menu").exists)
        // ICP R2-HAB-05, R2-VET-06: a daily rule shows its week, a longer one how far it has come.
        let screensRow = element(app, "protocol-rule-screens-off")
        XCTAssertTrue(screensRow.label.contains("This week: Mon kept"), "Read \"\(screensRow.label)\"")
        let weekly = element(app, "protocol-rule-zone-2-week")
        XCTAssertTrue(weekly.waitForExistence(timeout: 10))
        XCTAssertTrue(weekly.label.contains(" of 150 min") && weekly.label.contains("days left"), "Read \"\(weekly.label)\"")
        XCTAssertFalse(element(app, "protocol-rule-zone-2").exists, "version 3 replaced the daily Zone 2 (ICP R3-VET-05)")
        // ICP R3-NEW-10, R3-VET-12: the rule under test says so, with the night.
        let magnesium = element(app, "protocol-rule-magnesium")
        XCTAssertTrue(magnesium.label.contains("Under test, night 9 of 14"), "Read \"\(magnesium.label)\"")
        XCTAssertTrue(element(app, "protocol-rule-blood-panel").label.contains("due"), element(app, "protocol-rule-blood-panel").label)
        attach(app, "protocol-rules")

        tap(app, "protocol-rule-screens-off")
        XCTAssertTrue(element(app, "rule-editor").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "rule-editor-version").exists, "no version line before Save (ICP R1-HAB-19)")
        expandSheet(app, title: "Edit rule")
        // The first view is short: a summary line, name, why and days; the rest folds under More options (ICP R2-HAB-08).
        for id in ["rule-editor-summary", "rule-editor-why", "rule-editor-days", "rule-editor-more"] {
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 5), id)
        }
        // ICP R3-VET-08: where the rule comes from, read only, under the Why.
        let evidence = element(app, "rule-editor-evidence")
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Where this comes from") && evidence.label.contains("45 minutes"), "Read \"\(evidence.label)\"")
        XCTAssertFalse(element(app, "rule-editor-time").exists, "the time waits under More options")
        let more = element(app, "rule-editor-more")
        XCTAssertTrue(reveal(app, more))
        more.tap()
        XCTAssertTrue(reveal(app, element(app, "rule-editor-reminder")))
        // A rule you tick is always asked, so it has no ask switch (ICP R2-NEW-05).
        XCTAssertFalse(element(app, "rule-editor-evening").exists)

        let time = element(app, "rule-editor-time")
        XCTAssertTrue(reveal(app, time))
        time.tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5), "the compact time opens its wheels")
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "22")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "05")
        // Closes the time's popover without touching the form.
        app.navigationBars["Edit rule"].firstMatch.tap()
        XCTAssertTrue(wheels.element(boundBy: 0).waitForNonExistence(timeout: 5))

        let reason = element(app, "rule-editor-rebuttal")
        XCTAssertTrue(reveal(app, reason))
        reason.tap()
        reason.typeText("Tomorrow starts tonight.")
        attach(app, "rule-editor")
        for id in ["rule-editor-source", "rule-editor-delete"] {
            XCTAssertTrue(reveal(app, element(app, id)), id)
        }

        let save = app.buttons["rule-editor-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(element(app, "rule-editor").waitForNonExistence(timeout: 10), "Save closes the editor")

        let toast = element(app, "loopr-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.label.contains("Saved as version 4"), "Read \"\(toast.label)\"")
        XCTAssertTrue(element(app, "loopr-toast-action").exists, "the toast offers Undo")
        attach(app, "protocol-rules-saved")
        let row = element(app, "protocol-rule-screens-off")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("22:05"), "Read \"\(row.label)\"")

        openMenuItem(app, "protocol-versions-open", label: "Versions")
        XCTAssertTrue(element(app, "protocol-versions").waitForExistence(timeout: 10))
        let entry = element(app, "protocol-version-4")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.label.contains("Changed Screens off by 22:05: time to 22:05"), "Read \"\(entry.label)\"")
        // ICP R2-VET-07: the fixture's version 3 says what it changed and why.
        let added = element(app, "protocol-version-3")
        XCTAssertTrue(added.label.contains("Added Zone 2, 150 min a week") && added.label.contains("Removed Zone 2, 45 min")
                      && added.label.contains("Why: Changed Zone 2 to 150 min a week"), "Read \"\(added.label)\"")
        XCTAssertTrue(element(app, "protocol-version-2").exists && element(app, "protocol-version-1").exists)
        attach(app, "protocol-versions")
        entry.tap()
        let change = element(app, "protocol-version-change-screens-off")
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the version opens on what changed")
        XCTAssertTrue(change.label.contains("Time 21:45 to 22:05"), "Read \"\(change.label)\"")
        XCTAssertTrue(element(app, "protocol-version-unchanged").exists, "the rules that stayed the same are folded")
        attach(app, "protocol-version-detail")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        openMenuItem(app, "protocol-share", label: "Share protocol")
        XCTAssertTrue(element(app, "protocol-pass").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-pass-card").waitForExistence(timeout: 10))
        let counts = element(app, "protocol-pass-counts")
        XCTAssertTrue(counts.exists)
        XCTAssertTrue(counts.label.hasPrefix("11 rules"), "Read \"\(counts.label)\"")
        XCTAssertTrue(element(app, "protocol-pass-rosette").exists)
        XCTAssertTrue(reveal(app, element(app, "protocol-pass-share")))
        XCTAssertTrue(reveal(app, element(app, "protocol-pass-github")))
        attach(app, "protocol-pass")
    }

    /// ICP R1-HAB-02, R1-DES-21: a new rule on chosen days shows them on its row; Remove asks first and then saves.
    @MainActor func testAddingARuleOnChosenDaysThenRemovingItAfterTheConfirm() {
        let app = launch()
        tap(app, "protocol-rule-add")
        XCTAssertTrue(element(app, "rule-editor").waitForExistence(timeout: 10))
        expandSheet(app, title: "New rule")
        XCTAssertTrue(element(app, "rule-editor-summary").label.hasPrefix("Every day."), "Every day is picked to start")
        XCTAssertFalse(element(app, "rule-editor-problem").exists, "an untouched name is not told off (ICP R2-DES-10)")
        app.buttons["rule-editor-save"].tap()
        XCTAssertTrue(element(app, "rule-editor-problem").waitForExistence(timeout: 5), "Save says the rule needs a name")
        XCTAssertTrue(element(app, "rule-editor").exists, "nothing was saved")
        let name = element(app, "rule-editor-title")
        name.tap()
        name.typeText("Gym")
        let why = element(app, "rule-editor-why")
        XCTAssertTrue(reveal(app, why))
        why.tap()
        why.typeText("Strength keeps me on my feet.")
        // "How often" is one row with a menu (ICP R3-DES-07).
        let howOften = element(app, "rule-editor-days")
        XCTAssertTrue(reveal(app, howOften))
        XCTAssertTrue(howOften.label.contains("How often"), "Read \"\(howOften.label)\"")
        howOften.tap()
        let byID = app.buttons["rule-editor-days-some-days"].firstMatch
        let someDays = byID.waitForExistence(timeout: 5) ? byID : app.buttons["Some days"].firstMatch
        XCTAssertTrue(someDays.waitForExistence(timeout: 5), "the menu lists Some days")
        someDays.tap()
        for day in ["mon", "wed", "fri"] {
            let chip = element(app, "rule-editor-weekdays-\(day)")
            XCTAssertTrue(reveal(app, chip), day)
            chip.tap()
        }
        attach(app, "rule-editor-new")
        app.buttons["rule-editor-save"].tap()
        XCTAssertTrue(element(app, "rule-editor").waitForNonExistence(timeout: 10))
        let row = element(app, "protocol-rule-gym")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Mon, Wed, Fri"), "Read \"\(row.label)\"")
        XCTAssertTrue(row.label.contains("Strength keeps me on my feet."), "Read \"\(row.label)\"")
        XCTAssertTrue(element(app, "loopr-toast").waitForNonExistence(timeout: 15), "the toast goes on its own")

        tap(app, "protocol-rule-gym")
        XCTAssertTrue(element(app, "rule-editor").waitForExistence(timeout: 10))
        let remove = element(app, "rule-editor-delete")
        XCTAssertTrue(reveal(app, remove))
        remove.tap()
        let confirm = app.buttons["rule-editor-remove-confirm"].firstMatch
        let confirmButton = confirm.waitForExistence(timeout: 5) ? confirm : app.buttons["Remove rule"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Remove asks first")
        attach(app, "rule-editor-remove-confirm")
        confirmButton.tap()
        XCTAssertTrue(element(app, "rule-editor").waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-rule-gym").waitForNonExistence(timeout: 10))
        let toast = element(app, "loopr-toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.label.contains("Removed Gym"), "Read \"\(toast.label)\"")
    }

    /// ICP R3-VET-05: a new rule that measures what another rule measures asks "Keep both?" before it saves. Go back
    /// leaves the editor open with nothing saved.
    @MainActor func testANewRuleOnAMeasureAlreadyCheckedAsksKeepBoth() {
        let app = launch()
        tap(app, "protocol-rule-add")
        XCTAssertTrue(element(app, "rule-editor").waitForExistence(timeout: 10))
        expandSheet(app, title: "New rule")
        let name = element(app, "rule-editor-title")
        name.tap()
        name.typeText("More protein")
        let more = element(app, "rule-editor-more")
        XCTAssertTrue(reveal(app, more))
        more.tap()
        let food = element(app, "rule-editor-source-food")
        XCTAssertTrue(reveal(app, food))
        food.tap()
        app.buttons["rule-editor-save"].tap()
        let keepBoth = app.buttons["rule-editor-overlap-keep-both"].firstMatch
        let keep = keepBoth.waitForExistence(timeout: 5) ? keepBoth : app.buttons["Keep both"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Save asks first")
        XCTAssertTrue(app.staticTexts["You already have a protein rule. Keep both?"].firstMatch.exists)
        attach(app, "rule-editor-overlap")
        let byID = app.buttons["rule-editor-overlap-go-back"].firstMatch
        let goBack = byID.exists ? byID : app.buttons["Go back"].firstMatch
        XCTAssertTrue(goBack.waitForExistence(timeout: 5))
        goBack.tap()
        XCTAssertTrue(element(app, "rule-editor").exists, "Go back saves nothing")
        app.buttons["rule-editor-cancel"].tap()
        XCTAssertTrue(element(app, "rule-editor").waitForNonExistence(timeout: 10))
        XCTAssertFalse(element(app, "protocol-rule-more-protein").exists)
    }

    /// ICP round 1 (R1-DES-03, R1-NEW-03, R1-SEN-03): the start screen has no segments and marks the gentlest template.
    /// A template opens its preview, with who checks each rule and why; Cancel saves nothing, and "Use these 6 rules"
    /// makes version 1 and lands on Check-in under the "Your list is ready" card.
    @MainActor func testFirstRunPreviewsATemplateAndUsingItLandsOnTheReadyCard() {
        let app = launch(empty: true)
        XCTAssertTrue(element(app, "protocol-templates").waitForExistence(timeout: 15))
        for id in ["gentle-start", "sleep-first", "fitness-for-the-long-run", "everything-at-once", "start-empty"] {
            XCTAssertTrue(element(app, "protocol-template-\(id)").exists, id)
        }
        XCTAssertTrue(element(app, "protocol-template-start-here").exists, "one template is marked Start here")
        XCTAssertTrue(element(app, "protocol-template-gentle-start").label.hasPrefix("Start here. A gentle start."))
        XCTAssertFalse(element(app, "protocol-segments").exists, "no segment bar before there is a protocol")
        XCTAssertTrue(reveal(app, element(app, "protocol-templates-github")))
        attach(app, "protocol-templates")

        tap(app, "protocol-template-sleep-first")
        let preview = element(app, "protocol-template-preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "a template opens its preview")
        let inBed = element(app, "protocol-template-preview-rule-in-bed")
        XCTAssertTrue(inBed.waitForExistence(timeout: 5))
        XCTAssertTrue(inBed.label.contains("Your band checks this") && inBed.label.contains("7 to 9 hours"), "Read \"\(inBed.label)\"")
        XCTAssertTrue(element(app, "protocol-template-preview-rule-screens-off").label.contains("You tick this"))
        attach(app, "protocol-template-preview")
        app.buttons["protocol-template-preview-cancel"].tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertTrue(element(app, "protocol-templates").exists, "Cancel saves nothing")

        tap(app, "protocol-template-sleep-first")
        let use = app.buttons["protocol-template-preview-use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        XCTAssertEqual(use.label, "Use these 6 rules")
        use.tap()
        let ready = element(app, "protocol-ready")
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "the template lands on Check-in with the ready card")
        XCTAssertTrue(element(app, "protocol-segments").exists)
        XCTAssertTrue(element(app, "protocol-ready-body").label.contains("Each evening"))
        XCTAssertFalse(element(app, "protocol-templates").exists)
        attach(app, "protocol-template-installed")
        if element(app, "protocol-ready-offer").exists {
            XCTAssertTrue(element(app, "protocol-ready-offer").label.contains("each evening?"))
            tap(app, "protocol-ready-not-now")
            XCTAssertTrue(ready.waitForNonExistence(timeout: 10), "Not now closes the card")
        }

        tap(app, "protocol-segment-rules")
        XCTAssertTrue(element(app, "protocol-rules-header").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "protocol-rule-in-bed").waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    /// Pulls the editor sheet from half height to full height by its navigation bar.
    @MainActor private func expandSheet(_ app: XCUIApplication, title: String) {
        let bar = app.navigationBars[title].firstMatch
        guard bar.waitForExistence(timeout: 5) else { return }
        bar.swipeUp()
    }

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

    /// Scrolls until `target` is hittable, up to a few swipes.
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        guard target.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<8 {
            if target.isHittable { return true }
            drag(app, by: -260)
        }
        return target.isHittable
    }

    /// Scrolls `id` into the band between the sticky header and the tab bar, then taps it (see ProtocolTabUITests).
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

    /// A slow vertical drag along the left gutter, so it scrolls the page and never moves a picker.
    @MainActor private func drag(_ app: XCUIApplication, by distance: CGFloat) {
        guard abs(distance) > 1 else { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor private func expect(_ element: XCUIElement, contains text: String) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        let result = XCTWaiter.wait(for: [condition], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected \"\(text)\" in \"\(element.label)\"")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
