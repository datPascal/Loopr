//
//  LooprUITestsLaunchTests.swift
//  LooprUITests
//
//  Created by Pascal Lindenau on 06.08.26.
//

import XCTest

final class LooprUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        let sections = ["top", "trend", "zones", "recap", "states"]
        app.launchArguments = visualLaunchArguments()
        app.launch()

        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Today Shell"
        attachment.lifetime = .keepAlways
        add(attachment)

        for (offset, section) in sections.enumerated() {
            app.terminate()
            app.launchArguments = visualLaunchArguments(section: section)
            app.launch()
            XCTAssertTrue(element(app, "design-system-gallery").waitForExistence(timeout: 10))
            capture(app, name: "Design System \(offset + 1)")
        }
    }

    private func visualLaunchArguments(section: String? = nil) -> [String] {
        var arguments = [
            "--loopr-launch-mode=populated",
            "--loopr-visual-capture"
        ]
        if let section {
            arguments.append("--loopr-open-design-system")
            arguments.append("--loopr-design-system-section=\(section)")
        }
        return arguments
    }

    @MainActor
    func testPhase06VisualCandidates() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=populated"]
        app.launch()

        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 5))
        capture(app, name: "Phase06 Today")

        selectTab(app, "Sleep", root: "sleep-screen")
        capture(app, name: "Phase06 Sleep")

        selectTab(app, "Heart", root: "heart-screen")
        capture(app, name: "Phase06 Heart")

        selectTab(app, "Body", root: "body-screen")
        capture(app, name: "Phase06 Body")

        selectTab(app, "Workouts", root: "workouts-screen")
        capture(app, name: "Phase06 Workouts")

        selectTab(app, "Today", root: "today-screen")
        tapPhase06Element(app, identifier: "open-settings")
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))
        capture(app, name: "Phase06 Settings")
    }

    /// Captures the first shard of the complete Phase 06 candidate set, or
    /// exactly one requested candidate when a screen ID is supplied. Keeping
    /// each shard below ten app launches prevents XCTest's UI host from
    /// accumulating enough launch sessions and attachments to terminate.
    @MainActor
    func testPhase06VisualScreenCandidates() throws {
        capturePhase06CandidateShard(0, handlesRequestedCandidate: true)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard2() throws {
        capturePhase06CandidateShard(1)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard3() throws {
        capturePhase06CandidateShard(2)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard4() throws {
        capturePhase06CandidateShard(3)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard5() throws {
        capturePhase06CandidateShard(4)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard6() throws {
        capturePhase06CandidateShard(5)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard7() throws {
        capturePhase06CandidateShard(6)
    }

    @MainActor
    func testPhase06VisualScreenCandidatesShard8() throws {
        capturePhase06CandidateShard(7)
    }

    @MainActor
    private func capturePhase06CandidateShard(
        _ shardIndex: Int,
        handlesRequestedCandidate: Bool = false
    ) {
        let candidates = phase06Candidates()
        XCTAssertEqual(candidates.count, 68, "The Phase 06 visual routing table must cover all manifest screens")
        XCTAssertEqual(Set(candidates.map(\.id)).count, 68, "Phase 06 visual screen IDs must be unique")

        if let requestedID = requestedPhase06ScreenID() {
            guard handlesRequestedCandidate else { return }
            guard let candidate = candidates.first(where: { $0.id == requestedID }) else {
                XCTFail("Unknown Phase 06 visual screen ID: \(requestedID)")
                return
            }
            capturePhase06Candidate(candidate)
        } else {
            let shardCount = 8
            precondition((0..<shardCount).contains(shardIndex))
            let shard = candidates.enumerated().compactMap { offset, candidate in
                offset % shardCount == shardIndex ? candidate : nil
            }
            XCTAssertFalse(shard.isEmpty, "Phase 06 visual shard \(shardIndex + 1) must not be empty")
            XCTAssertLessThanOrEqual(shard.count, 9, "Phase 06 visual shards must remain bounded")
            for candidate in shard {
                capturePhase06Candidate(candidate)
            }
        }
    }

    /// Keeps the sheet-over-tab-bar accessibility boundary independently
    /// testable without replaying the full candidate traversal.
    @MainActor
    func testPhase06RouteShareCandidate() throws {
        guard let candidate = phase06Candidates().first(where: { $0.id == "route-share-preview-screen" }) else {
            XCTFail("Missing Phase 06 Route share candidate")
            return
        }
        capturePhase06Candidate(candidate)
    }

    /// Guards the full-width Today goal action independently so a visual
    /// matrix failure can be reproduced without replaying every screen.
    @MainActor
    func testPhase06GoalSettingsCandidate() throws {
        guard let candidate = phase06Candidates().first(where: { $0.id == "goal-settings-screen" }) else {
            XCTFail("Missing Phase 06 Goal Settings candidate")
            return
        }
        capturePhase06Candidate(candidate)
    }

    /// Exercises the adjacent full-width Cycle actions independently; at
    /// accessibility sizes a scroll gesture must not activate the first row
    /// while looking for a later destination.
    @MainActor
    func testPhase06CycleDestinationCandidates() throws {
        let requested = ["cycle-log-screen", "cycle-reminders-screen", "cycle-export-screen"]
        let candidates = phase06Candidates().filter { requested.contains($0.id) }
        XCTAssertEqual(candidates.map(\.id), requested)
        for candidate in candidates {
            capturePhase06Candidate(candidate)
        }
    }

    @MainActor
    private func selectTab(_ app: XCUIApplication, _ tab: String, root: String) {
        for _ in 0..<6 {
            // Query the native tab bar and its label on every attempt.  A
            // SwiftUI TabView can recycle the AX element behind a previously
            // captured XCUIElement while the selected tab is changing; using
            // the old object can dispatch the tap at another tab's frame.
            let tabBar = app.tabBars.firstMatch
            guard tabBar.waitForExistence(timeout: 1) else { continue }
            let tabButton = tabBar.buttons
                .matching(NSPredicate(format: "label == %@ OR identifier == %@", tab, tab))
                .firstMatch
            guard tabButton.waitForExistence(timeout: 1), tabButton.isHittable else { continue }

            tabButton.tap()
            if element(app, root).waitForExistence(timeout: 2) {
                return
            }
        }

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "phase06-tab-missing-\(tab)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Missing \(root) after selecting \(tab)")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func requestedPhase06ScreenID() -> String? {
        let argumentPrefixes = [
            "--loopr-phase06-screen=",
            "--loopr-phase06-visual-screen=",
            "--loopr-visual-screen=",
            "--phase06-screen="
        ]
        for argument in ProcessInfo.processInfo.arguments {
            if let prefix = argumentPrefixes.first(where: { argument.hasPrefix($0) }) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        let environment = ProcessInfo.processInfo.environment
        for key in ["LOOPR_PHASE06_SCREEN_ID", "LOOPR_PHASE06_VISUAL_SCREEN_ID", "LOOPR_VISUAL_SCREEN_ID"] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return nil
    }

    @MainActor
    private func navigate(_ app: XCUIApplication, using steps: [Phase06VisualStep]) {
        for step in steps {
            switch step {
            case .selectTab(let title, let root):
                selectTab(app, title, root: root)
            case .tapID(let identifier):
                tapPhase06Element(app, identifier: identifier)
            case .tapLabel(let text):
                tapPhase06Element(app, labelContaining: text)
            case .deepLink:
                // The app consumes deep-link launch arguments before the
                // first frame. Waiting for the target below is sufficient.
                break
            case .onboardingStage(let identifier):
                // These stages are selected by the app's visual launch router
                // when present; the wait keeps this test deterministic on
                // both routed and ordinary fixture launches.
                // A fresh onboarding launch opens on the band intro first.
                let getStarted = app.buttons["band-intro-get-started"]
                if getStarted.waitForExistence(timeout: 15) { getStarted.tap() }
                XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5), "Onboarding stage did not load: \(identifier)")
            }
        }
    }

    /// SwiftUI List rows are lazily materialized on iOS 26.  Re-query the
    /// route element after each bounded coordinate drag so a route that starts
    /// below the fold becomes hittable without depending on a fixed hierarchy.
    @MainActor
    private func tapPhase06Element(
        _ app: XCUIApplication,
        identifier: String? = nil,
        labelContaining: String? = nil
    ) {
        precondition(identifier != nil || labelContaining != nil)
        let attempts = 10
        for _ in 0..<attempts {
            let button: XCUIElement
            if let identifier {
                button = app.buttons[identifier].firstMatch
            } else {
                button = app.buttons
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", labelContaining!))
                    .firstMatch
            }
            if button.waitForExistence(timeout: 0.6) {
                // At accessibility sizes a SwiftUI button can report
                // `isHittable` while its lower edge is behind the native tab
                // bar.  Tapping that stale frame either does nothing or hits
                // the tab bar.  Re-query the current frame and only accept a
                // target that is clear of the tab bar; the next iteration
                // scrolls the lazy container and queries it again.
                if phase06CanTap(button, in: app) {
                    button.tap()
                    if phase06TapReachedDestination(app, identifier: identifier, labelContaining: labelContaining) {
                        return
                    }
                    // A freshly launched app can briefly retain the prior
                    // SwiftUI surface after an AX tap. Re-query and retry
                    // rather than accepting a tap that did not navigate.
                    if button.exists {
                        continue
                    }
                }

                // Keep identifier routes on their native Button element. A
                // container may share the same accessibility identifier and
                // can be hittable while its child button is still below the
                // fold; tapping that container does not invoke the route.
                scrollPhase06Content(app)
                if phase06ScrollReachedDestination(app, identifier: identifier, labelContaining: labelContaining) {
                    return
                }
                _ = button.waitForExistence(timeout: 0.35)
                continue
            }

            let any: XCUIElement
            if let identifier {
                any = element(app, identifier)
            } else {
                any = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", labelContaining!))
                    .firstMatch
            }
            if any.waitForExistence(timeout: 0.35), phase06CanTap(any, in: app) {
                any.tap()
                if phase06TapReachedDestination(app, identifier: identifier, labelContaining: labelContaining) {
                    return
                }
                if any.exists {
                    continue
                }
            }

            scrollPhase06Content(app)
            if phase06ScrollReachedDestination(app, identifier: identifier, labelContaining: labelContaining) {
                return
            }
            // Give the lazy container one run-loop turn to materialize the
            // next rows before the next query.
            _ = any.waitForExistence(timeout: 0.35)
        }

        let missing = identifier ?? "label containing \(labelContaining!)"
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "phase06-route-missing-\(missing)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Could not find tappable Phase 06 route element \(missing)")
    }

    @MainActor
    private func phase06CanTap(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        guard target.exists, target.isHittable else { return false }

        // Keep the check tied to a fresh native tab-bar query.  Do not use a
        // cached frame: SwiftUI can rebuild the tab bar while a List row is
        // being materialized, especially at AX XXL.
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists else { return true }
        let tabFrame = tabBar.frame
        let targetFrame = target.frame
        guard tabFrame.height > 0, targetFrame.height > 0 else { return true }
        // XCTest taps the element's center. At accessibility sizes a valid
        // sheet row can be taller than the remaining viewport and overlap
        // the underlying tab bar's AX frame even though its tappable center
        // is safely above it. Reject only targets whose tap point would land
        // in the tab bar; requiring the entire large-text row to clear the
        // bar makes the final Route action permanently unreachable.
        return targetFrame.midY < tabFrame.minY - 4
    }

    @MainActor
    private func phase06TapReachedDestination(
        _ app: XCUIApplication,
        identifier: String?,
        labelContaining: String?
    ) -> Bool {
        if identifier == "cycle-opt-in" {
            // The cycle screen itself is already present before opt-in, so it
            // is not a sufficient post-tap signal.  Require one of the
            // populated actions to materialize before accepting the tap.
            return element(app, "cycle-log").waitForExistence(timeout: 1.5)
                || element(app, "cycle-export").waitForExistence(timeout: 1.5)
        }
        if let expectedSurface = phase06ExpectedSurface(for: identifier, labelContaining: labelContaining) {
            return element(app, expectedSurface).waitForExistence(timeout: 1.5)
        }
        return true
    }

    @MainActor
    private func phase06ScrollReachedDestination(
        _ app: XCUIApplication,
        identifier: String?,
        labelContaining: String?
    ) -> Bool {
        if identifier == "cycle-opt-in" {
            return element(app, "cycle-log").waitForExistence(timeout: 0.3)
                || element(app, "cycle-export").waitForExistence(timeout: 0.3)
        }
        guard let expectedSurface = phase06ExpectedSurface(
            for: identifier,
            labelContaining: labelContaining
        ) else { return false }
        return element(app, expectedSurface).waitForExistence(timeout: 0.3)
    }

    @MainActor
    private func phase06ExpectedSurface(for identifier: String?, labelContaining: String?) -> String? {
        if let identifier {
            switch identifier {
            case "open-settings": return "settings-modal"
            case "settings-device-center": return "device-center-screen"
            case "settings-cycle-tracking": return "cycle-screen"
            case "settings-data-history", "settings-import-and-export": return "data-screen"
            case "today-goal-movement": return "goal-settings-screen"
            case "device-find-my-strap": return "find-my-strap-screen"
            case "strap-alarm-setup", "today-wake-alarm-card": return "wake-alarm-screen"
            case "route-map": return "route-map-screen"
            case "route-splits": return "route-splits-screen"
            case "route-share-preview": return "route-share-preview-screen"
            case "cycle-log": return "cycle-log-screen"
            case "cycle-reminders": return "cycle-reminders-screen"
            case "cycle-export": return "cycle-export-screen"
            default: break
            }
        }
        if let labelContaining {
            switch labelContaining {
            case "Supported gestures": return "gesture-mapping-screen"
            default: break
            }
        }
        return nil
    }

    @MainActor
    private func scrollPhase06Content(_ app: XCUIApplication) {
        let target = app.collectionViews.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
            ?? app.scrollViews.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        guard let target else {
            app.swipeUp()
            return
        }

        // Keep the drag at the trailing edge of the scroll container. At
        // accessibility sizes the Cycle rows can fill the entire viewport;
        // a center drag may begin on a Button and invoke its action instead
        // of scrolling (for example, opening the log while looking for
        // Export). The edge remains inside the ScrollView while avoiding the
        // package-owned row hit targets.
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.82))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.24))
        start.press(forDuration: 0, thenDragTo: end)
    }

    @MainActor
    private func capturePhase06Candidate(_ candidate: Phase06VisualCandidate) {
        let app = XCUIApplication()
        // The fixture settings snapshot pins a dark appearance override, so any
        // screen that loads Settings renders dark whatever the simulator is set
        // to. A capture run names the appearance it wants; without the variable
        // the lane behaves exactly as before.
        let appearanceArguments = ProcessInfo.processInfo.environment["LOOPR_CAPTURE_APPEARANCE"]
            .map { ["--loopr-appearance=\($0)"] } ?? []

        app.launchArguments = [
            "--loopr-launch-mode=\(candidate.launchMode.rawValue)",
            "--loopr-phase06-screen=\(candidate.id)"
        ] + (candidate.deepLink.map { ["--loopr-deep-link=\($0)"] } ?? []) + appearanceArguments
        app.launchEnvironment["LOOPR_PHASE06_SCREEN_ID"] = candidate.id
        app.launch()

        navigate(app, using: candidate.steps)
        XCTAssertTrue(element(app, candidate.id).waitForExistence(timeout: 5), "Missing Phase 06 visual screen \(candidate.id)")
        XCTAssertGreaterThan(app.staticTexts.count, 0, "Phase 06 visual screen \(candidate.id) has no accessible text")
        switch candidate.id {
        case "stress-screen":
            XCTAssertTrue(element(app, "stress-metric-face").exists)
        case "workout-detail-screen":
            XCTAssertTrue(element(app, "workout-detail-metric-face").exists)
        case "heart-screen":
            XCTAssertTrue(element(app, "heart-vitals-section").exists)
        case "heart-detail-screen":
            XCTAssertTrue(element(app, "heart-advanced-section").exists)
        default:
            break
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Phase06 Screen \(candidate.id)_candidate"
        attachment.lifetime = .keepAlways
        add(attachment)
        // On iOS 26.3, terminating the only launched app in a single-screen
        // invocation can kill/restart the XCTest host after the attachment
        // has been committed. The multi-screen lane still terminates between
        // candidates to isolate fixture state; a single candidate needs no
        // subsequent launch, so let XCTest tear it down normally.
        if requestedPhase06ScreenID() == nil {
            app.terminate()
        }
    }

    @MainActor
    private func phase06Candidates() -> [Phase06VisualCandidate] {
        let onboarding = Phase06VisualCandidate.LaunchMode.onboarding
        let populated = Phase06VisualCandidate.LaunchMode.populated
        return [
            .init("onboarding-screen", launchMode: onboarding, steps: [.onboardingStage("onboarding-screen")]),
            .init("profile-setup-screen", launchMode: onboarding, deepLink: "phase06/profile", steps: [.deepLink("phase06/profile")]),
            .init("onboarding-destructive-actions-screen", launchMode: onboarding, deepLink: "phase06/destructive-actions", steps: [.deepLink("phase06/destructive-actions")]),
            .init("device-center-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-device-center")]),
            .init("find-my-strap-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-device-center"), .tapID("device-find-my-strap")]),
            .init("wake-alarm-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-device-center"), .tapID("strap-alarm-setup")]),
            .init("gesture-mapping-screen", launchMode: populated, deepLink: "phase06/gesture-mapping", steps: [.deepLink("phase06/gesture-mapping")]),
            .init("today-screen", launchMode: populated, steps: [.selectTab("Today", root: "today-screen")]),
            .init("goal-settings-screen", launchMode: populated, steps: [.tapID("today-goal-movement")]),
            .init("coach-screen", launchMode: populated, steps: [.tapID("today-coach")]),
            .init("sleep-screen", launchMode: populated, steps: [.selectTab("Sleep", root: "sleep-screen")]),
            .init("sleep-hypnogram-screen", launchMode: populated, steps: [.selectTab("Sleep", root: "sleep-screen"), .tapLabel("Sleep stages")]),
            .init("sleep-trends-screen", launchMode: populated, steps: [.selectTab("Sleep", root: "sleep-screen"), .tapLabel("Sleep trends")]),
            .init("sleep-corrections-screen", launchMode: populated, steps: [.selectTab("Sleep", root: "sleep-screen"), .tapLabel("Corrections")]),
            .init("heart-screen", launchMode: populated, steps: [.selectTab("Heart", root: "heart-screen")]),
            .init("heart-live-screen", launchMode: populated, steps: [.selectTab("Heart", root: "heart-screen"), .tapID("heart-live-card")]),
            .init("heart-detail-screen", launchMode: populated, deepLink: "heart/detail", steps: [.deepLink("heart/detail")]),
            .init("heart-trends-screen", launchMode: populated, deepLink: "phase06/heart-trends", steps: [.deepLink("phase06/heart-trends")]),
            .init("heart-spot-check-screen", launchMode: populated, steps: [.selectTab("Heart", root: "heart-screen"), .tapLabel("60-second spot check")]),
            .init("body-screen", launchMode: populated, steps: [.selectTab("Body", root: "body-screen")]),
            .init("body-load-screen", launchMode: populated, steps: [.selectTab("Body", root: "body-screen"), .tapID("body-training-load")]),
            .init("cardio-age-screen", launchMode: populated, steps: [.selectTab("Body", root: "body-screen"), .tapLabel("Cardio Age")]),
            .init("loopr-age-screen", launchMode: populated, steps: [.selectTab("Body", root: "body-screen"), .tapLabel("Loopr Age")]),
            .init("workouts-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen")]),
            .init("workout-recovery-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000702")]),
            .init("workout-detail-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701")]),
            .init("workout-start-picker-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workouts-start")]),
            .init("workout-log-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workouts-manual-entry")]),
            .init("workout-edit-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-edit")]),
            .init("workout-live-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workouts-start"), .tapID("workout-start-confirm")]),
            .init("workout-finish-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workouts-start"), .tapID("workout-start-confirm"), .tapID("workout-live-finish")]),
            .init("workout-share-preview-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-share")]),
            .init("route-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-route")]),
            .init("route-map-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-route"), .tapID("route-map")]),
            .init("route-splits-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-route"), .tapID("route-splits")]),
            .init("route-share-preview-screen", launchMode: populated, steps: [.selectTab("Workouts", root: "workouts-screen"), .tapID("workout-row-00000000-0000-0000-0000-000000000701"), .tapID("workout-detail-route"), .tapID("route-share-preview")]),
            .init("journal-screen", launchMode: populated, steps: [.tapLabel("Journal")]),
            .init("journal-compose-screen", launchMode: populated, steps: [.tapLabel("Journal"), .tapID("journal-compose")]),
            .init("journal-history-screen", launchMode: populated, steps: [.tapLabel("Journal"), .tapID("journal-history")]),
            .init("habit-insights-screen", launchMode: populated, deepLink: "phase06/journal-correlations", steps: [.deepLink("phase06/journal-correlations")]),
            .init("journal-privacy-screen", launchMode: populated, steps: [.tapLabel("Journal"), .tapID("journal-privacy")]),
            .init("cycle-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-cycle-tracking")]),
            .init("cycle-log-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-cycle-tracking"), .tapID("cycle-opt-in"), .tapID("cycle-log")]),
            .init("cycle-reminders-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-cycle-tracking"), .tapID("cycle-opt-in"), .tapID("cycle-reminders")]),
            .init("cycle-export-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-cycle-tracking"), .tapID("cycle-opt-in"), .tapID("cycle-export")]),
            .init("records-screen", launchMode: populated, steps: [.tapLabel("Records")]),
            .init("records-detail-screen", launchMode: populated, deepLink: "phase06/records-detail", steps: [.deepLink("phase06/records-detail")]),
            .init("records-streaks-screen", launchMode: populated, steps: [.tapLabel("Streaks")]),
            .init("records-journey-screen", launchMode: populated, steps: [.tapLabel("Journey")]),
            .init("records-timeline-screen", launchMode: populated, steps: [.tapLabel("Records"), .tapID("records-timeline")]),
            .init("records-recap-screen", launchMode: populated, deepLink: "phase06/records-recap", steps: [.deepLink("phase06/records-recap")]),
            .init("records-share-preview-screen", launchMode: populated, steps: [.tapLabel("Records"), .tapID("records-share-preview")]),
            .init("stress-screen", launchMode: populated, steps: [.tapID("today-metric-stress")]),
            .init("stress-breathing-screen", launchMode: populated, steps: [.tapID("today-metric-stress"), .tapID("stress-breathing")]),
            .init("stress-spot-check-screen", launchMode: populated, steps: [.tapID("today-metric-stress"), .tapID("stress-spot-check")]),
            .init("stress-history-screen", launchMode: populated, steps: [.tapID("today-metric-stress"), .tapID("stress-history")]),
            .init("settings-modal", launchMode: populated, steps: [.tapID("open-settings")]),
            .init("settings-screen", launchMode: populated, steps: [.tapID("open-settings")]),
            .init("settings-destination-profile", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-profile")]),
            .init("settings-destination-privacy", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-privacy")]),
            .init("settings-ai-provider-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-ai-and-privacy")]),
            .init("data-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-data-history")]),
            .init("data-history-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-data-history"), .tapID("data-history")]),
            .init("data-import-preview-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-import-and-export"), .tapID("data-importPreview")]),
            .init("data-export-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-import-and-export"), .tapID("data-export")]),
            .init("data-reanalysis-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-data-history"), .tapID("data-reanalysis")]),
            .init("data-diagnostics-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-data-history"), .tapID("data-diagnostics")]),
            .init("data-deletion-screen", launchMode: populated, steps: [.tapID("open-settings"), .tapID("settings-data-history"), .tapID("data-deletion")])
        ]
    }
}

private struct Phase06VisualCandidate {
    enum LaunchMode: String { case onboarding, populated }
    let id: String
    let launchMode: LaunchMode
    let deepLink: String?
    let steps: [Phase06VisualStep]

    init(_ id: String, launchMode: LaunchMode, deepLink: String? = nil, steps: [Phase06VisualStep]) {
        self.id = id
        self.launchMode = launchMode
        self.deepLink = deepLink
        self.steps = steps
    }
}

private enum Phase06VisualStep {
    case selectTab(String, root: String)
    case tapID(String)
    case tapLabel(String)
    case deepLink(String)
    case onboardingStage(String)
}

private extension XCUIElement {
    @MainActor
    func tapWhenHittable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let elementDescription = identifier.isEmpty ? label : identifier
        for _ in 0..<5 {
            // Resolve a fresh AX element before every tap.  Reusing `self`
            // after a SwiftUI navigation transition can retain the previous
            // frame and synthesize a tap on a neighboring control.
            let fresh: XCUIElement
            if !identifier.isEmpty {
                fresh = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier == %@", identifier))
                    .firstMatch
            } else if !label.isEmpty {
                fresh = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", label))
                    .firstMatch
            } else {
                fresh = self
            }

            if fresh.waitForExistence(timeout: 1), fresh.isHittable {
                fresh.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Element \(elementDescription) is not hittable", file: file, line: line)
    }
}
