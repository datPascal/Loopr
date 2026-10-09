import XCTest

final class LooprUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPopulatedLaunchShowsPhase06ShellAndAccessibleRoots() {
        let app = launch(mode: "populated")
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Today", "Sleep", "Heart", "Body", "Workouts"])
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-goals").waitForExistence(timeout: 5))
        // Recovery sits directly above the Sleep, Strain and Stress rings.
        XCTAssertTrue(element(app, "today-metric-recovery").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-metric-sleep").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "today-metric-strain").waitForExistence(timeout: 5))
    }

    @MainActor
    func testTodayCanRestartPairingAfterItWasDeferred() {
        let app = launch(mode: "empty")
        let connect = app.buttons["today-connect-band"]

        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tapWhenHittable(in: app)

        XCTAssertTrue(app.alerts["Connect your band?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["today-connect-continue"].exists)
    }

    @MainActor
    func testHeartLiveControlsAreVisibleWithoutHistory() {
        let app = launch(mode: "empty")
        selectTab(app, "Heart", root: "heart-screen")
        XCTAssertTrue(app.buttons["heart-live-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["heart-spot-check-route"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Heart before first sync"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["heart-live-card"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "heart-live-zones").exists)
        element(app, "heart-zone-settings-route").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-zone-settings-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testMissingHeartZonesOpenProfileAgeField() {
        let app = launch(mode: "empty")
        selectTab(app, "Heart", root: "heart-screen")
        let prompt = app.buttons["heart-profile-age-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "settings-profile-age").waitForExistence(timeout: 5))
    }

    @MainActor
    func testZoneSettingsAgePromptOpensProfileAfterClosingSheet() {
        let app = launch(mode: "empty")
        selectTab(app, "Heart", root: "heart-screen")
        app.buttons["heart-live-card"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-screen").waitForExistence(timeout: 5))
        element(app, "heart-zone-settings-route").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-zone-settings-screen").waitForExistence(timeout: 5))
        app.buttons["heart-zone-settings-age-action"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "settings-profile-age").waitForExistence(timeout: 10))
    }

    @MainActor
    func testHeartLiveFixtureShowsSessionAndZoneSettings() {
        let app = launch(mode: "populated", additionalArguments: ["--loopr-heart-live-fixture"])
        selectTab(app, "Heart", root: "heart-screen")
        let card = element(app, "heart-live-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let deadline = Date(timeIntervalSinceNow: 15)
        while !card.label.contains("Zone") && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        XCTAssertTrue(card.label.contains("Zone"))
        element(app, "heart-live-card").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-chart").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "heart-live-session-stats").exists)
        let zones = element(app, "heart-live-zones")
        for _ in 0..<4 {
            if zones.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(zones.exists)
        element(app, "heart-zone-settings-route").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-zone-boundary-1").waitForExistence(timeout: 5))
    }

    @MainActor
    func testHeartLastReadingCardNamesItsZone() {
        let app = launch(mode: "populated")
        selectTab(app, "Heart", root: "heart-screen")
        let card = element(app, "heart-live-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.localizedCaseInsensitiveContains("zone"))
    }

    @MainActor
    func testHeartLiveTraceContinuesAfterLeavingDetail() {
        let app = launch(mode: "populated", additionalArguments: ["--loopr-heart-live-fixture"])
        selectTab(app, "Heart", root: "heart-screen")
        element(app, "heart-live-card").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-chart").waitForExistence(timeout: 10))
        let elapsed = app.otherElements["heart-live-session-stats"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let first = sessionSeconds(elapsed.value as? String ?? "")
        XCTAssertGreaterThan(first, 120)

        app.navigationBars.buttons.firstMatch.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-screen").waitForExistence(timeout: 5))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
        element(app, "heart-live-card").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-chart").waitForExistence(timeout: 10))
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(sessionSeconds(elapsed.value as? String ?? ""), first + 4)
    }

    private func sessionSeconds(_ text: String) -> Int {
        let fields = text.split(separator: ":").compactMap { Int($0) }
        guard fields.count == 2 else { return 0 }
        return fields[0] * 60 + fields[1]
    }

    @MainActor
    func testDisconnectedSpotCheckWaitsForBand() {
        let app = launch(mode: "disconnected")
        selectTab(app, "Heart", root: "heart-screen")
        app.buttons["heart-spot-check-route"].tapWhenHittable(in: app)
        let start = app.buttons["heart-spot-check-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.staticTexts["Waiting for your band"].exists)
        XCTAssertFalse(element(app, "heart-spot-check-error").exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Spot check waiting for connection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOnboardingAndPairingStayAheadOfShell() {
        for mode in ["onboarding", "pairing"] {
            let app = launch(mode: mode)
            XCTAssertTrue(element(app, "root-onboarding").waitForExistence(timeout: 5))
            XCTAssertFalse(element(app, "main-tab-shell").exists)
            app.terminate()
        }
    }

    @MainActor
    func testEachPhase06TabRendersItsCanonicalRoot() {
        let app = launch(mode: "populated")
        let roots = [
            ("Today", "today-screen"),
            ("Sleep", "sleep-screen"),
            ("Heart", "heart-screen"),
            ("Body", "body-screen"),
            ("Workouts", "workouts-screen")
        ]
        for (tab, identifier) in roots {
            selectTab(app, tab, root: identifier)
        }
    }

    @MainActor
    func testTodaySettingsRouteIsReachableAndReturnsToToday() {
        let app = launch(mode: "populated")
        app.buttons["open-settings"].firstMatch.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings-screen").exists)
        XCTAssertTrue(app.navigationBars.staticTexts["Settings"].firstMatch.exists)
        XCTAssertTrue(app.navigationBars.buttons["Done"].firstMatch.exists)
        dismissSettings(app)
    }

    @MainActor
    func testAppleHealthSettingsShowsDefaultOnAndExplainsPermission() {
        let app = launch(mode: "populated")
        app.buttons["open-settings"].firstMatch.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))
        tapSettingsEntry(app, "settings-apple-health")
        let toggle = app.switches["settings-health-sync-enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Choose what Loopr reads and saves below."].exists)
        XCTAssertTrue(app.buttons["settings-health-manage-access"].exists)
        XCTAssertTrue(app.staticTexts["Change system permission in the Health app. The switches below control what Loopr uses."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple Health settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSettingsRoutesReachDeviceCenterCycleAndDataScreens() {
        let app = launch(mode: "populated")
        app.buttons["open-settings"].firstMatch.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "settings-modal").waitForExistence(timeout: 5))

        let destinations = [
            ("settings-device-center", "device-center-screen"),
            ("settings-cycle-tracking", "cycle-screen"),
            ("settings-data-history", "data-screen"),
            ("settings-import-and-export", "data-screen")
        ]
        for (entry, destination) in destinations {
            tapSettingsEntry(app, entry)
            XCTAssertTrue(element(app, destination).waitForExistence(timeout: 5), "Missing " + destination + " from " + entry)
            XCTAssertGreaterThan(app.staticTexts.count, 0, destination + " has no accessible content")
            navigateBack(app, to: "settings-modal")
        }
        dismissSettings(app)
    }

    @MainActor
    func testTodayJournalAndRecordsRoutesAreReachable() {
        let app = launch(mode: "populated")

        assertReachableLabel("Journal", in: app)
        button(containing: "Journal", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "journal-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "journal-compose").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "journal-privacy").waitForExistence(timeout: 5))
        navigateBack(app, to: "today-screen")

        assertReachableLabel("Records", in: app)
        button(containing: "Records", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "records-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "loopr-navigation-header").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "records-timeline").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "records-share-preview").waitForExistence(timeout: 5))
    }

    @MainActor
    func testWorkoutsRoutesExposeStartLogAndCompletedDetail() {
        let app = launch(mode: "populated")
        app.tabBars.buttons["Workouts"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: 5))

        element(app, "workouts-start").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workout-start-picker-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "workouts-screen")

        element(app, "workouts-manual-entry").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workout-log-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "workouts-screen")

        let completedWorkout = element(app, "workout-row-00000000-0000-0000-0000-000000000701")
        XCTAssertTrue(completedWorkout.waitForExistence(timeout: 5))
        completedWorkout.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workout-detail-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testWorkoutsRecoveryRouteOffersExplicitResumeAndDiscard() {
        let app = launch(mode: "populated")
        app.tabBars.buttons["Workouts"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workouts-screen").waitForExistence(timeout: 5))

        let recoveryRow = element(app, "workout-row-00000000-0000-0000-0000-000000000702")
        XCTAssertTrue(recoveryRow.waitForExistence(timeout: 5))
        recoveryRow.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "workout-recovery-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "workout-recovery-resume").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "workout-recovery-discard").waitForExistence(timeout: 5))
    }

    @MainActor
    func testUniversalLaunchModesKeepEveryPhase06TabRootReachable() {
        let modes = ["empty", "populated", "stale", "disconnected", "connectedMixedCapabilities", "activeWorkout"]
        let roots = [
            ("Today", "today-screen"),
            ("Sleep", "sleep-screen"),
            ("Heart", "heart-screen"),
            ("Body", "body-screen"),
            ("Workouts", "workouts-screen")
        ]
        for mode in modes {
            let app = launch(mode: mode)
            XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 5), "Shell missing for " + mode)
            for (tab, root) in roots {
                selectTab(app, tab, root: root)
            }
            app.terminate()
        }
    }

    @MainActor
    func testActiveWorkoutAccessoryAppearsOnEveryTabAndOpensSession() {
        let app = launch(mode: "activeWorkout")
        for tab in ["Today", "Sleep", "Heart", "Body", "Workouts"] {
            app.tabBars.buttons[tab].tapWhenHittable(in: app)
            XCTAssertTrue(app.buttons["active-workout-mini-player"].waitForExistence(timeout: 5), "Missing mini-player on \(tab)")
        }
        app.buttons["active-workout-mini-player"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "active-workout-modal").waitForExistence(timeout: 5))
    }

    @MainActor
    func testMiniPlayerIsAbsentWithoutActiveWorkout() {
        let app = launch(mode: "populated")
        XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["active-workout-mini-player"].exists)
    }

    @MainActor
    func testPhase06DeepLinksSelectCanonicalTabsAndRoutes() {
        let cases: [(link: String, identifiers: [String], tab: String)] = [
            ("sleep/detail", ["sleep-screen"], "Sleep"),
            ("heart/detail", ["heart-detail-screen"], "Heart"),
            ("body/detail", ["body-screen"], "Body"),
            ("workouts/detail", ["workout-detail-screen"], "Workouts")
        ]
        for (link, identifiers, tab) in cases {
            let app = launch(mode: "populated", additionalArguments: ["--loopr-deep-link=\(link)"])
            XCTAssertTrue(element(app, anyOf: identifiers).waitForExistence(timeout: 5), "Missing deep-link destination for \(link)")
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, "Deep link \(link) selected the wrong tab")
            app.terminate()
        }
    }

    @MainActor
    func testUniversalTodayStateMatrixLaunchesDeterministically() {
        // The header chip appears only when there is something to act on
        // (days lane, 2026-09-24): "Partial data" beside a populated day is
        // gone, an empty day says so in its own card, and stale or
        // disconnected states keep their chip.
        let cases: [(String, String?, String?)] = [
            ("empty", "Nothing for today yet", nil),
            ("populated", nil, "today-goals"),
            ("stale", "Out of date", nil),
            ("disconnected", "Strap disconnected", nil),
            ("connectedMixedCapabilities", nil, "today-goals"),
            ("activeWorkout", nil, "today-goals")
        ]
        for (mode, stateTitle, identifier) in cases {
            let app = launch(mode: mode)
            XCTAssertTrue(element(app, "main-tab-shell").waitForExistence(timeout: 5), "Shell missing for \(mode)")
            XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 5), "Today missing for \(mode)")
            if let stateTitle {
                XCTAssertTrue(app.staticTexts[stateTitle].waitForExistence(timeout: 5), "State \(stateTitle) missing for \(mode)")
            }
            if let identifier {
                XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5), "\(identifier) missing for \(mode)")
            }
            app.terminate()
        }
    }

    @MainActor
    func testTodayRoutesToCanonicalSleepHeartBodyAndCoachScreens() {
        let app = launch(mode: "populated")

        element(app, "today-metric-sleep").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "loopr-navigation-header").waitForExistence(timeout: 5))
        navigateBack(app, to: "today-screen")

        // Today redesign (2026-09-24): the recovery hero opens its
        // breakdown, the strain ring opens the strain breakdown (which links
        // on to Body), and the coach sits in the More grid. The old heart
        // lens is gone; heart numbers open their metric pages.
        element(app, "today-metric-recovery").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "today-recovery-breakdown-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "today-screen")

        element(app, "today-metric-strain").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "today-strain-breakdown-screen").waitForExistence(timeout: 5))
        element(app, "today-breakdown-body").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "body-screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "loopr-navigation-header").waitForExistence(timeout: 5))
        navigateBack(app, to: "today-strain-breakdown-screen")
        navigateBack(app, to: "today-screen")

        // More sits below the first viewport. Scroll it into the accessibility
        // tree before asking the shared tap helper to find it.
        let coach = element(app, "today-coach")
        for _ in 0..<8 where !coach.exists { app.swipeUp() }
        coach.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "coach-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testTodayGoalOpensGoalSettings() {
        let app = launch(mode: "populated")

        element(app, "today-goal-movement").tapWhenHittable(in: app)

        XCTAssertTrue(element(app, "goal-settings-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testSleepDetailRoutesExposeHypnogramTrendsCorrectionsAndCoach() {
        let app = launch(mode: "populated")
        app.tabBars.buttons["Sleep"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "sleep-screen").waitForExistence(timeout: 5))

        button(containing: "Sleep stages", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "sleep-hypnogram-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "sleep-screen")

        button(containing: "Sleep trends", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "sleep-trends-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "sleep-screen")

        button(containing: "Corrections", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "sleep-corrections-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "sleep-screen")

        button(containing: "Sleep coach", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "coach-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testHeartAndBodyDetailRoutesExposeQualityAndAgeDestinations() {
        let app = launch(mode: "populated")

        app.tabBars.buttons["Heart"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-screen").waitForExistence(timeout: 5))
        element(app, "heart-live-card").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-live-screen").waitForExistence(timeout: 5))
        element(app, "heart-zone-settings-route").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-zone-settings-screen").waitForExistence(timeout: 5))
        app.buttons["Cancel"].tapWhenHittable(in: app)
        navigateBack(app, to: "heart-screen")
        button(containing: "60-second spot check", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "heart-spot-check-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "heart-screen")

        app.tabBars.buttons["Body"].tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "body-screen").waitForExistence(timeout: 5))
        element(app, "body-training-load").tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "body-load-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "body-screen")
        button(containing: "Cardio Age", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "cardio-age-screen").waitForExistence(timeout: 5))
        navigateBack(app, to: "body-screen")
        button(containing: "Loopr Age", in: app).tapWhenHittable(in: app)
        XCTAssertTrue(element(app, "loopr-age-screen").waitForExistence(timeout: 5))
    }

    @MainActor
    func testPhase06ScreenIdentifiersProvideAccessibleContent() {
        let app = launch(mode: "populated")
        let tabRoots = [
            ("Today", "today-screen"),
            ("Sleep", "sleep-screen"),
            ("Heart", "heart-screen"),
            ("Body", "body-screen"),
            ("Workouts", "workouts-screen")
        ]
        for (tab, identifier) in tabRoots {
            selectTab(app, tab, root: identifier)
            let root = element(app, identifier)
            XCTAssertTrue(root.isEnabled, "\(identifier) is not enabled")
            XCTAssertGreaterThan(app.staticTexts.count, 0, "\(identifier) has no accessible text")
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected)
        }
    }

    @MainActor
    func testHabitInsightCollectingStatesRenderSpecificCopy() {
        assertHabitInsightStates([
            ("collecting", "Collecting"),
            ("earlySignal", "Early signal"),
            ("enoughData", "Calculating"),
            ("clearAssociation", "Clear association")
        ])
    }

    @MainActor
    func testHabitInsightResolvedStatesRenderSpecificCopy() {
        assertHabitInsightStates([
            ("noClearAssociation", "No clear result"),
            ("cannotSeparate", "Cannot separate"),
            ("stale", "Out of date"),
            ("unavailable", "Unavailable")
        ])
    }

    @MainActor
    func testHabitDetailExposesTheAnswerHistoryAndCalculationAuditTrail() {
        let detail = launch(mode: "populated", additionalArguments: [
            "--loopr-deep-link=journal/habit-detail",
            "--loopr-habit-insight-state=clearAssociation"
        ])
        XCTAssertTrue(element(detail, "habit-detail-screen").waitForExistence(timeout: 5))
        assertReachableLabel("Answer history", in: detail)
        assertReachableLabel("Calculation", in: detail)
    }

    @MainActor
    private func assertHabitInsightStates(_ states: [(state: String, label: String)]) {
        for (state, label) in states {
            let app = launch(mode: "populated", additionalArguments: [
                "--loopr-deep-link=journal/habit-insights",
                "--loopr-habit-insight-state=\(state)"
            ])
            XCTAssertTrue(element(app, "habit-insights-screen").waitForExistence(timeout: 5), "Missing Habit insights for \(state)")
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                    .firstMatch
                    .waitForExistence(timeout: 5),
                "Missing \(label) presentation for \(state)"
            )
            app.terminate()
        }
    }

    @MainActor
    func testEveryHabitDestinationHasAStableDebugRoute() {
        let destinations = [
            ("journal/habit-setup", "habit-setup-screen"),
            ("journal/habit-management", "habit-management-screen"),
            ("journal/habit-check-in", "habit-check-in-screen"),
            ("journal/habit-history", "habit-history-screen"),
            ("journal/habit-insights", "habit-insights-screen"),
            ("journal/habit-detail", "habit-detail-screen")
        ]

        for (link, identifier) in destinations {
            let app = launch(mode: "populated", additionalArguments: [
                "--loopr-deep-link=\(link)",
                "--loopr-habit-insight-state=clearAssociation"
            ])
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5), "Missing \(identifier) from \(link)")
            XCTAssertGreaterThan(app.staticTexts.count, 0, "\(identifier) has no accessible text")
            app.terminate()
        }
    }

    @MainActor
    private func launch(mode: String, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--loopr-launch-mode=\(mode)"] + additionalArguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func element(_ app: XCUIApplication, anyOf identifiers: [String]) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", identifiers))
            .firstMatch
    }

    @MainActor
    private func button(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func assertReachableLabel(
        _ label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
            .firstMatch
        for _ in 0..<10 {
            if target.waitForExistence(timeout: 0.5) { return }
            app.swipeUp()
        }
        XCTFail("Could not reach label \(label)", file: file, line: line)
    }

    @MainActor
    private func selectTab(
        _ app: XCUIApplication,
        _ tab: String,
        root identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<3 {
            let tabBar = app.tabBars.firstMatch
            let tabButton = tabBar.buttons[tab].firstMatch
            guard tabBar.waitForExistence(timeout: 3),
                  tabButton.waitForExistence(timeout: 3),
                  tabButton.isHittable else {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
                continue
            }

            tabButton.tap()
            let selectedButton = tabBar.buttons[tab].firstMatch
            if selectedButton.waitForExistence(timeout: 2),
               selectedButton.isSelected,
               element(app, identifier).waitForExistence(timeout: 3) {
                return
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "tab-selection-failed-\(tab)-\(identifier)-hierarchy"
        add(hierarchy)
        XCTFail("Could not select \(tab) and reach \(identifier)", file: file, line: line)
    }

    @MainActor
    private func navigateBack(_ app: XCUIApplication, to identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back navigation is missing", file: file, line: line)
        back.tapWhenHittable(in: app)
        XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 5), "Did not return to \(identifier)", file: file, line: line)
    }

    @MainActor
    private func dismissSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Settings Done button is missing", file: file, line: line)
        done.tapWhenHittable(in: app, file: file, line: line)
        XCTAssertTrue(element(app, "today-screen").waitForExistence(timeout: 5), "Settings did not dismiss", file: file, line: line)
    }

    @MainActor
    private func tapSettingsEntry(
        _ app: XCUIApplication,
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Settings is a lazy List on iOS 26. Target its actual collection view
        // rather than the application window; window-level swipes leave the
        // modal collection view at its initial offset.
        let settingsCollection = app.collectionViews["settings-modal"].firstMatch
        for _ in 0..<8 {
            let entry = element(app, identifier)
            if entry.waitForExistence(timeout: 0.25) && entry.isHittable {
                entry.tap()
                return
            }

            guard settingsCollection.waitForExistence(timeout: 0.5), settingsCollection.isHittable else {
                break
            }

            let start = settingsCollection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = settingsCollection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.1, thenDragTo: end)

            // Allow the lazy row to be materialized before re-querying it.
            _ = element(app, identifier).waitForExistence(timeout: 0.5)
        }

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "settings-missing-\(identifier)-hierarchy"
        add(hierarchy)
        XCTFail("Settings entry \(identifier) did not become hittable after bounded scrolling", file: file, line: line)
    }
}

private extension XCUIElement {
    @MainActor
    func tapWhenHittable(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: 5), "Element \(identifier) did not appear", file: file, line: line)
        for _ in 0..<5 {
            // SwiftUI scroll content can be technically hittable while its
            // center is underneath the native tab bar. XCTest then dispatches
            // the tap to the tab bar instead of the requested row. Keep the
            // target's center in the content viewport before tapping.
            let tabBarTop = app.tabBars.firstMatch.exists
                ? app.tabBars.firstMatch.frame.minY
                : app.frame.maxY
            // Tab-bar buttons necessarily live inside the tab bar; the
            // content-viewport guard applies only to scrollable content
            // controls whose center can be covered by that bar.
            let isTabBarButton = app.tabBars.firstMatch.buttons
                .matching(NSPredicate(format: "label == %@", label))
                .firstMatch
                .exists
            if isHittable, (isTabBarButton || frame.midY < tabBarTop - 8) {
                tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Element \(identifier) is not hittable", file: file, line: line)
    }
}
