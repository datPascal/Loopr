import Foundation
import XCTest

/// Screenshots of the NOOP parity surfaces for design review. Each test
/// launches the populated fixture with the DEBUG arguments it needs and
/// attaches keep-always screenshots named `<appearance>-<surface>`.
///
/// Appearance comes from LOOPR_CAPTURE_APPEARANCE (pass it to xcodebuild as
/// TEST_RUNNER_LOOPR_CAPTURE_APPEARANCE) and should match the simulator's
/// `simctl ui appearance`.
final class NoopParityCaptureUITests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light"
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Tabs

    @MainActor
    func testMainTabTops() {
        let app = launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 20))
        for (tab, root) in [("Today", "today-screen"), ("Sleep", "sleep-screen"), ("Heart", "heart-screen"),
                            ("Body", "body-screen"), ("Workouts", "workouts-screen")] {
            guard selectTab(app, tab, root: root) else { continue }
            settle(app, root)
            capture("tab-\(tab.lowercased())")
        }
    }

    // MARK: Heart timeline

    @MainActor
    func testHeartDayTimeline() {
        let app = launch()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 20))
        guard selectTab(app, "Heart", root: "heart-screen") else { return }
        settle(app, "heart-screen")
        let timeline = element(app, "heart-day-timeline")
        guard timeline.waitForExistence(timeout: 10) else {
            dumpHierarchy(app, "heart-timeline-missing")
            XCTFail("heart-day-timeline missing")
            return
        }
        revealFully(app, timeline)
        capture("heart-timeline-default")

        let zoomIn = timeline.buttons["Zoom in"].firstMatch
        if zoomIn.waitForExistence(timeout: 5) {
            XCTAssertTrue(tap(zoomIn, until: timeline.staticTexts["12 h"].firstMatch))
            capture("heart-timeline-zoom-12h")
            XCTAssertTrue(tap(zoomIn, until: timeline.staticTexts["6 h"].firstMatch))
            XCTAssertTrue(tap(zoomIn, until: timeline.staticTexts["3 h"].firstMatch))
            capture("heart-timeline-zoom-3h")
            let range = element(app, "heart-timeline-range")
            XCTAssertEqual(range.label, "3 h")
            let plot = element(app, "heart-timeline-plot")
            let beforePan = plot.value as? String
            let window = app.windows.firstMatch
            let visiblePlot = plot.frame.intersection(window.frame)
            XCTAssertFalse(visiblePlot.isEmpty, "The chart must be on screen")
            func chartPoint(_ fraction: CGFloat) -> XCUICoordinate {
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: visiblePlot.minX + visiblePlot.width * fraction,
                    dy: visiblePlot.minY + visiblePlot.height * 0.4))
            }
            // A short drag pans; only a held finger selects a reading.
            chartPoint(0.75).press(forDuration: 0.02, thenDragTo: chartPoint(0.15),
                                   withVelocity: .fast, thenHoldForDuration: 0)
            pause(1.2)
            if plot.value as? String == beforePan { dumpHierarchy(app, "heart-pan-not-moving") }
            XCTAssertNotEqual(plot.value as? String, beforePan, "A horizontal drag must move the viewport")
            func startMinute(_ value: String?) -> Int? {
                guard let time = value?.components(separatedBy: " to ").first else { return nil }
                let parts = time.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                return parts[0] * 60 + parts[1]
            }
            if let before = startMinute(beforePan), let after = startMinute(plot.value as? String) {
                XCTAssertGreaterThanOrEqual(after - before, 60, "A wide drag through a three-hour window must advance at least an hour")
            } else {
                XCTFail("Visible chart times missing")
            }
            XCTAssertEqual(range.label, "3 h", "Panning must keep the zoom")
            let afterPan = plot.value as? String
            capture("heart-timeline-zoom-3h-panned")
            // Hold to read a time while zoomed.
            chartPoint(0.5).press(forDuration: 1.2)
            XCTAssertTrue(element(app, "heart-timeline-readout").exists, "Holding must show a time readout")
            XCTAssertEqual(plot.value as? String, afterPan, "Reading must keep the panned viewport")
            XCTAssertEqual(range.label, "3 h", "Selection must keep the zoom")
            capture("heart-timeline-zoom-after-hold")
        } else {
            XCTFail("Zoom in control missing")
        }
    }

    // MARK: Stress

    @MainActor
    func testStressScoredWithTodayHint() {
        let app = launch(["--loopr-hourly-stress-fixture=scored"])
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 20))
        settle(app, "today-screen")
        let hint = element(app, "today-hourly-stress-hint")
        if hint.waitForExistence(timeout: 5) {
            revealFully(app, hint)
            capture("today-stress-hint")
            hint.tap()
        } else {
            dumpHierarchy(app, "today-hint-missing")
            XCTFail("today-hourly-stress-hint missing")
            let stress = element(app, "today-metric-stress")
            guard stress.waitForExistence(timeout: 5) else { return }
            revealFully(app, stress)
            stress.tap()
        }
        guard element(app, "stress-screen").waitForExistence(timeout: 10) else {
            dumpHierarchy(app, "stress-screen-missing")
            XCTFail("stress-screen missing")
            return
        }
        settle(app, "stress-screen")
        capture("stress-top")
        let card = element(app, "hourly-stress-timeline")
        guard card.waitForExistence(timeout: 10) else {
            dumpHierarchy(app, "hourly-card-missing")
            XCTFail("hourly-stress-timeline missing")
            return
        }
        revealFully(app, card)
        capture("stress-hourly-chart")
        // Hold a bar to show the selected hour readout.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.35)).press(forDuration: 1.0)
        XCTAssertTrue(element(app, "hourly-stress-readout").exists)
        capture("stress-hourly-selected")
        // The card's own identifier hides the button's, so find it by its title.
        let breathing = app.staticTexts["Take a breathing break"].firstMatch
        if breathing.waitForExistence(timeout: 3) {
            revealFully(app, breathing)
            capture("stress-breathing-suggestion")
            if tap(breathing, until: element(app, "stress-breathing-screen")) {
                settle(app, "stress-breathing-screen")
                capture("breathing-from-suggestion-band-disconnected")
            } else {
                XCTFail("Breathing suggestion did not open breathing")
            }
        } else {
            XCTFail("hourly-stress-breathing suggestion missing")
        }
    }

    @MainActor
    func testStressLearningBaseline() {
        let app = launch(["--loopr-hourly-stress-fixture=learning", "--loopr-deep-link=today/stress"])
        captureCard(app, root: "stress-screen", card: "hourly-stress-timeline", name: "stress-hourly-learning")
    }

    @MainActor
    func testStressNoHourlyData() {
        let app = launch(["--loopr-deep-link=today/stress"])
        captureCard(app, root: "stress-screen", card: "hourly-stress-timeline", name: "stress-hourly-no-data")
    }

    // MARK: Breathing

    @MainActor
    func testBreathingPaceWithBand() {
        let app = launch(["--loopr-band-connected-fixture", "--loopr-deep-link=today/breathing"])
        let root = element(app, "stress-breathing-screen")
        guard root.waitForExistence(timeout: 20) else {
            dumpHierarchy(app, "breathing-missing")
            XCTFail("stress-breathing-screen missing")
            return
        }
        settle(app, "stress-breathing-screen")
        capture("breathing-ready-band-on")
        let toggle = element(app, "stress-band-pacing")
        if toggle.waitForExistence(timeout: 3) {
            revealFully(app, toggle)
            capture("breathing-band-toggle")
        }
        let start = element(app, "stress-breathing-start")
        guard start.waitForExistence(timeout: 5) else { XCTFail("start missing"); return }
        revealFully(app, start)
        let finish = element(app, "stress-breathing-finish")
        guard tap(start, until: finish) else {
            dumpHierarchy(app, "breathing-not-running")
            XCTFail("Breathing did not start")
            return
        }
        pause(4)
        scrollToTop(app)
        capture("breathing-running")
        pause(6)
        revealFully(app, finish)
        finish.tap()
        pause(2)
        if element(app, "stress-breathing-screen").exists {
            scrollToTop(app)
            capture("breathing-finished-top")
            let result = app.staticTexts["Session result"].firstMatch
            if result.waitForExistence(timeout: 3) {
                revealFully(app, result)
                app.swipeUp(); pause(0.8)
                capture("breathing-result")
            } else {
                capture("breathing-after-finish-no-result")
            }
        } else {
            capture("breathing-after-finish-left-screen")
        }
    }

    // MARK: Workouts

    @MainActor
    func testIntervalTimer() {
        let app = launch(["--loopr-deep-link=workouts/intervals", "--loopr-interval-live-fixture"])
        let root = element(app, "interval-timer-screen")
        guard root.waitForExistence(timeout: 20) else {
            dumpHierarchy(app, "interval-missing")
            XCTFail("interval-timer-screen missing")
            return
        }
        settle(app, "interval-timer-screen")
        capture("interval-setup")
        let tabata = app.buttons["Tabata 20/10 × 8"].firstMatch
        if tabata.waitForExistence(timeout: 3), tabata.isHittable {
            tabata.tap(); pause(0.6)
            capture("interval-setup-tabata")
        }
        let start = element(app, "interval-start")
        guard start.waitForExistence(timeout: 5) else { XCTFail("interval-start missing"); return }
        revealFully(app, start)
        capture("interval-setup-bottom")
        guard tap(start, until: element(app, "interval-stop")) else {
            dumpHierarchy(app, "interval-not-running")
            XCTFail("Interval timer did not start")
            return
        }
        pause(3)
        scrollToTop(app)
        XCTAssertTrue(element(app, "interval-heart-rate").waitForExistence(timeout: 5))
        capture("interval-running")
        let restPhase = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rest"),
                                                  object: element(app, "interval-phase"))
        XCTAssertEqual(XCTWaiter.wait(for: [restPhase], timeout: 25), .completed)
        pause(0.5)
        capture("interval-running-rest")
        let stop = element(app, "interval-stop")
        revealFully(app, stop)
        capture("interval-running-bottom")
        stop.tap(); pause(1)
        capture("interval-stopped")
    }

    @MainActor
    func testWorkoutDetailGPXShare() {
        let app = launch(["--loopr-gpx-route-fixture", "--loopr-deep-link=workouts/detail"])
        let share = element(app, "workout-share-gpx")
        guard element(app, "workout-detail-metric-face").waitForExistence(timeout: 20) else {
            dumpHierarchy(app, "workout-detail-missing")
            XCTFail("workout detail missing")
            return
        }
        pause(1.5)
        capture("workout-detail-gpx-button")
        guard share.waitForExistence(timeout: 5) else {
            dumpHierarchy(app, "gpx-share-missing")
            XCTFail("workout-share-gpx missing")
            return
        }
        revealFully(app, share)
        share.tap()
        pause(3)
        capture("workout-gpx-share-sheet")
    }

    // MARK: Device Center

    @MainActor
    func testDeviceCenterCharging() {
        captureDeviceCenter(state: "charging,sharing", name: "charging")
    }

    @MainActor
    func testDeviceCenterOffWrist() {
        captureDeviceCenter(state: "off-wrist", name: "off-wrist")
    }

    @MainActor
    func testBandIndicatorCharging() {
        let app = launch(["--loopr-band-state-fixture=charging"])
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 20))
        settle(app, "today-screen")
        capture("band-indicator-charging-today")
        let button = app.buttons["open-settings"].firstMatch
        if button.exists {
            let shot = button.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(appearance)-band-indicator-charging-closeup"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func captureDeviceCenter(state: String, name: String) {
        let app = launch(["--loopr-band-state-fixture=\(state)", "--loopr-deep-link=settings/device-center"])
        let root = element(app, "device-center-screen")
        guard root.waitForExistence(timeout: 20) || element(app, "settings-modal").exists else {
            dumpHierarchy(app, "device-center-missing-\(name)")
            XCTFail("device center missing")
            return
        }
        pause(2)
        capture("device-center-\(name)-top")
        let toggle = element(app, "device-share-heart-rate")
        if toggle.waitForExistence(timeout: 5) {
            revealFully(app, toggle)
            capture("device-center-\(name)-share-heart-rate")
        } else {
            dumpHierarchy(app, "share-toggle-missing-\(name)")
            XCTFail("device-share-heart-rate missing")
        }
    }

    // MARK: Data import

    @MainActor
    func testImportWHOOPEntry() {
        captureImport(extra: [], name: "import-whoop-entry")
    }

    @MainActor
    func testImportWHOOPResult() {
        captureImport(extra: ["--loopr-whoop-import-result-fixture"], name: "import-whoop-result")
    }

    @MainActor
    private func captureImport(extra: [String], name: String) {
        let app = launch(extra + ["--loopr-deep-link=settings/import-export"])
        let entry = element(app, "data-importPreview")
        guard entry.waitForExistence(timeout: 20) else {
            dumpHierarchy(app, "import-entry-missing")
            XCTFail("data-importPreview missing")
            return
        }
        pause(1)
        if extra.isEmpty { capture("import-export-menu") }
        revealFully(app, entry)
        guard tap(entry, until: element(app, "data-import-preview-screen")) else {
            dumpHierarchy(app, "import-screen-missing")
            XCTFail("data-import-preview-screen missing")
            return
        }
        pause(1.5)
        capture("\(name)-top")
        let target = element(app, extra.isEmpty ? "data-import-account-choose" : "data-import-account-result")
        if target.waitForExistence(timeout: 5) {
            revealFully(app, target)
            capture(name)
        } else {
            dumpHierarchy(app, "\(name)-missing")
            XCTFail("\(name) element missing")
        }
    }

    @MainActor
    func testZoneTwoStartSheet() {
        let app = launch(["--loopr-zone-fixture=start", "--loopr-deep-link=workouts/zone2"])
        XCTAssertTrue(element(app, "workout-start-zone-two").waitForExistence(timeout: 20))
        pause(1)
        capture("zone2-start-sheet")
    }

    @MainActor
    func testZoneTwoSettings() {
        let app = launch(["--loopr-zone-fixture=settings", "--loopr-deep-link=workouts/zone2"])
        XCTAssertTrue(element(app, "workout-live-screen").waitForExistence(timeout: 20))
        let settings = element(app, "workout-alert-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        let footnote = app.staticTexts["Buzzes twice after 30 s above your zone, then every 90 s, up to 3 times."].firstMatch
        XCTAssertTrue(footnote.waitForExistence(timeout: 5))
        XCTAssertTrue(footnote.isHittable)
        capture("zone2-alert-settings")
    }

    @MainActor
    func testZoneTwoLiveStatuses() {
        for status in ["warm-up", "in-zone", "above", "below"] {
            let app = launch(["--loopr-zone-fixture=\(status)", "--loopr-deep-link=workouts/zone2"])
            let target = element(app, "workout-target-status")
            XCTAssertTrue(target.waitForExistence(timeout: 20))
            let expected = status == "warm-up" ? "Warm-up" : status == "above" ? "Above" : status == "below" ? "Below" : "In zone"
            let statusReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", expected, status == "above" ? "156 bpm" : status == "below" ? "122 bpm" : "138 bpm"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [statusReady], timeout: 10), .completed, target.debugDescription)
            let zoneTwo = element(app, "workout-zone-row-2")
            XCTAssertTrue(zoneTwo.waitForExistence(timeout: 5))
            XCTAssertTrue(zoneTwo.label.contains("Target"), zoneTwo.debugDescription)
            if status == "above" { XCTAssertTrue(target.label.contains("Above by 12 bpm")) }
            if status == "below" { XCTAssertTrue(target.label.contains("Below by 9 bpm")) }
            capture("zone2-live-\(status)")
            app.terminate()
        }
    }

    @MainActor
    func testZoneTwoSummary() {
        let app = launch(["--loopr-zone-fixture=summary", "--loopr-deep-link=workouts/zone2"])
        XCTAssertTrue(element(app, "workout-target-summary").waitForExistence(timeout: 20))
        let targetTime = element(app, "workout-target-time")
        guard targetTime.waitForExistence(timeout: 5) else {
            dumpHierarchy(app, "zone2-target-time-missing")
            XCTFail("Target time is missing from the summary")
            return
        }
        XCTAssertTrue(targetTime.label.contains("41 of 50 min"))
        XCTAssertTrue(targetTime.label.contains("82%"))
        pause(1)
        capture("zone2-summary-strip")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func captureCard(_ app: XCUIApplication, root: String, card: String, name: String) {
        guard element(app, root).waitForExistence(timeout: 20) else {
            dumpHierarchy(app, "\(name)-root-missing")
            XCTFail("\(root) missing")
            return
        }
        settle(app, root)
        capture("\(name)-top")
        let target = element(app, card)
        if target.waitForExistence(timeout: 10) {
            revealFully(app, target)
            capture(name)
        } else {
            dumpHierarchy(app, "\(name)-missing")
            XCTFail("\(card) missing")
        }
    }

    /// Wait for a settled hit target, then tap once so a missed action fails.
    @MainActor
    private func tap(_ target: XCUIElement, until next: XCUIElement) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
        guard XCTWaiter.wait(for: [hittable], timeout: 5) == .completed else { return false }
        target.tap()
        return next.waitForExistence(timeout: 10)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ tab: String, root: String) -> Bool {
        let button = app.tabBars.firstMatch.buttons[tab].firstMatch
        if button.waitForExistence(timeout: 10), tap(button, until: element(app, root)) { return true }
        dumpHierarchy(app, "tab-\(tab)-failed")
        XCTFail("Could not open \(tab)")
        return false
    }

    @MainActor
    private func settle(_ app: XCUIApplication, _ root: String) {
        let deadline = Date(timeIntervalSinceNow: 8)
        let screen = element(app, root)
        while Date() < deadline, !screen.activityIndicators.allElementsBoundByIndex.isEmpty { pause(0.25) }
        pause(1)
    }

    /// Scrolls until the whole element sits between the nav bar and the tab bar.
    @MainActor
    private func revealFully(_ app: XCUIApplication, _ target: XCUIElement) {
        let window = app.windows.firstMatch.frame
        let bottomLimit = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.maxY - 34
        for _ in 0..<10 {
            let frame = target.frame
            if frame.minY >= 100, frame.maxY <= bottomLimit - 8 { break }
            if frame.maxY > bottomLimit - 8 {
                let distance = min(frame.maxY - bottomLimit + 60, window.height * 0.5)
                drag(app, by: -distance)
            } else {
                drag(app, by: min(160 - frame.minY, window.height * 0.5))
            }
        }
        pause(0.8)
    }

    @MainActor
    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<3 { app.swipeDown() }
        pause(2)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func dumpHierarchy(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "\(appearance)-hierarchy-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
