import XCTest

/// Runs the shipped views with synthetic histories. The lease sets appearance
/// and optionally LOOPR_CAPTURE_LARGE_TEXT through TEST_RUNNER environment.
final class SIPolishCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    private var large: Bool { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_LARGE_TEXT"] == "1" }
    private var sizeSuffix: String { large ? "-largest-text" : "" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testTodayStates() {
        for state in ["good", "first-night", "empty", "flagged"] {
            let app = launch(link: "today", arguments: ["--loopr-si-polish-fixture=\(state)"])
            XCTAssertTrue(element(app, "today-metric-recovery").waitForExistence(timeout: 20))
            capture("today-\(state)-briefing")
            if large, state == "good" || state == "flagged" {
                reveal(app, app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep strain between")).firstMatch)
                capture("today-\(state)-plan")
            }
            if state == "empty" {
                reveal(app, element(app, "today-signals-empty"))
                capture("today-empty-signals")
            } else {
                for id in large ? ["rmssd", "resting_heart_rate", "skin_temperature_deviation"] : ["rmssd", "skin_temperature_deviation"] {
                    let row = element(app, "today-contributor-\(id)")
                    reveal(app, row)
                    XCTAssertLessThanOrEqual(row.frame.width, app.windows.firstMatch.frame.width)
                    capture("today-\(state)-\(id)")
                }
            }
            for id in large ? ["sleep", "strain", "stress"] : ["stress"] {
                reveal(app, element(app, "today-metric-\(id)"))
                capture("today-\(state)-\(id)-rings")
            }
            app.terminate()
        }
    }

    @MainActor func testOvernightCheckSelectsHeartClearsDetailsAndKeepsDay() {
        let app = launch(link: "heart", arguments: ["--loopr-si-polish-fixture=flagged"])
        let hrv = element(app, "heart-vital-rmssd")
        reveal(app, hrv)
        hrv.tap()
        XCTAssertTrue(element(app, "metric-detail-screen").waitForExistence(timeout: 10))
        app.tabBars.buttons["Today"].tap()
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let navigator = element(app, "day-navigator")
        let day = navigator.value as? String
        let check = element(app, "today-heads-up")
        reveal(app, check)
        capture("overnight-check-link")
        check.tap()
        XCTAssertTrue(element(app, "heart-screen").waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Heart"].isSelected)
        XCTAssertFalse(element(app, "metric-detail-screen").exists)
        XCTAssertEqual(element(app, "day-navigator").value as? String, day)
        reveal(app, element(app, "heart-vital-skin_temperature_deviation"))
        capture("overnight-check-destination")
    }

    @MainActor func testHeartStates() {
        for state in ["good", "first-night", "empty", "flagged"] {
            let app = launch(link: "heart", arguments: ["--loopr-si-polish-fixture=\(state)"])
            waitForLayout(element(app, "heart-vital-rmssd"))
            capture("heart-\(state)-top")
            for id in large ? ["rmssd", "resting_heart_rate", "skin_temperature_deviation"] : ["rmssd", "skin_temperature_deviation"] {
                reveal(app, element(app, "heart-vital-\(id)"))
                capture("heart-\(state)-\(id)")
            }
            app.terminate()
        }
    }

    @MainActor func testTemperatureStates() {
        for state in ["normal", "calibrating", "empty", "outside"] {
            let app = launch(link: "heart", arguments: ["--loopr-si-vitals-fixture=\(state)",
                "--loopr-metric-history-fixture", "--loopr-metric-range=month"])
            let temperature = element(app, "heart-vital-skin_temperature_deviation")
            reveal(app, temperature)
            temperature.tap()
            let value = element(app, state == "empty" || state == "calibrating" ? "metric-detail-empty" : "metric-detail-value")
            XCTAssertTrue(value.waitForExistence(timeout: 20))
            reveal(app, value)
            capture("temperature-\(state)-top")
            if state == "normal" || state == "outside" {
                reveal(app, element(app, "metric-detail-trend"))
                capture("temperature-\(state)-chart")
                    if large {
                        reveal(app, element(app, "loopr-metric-trend-chart"))
                        capture("temperature-\(state)-plot")
                    }
            } else {
                reveal(app, value)
                capture("temperature-\(state)-reason")
            }
            app.terminate()
        }
    }

    @MainActor func testHeartRateDipStates() {
        for state in ["ready", "learning", "empty", "flagged"] {
            let app = launch(link: "heart/detail", arguments: ["--loopr-si-surfaces-state=\(state)"])
            let row = element(app, "heart-metric-heartRateDip")
            reveal(app, row)
            row.tap()
            let value = element(app, state == "empty" ? "metric-detail-empty" : "metric-detail-value")
            XCTAssertTrue(value.waitForExistence(timeout: 20))
            reveal(app, value)
            capture("hr-dip-\(state)-top")
            if state != "empty" {
                reveal(app, element(app, "metric-detail-trend"))
                capture("hr-dip-\(state)-chart")
                    if large {
                        reveal(app, element(app, "loopr-metric-trend-chart"))
                        capture("hr-dip-\(state)-plot")
                    }
            } else {
                reveal(app, value)
                capture("hr-dip-empty-reason")
            }
            app.terminate()
        }
    }

    @MainActor func testBodyStates() {
        for state in ["ready", "learning", "empty", "flagged"] {
            let app = launch(link: "body", arguments: ["--loopr-si-body-fixture=\(state)"])
            XCTAssertTrue(element(app, "body-screen").waitForExistence(timeout: 20))
            capture("body-\(state)-target")
            for id in ["body-strain-week", "body-training-load"] {
                reveal(app, element(app, id))
                capture("\(id)-\(state)")
                if large, id == "body-strain-week", state == "ready" || state == "flagged" {
                    revealBottom(app, element(app, "body-strain-week-chart"))
                    capture("body-strain-week-\(state)-plot")
                }
            }
            element(app, "body-training-load").tap()
            XCTAssertTrue(element(app, "body-load-screen").waitForExistence(timeout: 10))
            capture("body-load-\(state)-detail")
            if state == "ready" || state == "flagged" {
                reveal(app, element(app, "body-load-trend"))
                capture("body-load-\(state)-trend")
            }
            app.terminate()
        }
    }

    @MainActor func testStrainTargetDetail() {
        for state in ["ready", "flagged"] {
            let app = launch(link: "today", arguments: ["--loopr-si-body-fixture=\(state)",
                "--loopr-metric-history-fixture", "--loopr-open-metric=strain"])
            let target = element(app, "metric-detail-strain-target")
            XCTAssertTrue(target.waitForExistence(timeout: 20))
            reveal(app, target)
            capture("strain-target-\(state)-detail")
            let chart = element(app, "metric-detail-trend")
            reveal(app, chart)
            capture("strain-target-\(state)-chart")
            app.terminate()
        }
    }

    @MainActor func testWorkoutRecoveryStates() {
        for state in ["ready", "learning", "empty"] {
            let app = launch(link: "workouts/detail", arguments: ["--loopr-si-body-fixture=\(state)"])
            reveal(app, element(app, "workout-heart-rate-recovery"))
            capture("workout-recovery-\(state)")
            app.terminate()
        }
    }

    @MainActor func testWidgetAndWatchStates() {
        for state in ["good", "flagged", "learning", "empty", "stale", "flagged-unscored"] {
            let app = launch(link: "today", arguments: ["--loopr-si-polish-fixture=\(state)",
                "--loopr-open-design-system", "--loopr-si-polish-glances"])
            XCTAssertTrue(element(app, "si-polish-glances").waitForExistence(timeout: 20))
            capture("widgets-\(state)")
            reveal(app, element(app, "si-polish-accessories"))
            capture("accessories-\(state)")
            reveal(app, element(app, "si-polish-watch"))
            capture("watch-\(state)")
            if large {
                reveal(app, element(app, "watch-summary-band"))
                capture("watch-\(state)-lower")
            }
            reveal(app, element(app, "si-polish-watch-complication"))
            capture("watch-complication-\(state)")
            app.terminate()
        }
    }

    @MainActor func testAdvancedHeartAndStress() {
        let app = launch(link: "heart", arguments: ["--loopr-si-heartnav-fixture=normal", "--loopr-metric-history-fixture"])
        reveal(app, app.buttons["Zoom in"])
        capture("heart-rate-day-controls")
        reveal(app, element(app, "heart-timeline-plot"))
        capture("heart-rate-through-day")
        let advanced = element(app, "heart-advanced-disclosure")
        reveal(app, advanced)
        advanced.tap()
        for id in ["heart-metric-sdnn", "heart-beat-poincare", "heart-beat-tachogram"] {
            reveal(app, element(app, id))
            capture(id)
            if large, id != "heart-metric-sdnn" {
                revealBottom(app, element(app, id))
                capture("\(id)-plot")
            }
        }
        let stress = element(app, "heart-stress-route")
        reveal(app, stress)
        capture("stress-entry-on-heart")
        stress.tap()
        XCTAssertTrue(element(app, "stress-screen").waitForExistence(timeout: 20))
        reveal(app, element(app, "stress-metric-face"))
        capture("stress-from-heart")
        reveal(app, element(app, "hourly-stress-timeline"))
        capture("stress-through-day")
        app.terminate()

        let empty = launch(link: "heart/detail", arguments: ["--loopr-si-heartnav-fixture=empty"])
        reveal(empty, element(empty, "heart-advanced-section"))
        capture("advanced-empty-readings")
        reveal(empty, element(empty, "heart-beat-to-beat-section"))
        capture("advanced-empty-beats")
    }

    @MainActor func testAdditionalHeartMetricPages() {
        for (metric, rowID) in [("sleeping_heart_rate", "sleepingHeartRate"), ("max_heart_rate", "maxHeartRate")] {
            for state in ["ready", "learning", "empty", "flagged"] {
                let app = launch(link: "heart/detail", arguments: ["--loopr-si-surfaces-state=\(state)"])
                let row = element(app, "heart-metric-\(rowID)")
                reveal(app, row)
                row.tap()
                let value = element(app, state == "empty" ? "metric-detail-empty" : "metric-detail-value")
                reveal(app, value)
                capture("\(metric)-\(state)-top")
                if state != "empty" {
                    reveal(app, element(app, "metric-detail-trend"))
                    capture("\(metric)-\(state)-chart")
                    if large {
                        reveal(app, element(app, "loopr-metric-trend-chart"))
                        capture("\(metric)-\(state)-plot")
                    }
                }
                app.terminate()
            }
        }
    }

    @MainActor func testBeatCloudLayout() {
        let app = launch(link: "heart/detail", arguments: ["--loopr-si-heartnav-fixture=normal"])
        let mean = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Average beat interval,")).firstMatch
        reveal(app, mean)
        XCTAssertTrue(mean.label.contains("21,837 clean beats"))
        capture("heart-beat-mean")
        let plot = element(app, "heart-beat-poincare")
        reveal(app, plot)
        capture("heart-beat-poincare")
        if large {
            revealBottom(app, plot)
            capture("heart-beat-poincare-plot")
        }
        app.terminate()
    }

    @MainActor func testRecoveryExplanationAndStressLearning() {
        let app = launch(link: "today", arguments: ["--loopr-si-polish-fixture=good"])
        let recovery = element(app, "today-metric-recovery")
        reveal(app, recovery)
        recovery.tap()
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: 20))
        capture("recovery-weights")
        reveal(app, element(app, "today-breakdown-restingHeartRate"))
        capture("recovery-rhr-not-scored")
        reveal(app, app.staticTexts["How it's calculated"].firstMatch)
        capture("recovery-explanation")
        app.terminate()

        let learning = launch(link: "today/stress", arguments: ["--loopr-si-polish-fixture=good",
            "--loopr-hourly-stress-fixture=learning"])
        reveal(learning, element(learning, "hourly-stress-timeline"))
        capture("stress-learning")
    }

    @MainActor func testDataHistoryRecordCount() {
        let app = launch(link: "settings", arguments: ["--loopr-si-polish-fixture=good", "--loopr-metric-history-fixture"])
        let route = element(app, "settings-data-history")
        XCTAssertTrue(route.waitForExistence(timeout: 20))
        reveal(app, route)
        route.tap()
        let history = element(app, "data-history")
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        reveal(app, history)
        history.tap()
        XCTAssertTrue(element(app, "data-history-screen").waitForExistence(timeout: 20))
        let countUnit = app.staticTexts["record"]
        XCTAssertTrue(countUnit.waitForExistence(timeout: 20))
        reveal(app, countUnit)
        XCTAssertLessThanOrEqual(countUnit.frame.width, app.windows.firstMatch.frame.width)
        capture("data-history-record-count")
    }

    @MainActor func testAppStoreNativeFrames() {
        let fixture = storeFixtureArguments
        for (tab, root, name) in [("Today", "today-screen", "today"),
                                  ("Heart", "heart-vitals-section", "heart"),
                                  ("Body", "body-screen", "body"),
                                  ("Workouts", "workouts-screen", "workouts")] {
            let app = launch(link: tab == "Heart" ? "heart" : tab == "Body" ? "body" : "today", arguments: fixture)
            if tab == "Workouts" { app.tabBars.buttons[tab].tap() }
            XCTAssertTrue(element(app, root).waitForExistence(timeout: 20))
            if tab == "Today" { waitForLayout(element(app, "today-metric-recovery")) }
            if tab == "Body" { waitForLayout(element(app, "body-strain-lens")) }
            if tab == "Workouts" {
                waitForLayout(app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout-row-")).firstMatch)
            }
            if tab == "Heart" {
                waitForLayout(element(app, "heart-live-card"))
                waitForLiveReading(element(app, "heart-live-card"))
                waitForLayout(element(app, "heart-vital-rmssd"))
                reveal(app, element(app, root))
            }
            capture("appstore-\(name)")
            app.terminate()
        }
        let sleep = launch(link: "sleep", arguments: fixture)
        let stages = element(sleep, "sleep-hypnogram-route")
        reveal(sleep, stages)
        stages.tap()
        XCTAssertTrue(element(sleep, "sleep-hypnogram-screen").waitForExistence(timeout: 20))
        capture("appstore-sleep-stages")
        sleep.terminate()

        let temperature = launch(link: "heart", arguments: fixture)
        let row = element(temperature, "heart-vital-skin_temperature_deviation")
        reveal(temperature, row)
        row.tap()
        let value = element(temperature, "metric-detail-value")
        XCTAssertTrue(value.waitForExistence(timeout: 20))
        capture("appstore-skin-temperature")
        temperature.terminate()

        let data = launch(link: "settings", arguments: fixture)
        let dataRoute = element(data, "settings-data-history")
        XCTAssertTrue(dataRoute.waitForExistence(timeout: 20))
        reveal(data, dataRoute)
        dataRoute.tap()
        let history = element(data, "data-history")
        XCTAssertTrue(history.waitForExistence(timeout: 20))
        reveal(data, history)
        history.tap()
        XCTAssertTrue(element(data, "data-history-screen").waitForExistence(timeout: 20))
        capture("appstore-data-history")
        data.terminate()

        let device = launch(link: "settings/device-center", arguments: fixture)
        XCTAssertTrue(element(device, "device-center-screen").waitForExistence(timeout: 20))
        XCTAssertTrue(device.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Connected and ready.")).firstMatch.waitForExistence(timeout: 20))
        capture("appstore-device-center")
    }

    private var storeFixtureArguments: [String] {
        ["--loopr-si-polish-fixture=good", "--loopr-metric-history-fixture", "--loopr-si-store-fixture",
         "--loopr-heart-connected-fixture", "--loopr-heart-live-fixture"]
    }

    @MainActor func testFinalReviewFrames() {
        let today = launch(link: "today", arguments: storeFixtureArguments)
        let temperature = element(today, "today-contributor-skin_temperature_deviation")
        reveal(today, temperature)
        capture("final-today-temperature-row")
        today.terminate()

        let heart = launch(link: "heart", arguments: storeFixtureArguments)
        waitForLayout(element(heart, "heart-live-card"))
        waitForLiveReading(element(heart, "heart-live-card"))
        capture("final-heart-live")
        reveal(heart, element(heart, "heart-vital-skin_temperature_deviation"))
        capture("final-heart-temperature-row")
        heart.terminate()

        captureDeviceCenterReviewFrames()
    }

    @MainActor func testDeviceCenterReviewFrames() {
        captureDeviceCenterReviewFrames()
    }

    @MainActor func testStoreDateReviewFrames() {
        let workouts = launch(link: "today", arguments: storeFixtureArguments)
        workouts.tabBars.buttons["Workouts"].tap()
        let run = workouts.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout-row-")).firstMatch
        waitForLayout(element(workouts, "workouts-screen"))
        capture("final-workouts-top")
        for _ in 0..<8 {
            if run.exists { break }
            workouts.swipeUp()
        }
        waitForLayout(run)
        reveal(workouts, run)
        capture("final-workouts-dates")
        if large {
            let tuesday = element(workouts, "workout-row-00000000-0000-0000-0000-000000000701")
            for _ in 0..<8 {
                if tuesday.exists { break }
                workouts.swipeUp()
            }
            reveal(workouts, tuesday)
            XCTAssertTrue(tuesday.staticTexts["TUE · 30 MIN · 5.0 KM"].exists)
            capture("final-workouts-tuesday")
        }
        workouts.terminate()

        let data = launch(link: "settings", arguments: storeFixtureArguments)
        let route = element(data, "settings-data-history")
        reveal(data, route)
        route.tap()
        let history = element(data, "data-history")
        reveal(data, history)
        history.tap()
        let record = element(data, "data-record-si-store-record")
        reveal(data, record)
        XCTAssertEqual(record.label, "2023-11-14, Account export")
        capture("final-data-history-date")
        let export = element(data, "data-export-day-2023-11-14")
        reveal(data, export)
        capture("final-data-history-actions")
        data.terminate()
    }

    @MainActor private func captureDeviceCenterReviewFrames() {
        let device = launch(link: "settings/device-center", arguments: storeFixtureArguments)
        XCTAssertTrue(element(device, "device-center-screen").waitForExistence(timeout: 20))
        let ready = device.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Connected and ready.")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        capture("final-device-ready")
        let serial = device.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "4B7C2D9A6F31")).firstMatch
        reveal(device, serial)
        capture("final-device-identity")
        reveal(device, ready)
        capture("final-device-status")
        let packet = device.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Last packet,")).firstMatch
        reveal(device, packet)
        capture("final-device-timestamps")
        device.terminate()
    }

    @MainActor private func launch(link: String, arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-deep-link=\(link)"] + arguments
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func waitForLayout(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        let laidOut = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.exists && !target.frame.isEmpty
        }, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [laidOut], timeout: 20), .completed)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.75))
    }
    @MainActor private func waitForLiveReading(_ target: XCUIElement) {
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.label.hasPrefix("Live heart rate, ") && target.label.contains("beats per minute")
        }, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 20), .completed)
    }
    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.exists && app.tabBars.firstMatch.isHittable ? app.tabBars.firstMatch.frame.minY : window.frame.maxY - 34
        let navigator = element(app, "day-navigator")
        let top = navigator.exists && navigator.isHittable ? max(115, navigator.frame.maxY + 16) :
            element(app, "si-polish-glances").exists ? 175 : 115
        for _ in 0..<32 {
            let frame = target.frame
            if frame.minY >= top, frame.maxY <= bottom - 8 { break }
            if frame.height > bottom - top - 8, abs(frame.minY - top) < 16 { break }
            // A tall accessibility card gets a top-aligned capture, then a
            // separate capture of its next row instead of shrinking the text.
            let desired = frame.isEmpty ? -350 :
                frame.height > bottom - top - 8 ? top - frame.minY :
                frame.maxY > bottom - 8 ? bottom - 40 - frame.maxY : top + 20 - frame.minY
            let dy = min(max(desired, -350), 350)
            // Start inside the scroll content, above the floating tab bar.
            // Moving before the chart hold threshold keeps this a page scroll.
            let startY = dy < 0 ? min(bottom - 40, top + (bottom - top) * 0.55) : top + 40
            let bounded = min(max(dy, top + 8 - startY), bottom - 8 - startY)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.frame.width * 0.5, dy: startY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: bounded)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        if !target.isHittable {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(appearance)-si-polish-offscreen-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(target.isHittable)
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(target.frame.maxX, window.frame.maxX)
    }
    @MainActor private func revealBottom(_ app: XCUIApplication, _ target: XCUIElement) {
        reveal(app, target)
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.frame.minY - 8
        for _ in 0..<16 {
            let delta = min(0, bottom - 8 - target.frame.maxY)
            if delta >= 0 { break }
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.frame.width * 0.5, dy: bottom - 45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: max(min(delta, -24), -350))),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(target.isHittable)
        XCTAssertLessThanOrEqual(target.frame.maxY, bottom)
    }
    @MainActor private func capture(_ surface: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-polish-\(surface)\(sizeSuffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
