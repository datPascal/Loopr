import XCTest

final class JournalFiveTabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testRatingsCanBeClearedAndNotesWaitForSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        defer { attachDiagnostics(app, name: "journal-final") }
        XCTAssertTrue(app.tabBars.buttons["Protocol"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Protocol"].tap()
        // How you feel and the note sit behind "How was your day?" (ICP R1-DES-01).
        openEvening(app)
        let mood = app.buttons["journal-mood-4"]
        XCTAssertTrue(mood.waitForExistence(timeout: 10))
        expect(mood, "enabled == true AND selected == false")
        mood.tap()
        expect(mood, "selected == true")
        mood.tap()
        expect(mood, "selected == false")

        tapInEveningSheet(app, "journal-check-in-note")
        let note = app.textViews["journal-note-input"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        focus(note); note.typeText("Unsaved draft")
        tap(app, "journal-note-cancel")
        // The note editor opens from the tab once the evening sheet has closed, so the sheet opens again to read it.
        openEvening(app)
        XCTAssertTrue(app.buttons["journal-check-in-note"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["journal-check-in-note"].label.contains("Unsaved draft"))

        tapInEveningSheet(app, "journal-check-in-note")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        focus(note); note.typeText("A note saved for this day")
        let tags = app.textFields["journal-tags-input"].firstMatch
        focus(tags); tags.typeText("work, knee")
        tap(app, "journal-save")
        openEvening(app)
        XCTAssertTrue(app.buttons["journal-check-in-note"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["journal-check-in-note"].label.contains("A note saved for this day"))
        // One way to every note: the Note section's "All" action opens them (ICP R1-OPT-8).
        tapInEveningSheet(app, "protocol-notes")
        XCTAssertTrue(app.staticTexts["A note saved for this day"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor func testInsightPickerOffersFiveTargetsAndKeepsCalendarReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Protocol"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Protocol"].tap()
        openEvening(app)
        tapInEveningSheet(app, "journal-insights-open")
        for (metric, title) in [("recoveryScore", "Recovery"), ("hrvRMSSD", "HRV"), ("deepSleepMinutes", "Deep sleep"),
                                ("restingHeartRate", "Resting heart rate"), ("mood", "Mood")] {
            tap(app, "journal-insight-target-action")
            tap(app, "journal-target-" + metric)
            let picker = app.buttons["journal-insight-target-action"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            XCTAssertEqual(picker.label, title)
        }
        XCTAssertTrue(app.descendants(matching: .any)["journal-mood-calendar"].firstMatch.exists)
        attachDiagnostics(app, name: "journal-insights-mood")
    }

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

    /// Opens "How was your day?", the sheet that holds how you feel, the questions, the note and More.
    @MainActor private func openEvening(_ app: XCUIApplication) {
        tap(app, "protocol-evening-open")
        XCTAssertTrue(app.descendants(matching: .any)["protocol-evening-sheet"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        let target = app.buttons[id].firstMatch
        for index in 0..<12 {
            if target.exists && target.isHittable { target.tap(); return }
            app.swipeUp()
            if index == 3 { attachDiagnostics(app, name: id + "-scrolled") }
        }
        for _ in 0..<12 {
            if target.exists && target.isHittable { target.tap(); return }
            app.swipeDown()
        }
        attachDiagnostics(app, name: id + "-unreachable")
        XCTFail("Could not reach \(id)")
    }

    @MainActor private func attachDiagnostics(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print(app.debugDescription)
    }

    @MainActor private func expect(_ element: XCUIElement, _ predicate: String) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed, predicate)
    }

    /// A tap that lands while the note sheet still slides in leaves the field without the keyboard, so tap until it has it.
    private func focus(_ field: XCUIElement) {
        for _ in 0..<4 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
