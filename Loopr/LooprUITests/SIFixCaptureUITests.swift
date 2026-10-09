import XCTest

final class SIFixCaptureUITests: XCTestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"] ?? "light" }
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testSharedFixtureStory() {
        let today = launch(link: "today")
        let recovery = element(today, "today-metric-recovery")
        wait(recovery)
        XCTAssertTrue(recovery.label.contains("79"), recovery.label)
        capture("today-shared-briefing")
        reveal(today, element(today, "today-contributor-resting_heart_rate"))
        capture("today-shared-contributors")
        today.terminate()

        for (link, root) in [("heart", "heart-vital-rmssd"), ("body", "body-screen"), ("sleep", "sleep-screen")] {
            let app = launch(link: link)
            wait(element(app, root))
            capture("\(link)-shared")
            app.terminate()
        }
    }

    @MainActor func testScoredTodayAtRegularAndLargestText() {
        for large in [false, true] {
            for state in ["shared", "good"] {
                var arguments = state == "shared" ? [] : ["--loopr-si-polish-fixture=good"]
                if large { arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
                let app = launch(link: "today", extra: arguments)
                let recovery = element(app, "today-metric-recovery")
                wait(recovery)
                XCTAssertTrue(recovery.label.contains("79"), recovery.label)
                capture("today-\(state)-\(large ? "largest" : "regular")-briefing")
                let check = element(app, "today-heads-up")
                reveal(app, check)
                capture("today-\(state)-\(large ? "largest" : "regular")-overnight-check")
                reveal(app, element(app, "today-contributor-resting_heart_rate"))
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Recovery can start after")).firstMatch.exists)
                capture("today-\(state)-\(large ? "largest" : "regular")-signals")
                app.terminate()
            }
        }
    }

    @MainActor func testMorningStates() {
        for state in ["good", "first-night", "empty", "flagged"] {
            let app = launch(link: "today", extra: ["--loopr-si-polish-fixture=\(state)"])
            let recovery = element(app, "today-metric-recovery")
            wait(recovery)
            if state == "good" { XCTAssertTrue(recovery.label.contains("79"), recovery.label) }
            if state == "first-night" { XCTAssertTrue(recovery.label.contains("1 of 4 nights"), recovery.label) }
            capture("today-\(state)-briefing")
            let signals = element(app, state == "empty" ? "today-signals-empty" : "today-contributor-resting_heart_rate")
            reveal(app, signals)
            capture("today-\(state)-signals")
            app.terminate()
        }
    }

    @MainActor func testRecoveryBreakdown() {
        let app = launch(link: "today")
        let recovery = element(app, "today-metric-recovery")
        wait(recovery)
        recovery.tap()
        wait(element(app, "today-recovery-breakdown-screen"))
        capture("recovery-shared-weights")
        reveal(app, element(app, "today-breakdown-restingHeartRate"))
        capture("recovery-shared-contributors")
        app.terminate()
    }

    @MainActor func testMetricHistoryPagesAndTeardown() {
        for key in ["rmssd", "resting_heart_rate", "respiratory_rate", "sleep_duration"] {
            let isSleep = key == "sleep_duration"
            let root = isSleep ? "sleep" : "heart"
            let app = launch(link: root)
            let row = element(app, isSleep ? "sleep-metric-duration" : "heart-vital-\(key)")
            reveal(app, row)
            row.tap()
            wait(element(app, "metric-detail-screen"))
            wait(element(app, "metric-detail-value"))
            capture("metric-\(key)-shared")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
            XCTAssertTrue(element(app, "\(root)-screen").waitForExistence(timeout: 10))
            XCTAssertFalse(element(app, "metric-detail-screen").exists)
            app.terminate()
        }
    }

    @MainActor func testHeartStatesAndLargeText() {
        for state in ["good", "first-night", "empty", "flagged"] {
            let app = launch(link: "heart", extra: ["--loopr-si-polish-fixture=\(state)"])
            wait(element(app, "heart-vital-rmssd"))
            capture("heart-\(state)-top")
            reveal(app, element(app, "heart-vital-resting_heart_rate"))
            capture("heart-\(state)-signals")
            app.terminate()
        }
        let large = launch(link: "today", extra: ["--loopr-si-polish-fixture=flagged",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        wait(element(large, "today-metric-recovery"))
        capture("today-flagged-largest-text")
        reveal(large, element(large, "today-contributor-resting_heart_rate"))
        capture("today-flagged-largest-text-rhr")
        large.terminate()
    }

    @MainActor private func launch(link: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--loopr-launch-mode=populated", "--loopr-appearance=\(appearance)",
            "--loopr-metric-history-fixture", "--loopr-deep-link=\(link)"] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func wait(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        let laidOut = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            target.exists && !target.frame.isEmpty
        }, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [laidOut], timeout: 20), .completed)
    }

    @MainActor private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        wait(target)
        let window = app.windows.firstMatch
        let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.frame.maxY - 34
        let navigator = element(app, "day-navigator")
        let top = navigator.exists && navigator.isHittable ? max(115, navigator.frame.maxY + 16) : 115
        for _ in 0..<24 {
            let frame = target.frame
            if frame.minY >= top, frame.maxY <= bottom - 8 { break }
            if frame.height > bottom - top - 8, abs(frame.minY - top) < 16 { break }
            let desired = frame.height > bottom - top - 8 ? top - frame.minY :
                frame.maxY > bottom - 8 ? bottom - 40 - frame.maxY : top + 20 - frame.minY
            let dy = min(max(desired, -350), 350)
            let startY = dy < 0 ? top + (bottom - top) * 0.55 : top + 40
            let distance = min(max(dy, top + 8 - startY), bottom - 8 - startY)
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.frame.width * 0.5, dy: startY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(target.isHittable)
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(target.frame.maxX, window.frame.maxX)
    }

    @MainActor private func capture(_ surface: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(appearance)-si-fix-\(surface)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
