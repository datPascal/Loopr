import XCTest

final class JournalVisualUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPopulatedCheckInThroughEditQuestions() {
        let app = launch(mode: "check-in")
        XCTAssertTrue(app.buttons["journal-mood-4"].isSelected)
        XCTAssertTrue(app.buttons["journal-energy-4"].isSelected)
        XCTAssertTrue(app.buttons["journal-stress-2"].isSelected)
        capture(app, "14-check-in", end: "journal-edit-questions",
            required: ["journal-source-00000000-0000-0000-0000-000000001401"])
        let edit = app.buttons["journal-edit-questions"]
        assertMinimumHeight(edit, in: app)
        edit.tap()
        XCTAssertTrue(element(app, "habit-management-screen").waitForExistence(timeout: 10))
    }

    @MainActor func testCalculatedInsightsThroughMoodCalendarAndAsk() {
        let app = launch(mode: "insights")
        let open = app.buttons["journal-insights-open"]
        for _ in 0..<24 where !(open.exists && open.isHittable) { app.swipeUp() }
        open.tap()
        let first = app.buttons["journal-insight-00000000-0000-0000-0000-000000001401"]
        // This waits for source history to finish the unchanged 2,000-replicate
        // estimator. A loading screenshot cannot satisfy visual acceptance.
        XCTAssertTrue(first.waitForExistence(timeout: 180))
        XCTAssertTrue(first.label.contains("days with"), first.label)
        XCTAssertFalse(first.label.contains("No eligible"), first.label)
        capture(app, "15-insights", end: "journal-insights-ask")
        XCTAssertTrue(element(app, "journal-mood-calendar").exists)
        app.buttons["journal-insights-ask"].tap()
        XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "ask-origin").label.contains("Journal insights"))
    }

    @MainActor func testLargestTextKeepsCheckInAndEditQuestionsReachable() {
        let app = launch(mode: "check-in", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let mood = app.buttons["journal-mood-4"]
        XCTAssertTrue(mood.isSelected)
        assertMinimumHeight(mood, in: app)
        let edit = app.buttons["journal-edit-questions"]
        for _ in 0..<24 {
            if edit.exists && edit.frame.maxY <= app.tabBars.firstMatch.frame.minY && edit.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(edit.isHittable)
        assertMinimumHeight(edit, in: app)
        edit.tap()
        XCTAssertTrue(element(app, "habit-management-screen").waitForExistence(timeout: 10))
    }

    @MainActor private func launch(mode: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-coach-fixture", "--loopr-journal-fixture=" + mode,
            "--loopr-appearance=system", "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Protocol"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Protocol"].tap()
        // How you feel, the questions and More sit in "How was your day?" (ICP R1-DES-01).
        let evening = app.buttons["protocol-evening-open"]
        for _ in 0..<12 where !(evening.exists && evening.isHittable) { app.swipeUp() }
        evening.tap()
        XCTAssertTrue(app.buttons["journal-mood-4"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true AND enabled == true"), object: app.buttons["journal-mood-4"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func assertMinimumHeight(_ element: XCUIElement, in app: XCUIApplication) {
        // AX frame subtraction can report 55.99999999999994 for 56 points.
        // Compare rendered pixels against the same 56-point requirement.
        let pixels = CGFloat(app.screenshot().image.cgImage!.width)
        let scale = pixels / app.frame.width
        XCTAssertGreaterThanOrEqual((element.frame.height * scale).rounded(), (56 * scale).rounded())
    }

    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, end endID: String, required: Set<String> = []) {
        let scroll = app.scrollViews["protocol-evening-scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let end = app.buttons[endID].firstMatch
        var observed = Set<String>()
        for index in 1...24 {
            let bottom = min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY)
            for identifier in required {
                let value = element(app, identifier)
                if value.exists, value.frame.height > 0, value.frame.minY >= scroll.frame.minY, value.frame.maxY <= bottom {
                    observed.insert(identifier)
                }
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "FiveTab Screen \(index == 1 ? slug : "\(slug)-\(index)")_candidate"
            attachment.lifetime = .keepAlways
            add(attachment)
            if end.exists, end.frame.height > 0, end.frame.minY >= scroll.frame.minY, end.frame.maxY <= bottom {
                XCTAssertEqual(observed, required, "Every required source label must appear in a captured viewport")
                let data = try! JSONSerialization.data(withJSONObject: ["screen": slug, "viewports": index,
                    "reachedEnd": true, "lastElement": endID], options: [.sortedKeys])
                let coverage = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                coverage.name = "FiveTab Coverage \(slug)"
                coverage.lifetime = .keepAlways
                add(coverage)
                return
            }
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.34)))
        }
        XCTFail("Did not reach the end of \(slug) after 24 overlapping viewports")
    }
}
