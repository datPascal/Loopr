import SettingsKit
import ProfileKit
import DesignSystem
import XCTest

final class SettingsKitTests: XCTestCase {
    actor TestHealthKitEntryPoint: HealthKitSettingsEntryPoint {
        private var current: SettingsIntegrationState = .permissionRequired
        private(set) var requestCount = 0

        func state() async -> SettingsIntegrationState { current }

        func requestPermission() async -> SettingsIntegrationState {
            requestCount += 1
            current = .available
            return current
        }

        func reset() async throws { current = .permissionRequired }
    }

    actor TestNotificationEntryPoint: NotificationSettingsEntryPoint {
        private var current: SettingsIntegrationState = .denied
        private var values = [
            NotificationPreferenceSetting(id: "battery", title: "Battery", isEnabled: true),
            NotificationPreferenceSetting(id: "cycleReminders", title: "Cycle reminders", isEnabled: false)
        ]

        func state() async -> SettingsIntegrationState { current }
        func requestPermission() async -> SettingsIntegrationState { current = .available; return current }
        func reset() async throws { current = .denied }
        func preferences() async -> [NotificationPreferenceSetting] { values }
        func setPreference(id: String, enabled: Bool) async throws {
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            values[index] = .init(id: values[index].id, title: values[index].title, isEnabled: enabled)
        }
    }

    actor TestAIPrivacyEntryPoint: AIPrivacySettingsEntryPoint {
        private var current: SettingsIntegrationState = .available
        private(set) var enabled = false

        func state() async -> SettingsIntegrationState { current }
        func setEnabled(_ enabled: Bool) async throws -> SettingsIntegrationState {
            self.enabled = enabled
            return current
        }
        func reset() async throws { enabled = false }
    }

    func testSettingsRoundTripValidationAndReset() async throws {
        let repository = InMemorySettingsRepository()
        let viewModel = SettingsViewModel(repository: repository, versions: VersionRegistry(appVersion: "1.0", algorithmVersion: 2, protocolVersion: "edge"), releaseBuild: true)
        let desired = SettingsSnapshot(profile: ProfileSettings(displayName: "Sam", age: 34), units: .imperial, appearance: .dark, goals: GoalSettings(stepGoal: 8_000))
        try await viewModel.update(desired)
        let loaded = await viewModel.load()
        XCTAssertEqual(loaded, desired)
        do {
            try await viewModel.update(SettingsSnapshot(goals: GoalSettings(stepGoal: 0)))
            XCTFail("invalid goals must not persist")
        } catch SettingsError.invalidGoal { }
        await viewModel.resetProfile()
        let reset = await repository.snapshot()
        XCTAssertNil(reset.profile.displayName)
        XCTAssertNil(reset.goals.stepGoal)
        let state = await viewModel.screenState()
        XCTAssertEqual(state, .ready)
    }

    func testRouteOwnershipAndReleaseDiagnosticsGate() async throws {
        let release = SettingsViewModel(repository: InMemorySettingsRepository(), versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"), releaseBuild: true)
        do {
            _ = try await release.navigate(to: .hiddenDiagnostics)
            XCTFail("hidden diagnostics must not be reachable in release builds")
        } catch SettingsError.hiddenRouteUnavailable { }
        let dataEntry = try await release.navigate(to: .dataHistory)
        XCTAssertEqual(dataEntry.owner, "APP-16")

        let debug = SettingsViewModel(repository: InMemorySettingsRepository(), versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"), releaseBuild: false)
        let entry = try await debug.navigate(to: .hiddenDiagnostics)
        XCTAssertTrue(entry.isHidden)
        XCTAssertEqual(entry.typedOwner, .data)
        XCTAssertEqual(entry.owner, "APP-16")
        XCTAssertTrue(SettingsRoute.allCases.contains(.importExport))
        XCTAssertEqual(SettingsRoute.goals.owner, .profile)
        XCTAssertEqual(SettingsRoute.appearance.owner, .designSystem)
    }

    func testSettingsFixtureAndTypedDestinationsCoverPrivacy() {
        XCTAssertEqual(SettingsFixtures.darkPrivate.appearance, .dark)
        XCTAssertFalse(SettingsFixtures.darkPrivate.surfacePrivacy.todayWidget)
        XCTAssertTrue(SettingsRouteDestination.allCases.contains(.privacy))
    }

    func testSettingsScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(SettingsScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(SettingsScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(SettingsScreenStateFixtures.accessibilitySummary(for: .absent), SettingsScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(SettingsScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

    func testSurfacePrivacyRoundTripVersionRegistryAndCompleteReset() async throws {
        let repository = InMemorySettingsRepository()
        let configured = SettingsSnapshot(
            profile: ProfileSettings(displayName: "Private", age: 40),
            units: .imperial,
            appearance: .dark,
            accessibility: AccessibilitySettings(reduceMotionOverride: true, increasedContrastPreview: true, voiceOverHints: true),
            goals: GoalSettings(stepGoal: 9_000, strainTarget: 12),
            surfacePrivacy: SurfacePrivacySettings(todayWidget: false, batteryWidget: true, watchSnapshot: false, liveActivity: false)
        )
        try await repository.update(configured)
        let roundTrip = await repository.snapshot()
        XCTAssertEqual(roundTrip, configured)
        XCTAssertFalse(roundTrip.includesData(on: .todayWidget))
        XCTAssertTrue(roundTrip.includesData(on: .batteryWidget))
        XCTAssertFalse(roundTrip.surfaceSnapshot(for: .liveActivity).includesHealthData)
        XCTAssertEqual(SettingsLicenseCatalog.notices.count, 9)
        XCTAssertTrue(SettingsLicenseCatalog.notices.contains { $0.name == "WHOOP non-affiliation" && $0.text.contains("not affiliated") })
        XCTAssertTrue(SettingsLicenseCatalog.notices.contains { $0.name == "Wellness, not medical care" && $0.text.contains("not a medical device") })
        XCTAssertTrue(SettingsLicenseCatalog.notices.contains { $0.name.contains("OpenStrap") && $0.text.contains("Permission is hereby granted") && $0.text.contains("THE SOFTWARE IS PROVIDED") })
        XCTAssertTrue(SettingsLicenseCatalog.notices.contains { $0.name.contains("BodyParts3D") && $0.text.contains("CC BY-SA 2.1 JP") && $0.text.contains("dbarchive.biosciencedbc.jp") })
        XCTAssertEqual(SettingsLicenseCatalog.notices.filter { $0.text.contains("Open Font License") }.count, 4)
        XCTAssertEqual(SettingsLegalDocuments.all.map(\.title), ["Privacy policy", "Terms", "Notice", "Imprint"])
        XCTAssertEqual(
            SettingsLegalDocuments.all.map(\.url.absoluteString),
            [
                "https://datpascal.github.io/loopr-legal/privacy.html",
                "https://datpascal.github.io/loopr-legal/terms.html",
                "https://datpascal.github.io/loopr-legal/notice.html",
                "https://datpascal.github.io/loopr-legal/imprint.html"
            ]
        )
        await repository.resetAll()
        let reset = await repository.snapshot()
        XCTAssertEqual(reset, SettingsSnapshot())
    }

    func testCanonicalRouteFailsClosedWithoutInjectedAPP02ARepositories() async throws {
        let viewModel = SettingsViewModel(
            repository: InMemorySettingsRepository(),
            versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"),
            releaseBuild: true
        )

        do {
            _ = try await viewModel.canonicalGoals()
            XCTFail("Settings must not fabricate a local goals repository")
        } catch SettingsError.canonicalRepositoryUnavailable { }
    }

    func testDesignSystemTokenBridgeRoundTripsAppearanceAndAccessibility() async throws {
        let bridge = InMemoryDesignSystemTokenBridge()
        let repository = InMemorySettingsRepository()
        let viewModel = SettingsViewModel(
            repository: repository,
            versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"),
            releaseBuild: true,
            tokenBridge: bridge
        )
        let configured = SettingsSnapshot(
            appearance: .dark,
            accessibility: AccessibilitySettings(reduceMotionOverride: true, increasedContrastPreview: true)
        )

        try await viewModel.update(configured)
        let configuredTokens = await bridge.state()
        XCTAssertEqual(configuredTokens, DesignSystemTokenState(appearance: .dark, increasedContrastPreview: true, reduceMotionOverride: true))
        try await viewModel.reset(section: .appearance)
        let resetTokens = await bridge.state()
        XCTAssertEqual(resetTokens, DesignSystemTokenState())
    }

    func testPlatformEntryPointsExposeExplicitPermissionAndUnavailableStates() async throws {
        let health = TestHealthKitEntryPoint()
        let notifications = TestNotificationEntryPoint()
        let ai = TestAIPrivacyEntryPoint()
        let viewModel = SettingsViewModel(
            repository: InMemorySettingsRepository(),
            versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"),
            releaseBuild: true,
            integrationClients: SettingsIntegrationClients(healthKit: health, notifications: notifications, aiPrivacy: ai)
        )

        let initialHealthState = await viewModel.integrationState(for: .healthKit)
        XCTAssertEqual(initialHealthState, .permissionRequired)
        let requestedHealthState = await viewModel.requestPermission(for: .healthKit)
        XCTAssertEqual(requestedHealthState, .available)
        let initialNotificationState = await viewModel.integrationState(for: .notifications)
        XCTAssertEqual(initialNotificationState, .denied)
        let aiState = try await viewModel.setAIPrivacyEnabled(true)
        XCTAssertEqual(aiState, .available)
        let aiEnabled = await ai.enabled
        XCTAssertTrue(aiEnabled)
        var preferences = await viewModel.notificationPreferences()
        XCTAssertEqual(preferences.map(\.isEnabled), [true, false])
        try await viewModel.setNotificationPreference(id: "battery", enabled: false)
        preferences = await viewModel.notificationPreferences()
        XCTAssertEqual(preferences.map(\.isEnabled), [false, false])

        let unavailable = SettingsViewModel(
            repository: InMemorySettingsRepository(),
            versions: VersionRegistry(appVersion: "1", algorithmVersion: 1, protocolVersion: "1"),
            releaseBuild: true,
            integrationClients: SettingsIntegrationClients()
        )
        let unavailableHealthState = await unavailable.integrationState(for: .healthKit)
        XCTAssertEqual(unavailableHealthState, .unavailable)
        do {
            try await unavailable.resetIntegration(.notifications)
            XCTFail("missing notification adapter must fail closed")
        } catch SettingsError.integrationUnavailable { }
    }

    func testEachLocalSettingsSectionResetsWithoutTouchingOtherSections() async throws {
        let initial = SettingsSnapshot(
            profile: ProfileSettings(displayName: "Sam", age: 34),
            units: .imperial,
            appearance: .dark,
            accessibility: AccessibilitySettings(reduceMotionOverride: true, increasedContrastPreview: true, voiceOverHints: false),
            goals: GoalSettings(stepGoal: 8_000, strainTarget: 12),
            surfacePrivacy: SurfacePrivacySettings(todayWidget: false, batteryWidget: false, watchSnapshot: false, liveActivity: false)
        )
        let repository = InMemorySettingsRepository(initial: initial)
        for section in [SettingsResetSection.profile, .units, .appearance, .accessibility, .goals, .surfacePrivacy] {
            try await repository.update(initial)
            try await repository.reset(section: section)
            let value = await repository.snapshot()
            switch section {
            case .profile: XCTAssertEqual(value.profile, ProfileSettings())
            case .units: XCTAssertEqual(value.units, .metric)
            case .appearance: XCTAssertEqual(value.appearance, .system)
            case .accessibility: XCTAssertEqual(value.accessibility, AccessibilitySettings())
            case .goals: XCTAssertEqual(value.goals, GoalSettings())
            case .surfacePrivacy: XCTAssertEqual(value.surfacePrivacy, SurfacePrivacySettings())
            case .healthKit, .notifications, .aiPrivacy: XCTFail("platform sections are injected owners")
            }
        }
    }

    func testVersionProviderAndAllSurfacePrivacyControlsAreTyped() async throws {
        let registry = StaticSettingsVersionRegistryProvider(VersionRegistry(appVersion: "2.4", algorithmVersion: 7, protocolVersion: "ble-08"))
        let currentVersion = await registry.current()
        XCTAssertEqual(currentVersion, VersionRegistry(appVersion: "2.4", algorithmVersion: 7, protocolVersion: "ble-08"))

        let snapshot = SettingsSnapshot(surfacePrivacy: SurfacePrivacySettings(todayWidget: false, batteryWidget: true, watchSnapshot: false, liveActivity: true))
        XCTAssertFalse(snapshot.includesData(on: .todayWidget))
        XCTAssertTrue(snapshot.includesData(on: .batteryWidget))
        XCTAssertFalse(snapshot.surfaceSnapshot(for: .watchSnapshot).includesHealthData)
        XCTAssertTrue(snapshot.surfaceSnapshot(for: .liveActivity).includesHealthData)
        XCTAssertTrue(SettingsRouteDestination.allCases.contains(.healthKit))
        XCTAssertTrue(SettingsRouteDestination.allCases.contains(.notifications))
        XCTAssertTrue(SettingsRouteDestination.allCases.contains(.aiPrivacy))
        XCTAssertTrue(SettingsRouteDestination.allCases.contains(.hiddenDiagnostics))
    }

    func testReleaseNavigationExcludesGalleryAndProtocolConsole() {
        let releaseGate = HiddenDiagnosticsGate(releaseBuild: true)
        XCTAssertFalse(releaseGate.canOpen(route: .hiddenDiagnostics))
        XCTAssertFalse(SettingsRoute.allCases.map(\.rawValue).contains("designGallery"))
        XCTAssertFalse(SettingsRoute.allCases.map(\.rawValue).contains("protocolConsole"))
    }

    func testCanonicalGoalsEditorUsesProfileKitRepositoryOnly() async throws {
        let repository = InMemoryProfileRepository()
        let model = await MainActor.run { CanonicalGoalsEditorModel(repository: repository) }
        await model.load()
        await MainActor.run {
            model.setDraft("9000", for: .steps)
            model.setEnabled(true, for: .steps)
        }
        await model.save(.steps)

        let goals = try await repository.readGoals()
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals.first?.type, .steps)
        XCTAssertEqual(goals.first?.target, 9000)
        XCTAssertEqual(goals.first?.unit, "steps")
        let state = await model.state
        if case .saved(.steps) = state {
            // expected
        } else {
            XCTFail("canonical goal save should report success")
        }
    }

    func testSurfacePrivacyGateFailsClosedAndDoesNotPublishDisabledData() async {
        let gate = SettingsSurfacePrivacyGate()
        let privateSettings = SettingsSnapshot(surfacePrivacy: SurfacePrivacySettings(
            todayWidget: false,
            batteryWidget: true,
            watchSnapshot: false,
            liveActivity: true
        ))
        let today = await gate.decision(for: .todayWidget, settings: privateSettings)
        let battery = await gate.decision(for: .batteryWidget, settings: privateSettings)
        XCTAssertTrue(today.isRedacted)
        XCTAssertFalse(today.includesHealthData)
        XCTAssertFalse(battery.isRedacted)
        XCTAssertTrue(battery.includesHealthData)

        let unavailable = await UnavailableSurfacePrivacyConsumer().decision(
            for: .liveActivity,
            settings: SettingsSnapshot()
        )
        XCTAssertTrue(unavailable.isRedacted)
    }

    func testInMemoryTokenBridgeAppliesDesignSystemRuntime() async throws {
        let bridge = InMemoryDesignSystemTokenBridge()
        try await bridge.apply(DesignSystemTokenState(
            appearance: .dark,
            increasedContrastPreview: true,
            reduceMotionOverride: true
        ))
        let state = DesignSystemRuntime.state()
        XCTAssertEqual(state.appearance, .dark)
        XCTAssertTrue(state.increasedContrast)
        XCTAssertEqual(state.reduceMotion, true)
        try await bridge.reset()
        XCTAssertEqual(DesignSystemRuntime.state(), LooprDesignSystemRuntimeState())
    }
}
