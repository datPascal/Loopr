import Testing
import Foundation
import BluetoothKit
import DeviceCenterKit
import DesignSystem
import DomainKit
import HealthKitBridge
import OnboardingKit
import ProfileKit
import SleepKit
import StorageKit
import SyncKit
import TodayKit
import WorkoutKit
@testable import Loopr

struct LooprTests {
    @Test func launchModeParsesEveryDeterministicProductMode() {
        #expect(LaunchMode.allCases.map(\.rawValue) == ["onboarding", "pairing", "empty", "populated", "stale", "disconnected", "activeWorkout", "connectedMixedCapabilities"])
        for mode in LaunchMode.allCases {
            #expect(LaunchModeParser.parse(arguments: ["app", "--loopr-launch-mode=\(mode.rawValue)"], environment: [:]) == mode)
        }
    }

    @Test func launchModeUnknownAndAbsentSelectProduction() {
        #expect(LaunchModeParser.parse(arguments: ["app"], environment: [:]) == nil)
        #expect(LaunchModeParser.parse(arguments: ["app", "--loopr-launch-mode=unknown"], environment: [:]) == nil)
        #expect(AppEnvironment.make(arguments: ["app"], environment: [:]).composition == .production)
        #expect(AppEnvironment.make(arguments: ["app", "--loopr-launch-mode=unknown"], environment: [:]).composition == .production)
    }

    @Test func launchArgumentTakesPrecedenceOverEnvironment() {
        #expect(LaunchModeParser.parse(arguments: ["app", "--loopr-launch-mode=empty"], environment: ["LOOPR_LAUNCH_MODE": "populated"]) == .empty)
    }

    #if DEBUG
    @Test func debugFixtureCompositionsAreDistinctAndDeterministic() {
        let compositions = LaunchMode.allCases.map { mode in AppEnvironment.make(arguments: ["app", "--loopr-launch-mode=\(mode.rawValue)"], environment: [:]).composition }
        #expect(Set(compositions).count == LaunchMode.allCases.count)
        #expect(compositions == LaunchMode.allCases.map { AppEnvironment.make(arguments: ["app", "--loopr-launch-mode=\($0.rawValue)"], environment: [:]).composition })
    }
    #else
    @Test func releaseConfigurationFixtureAndResearchCodeUnreachable() {
        for mode in LaunchMode.allCases {
            #expect(AppEnvironment.make(arguments: ["app", "--loopr-launch-mode=\(mode.rawValue)"], environment: ["LOOPR_LAUNCH_MODE": mode.rawValue]).composition == .production)
        }
    }
    #endif

    @Test func shellUsesCanonicalEdgeTabOrder() {
        #expect(MainTab.allCases.map(\.rawValue) == ["today", "sleep", "heart", "body", "workouts"])
    }

    @Test func completedWorkoutReplacesLiveAndKeepsUUIDThroughDetail() {
        let workout = WorkoutFixtures.completedRun
        let completedPath = AppWorkoutPathTransition.replacingLiveWithCompletedSummary(
            in: [.startPicker, .live(workout.id, workout.activity)],
            workoutID: workout.id
        )
        #expect(completedPath == [.startPicker, .finish(workout.id)])

        let action = WorkoutFinishSummaryAction(workout: workout)
        #expect(AppWorkoutPathTransition.detailDestination(for: action) == .detail(workout.id))
    }

    @Test func persistentProductRepositoriesRoundTripAndKeepDestructiveScopesSeparate() async throws {
        let suiteName = "LooprTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let onboarding = PersistentOnboardingRepository(defaults: defaults)
        let onboardingValue = OnboardingSnapshot(stage: .profileSetup, pairingRequested: true, lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await onboarding.save(onboardingValue)
        #expect(try await onboarding.load() == onboardingValue)

        let profile = PersistentProfileRepository(defaults: defaults)
        _ = try await profile.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        _ = try await profile.saveGoal(type: .steps, target: 8_000, unit: "steps", isEnabled: true)
        try await profile.resetProfile()
        #expect(try await profile.readProfile() == nil)
        #expect(try await profile.readGoals().isEmpty)

        let device = PersistentDeviceCenterRepository(defaults: defaults)
        try await device.saveIdentity(DeviceCenterStateFixtures.sampleDevice)
        #expect(try await device.readIdentity() == DeviceCenterStateFixtures.sampleDevice)
        await device.forgetBand()
        #expect(try await device.readIdentity() == nil)
    }

    @Test
    func profileGoalsRefreshTodayTargetsWithoutCalculatingMetricValues() async throws {
        let current = TodayGoalProgress(id: "steps", title: "Steps", value: "4,200", target: "10,000", unit: "steps", state: .partial, progressFraction: 0.42)
        let today = InMemoryTodayGoalsRepository(values: [TodayFixtures.day: [current]])
        let configured = Goal(id: UUID(), type: .steps, target: 8_000, unit: "steps", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let profile = InMemoryProfileRepository(goals: [configured])
        let adapter = ProfileBackedTodayGoalsRepository(today: today, profile: profile)

        let refreshed = try await adapter.readGoals(for: TodayFixtures.day)

        #expect(refreshed.first?.target == "8000")
        #expect(refreshed.first?.title == "Estimated steps")
        #expect(refreshed.first?.value == "4,200")
        #expect(refreshed.first?.progressFraction == nil)
        #expect(refreshed.first?.state == .settling)
    }

    @Test func savedSleepNeedSurvivesRepositoryReopenAndFeedsBothTabs() async throws {
        let suiteName = "LooprTests.sleepNeed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = PersistentProfileRepository(defaults: defaults)
        #expect(SleepNeed.minutes(from: try await first.readGoals()) == 480)
        _ = try await first.saveGoal(type: .sleep, target: 7.5, unit: "hours", isEnabled: true)
        let reopened = PersistentProfileRepository(defaults: defaults)
        let saved = try await reopened.readGoals()
        #expect(SleepGoalReading.minutes(saved) == 450)
        let adapter = ProfileBackedTodayGoalsRepository(
            today: InMemoryTodayGoalsRepository(), profile: reopened)
        let todayGoals = try await adapter.readGoals(for: TodayFixtures.day)
        #expect(TodaySleepNeed.minutes(from: todayGoals) == 450)
        #expect(SleepTarget.resolve(needHours: 9, goalMinutes: SleepGoalReading.minutes(saved),
                                    history: SleepNightHistory(trend: [], day: TodayFixtures.day)).minutes == 450)
    }

    #if DEBUG
    @Test func fixtureDeepLinksAreTypedAndFailClosed() {
        #expect(ShellDeepLink.parse(arguments: ["app", "--loopr-deep-link=heart/detail"]) == .heartDetail)
        #expect(ShellDeepLink.parse(arguments: ["app", "--loopr-deep-link=unknown"]) == nil)
        #expect(ShellDeepLink.parse(arguments: ["app"]) == nil)
    }
    #endif

    @Test @MainActor
    func productionBluetoothRuntimeFactoryIsNotAFixture() {
        let model = BluetoothApplicationModel.production()
        #if canImport(CoreBluetooth)
        #expect(model.runtimeFactory is CoreBluetoothRuntimeFactoryAdapter)
        #else
        #expect(!(model.runtimeFactory is FailingBluetoothRuntimeFactory))
        #endif
    }

    @Test @MainActor
    func launchInspectionDoesNotCreateRuntimeBeforeProvisioning() async {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .noResult,
            pairOutcome: .explanationRequired,
            continueOutcome: .provisioned(identifier)
        )
        let runtime = TestBluetoothRuntime(initialState: .scanning)
        let factory = TestRuntimeFactory(runtime: runtime)
        let model = BluetoothApplicationModel(provisioning: provisioning, runtimeFactory: factory)

        await model.inspectProvisioningOnLaunch()
        #expect(model.status == .needsPairing)
        #expect(await factory.makeCalls().isEmpty)

        await model.userTappedPair()
        #expect(model.status == .explanationRequired)
        #expect(await factory.makeCalls().isEmpty)

        await model.continueAfterExplanation()
        #expect(await factory.makeCalls() == [identifier])
        #expect(await runtime.startCount() == 1)
        #expect(model.status == .scanning)
    }

    @Test @MainActor
    func persistedLaunchWaitsForRuntimeBeforeMainSurfaceIsReady() async {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000044")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .alreadyProvisioned(identifier),
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let runtime = TestBluetoothRuntime(initialState: .subscribing)
        let factory = TestRuntimeFactory(runtime: runtime)
        let model = BluetoothApplicationModel(provisioning: provisioning, runtimeFactory: factory)

        #expect(!model.didFinishLaunchInspection)
        #expect(!model.isMainSurfaceReady)

        await model.inspectProvisioningOnLaunch()

        #expect(model.didFinishLaunchInspection)
        #expect(model.isMainSurfaceReady)
        #expect(model.heartLiveRuntime() != nil)
        #expect(await factory.makeCalls() == [identifier])
    }

    @Test @MainActor
    func acknowledgedBackgroundDrainSavesHealthBeforeReportingSuccess() async throws {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .alreadyProvisioned(identifier),
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let bluetooth = TestBluetoothRuntime(initialState: .subscribing)
        let budget = LooprDerivationBudget(foreground: LooprFixedForegroundState(false))
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: bluetooth),
            backgroundBudget: budget
        )
        await model.inspectProvisioningOnLaunch()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("background-health-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let start: Int64 = 1_788_739_200
        for second in 0..<60 {
            try history.replaceHistoricalSecond(StoredHistoricalRecord(
                physiologicalTimestamp: start + Int64(second),
                bandCounter: UInt32(second),
                absoluteTimestamp: start + Int64(second),
                localDay: "2026-09-07",
                version: 24,
                heartRate: 60
            ))
        }
        let dates = WP6TestDate(value: Date(timeIntervalSince1970: Double(start + 120)))
        let analytics = try CanonicalDailyAnalytics(
            history: history,
            products: products,
            profile: InMemoryProfileRepository(),
            dateProvider: dates,
            timeZoneProvider: HealthExportTimeZone(timeZone: .gmt)
        )
        let client = WP6HealthClient()
        await client.allow([.heartRate])
        // The background budget is process-wide in the app. Give this test
        // its own budget and mark the seeded history as a new commit, as the
        // Bluetooth offload does before asking for a Health export.
        await budget.noteHistoryCommit()
        let health = try LooprHealthSyncRuntime(
            history: history,
            analytics: analytics,
            workouts: InMemoryWorkoutStore(),
            store: try SQLiteHealthSyncStore(database: products, timeZone: "UTC"),
            dates: dates,
            client: client,
            budget: budget
        )
        model.bindBackgroundHealthSync(health)

        let success = await model.runBackgroundTask(identifier: LooprBluetoothBackgroundTaskID.sync)

        #expect(success)
        #expect(await bluetooth.backgroundRunCount() == 1)
        #expect(await client.saved().contains { $0.metric == .heartRate })
    }

    @Test @MainActor
    func launchWithoutProvisionedAccessoryReleasesMainSurfaceGate() async {
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .noResult,
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle))
        )

        await model.inspectProvisioningOnLaunch()

        #expect(model.status == .needsPairing)
        #expect(model.didFinishLaunchInspection)
        #expect(model.isMainSurfaceReady)
        #expect(model.heartLiveRuntime() == nil)
    }

    @Test @MainActor
    func deferredPairingCanBeStartedFromTheMainSurface() async {
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .noResult,
            pairOutcome: .explanationRequired,
            continueOutcome: .noResult
        )
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle))
        )

        await model.inspectProvisioningOnLaunch()
        #expect(model.canOfferPairing)

        await model.userTappedPair()
        #expect(model.status == .explanationRequired)
        #expect(!model.canOfferPairing)
        #expect(await provisioning.calls() == ["inspectExisting", "userTappedPair"])

        model.cancelExplanation()
        #expect(model.canOfferPairing)
    }

    @Test @MainActor
    func provisionedLaunchRejectsRuntimeWithoutHeartAndDeviceCenterCapabilities() async {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .alreadyProvisioned(identifier),
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let runtime = GenericTestBluetoothRuntime()
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: runtime)
        )

        await model.inspectProvisioningOnLaunch()

        #expect(!model.hasSharedProductRuntimeCapabilities)
        #expect(model.heartLiveRuntime() == nil)
        // The engineering reason goes to the debug log; the person reads calm copy.
        #expect(model.status == .failed(BluetoothApplicationModel.runtimeInstallFailureCopy))
        #expect(model.isMainSurfaceReady)
        #expect(await runtime.stopCount() == 1)
    }

    @Test @MainActor
    func cancelledInspectionCallerDoesNotStrandRetainedLaunchInspection() async {
        let provisioning = BlockingProvisioningFlow(outcome: .noResult)
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle))
        )

        let firstCaller = Task { await model.inspectProvisioningOnLaunch() }
        await provisioning.waitUntilInspectionStarted()
        firstCaller.cancel()
        let secondCaller = Task { await model.inspectProvisioningOnLaunch() }
        await provisioning.finishInspection()
        await secondCaller.value

        #expect(model.didFinishLaunchInspection)
        #expect(model.status == .needsPairing)
        #expect(await provisioning.inspectCallCount() == 1)
    }

    @Test @MainActor
    func startupFailureCanRebuildDependenciesAndRetryInspection() async {
        let recoveredProvisioning = TestProvisioningFlow(
            inspectOutcome: .noResult,
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let recoveredFactory = TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle))
        var recoveryCalls = 0
        let initialError = ProductStorageInitializationFailure(message: "Protected history unavailable")
        let model = BluetoothApplicationModel(
            provisioning: recoveredProvisioning,
            runtimeFactory: recoveredFactory,
            startupError: initialError.localizedDescription,
            startupRecovery: {
                recoveryCalls += 1
                return BluetoothApplicationDependencies(
                    provisioning: recoveredProvisioning,
                    runtimeFactory: recoveredFactory
                )
            }
        )

        await model.inspectProvisioningOnLaunch()
        #expect(model.startupFailureMessage != nil)
        #expect(model.status == .failed(initialError.localizedDescription))

        await model.retryStartup()

        #expect(recoveryCalls == 1)
        #expect(model.startupFailureMessage == nil)
        #expect(model.didFinishLaunchInspection)
        #expect(model.status == .needsPairing)
        #expect(model.isMainSurfaceReady)
    }

    @Test @MainActor
    func installAndRemoveAreSerializedAndAdvanceRuntimeBindingGeneration() async {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000046")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .alreadyProvisioned(identifier),
            pairOutcome: .noResult,
            continueOutcome: .noResult
        )
        let runtime = TestBluetoothRuntime(initialState: .subscribing)
        let factory = BlockingRuntimeFactory(runtime: runtime)
        let model = BluetoothApplicationModel(provisioning: provisioning, runtimeFactory: factory)

        let inspection = Task { await model.inspectProvisioningOnLaunch() }
        await factory.waitUntilMakeStarted()
        let removal = Task { await model.removePairing() }
        await Task.yield()
        #expect(await provisioning.calls() == ["inspectExisting"])

        await factory.finishMake()
        await inspection.value
        await removal.value

        #expect(await factory.maximumConcurrentMakeCount() == 1)
        #expect(await runtime.startCount() == 1)
        #expect(await runtime.stopCount() == 1)
        #expect(model.runtimeGeneration == 2)
        #expect(model.heartLiveRuntime() == nil)
        #expect(model.status == .removed)
    }

    @Test @MainActor
    func modelOwnedDeletionStopsThenClearsRuntimeAndAllowsRepair() async throws {
        let firstIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000047")!
        let secondIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000048")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .alreadyProvisioned(firstIdentifier),
            pairOutcome: .provisioned(secondIdentifier),
            continueOutcome: .noResult
        )
        let runtime = TestBluetoothRuntime(initialState: .subscribing)
        let factory = TestRuntimeFactory(runtime: runtime)
        let model = BluetoothApplicationModel(provisioning: provisioning, runtimeFactory: factory)

        await model.inspectProvisioningOnLaunch()
        try await BluetoothModelRuntimeDataDeleter(model: model).deleteAll()

        #expect(await runtime.stopCount() == 1)
        #expect(await runtime.clearCount() == 1)
        #expect(await runtime.lifecycleEvents() == ["stop", "clear"])
        #expect(model.status == .removed)
        #expect(model.heartLiveRuntime() == nil)

        await model.userTappedPair()
        #expect(await factory.makeCalls() == [firstIdentifier, secondIdentifier])
        #expect(await runtime.startCount() == 2)
        #expect(model.hasSharedProductRuntimeCapabilities)
    }

    @Test
    func onlyConnectedStatusMayClaimStrapConnected() {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000049")!
        let nonConnected: [BluetoothApplicationStatus] = [
            .checkingProvisioning, .needsPairing, .explanationRequired, .pickerPresented,
            .preparing(identifier), .retrieving, .scanning, .connecting, .discovering,
            .subscribing, .disconnected(identifier, reason: "Out of range"),
            .bluetoothOff(identifier), .cancelled, .removing(identifier), .removed,
            .failed("Unavailable")
        ]
        #expect(nonConnected.allSatisfy { !$0.isConnected })
        #expect(BluetoothApplicationStatus.connected(identifier).isConnected)
    }

    @Test @MainActor
    func productionStorageFailureThenRetryRebuildsPersistentFeatureAndOnboardingGraphs() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprTests.\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let environment = AppEnvironment(
            composition: .production,
            root: .main,
            storageURL: databaseURL,
            applicationVersion: "LooprTests (1)",
            dateProvider: SystemDateProvider(),
            calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
            uuidProvider: SystemUUIDProvider(),
            scheduler: SystemScheduler()
        )
        var attempts = 0
        let repositories = ProductRepositoryContainer(
            environment: environment,
            productionFactory: { environment, runtime, runtimeDataDeleter in
                attempts += 1
                if attempts == 1 {
                    throw ProductStorageInitializationFailure(message: "Forced first-open failure")
                }
                return try PersistentProductRepositories(
                    environment: environment,
                    heartLiveRuntime: runtime,
                    runtimeDataDeleter: runtimeDataDeleter
                )
            }
        )
        #expect(repositories.storageFailure != nil)
        #expect(repositories.persistent == nil)
        #expect(repositories.graphIdentity == .unavailable(1))
        #expect(ProductOnboardingRoot.presentationState(
            storageFailure: repositories.storageFailure,
            snapshot: nil
        ) == .storageUnavailable)

        let firstGeneration = repositories.storageGeneration
        repositories.retry()

        #expect(repositories.storageFailure == nil)
        #expect(repositories.persistent != nil)
        #expect(repositories.storageGeneration == firstGeneration + 1)
        #expect(repositories.graphIdentity == .persistent(2))
        #expect(attempts == 2)

        let persistent = try #require(repositories.persistent)
        let durableSummary = TodayFixtures.summary(for: .stale)
        try await persistent.today.saveSummary(durableSummary)
        try await persistent.today.saveGoals(durableSummary.goals, for: durableSummary.day)
        let postRetryViewModel = ProductFeatureViewModelFactory.makeToday(
            environment: environment,
            repositories: repositories
        )
        await postRetryViewModel.load(day: durableSummary.day)
        #expect(postRetryViewModel.summary?.overallState == .stale)

        let durableSnapshot = OnboardingSnapshot(
            stage: .profileSetup,
            pairingRequested: false,
            lastUpdatedAt: environment.dateProvider.now()
        )
        try await persistent.onboarding.save(durableSnapshot)
        let bluetoothModel = BluetoothApplicationModel(
            provisioning: TestProvisioningFlow(
                inspectOutcome: .noResult,
                pairOutcome: .noResult,
                continueOutcome: .noResult
            ),
            runtimeFactory: TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle))
        )
        let prepared = try await ProductOnboardingProductionPreparation.prepare(
            environment: environment,
            repositories: repositories,
            bluetoothModel: bluetoothModel
        )
        #expect(prepared.snapshot == durableSnapshot)
        #expect(ProductOnboardingRoot.presentationState(
            storageFailure: repositories.storageFailure,
            snapshot: prepared.snapshot
        ) == .ready(.profileSetup))
    }

    @Test @MainActor
    func pairActionsAreExplicitAndConnectedOnlyAfterRuntimeReady() async {
        let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .noResult,
            pairOutcome: .explanationRequired,
            continueOutcome: .provisioned(identifier)
        )
        let runtime = TestBluetoothRuntime(initialState: .subscribing)
        let factory = TestRuntimeFactory(runtime: runtime)
        let model = BluetoothApplicationModel(provisioning: provisioning, runtimeFactory: factory)

        await model.userTappedPair()
        #expect(model.status == .explanationRequired)
        #expect(await provisioning.calls() == ["userTappedPair"])

        await model.continueAfterExplanation()
        #expect(model.status == .subscribing)
        #expect(await provisioning.calls() == ["userTappedPair", "continueAfterExplanation"])
        #expect(!model.status.isConnected)
        #expect(!model.canReportStrapConnected)

        await runtime.emit(.ready(identifier))
        for _ in 0..<100 where model.status != .connected(identifier) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.status == .connected(identifier))
        #expect(model.status.isConnected)
        #expect(model.canReportStrapConnected)
    }

    @Test
    func bluetoothBackgroundTaskIdentifiersArePinned() {
        #expect(LooprBluetoothBackgroundTaskID.sync == "com.loopr.bluetooth.sync")
        #expect(LooprBluetoothBackgroundTaskID.refresh == "com.loopr.bluetooth.refresh")
        #expect(LooprBluetoothBackgroundTaskID.all == [
            "com.loopr.bluetooth.sync",
            "com.loopr.bluetooth.refresh"
        ])
    }

    @Test @MainActor
    func failedStoreStartupNeverInspectsProvisioning() async {
        let provisioning = TestProvisioningFlow(
            inspectOutcome: .noResult, pairOutcome: .noResult, continueOutcome: .noResult
        )
        let model = BluetoothApplicationModel(
            provisioning: provisioning,
            runtimeFactory: TestRuntimeFactory(runtime: TestBluetoothRuntime(initialState: .idle)),
            startupReadiness: { throw StartupReadinessTestError.unavailable }
        )

        await model.inspectProvisioningOnLaunch()

        #expect(model.didFinishLaunchInspection)
        #expect(model.startupFailureMessage != nil)
        #expect(await provisioning.calls().isEmpty)
    }
}

private enum StartupReadinessTestError: Error { case unavailable }

private actor TestProvisioningFlow: LooprAccessoryProvisioningFlow {
    let inspectOutcome: AccessoryProvisioningOutcome
    let pairOutcome: AccessoryProvisioningOutcome
    let continueOutcome: AccessoryProvisioningOutcome
    private var recordedCalls: [String] = []

    init(
        inspectOutcome: AccessoryProvisioningOutcome,
        pairOutcome: AccessoryProvisioningOutcome,
        continueOutcome: AccessoryProvisioningOutcome
    ) {
        self.inspectOutcome = inspectOutcome
        self.pairOutcome = pairOutcome
        self.continueOutcome = continueOutcome
    }

    func inspectExisting() async -> AccessoryProvisioningOutcome {
        recordedCalls.append("inspectExisting")
        return inspectOutcome
    }

    func userTappedPair() async -> AccessoryProvisioningOutcome {
        recordedCalls.append("userTappedPair")
        return pairOutcome
    }

    func continueAfterExplanation() async -> AccessoryProvisioningOutcome {
        recordedCalls.append("continueAfterExplanation")
        return continueOutcome
    }

    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome {
        recordedCalls.append("removeProvisionedAccessory")
        return .removed
    }

    func calls() -> [String] { recordedCalls }
}

private actor TestRuntimeFactory: LooprBluetoothRuntimeFactory {
    let runtime: any LooprBluetoothAdoptionRuntime
    private var recordedIdentifiers: [UUID] = []

    init(runtime: any LooprBluetoothAdoptionRuntime) { self.runtime = runtime }

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime {
        recordedIdentifiers.append(identifier)
        return runtime
    }

    func makeCalls() -> [UUID] { recordedIdentifiers }
}

private actor BlockingProvisioningFlow: LooprAccessoryProvisioningFlow {
    let outcome: AccessoryProvisioningOutcome
    private var calls = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var inspectionContinuation: CheckedContinuation<AccessoryProvisioningOutcome, Never>?

    init(outcome: AccessoryProvisioningOutcome) { self.outcome = outcome }

    func inspectExisting() async -> AccessoryProvisioningOutcome {
        calls += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            inspectionContinuation = continuation
        }
    }

    func waitUntilInspectionStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishInspection() {
        inspectionContinuation?.resume(returning: outcome)
        inspectionContinuation = nil
    }

    func inspectCallCount() -> Int { calls }
    func userTappedPair() async -> AccessoryProvisioningOutcome { .noResult }
    func continueAfterExplanation() async -> AccessoryProvisioningOutcome { .noResult }
    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome { .removed }
}

private actor BlockingRuntimeFactory: LooprBluetoothRuntimeFactory {
    let runtime: any LooprBluetoothAdoptionRuntime
    private var activeMakes = 0
    private var maximumMakes = 0
    private var makeStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var makeContinuation: CheckedContinuation<Void, Never>?

    init(runtime: any LooprBluetoothAdoptionRuntime) { self.runtime = runtime }

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime {
        activeMakes += 1
        maximumMakes = max(maximumMakes, activeMakes)
        makeStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            makeContinuation = continuation
        }
        activeMakes -= 1
        return runtime
    }

    func waitUntilMakeStarted() async {
        if makeStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishMake() {
        makeContinuation?.resume()
        makeContinuation = nil
    }

    func maximumConcurrentMakeCount() -> Int { maximumMakes }
}

private actor GenericTestBluetoothRuntime: LooprBluetoothAdoptionRuntime {
    private var stops = 0

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        AsyncStream { continuation in continuation.finish() }
    }
    func state() async -> LooprBluetoothRuntimeState { .idle }
    func start() async {}
    func stop() async { stops += 1 }
    func enterForeground() async {}
    func enterBackground() async {}
    func runBackground(kind: BackgroundRunKind) async -> Bool { false }
    func expireBackground() async {}
    func stopCount() -> Int { stops }
}

private actor TestBluetoothRuntime: LooprBluetoothAdoptionRuntime, LooprDeviceCenterRuntime, PersistentDataDeletionDeleter {
    private var current: LooprBluetoothRuntimeState
    private var continuation: AsyncStream<LooprBluetoothRuntimeState>.Continuation?
    private var starts = 0
    private var stops = 0
    private var clears = 0
    private var backgroundRuns = 0
    private var recordedLifecycleEvents: [String] = []

    init(initialState: LooprBluetoothRuntimeState) {
        self.current = initialState
    }

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        let pair = AsyncStream<LooprBluetoothRuntimeState>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func state() async -> LooprBluetoothRuntimeState { current }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        testDeviceRuntimeState()
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { true }

    nonisolated var storeName: String { "test.runtime" }

    func deleteAll() async throws {
        clears += 1
        recordedLifecycleEvents.append("clear")
    }

    func start() async {
        starts += 1
        continuation?.yield(current)
    }

    func stop() async {
        stops += 1
        recordedLifecycleEvents.append("stop")
    }
    func enterForeground() async {}
    func enterBackground() async {}
    func runBackground(kind: BackgroundRunKind) async -> Bool {
        backgroundRuns += 1
        return true
    }
    func expireBackground() async {}

    func emit(_ state: LooprBluetoothRuntimeState) {
        current = state
        continuation?.yield(state)
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func clearCount() -> Int { clears }
    func lifecycleEvents() -> [String] { recordedLifecycleEvents }
    func backgroundRunCount() -> Int { backgroundRuns }
}

private struct WP6TestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

private actor WP6HealthClient: HealthSyncClient {
    private var granted: Set<ExportMetricKind> = []
    private var writes: [HealthSyncSample] = []

    func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState {
        granted.contains(metric) ? .authorized : .notDetermined
    }
    func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws {}
    func save(_ sample: HealthSyncSample, version: Int) async throws { writes.append(sample) }
    func remove(metric: ExportMetricKind, identifiers: [String]) async throws {}
    func allow(_ metrics: Set<ExportMetricKind>) { granted = metrics }
    func saved() -> [HealthSyncSample] { writes }
}

private func testDeviceRuntimeState() -> BluetoothAdoptionRuntimeState {
    BluetoothAdoptionRuntimeState(
        running: true,
        generation: 1,
        connection: .listening(
            generation: 1,
            peripheral: UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        ),
        setupReady: true,
        setupComplete: true,
        radioState: .poweredOn,
        health: ConnectionHealthReport(
            healthy: true,
            stale: false,
            shouldBounce: false,
            ageOfLatestObservation: 1,
            corruptionRate: 0,
            reasons: []
        ),
        pendingReconnect: nil,
        liveConsumerCount: 0,
        pendingHistoryReplayCount: 0,
        validFrameCount: 1,
        corruptFrameCount: 0,
        writeTimeoutCount: 0,
        lastError: nil
    )
}
