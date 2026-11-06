import XCTest

final class FiveTabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testOwnedScreens() {
        let app = launch(extra: ["--loopr-habit-insights-fixture"])
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Today", "Food", "Fitness", "Protocol", "Data"])
        XCTAssertTrue(element(app, "today-metric-recovery").waitForExistence(timeout: 15))
        capture(app, "01-today", root: "today-screen", end: "today-more")
        app.tabBars.buttons["Data"].tap()
        XCTAssertTrue(element(app, "day-navigator-previous").waitForExistence(timeout: 10))
        capture(app, "02-health", root: "health-screen", end: "health-explore-metrics")
        tap(app, "health-explore-sleep")
        XCTAssertTrue(element(app, "sleep-metric-duration").waitForExistence(timeout: 15))
        capture(app, "03-sleep", root: "sleep-screen", end: "sleep-wake-alarm-card")
        back(app, root: "health-screen")
        // HRV opens from Recovery's last night; Data's root no longer lists the pins (Data ICP R1).
        tap(app, "health-explore-heart")
        tap(app, "data-last-night-rmssd")
        // The production estimator performs 2,000 bootstrap replicates per
        // eligible metric. Wait for its result, never capture the empty state
        // shown while this DEBUG-only source history is being calculated.
        XCTAssertTrue(app.buttons["metric-habit-00000000-0000-0000-0000-000000003001"].waitForExistence(timeout: 180))
        capture(app, "04-metric-detail", root: "metric-detail-screen", end: "metric-detail-methodology-open")
        XCTAssertTrue(element(app, "metric-detail-pin").exists)
        back(app, root: "heart-screen")
        back(app, root: "health-screen")
        tap(app, "health-explore-metrics")
        capture(app, "05-all-metrics", root: "metric-library-screen", end: "metric-library-recording-note")
        back(app, root: "health-screen")
        app.tabBars.buttons["Today"].tap()
        tap(app, "open-settings")
        XCTAssertTrue(element(app, "your-data-total").waitForExistence(timeout: 20))
        capture(app, "18-your-data", root: "your-data-screen", end: "your-data-delete")
    }

    @MainActor func testEveryTabOpensTheSameContextualAskSheet() {
        let app = launch()
        for (title, root, ask, originName) in [
            ("Today", "today-screen", "today-header-coach", "Today"),
            ("Food", "food-screen", "food-header-ask", "Food"),
            ("Fitness", "workouts-screen", "train-header-ask", "Fitness"),
            ("Protocol", "journal-screen", "journal-header-ask", "Protocol"),
            ("Data", "health-screen", "health-header-ask", "Data")
        ] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
            for identifier in [ask, "open-settings"] {
                let control = element(app, identifier)
                XCTAssertGreaterThanOrEqual(control.frame.width, 56, identifier)
                XCTAssertGreaterThanOrEqual(control.frame.height, 56, identifier)
            }
            tap(app, ask)
            XCTAssertTrue(element(app, "ask-sheet").waitForExistence(timeout: 10))
            let origin = element(app, "ask-origin")
            XCTAssertTrue(origin.waitForExistence(timeout: 10))
            XCTAssertTrue(origin.label.contains(originName), origin.label)
            tap(app, "ask-close")
            XCTAssertTrue(element(app, "ask-sheet").waitForNonExistence(timeout: 10))
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
        }
    }

    @MainActor func testPinToggleAndMetricAskKeepTheSelectedMetric() {
        let app = launch()
        app.tabBars.buttons["Data"].tap()
        tap(app, "day-navigator-previous")
        XCTAssertTrue(element(app, "day-navigator-next").isEnabled)
        tap(app, "day-navigator-next")
        tap(app, "health-explore-metrics")
        let search = app.textFields["metric-library-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("HRV")
        XCTAssertTrue(element(app, "metric-library-rmssd").exists)
        XCTAssertFalse(element(app, "metric-library-recovery").exists)
        tap(app, "metric-library-search-clear")
        XCTAssertTrue(element(app, "metric-library-recovery").exists)
        let pin = element(app, "metric-library-rmssd-pin")
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        let before = pin.value as? String
        pin.tap()
        XCTAssertNotEqual(pin.value as? String, before)
        tap(app, "metric-library-rmssd")
        tap(app, "metric-detail-ask")
        let origin = element(app, "ask-origin")
        XCTAssertTrue(origin.waitForExistence(timeout: 10))
        XCTAssertTrue(origin.label.contains("HRV"), origin.label)
    }

    @MainActor func testAskFromYourDataKeepsItsOrigin() {
        let app = launch()
        tap(app, "open-settings")
        XCTAssertTrue(element(app, "your-data-screen").waitForExistence(timeout: 10))
        tap(app, "screen-ask")
        let origin = element(app, "ask-origin")
        XCTAssertTrue(origin.waitForExistence(timeout: 10))
        XCTAssertTrue(origin.label.contains("Your data"), origin.label)
        tap(app, "ask-close")
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
    }

    @MainActor func testYourDataExportsAndOpensExistingDestinations() {
        let app = launch()
        tap(app, "open-settings")
        XCTAssertTrue(element(app, "your-data-total").waitForExistence(timeout: 20))
        for provider in ["claude", "openai"] {
            tap(app, "your-data-" + provider)
            XCTAssertTrue(element(app, "settings-ai-provider-screen").waitForExistence(timeout: 10))
            back(app, root: "your-data-screen")
        }
        tap(app, "your-data-export")
        XCTAssertTrue(element(app, "your-data-share").waitForExistence(timeout: 30))
        tap(app, "your-data-delete")
        XCTAssertTrue(element(app, "data-deletion-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "data-delete-all").exists)
    }

    @MainActor func testLegacyLaunchRoutesKeepTheirDestinations() {
        for (route, root, tab) in [
            ("sleep/detail", "sleep-screen", "Data"),
            ("heart", "heart-screen", "Data"),
            ("body/detail", "body-screen", "Data"),
            ("workouts", "workouts-screen", "Fitness")
        ] {
            let app = launch(extra: ["--loopr-deep-link=\(route)"])
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 15), route)
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, route)
            if tab == "Data" {
                XCTAssertTrue(element(app, "loopr-navigation-header").exists, route)
            }
            if route == "sleep/detail" {
                XCTAssertTrue(element(app, "sleep-stage-timeline").waitForExistence(timeout: 10))
                tap(app, "sleep-scope-month")
                XCTAssertTrue(element(app, "sleep-trends-screen").waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    @MainActor func testLargestTextKeepsLibraryAndDataControlsReachable() {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.tabBars.buttons["Data"].tap()
        tap(app, "health-explore-metrics")
        tap(app, "metric-library-rmssd-pin")
        back(app, root: "health-screen")
        tap(app, "open-settings")
        tap(app, "agent-access-journalNotes")
        XCTAssertTrue(element(app, "your-data-screen").exists)
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-metric-history-fixture", "--loopr-coach-fixture", "--loopr-your-data-fixture", "--loopr-appearance=system",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_AU"] + extra
        app.launch()
        // Database creation/migrations are fixture setup. The Your data tests
        // still require the screen's real inventory to appear within 20 seconds.
        XCTAssertTrue(element(app, "five-tab-fixture-loading").waitForNonExistence(timeout: 180))
        XCTAssertFalse(element(app, "five-tab-fixture-error").exists)
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 30))
        return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    @MainActor private func tap(_ app: XCUIApplication, _ id: String) {
        // iOS 26 toolbar hosts repeat their child's identifier on an Other.
        // Query the actionable child so taps do not target the glass wrapper.
        let button = app.buttons[id].firstMatch
        let target = button.exists ? button : element(app, id)
        let root = id.hasPrefix("metric-detail-") ? "metric-detail-screen" : nil
        func visible() -> Bool {
            guard target.exists else { return false }
            guard root != nil else { return true }
            let frame = target.frame
            var bottom = app.frame.maxY
            if app.tabBars.firstMatch.exists { bottom = min(bottom, app.tabBars.firstMatch.frame.minY) }
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
            // XCTest can throw for isHittable when SwiftUI exposes a button
            // below the viewport without an activation point. Scroll first.
            return !frame.isEmpty && frame.minY >= app.frame.minY && frame.maxY <= bottom
        }
        func scroll(up: Bool) {
            if let root, app.scrollViews[root].exists {
                let view = app.scrollViews[root]
                view.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: up ? 0.78 : 0.34))
                    .press(forDuration: 0.05, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: up ? 0.34 : 0.78)))
            } else if up { app.swipeUp() }
            else { app.swipeDown() }
        }
        for _ in 0..<10 {
            if visible() && target.isHittable { target.tap(); return }
            scroll(up: !id.hasPrefix("health-tile-"))
        }
        for _ in 0..<10 {
            if visible() && target.isHittable { target.tap(); return }
            scroll(up: id.hasPrefix("health-tile-"))
        }
        XCTFail("Could not reach \(id)")
    }
    @MainActor private func back(_ app: XCUIApplication, root: String) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, root).waitForExistence(timeout: 10))
    }
    /// The scroll view that holds a screen's content. A screen's identifier usually lands on the scroll view or on a
    /// container around it. Since build 18 a screen with an ambient `.background` can also resolve to an element that
    /// holds no scroll view (metric detail does), so fall back to the scroll view that contains the screen's own elements:
    /// first the element the capture scrolls to, then any element sharing the screen's identifier prefix.
    @MainActor private func scrollView(of screen: XCUIElement, in app: XCUIApplication, root: String, end endID: String) -> XCUIElement {
        if screen.elementType == .scrollView { return screen }
        let inside = screen.scrollViews.firstMatch
        if inside.waitForExistence(timeout: 3) { return inside }
        let holdsEnd = app.scrollViews.containing(NSPredicate(format: "identifier == %@", endID)).firstMatch
        if holdsEnd.waitForExistence(timeout: 3) { return holdsEnd }
        let prefix = (root.hasSuffix("-screen") ? String(root.dropLast("screen".count)) : root)
        return app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor private func capture(_ app: XCUIApplication, _ slug: String, root: String, end endID: String) {
        XCTAssertTrue(element(app, root).waitForExistence(timeout: 15))
        let screen = element(app, root)
        let end = element(app, endID)
        let scroll = scrollView(of: screen, in: app, root: root, end: endID)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10), "No scroll view holds \(root)")
        for index in 1...24 {
            captureViewport(app, index == 1 ? slug : "\(slug)-\(index)")
            let bottom = min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY)
            if end.exists, end.frame.height > 0, end.frame.minY >= scroll.frame.minY,
               end.frame.maxY <= bottom {
                let data = try! JSONSerialization.data(withJSONObject: ["screen": slug, "viewports": index, "reachedEnd": true, "lastElement": endID], options: [.sortedKeys])
                let coverage = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                coverage.name = "FiveTab Coverage \(slug)"
                coverage.lifetime = .keepAlways
                add(coverage)
                return
            }
            // Use the screen gutter so chart drag gestures cannot consume a
            // vertical capture scroll.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.34)))
        }
        XCTFail("Did not reach the end of \(slug) after 24 overlapping viewports")
    }

    @MainActor private func captureViewport(_ app: XCUIApplication, _ slug: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "FiveTab Screen \(slug)_candidate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
