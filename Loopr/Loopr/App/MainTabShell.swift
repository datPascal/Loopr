import AnalyticsKit
import BodyKit
import BluetoothKit
import Combine
import CycleKit
import DataKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import HeartKit
import JournalKit
import NotificationKit
import ProfileKit
import ProtocolKit
import SyncKit
import RecordsKit
import RouteKit
import SettingsKit
import SleepKit
import StressKit
import SwiftUI
import TodayKit
import WorkoutKit

enum MainTab: String, CaseIterable, Hashable {
    case today
    case sleep
    case heart
    case body
    case workouts

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .today: "house"
        case .sleep: "moon.stars"
        case .heart: "heart"
        case .body: "figure.strengthtraining.traditional"
        case .workouts: "figure.run"
        }
    }

    var accent: LooprColorToken {
        switch self {
        case .today: .brand
        case .sleep: .sleep
        case .heart: .heart
        case .body: .strain
        case .workouts: .movement
        }
    }
}

@MainActor
private final class TodayNavigationState: ObservableObject {
    @Published var path: [AppTodayRoute] = []
}

/// The only place in the shell that reads the band state.
///
/// It reads the debounced `BandLinkPresentation`, never the raw Bluetooth
/// status, so a reconnect that takes a second changes nothing below it. Only
/// this small body re-runs when the band state moves, and the tree below is
/// re-read only where `\.bandConnected` or `\.looprBandIndicator` is used.
private struct BandConnectionBridge: ViewModifier {
    let storageGeneration: UInt64
    let healthSync: (any LooprBackgroundHealthSynchronizing)?
    /// The battery a fixture launch shows on every tab's band button. Nil in
    /// production, where the battery comes from the band.
    let fixtureBatteryPercent: Int?
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.looprBluetoothModel) private var bluetoothModel
    #if DEBUG
    @State private var debugBatteryPercent: Int?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.bandConnected, bandLink?.state.isConnectedOrQuiet ?? false)
            .environment(\.looprBandIndicator, indicator)
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugLivePerformance.batteryChanged)) { event in
                guard DebugLivePerformance.enabled, fixtureBatteryPercent != nil,
                      let tick = event.object as? Int else { return }
                debugBatteryPercent = tick.isMultiple(of: 20) ? 79 : 80
            }
            #endif
            .task(id: storageGeneration) {
                guard let healthSync else { return }
                bluetoothModel?.bindBackgroundHealthSync(healthSync)
            }
    }

    private var indicator: LooprBandIndicator? {
        guard var fixture = fixtureBatteryPercent else { return bandLink?.indicator }
        #if DEBUG
        fixture = debugBatteryPercent ?? fixture
        #endif
        // The fixture stands for a paired band that is linked, so every tab
        // shows its battery and the header its sync age.
        var indicator = bandLink?.indicator ?? LooprBandIndicator(link: .connected)
        indicator.link = .connected
        indicator.batteryPercent = fixture
        #if DEBUG
        indicator = DebugCaptureFixtures.indicator(indicator)
        #endif
        return indicator
    }
}

/// Builds the shared day selection once. As `@State(initialValue:)` it was
/// rebuilt, UserDefaults read and JSON decoded included, on every init of the
/// shell, and SwiftUI threw all but the first away.
@MainActor
private final class DaySelectionHolder: ObservableObject {
    let selection: LooprDaySelection

    init(environment: AppEnvironment) {
        selection = LooprDaySelection(environment: environment)
    }
}

/// One haptic per finished workout action. The token changes on every event,
/// so two pauses in a row still play twice.
private struct WorkoutHapticEvent: Equatable {
    enum Kind { case started, paused, resumed, finished, saved, discarded, failed }
    let kind: Kind
    let token = UUID()

    var feedback: SensoryFeedback {
        switch kind {
        case .started, .finished, .saved: .success
        case .paused, .resumed: .impact(weight: .light)
        case .discarded: .impact(weight: .medium)
        case .failed: .error
        }
    }
}

private struct PresentedRouteWorkout: Identifiable {
    let id: UUID
}

struct MainTabShell: View {
    let environment: AppEnvironment
    let heartLiveRuntime: (any LooprHeartLiveRuntime)?
    @StateObject private var repositories: ProductRepositoryContainer

    @State private var selection: MainTab = .today
    @StateObject private var todayNavigation = TodayNavigationState()
    /// Holds the per-batch Health export and widget snapshot requests to one
    /// per window while the band offloads a backlog.
    @StateObject private var commitCoalescer = ProductionRefreshCoordinator()
    /// Held here so the ring can be silenced when Loopr comes forward.
    @State private var phoneActionPerformer = LooprPhoneActionPerformer()
    @State private var sleepPath: [SleepKit.SleepRoute] = []
    @State private var heartPath: [AppHeartRoute] = []
    @State private var tabScrollRequest: [MainTab: LooprTabScrollRequest] = [:]
    @State private var bodyPath: [BodyKit.BodyRoute] = []
    @State private var workoutsPath: [AppWorkoutRoute] = []
    @State private var selectedWorkoutID: UUID?
    @State private var presentedRouteWorkout: PresentedRouteWorkout?
    @State private var activeWorkout: WorkoutRecord?
    @State private var didPrepareWorkout = false
    @State private var handsFreeMessage: String?
    @State private var workoutActionError: String?
    @State private var showingRouteOptIn = false
    @State private var pendingWorkoutSource: WorkoutSource?
    @State private var pendingWorkoutActivity: ActivityType = .run
    @State private var activeRouteRecorder: RouteRecorder?
    @State private var activeZoneSet: HeartRateZoneSet?
    @State private var activeZoneTwo: ZoneTwoRange?
    @State private var zoneCuesUsePhone = false
    @Environment(\.metricHistoryProvider) private var metricHistoryProvider
    @State private var router = AppRouter()
    @State private var appliedDeepLink = false
    @State private var settingsInitialPath: [SettingsFlowRoute] = []
    @State private var settingsFocusAge = false
    @State private var workoutHaptic: WorkoutHapticEvent?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.looprBluetoothModel) private var bluetoothModel
    /// The one day Today, Sleep, Heart and Body show. Switching tabs keeps it.
    @StateObject private var dayHolder: DaySelectionHolder
    private var daySelection: LooprDaySelection { dayHolder.selection }
    /// Called when the durable onboarding snapshot says onboarding has not
    /// finished although RootGate opened the shell from its cached flag.
    private let onOnboardingIncomplete: (() -> Void)?

    init(
        environment: AppEnvironment,
        heartLiveRuntime: (any LooprHeartLiveRuntime)? = nil,
        runtimeDataDeleter: (any PersistentDataDeletionDeleter)? = nil,
        onOnboardingIncomplete: (() -> Void)? = nil
    ) {
        self.environment = environment
        self.heartLiveRuntime = heartLiveRuntime
        self.onOnboardingIncomplete = onOnboardingIncomplete
        _repositories = StateObject(wrappedValue: ProductRepositoryContainer(
            environment: environment,
            heartLiveRuntime: heartLiveRuntime,
            runtimeDataDeleter: runtimeDataDeleter
        ))
        _dayHolder = StateObject(wrappedValue: DaySelectionHolder(environment: environment))
    }

    var body: some View {
        lifecycleContent
        .onReceive(NotificationCenter.default.publisher(for: LooprQuickActions.notification)) { _ in
            if let link = LooprQuickActions.shared.take() { apply(link) }
        }
        .alert("Band sync", isPresented: Binding(get: { handsFreeMessage != nil }, set: { if !$0 { handsFreeMessage = nil } })) {
            Button("OK", role: .cancel) { handsFreeMessage = nil }
        } message: { Text(handsFreeMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: looprNotificationDeepLinkName)) { notification in
            guard let link = notification.object as? NotificationDeepLink else { return }
            _ = LooprNotificationLaunchRoute.shared.take()
            apply(ShellDeepLink(notification: link))
        }
        // A backlog offload acknowledges a batch about once a second. The
        // Health export and the widget snapshot both refuse to run that often
        // anyway, so firing two tasks per batch only spends main-thread time
        // being turned down. One request per coalescing window is enough.
        .onReceive(NotificationCenter.default.publisher(for: looprHealthHistoryCommitted).receive(on: RunLoop.main)) { _ in
            commitCoalescer.request {
                guard let persistent = repositories.persistent else { return }
                async let synchronized: Void = persistent.healthSync.synchronize()
                async let published: Void = persistent.derivedData.request()
                _ = await (synchronized, published)
            }
        }
        .task(id: scenePhase == .active ? repositories.storageGeneration : nil) {
            guard scenePhase == .active, let persistent = repositories.persistent else { return }
            await persistent.derivedData.request()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("com.loopr.journal.route"))) { notification in
            guard let route = notification.object as? JournalKit.JournalRoute else { return }
            todayNavigation.path.append(.journal(route))
        }
    }

    private var shellContent: some View {
        tabs
        .tint(Color.loopr(selection.accent))
        .accessibilityIdentifier("main-tab-shell")
        .looprTabViewBottomAccessory(when: activeWorkout != nil) {
            ActiveWorkoutAccessory(workout: activeWorkout) { router.present(.activeWorkout) }
        }
        .sheet(item: $router.modal) { route in
            modal(for: route)
                .tint(Color.loopr(sheetAccent(for: route)))
        }
        // RouteFeatureRoot owns its own NavigationStack for map, splits, and
        // share-preview destinations. Present that stack at the app surface
        // instead of embedding a second NavigationStack inside the workout
        // detail stack; iOS 26 otherwise pops the route surface as soon as
        // its loading task publishes.
        .sheet(item: $presentedRouteWorkout) { route in
            RouteFeatureRoot(
                repositories: repositories,
                workoutID: route.id.uuidString
            )
            .tint(Color.loopr(.movement))
        }
        .alert("Workout action failed", isPresented: Binding(
            get: { workoutActionError != nil },
            set: { if !$0 { workoutActionError = nil } }
        )) {
            Button("OK", role: .cancel) { workoutActionError = nil }
        } message: {
            Text(workoutActionError ?? "The workout could not be saved.")
        }
        .confirmationDialog("Record a route?", isPresented: $showingRouteOptIn, titleVisibility: .visible) {
            Button("Enable route & location") {
                let source = pendingWorkoutSource ?? .live
                pendingWorkoutSource = nil
                let activity = pendingWorkoutActivity
                startWorkout(source: source, activity: activity, wantsRoute: true)
            }
            .accessibilityIdentifier("workout-route-enable")
            Button("Start without route") {
                let source = pendingWorkoutSource ?? .live
                pendingWorkoutSource = nil
                let activity = pendingWorkoutActivity
                startWorkout(source: source, activity: activity, wantsRoute: false)
            }
            .accessibilityIdentifier("workout-route-skip")
            Button("Cancel", role: .cancel) { pendingWorkoutSource = nil; pendingWorkoutActivity = .run }
        } message: {
            Text("Location access is requested only after you explicitly enable route recording. You can start this workout without a route.")
        }
        .modifier(BandConnectionBridge(
            storageGeneration: repositories.storageGeneration,
            healthSync: repositories.persistent?.healthSync,
            fixtureBatteryPercent: ProductFixture.bandBatteryPercent(for: environment.composition)
        ))
        .environmentObject(repositories)
        .environment(\.sleepNeedRepository, repositories.persistent?.profile)
        .environment(\.profileAgeAction, ProfileAgeAction { openProfileAge() })
        .environment(\.looprOpenSettings, LooprShellAction { openSettings() })
        .environment(\.looprRefresh, LooprRefreshAction { await refreshFromPull() })
        .sensoryFeedback(trigger: workoutHaptic) { _, event in event?.feedback }
        .modifier(LooprDaySelectionDriver(selection: daySelection, repositories: repositories))
        .modifier(LaunchOnboardingReconciliation(repositories: repositories, onReturnToOnboarding: onOnboardingIncomplete))
    }

    private var lifecycleContent: some View {
        shellContent
        .task(id: repositories.storageGeneration) {
            await consumeBandEvents()
        }
        .onChange(of: scenePhase) { _, phase in
            // Opening Loopr counts as answering the ring.
            if phase == .active { phoneActionPerformer.stopRinging() }
        }
        .task(id: scenePhase == .active ? repositories.storageGeneration : nil) {
            guard scenePhase == .active, let healthSync = repositories.persistent?.healthSync else { return }
            while !Task.isCancelled {
                await healthSync.synchronize()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .task {
            openVisualCaptureSurfaceIfNeeded()
            applyFixtureDeepLinkIfNeeded()
            if let link = LooprQuickActions.shared.take() { apply(link) }
            if let link = LooprNotificationLaunchRoute.shared.take() { apply(ShellDeepLink(notification: link)) }
            await prepareActiveWorkoutIfNeeded()
            await LooprIntervalRuntime.shared.reconcileOnWake()
        }
        #if DEBUG
        .task { await DebugLivePerformance.run() }
        #endif
        .task(id: repositories.storageGeneration) {
            if let persistent = repositories.persistent {
                await LooprHeartAlertsRuntime.shared.attach(overnightSource: ProjectionOvernightSource(database: persistent.database, analytics: persistent.analytics))
                // Canonical assessments supply the four overnight signals.
                // Metric history remains a fallback for other compositions.
                await LooprHeartAlertsRuntime.shared.attach(metricHistory: LooprMetricHistory.shared)
            }
        }
        .task(id: activeWorkout?.id ?? selectedWorkoutID) {
            guard let id = activeWorkout?.id ?? selectedWorkoutID,
                  let session = repositories.workoutSession else { return }
            for await workout in await session.updates(for: id) {
                guard !Task.isCancelled else { return }
                guard workout.id == id else { continue }
                if workout.state == .active, workout.source == .live, activeWorkout?.id != id {
                    activeWorkout = workout
                    await startZoneAlerts(for: workout, session: session)
                }
                let nextPath = WorkoutRecoveryPathTransition.path(after: workout, in: workoutsPath)
                if nextPath != workoutsPath { workoutsPath = nextPath }
                await LooprLiveActivityRuntime.shared.synchronize(workout, zones: activeZoneSet)
                if !workout.isActive {
                    if activeWorkout?.id == id { activeWorkout = nil }
                    activeZoneSet = nil
                    await WorkoutZoneAlertRuntime.shared.stop()
                }
            }
        }
        .task(id: scenePhase == .active ? repositories.storageGeneration : nil) {
            guard scenePhase == .active, didPrepareWorkout else { return }
            await LooprIntervalRuntime.shared.reconcileOnWake()
            await LooprBreathingLiveActivityHook.shared.reconcileOnWake()
            if let session = repositories.workoutSession {
                await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: await session.activeWorkout())
            }
        }
    }

    private func consumeBandEvents() async {
        // One reader of the band's event stream for the whole app. It maps
        // a double tap to the action the user picked and re-arms the strap
        // alarm after the band reports one fired.
        guard let persistent = repositories.persistent,
              let runtime = repositories.deviceCenterRuntime else { return }
        let consumer = BandEventActionConsumerFactory.make(
            runtime: runtime,
            journal: persistent.journal,
            alarmRepository: persistent.device as? any StrapAlarmConfigurationRepository,
            performer: phoneActionPerformer,
            bandStateRecorder: persistent.device as? any LooprBandStateRecording
        )
        await consumer.start()
        #if DEBUG
        if let repository = persistent.device as? any StrapAlarmConfigurationRepository {
            let service = LooprStrapAlarmService(runtime: runtime, repository: repository)
            Task { await DebugLaunchAlarm.runIfRequested(service: service, runtime: runtime) }
        }
        #endif
        // Holding the lane means a storage reopen or shell teardown stops
        // the reader instead of leaving a second one attached.
        while !Task.isCancelled {
            await bluetoothModel?.heartRateSharing.reconcile()
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
        await consumer.stop()
    }

    private var tabs: some View {
        Group {
            if let failure = repositories.storageFailure {
                ProductStorageUnavailableView(failure: failure, retry: repositories.retry)
            } else {
                // This identity sits above every repository-consuming feature
                // root. A successful retry therefore destroys StateObjects
                // built for the previous graph before constructing new roots.
                TabView(selection: $selection.signpostingTabSwitch()) {
                    Tab("Today", systemImage: MainTab.today.symbol, value: MainTab.today) {
                        NavigationStack(path: $todayNavigation.path) {
                            TodayFeatureRoot(
                                environment: environment,
                                route: routeFromToday,
                                repositories: repositories,
                                openWakeAlarm: { todayNavigation.path.append(.wakeAlarm) }
                            )
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppTodayRoute.self) { route in todayDestination(route).metricDetailNavigation() }
                                .metricDetailNavigation(zooms: true)
                        }
                    }
                    Tab("Sleep", systemImage: MainTab.sleep.symbol, value: MainTab.sleep) {
                        NavigationStack(path: $sleepPath) {
                            SleepFeatureRoot(environment: environment, route: { sleepPath.append($0) }, repositories: repositories)
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: SleepKit.SleepRoute.self) { route in sleepDestination(route).metricDetailNavigation() }
                                .metricDetailNavigation(zooms: true)
                        }
                        .environment(\.looprTabScrollRequest, tabScrollRequest[.sleep])
                    }
                    Tab("Heart", systemImage: MainTab.heart.symbol, value: MainTab.heart) {
                        NavigationStack(path: $heartPath) {
                            HeartFeatureRoot(environment: environment, route: { heartPath.append(.feature($0)) }, repositories: repositories)
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppHeartRoute.self) { route in appHeartDestination(route).metricDetailNavigation() }
                                .metricDetailNavigation(zooms: true)
                        }
                        .environment(\.looprTabScrollRequest, tabScrollRequest[.heart])
                    }
                    Tab("Body", systemImage: MainTab.body.symbol, value: MainTab.body) {
                        NavigationStack(path: $bodyPath) {
                            BodyFeatureRoot(environment: environment, route: { bodyPath.append($0) }, repositories: repositories)
                                .environment(\.bodyOpenProfile, BodyProfileAction { openProfileAge() })
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: BodyKit.BodyRoute.self) { route in bodyDestination(route).metricDetailNavigation() }
                                .metricDetailNavigation(zooms: true)
                        }
                        .environment(\.looprTabScrollRequest, tabScrollRequest[.body])
                    }
                    Tab("Workouts", systemImage: MainTab.workouts.symbol, value: MainTab.workouts) {
                        NavigationStack(path: $workoutsPath) {
                            WorkoutFeatureRoot(
                                route: { destination in workoutsPath.append(appWorkoutRoute(destination, id: nil)) },
                                selectedRoute: { destination, workout in
                                    selectedWorkoutID = workout?.id
                                    workoutsPath.append(appWorkoutRoute(destination, id: workout?.id))
                                },
                                repositories: repositories
                            )
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppWorkoutRoute.self) { route in workoutDestination(route) }
                        }
                    }
                }
                .id(repositories.graphIdentity)
            }
        }
    }

    @ViewBuilder
    private func todayDestination(_ route: AppTodayRoute) -> some View {
        switch route {
        case .feature(.sleep), .feature(.heart), .feature(.body):
            Color.clear.task {
                if case .feature(let feature) = route { routeFromToday(feature) }
            }
        case .feature(.coach): CoachFeatureRoot(environment: environment, repositories: repositories)
        case .feature(.stress): StressFeatureRoot(route: { todayNavigation.path.append(.stress($0)) }, repositories: repositories)
        case .feature(.journal): JournalFeatureRoot(route: { todayNavigation.path.append(.journal($0)) }, repositories: repositories)
        case .feature(.records):
            RecordsFeatureRoot(route: { todayNavigation.path.append(.records($0)) }, repositories: repositories)
                .looprHeaderInNavigationBar()
        case .feature(.streaks): RecordsDestinationFeatureRoot(route: .streaks, repositories: repositories)
        case .feature(.journey): RecordsDestinationFeatureRoot(route: .journey, repositories: repositories)
        case .feature(.timeline): RecordsDestinationFeatureRoot(route: .timeline, repositories: repositories)
        // One goals editor for the whole app; Today keeps its old identifier.
        case .feature(.goalSettings): GoalsFeatureRoot(repositories: repositories, accessibilityIdentifier: "goal-settings-screen")
        case .feature(.settings): SettingsFeatureRoot(repositories: repositories)
        case .feature(.recoveryBreakdown):
            TodayBreakdownFeatureRoot(kind: .recovery, environment: environment, repositories: repositories, route: routeFromToday)
        case .feature(.strainBreakdown):
            TodayBreakdownFeatureRoot(kind: .strain, environment: environment, repositories: repositories, route: routeFromToday)
        case .sleep(let route): sleepDestination(route)
        case .heart(let route): heartDestination(route)
        case .body(let route): bodyDestination(route)
        case .journal(let route): JournalDestinationFeatureRoot(route: route, repositories: repositories)
        case .records(let route): RecordsDestinationFeatureRoot(route: route, repositories: repositories)
        case .stress(let route): StressDestinationFeatureRoot(route: route, repositories: repositories, navigate: { todayNavigation.path.append(.stress($0)) })
        case .startBreathing(let bandPacing, _):
            StressDestinationFeatureRoot(route: .breathing, repositories: repositories, autoStart: true, bandPacing: bandPacing)
        case .wakeAlarm: WakeAlarmFeatureRoot(repositories: repositories)
        }
    }

    @ViewBuilder
    private func sleepDestination(_ route: SleepKit.SleepRoute) -> some View {
        SleepDestinationFeatureRoot(environment: environment, route: route, repositories: repositories)
    }

    @ViewBuilder
    private func appHeartDestination(_ route: AppHeartRoute) -> some View {
        switch route {
        case .feature(.stress):
            StressFeatureRoot(route: { heartPath.append(.stress($0)) }, repositories: repositories)
        case .feature(let route): heartDestination(route)
        case .stress(let route):
            StressDestinationFeatureRoot(route: route, repositories: repositories,
                navigate: { heartPath.append(.stress($0)) })
        }
    }

    @ViewBuilder
    private func heartDestination(_ route: HeartKit.HeartRoute) -> some View {
        HeartDestinationFeatureRoot(environment: environment, route: route, repositories: repositories)
    }

    @ViewBuilder
    private func bodyDestination(_ route: BodyKit.BodyRoute) -> some View {
        BodyDestinationFeatureRoot(environment: environment, route: route, repositories: repositories)
    }

    @ViewBuilder
    private func workoutDestination(_ route: AppWorkoutRoute) -> some View {
        switch route {
        case .live(let id, let activity):
            WorkoutLiveScreen(
                activity: activity,
                session: repositories.workoutSession,
                workoutID: id,
                zones: activeZoneSet,
                zoneTwo: activeZoneTwo,
                usesPhoneCues: zoneCuesUsePhone,
                loadRoute: liveRouteLoader(),
                onAlertPreference: { preference in
                    Task { await configureZoneAlerts(preference) }
                },
                onPauseChange: { @Sendable paused in
                    try await setWorkoutPaused(id: id, paused: paused)
                },
                route: { destination in
                    switch destination {
                    case .finish:
                        replaceLiveWorkoutWithCompletedSummary(id: id)
                    default:
                        workoutsPath.append(appWorkoutRoute(destination, id: id))
                    }
                },
                onFinish: { @Sendable in
                    try await finishWorkoutRecord(id: id)
                }
            )
        case .detail(let id):
            WorkoutDestinationFeatureRoot(recovery: false, workoutID: id, route: { destination in
                switch destination {
                case .route:
                    if let id { presentedRouteWorkout = PresentedRouteWorkout(id: id) }
                case .sharePreview: workoutsPath.append(.sharePreview(id))
                case .edit: workoutsPath.append(.edit(id))
                case .delete: break
                }
            }, repositories: repositories)
        case .detectedReview(let detection):
            WorkoutDetectedReviewScreen(
                detection: detection,
                onSave: { activity, startedAt, endedAt in
                    try await acceptDetectedWorkout(
                        detection: detection,
                        activity: activity,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                },
                onDiscard: {
                    try await discardDetectedWorkout(detection)
                },
                onAccepted: { workout in
                    selectedWorkoutID = workout.id
                    workoutsPath.append(.detail(workout.id))
                },
                onDiscarded: {
                    if !workoutsPath.isEmpty { workoutsPath.removeLast() }
                }
            )
        case .sharePreview(let id):
            WorkoutShareDestinationFeatureRoot(workoutID: id, repositories: repositories)
        case .recovery(let id):
            WorkoutDestinationFeatureRoot(recovery: true, workoutID: id, repositories: repositories)
        case .route(let id):
            RouteFeatureRoot(repositories: repositories, workoutID: id?.uuidString)
        case .intervals:
            IntervalTimerScreen(
                model: LooprIntervalRuntime.shared.model,
                hooks: LooprIntervalRuntime.shared.hooks(runtime: repositories.isFixtureComposition ? nil : repositories.deviceCenterRuntime),
                liveSource: repositories.workoutLiveSampleSource,
                onSave: { @Sendable [repositories] start, end in
                    guard let session = await repositories.workoutSession else { throw HandsFreeError.storage }
                    let hooks = await repositories.workoutFinalizationHooks
                    _ = try await session.logManual(activity: .hiit, startedAt: start, endedAt: end, hooks: hooks)
                },
                bandCueUnavailableReason: { @Sendable [runtime = repositories.deviceCenterRuntime] in
                    await BandCueAvailability.reason(runtime: runtime)
                }
            )
        case .catalog, .startPicker:
            WorkoutStartPickerScreen(loadZoneContext: { @Sendable in await loadWorkoutZoneContext() }) { destination in
                switch destination {
                case .live(let activity): requestWorkoutStart(source: .live, activity: activity)
                case .detectedReview: workoutsPath.append(appWorkoutRoute(destination, id: nil))
                default: workoutsPath.append(appWorkoutRoute(destination, id: nil))
                }
            }
        case .log:
            WorkoutManualLogScreen(
                mode: .create,
                route: { destination in
                    switch destination {
                    case .finish: workoutsPath.append(.detail(selectedWorkoutID))
                    default: workoutsPath.append(appWorkoutRoute(destination, id: selectedWorkoutID))
                    }
                },
                onSave: { activity, startedAt, endedAt in
                    try await saveManualWorkout(activity: activity, startedAt: startedAt, endedAt: endedAt)
                }
            )
        case .edit(let id):
            if let id {
                WorkoutManualLogScreen(
                    mode: .edit,
                    route: { destination in
                        switch destination {
                        case .finish: workoutsPath.append(.detail(selectedWorkoutID ?? id))
                        default: workoutsPath.append(appWorkoutRoute(destination, id: id))
                        }
                    },
                    loadWorkout: { await repositories.workoutSession?.workout(id: id) },
                    onSave: { activity, startedAt, endedAt in
                        try await editWorkoutRecord(id: id, activity: activity, startedAt: startedAt, endedAt: endedAt)
                    }
                )
            } else {
                ContentUnavailableView("Workout unavailable", systemImage: "figure.run", description: Text("Choose a saved workout before editing."))
                    .accessibilityIdentifier("workout-edit-unavailable")
            }
        case .finish(let id):
            WorkoutFinishScreen(
                session: repositories.workoutSession,
                workoutID: id,
                onAction: { action in
                    workoutsPath.append(AppWorkoutPathTransition.detailDestination(for: action))
                }
            )
        }
    }

    private func appWorkoutRoute(_ destination: WorkoutKit.WorkoutRoute, id: UUID?) -> AppWorkoutRoute {
        switch destination {
        case .catalog: .catalog
        case .intervals: .intervals
        case .log: .log
        case .edit: .edit(id)
        case .startPicker: .startPicker
        case .live(let activity): .live(id, activity)
        case .finish: .finish(id)
        case .detail: .detail(id)
        case .recovery: .recovery(id)
        case .route: .route(id)
        case .sharePreview: .sharePreview(id)
        case .detectedReview(let detection): .detectedReview(detection)
        }
    }

    private func liveRouteLoader() -> (@Sendable () async -> WorkoutLiveRoute?)? {
        guard let recorder = activeRouteRecorder else { return nil }
        return { @Sendable in
            guard let route = await recorder.currentRoute() else { return nil }
            let distance = route.points.count > 1 ? RouteMath.distanceMeters(route: route) : nil
            let duration = route.points.last.flatMap { last in
                route.points.first.map { last.timestamp.timeIntervalSince($0.timestamp) }
            }
            let average = distance.flatMap { meters in
                duration.flatMap { seconds in meters > 0 && seconds > 0 ? seconds * 1000 / meters : nil }
            }
            let current = route.points.last.flatMap { point -> Double? in
                let age = Date().timeIntervalSince(point.timestamp)
                guard age >= 0, age <= 10,
                      let speed = point.speedMetersPerSecond, speed > 0 else { return nil }
                return 1000 / speed
            }
            return WorkoutLiveRoute(
                distanceMeters: distance,
                currentPaceSecondsPerKilometer: current,
                averagePaceSecondsPerKilometer: average,
                points: route.points.map { WorkoutLiveRoutePoint(latitude: $0.latitude, longitude: $0.longitude) },
                segments: RouteMath.polylineSegments(route: route).map { segment in
                    segment.map { WorkoutLiveRoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
                }
            )
        }
    }

    private func requestWorkoutStart(source: WorkoutSource, activity: ActivityType = .run) {
        // Fixture launches have no Core Location capability and must remain
        // deterministic. Production requires an explicit route decision
        // before any location permission can be requested.
        guard !repositories.isFixtureComposition,
              [.run, .cycle, .walk].contains(activity) else {
            startWorkout(source: source, activity: activity, wantsRoute: false)
            return
        }
        pendingWorkoutSource = source
        pendingWorkoutActivity = activity
        showingRouteOptIn = true
    }

    private func startWorkout(source: WorkoutSource, activity: ActivityType = .run, wantsRoute: Bool = false) {
        guard let session = repositories.workoutSession else {
            workoutActionError = "Workout storage is unavailable."
            return
        }
        Task { @MainActor in
            do {
                var workout = try await session.start(activity: activity, source: source)
                if source == .live {
                    switch workout.state {
                    case .selectedActivity:
                        _ = try await session.transition(to: .preparing)
                        workout = try await session.transition(to: .active)
                    case .preparing:
                        workout = try await session.transition(to: .active)
                    default:
                        break
                    }
                }
                if wantsRoute {
                    do {
                        activeRouteRecorder = try await startRouteRecording(for: workout)
                    } catch {
                        workoutActionError = "Workout started, but route recording is unavailable: \(error.localizedDescription)"
                    }
                }
                if source == .live {
                    await startZoneAlerts(for: workout, session: session)
                }
                selectedWorkoutID = workout.id
                activeWorkout = workout
                workoutHaptic = WorkoutHapticEvent(kind: .started)
                await LooprLiveActivityRuntime.shared.synchronize(workout, zones: activeZoneSet)
                await LooprHeartAlertsRuntime.shared.noteWorkout(id: workout.id.uuidString, start: workout.startedAt ?? Date(), end: nil)
                workoutsPath.append(source == .live ? .live(workout.id, activity) : .finish(workout.id))
            } catch {
                workoutHaptic = WorkoutHapticEvent(kind: .failed)
                workoutActionError = error.localizedDescription
            }
        }
    }

    private func loadWorkoutZoneContext() async -> WorkoutZoneContext {
        #if DEBUG
        if let context = DebugCaptureFixtures.zoneContext { return context }
        #endif
        let birthYear = try? await repositories.persistent?.profile.readProfile()?.birthYear
        let age = birthYear.map { Calendar.current.component(.year, from: Date()) - $0 }
        let settings = await HeartZonePreferences.shared.load()
        // Canonical band resting-HR history, over the same 14-day window as Heart.
        let nights = (try? await metricHistoryProvider.series(for: .restingHeartRate, days: 14, endingOn: Date())) ?? []
        let resting = nights.filter { $0.source == .band }.sorted { $0.day < $1.day }.map(\.value)
        let resolved = settings.resolved(age: age, restingNights: resting)
        let zones = resolved.flatMap {
            ActivityAnalytics.zones($0, source: $0.source == .manual ? .manual : $0.source == .observed ? .measured : .agePredicted).value
        }
        let preset = ZoneTwoRange.resolve(zones: resolved)
        let state = await repositories.deviceCenterRuntime?.runtimeState()
        return .init(zones: zones, zoneTwo: preset, usesPhoneCues: state?.bandModel != .whoop4)
    }

    private func startZoneAlerts(for workout: WorkoutRecord, session: WorkoutSessionController) async {
        let context = await loadWorkoutZoneContext()
        guard let current = await session.activeWorkout(), current.id == workout.id, current.state == .active else { return }
        activeZoneSet = context.zones
        activeZoneTwo = context.zoneTwo
        zoneCuesUsePhone = context.usesPhoneCues
        let preference = current.zoneAlertPreference ?? WorkoutZoneAlertPreferenceStore().preference(for: workout.activity)
        let target = WorkoutZoneTarget(preference: preference, zones: context.zones, zoneTwo: context.zoneTwo)
        if current.zoneAlertPreference == nil || current.currentZoneTarget != target {
            do {
                activeWorkout = try await session.configureZoneAlerts(id: workout.id, preference: preference,
                    target: target)
            } catch { workoutActionError = "Heart rate alerts could not be saved."; return }
        }
        await WorkoutZoneAlertRuntime.shared.start(workoutID: workout.id, session: session,
            zones: context.zones, preference: preference, band: repositories.deviceCenterRuntime)
    }

    private func configureZoneAlerts(_ preference: WorkoutZoneAlertPreference) async {
        guard let session = repositories.workoutSession, let workout = await session.activeWorkout() else { return }
        do {
            activeWorkout = try await session.configureZoneAlerts(id: workout.id, preference: preference,
                target: .init(preference: preference, zones: activeZoneSet, zoneTwo: activeZoneTwo))
            await WorkoutZoneAlertRuntime.shared.configure(preference)
        } catch { workoutActionError = "Heart rate alerts could not be saved." }
    }

    private func setWorkoutPaused(id: UUID?, paused: Bool) async throws {
        guard let session = repositories.workoutSession, let id,
              let current = await session.activeWorkout(), current.id == id else {
            throw WorkoutTransitionError.missingWorkout
        }
        let workout = try await session.transition(to: paused ? .paused : .active)
        activeWorkout = workout
        workoutHaptic = WorkoutHapticEvent(kind: paused ? .paused : .resumed)
        if let recorder = activeRouteRecorder {
            if paused { try await recorder.suspend() }
            else { try await recorder.resume() }
        }
    }

    private func saveManualWorkout(activity: ActivityType, startedAt: Date, endedAt: Date) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession else { throw WorkoutTransitionError.missingWorkout }
        let workout = try await session.logManual(
            activity: activity, startedAt: startedAt, endedAt: endedAt,
            hooks: repositories.workoutFinalizationHooks
        )
        selectedWorkoutID = workout.id
        workoutHaptic = WorkoutHapticEvent(kind: .saved)
        await LooprNotificationRuntime.shared.workoutCompleted(id: workout.id, at: workout.endedAt ?? Date())
        return workout
    }

    private func acceptDetectedWorkout(
        detection: WorkoutKit.DetectedWorkout,
        activity: ActivityType,
        startedAt: Date,
        endedAt: Date
    ) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession,
              let detectedRepository = repositories.detectedWorkouts,
              await detectedRepository.detection(id: detection.detectionID) != nil else {
            throw WorkoutTransitionError.missingWorkout
        }
        let candidate = try DetectedWorkoutCandidate.record(
            from: detection,
            activity: activity,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let workout = try await session.reconcile(candidate, hooks: repositories.workoutFinalizationHooks)
        // SQLiteWorkoutStore records the answer as it removes the row, so a
        // later re-derivation of the same day does not offer this bout again.
        try await detectedRepository.remove(id: detection.detectionID)
        selectedWorkoutID = workout.id
        workoutHaptic = WorkoutHapticEvent(kind: .saved)
        await LooprNotificationRuntime.shared.detectedWorkout(id: workout.id, at: workout.endedAt ?? Date())
        await LooprNotificationRuntime.shared.workoutCompleted(id: workout.id, at: workout.endedAt ?? Date())
        return workout
    }

    private func discardDetectedWorkout(_ detection: WorkoutKit.DetectedWorkout) async throws {
        guard let detectedRepository = repositories.detectedWorkouts else {
            throw DetectedWorkoutRepositoryError.missingDetection
        }
        try await detectedRepository.remove(id: detection.detectionID)
        workoutHaptic = WorkoutHapticEvent(kind: .discarded)
    }

    private func finishWorkoutRecord(id: UUID?) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession else { throw WorkoutTransitionError.missingWorkout }
        await WorkoutZoneAlertRuntime.shared.stop()
        await finishActiveRouteRecording()
        let workout = try await session.finish(id: id, hooks: repositories.workoutFinalizationHooks)
        selectedWorkoutID = workout.id
        activeWorkout = nil
        activeZoneSet = nil
        workoutHaptic = WorkoutHapticEvent(kind: .finished)
        await LooprNotificationRuntime.shared.workoutCompleted(id: workout.id, at: workout.endedAt ?? Date())
        return workout
    }

    private func startRouteRecording(for workout: WorkoutRecord) async throws -> RouteRecorder? {
        guard let persistent = repositories.persistent else { return nil }
        let recorder = RouteRecorder(store: persistent.routes, location: persistent.routeLocation)
        // Ask Core Location what it actually granted. Passing `.authorized`
        // unconditionally reported a permission nobody had checked.
        try await recorder.start(
            workoutID: workout.id.uuidString,
            activity: RouteActivity(rawValue: workout.activity.rawValue),
            permission: persistent.routeLocation.currentRoutePermission
        )
        return recorder
    }

    private func finishActiveRouteRecording() async {
        guard let recorder = activeRouteRecorder else { return }
        defer { activeRouteRecorder = nil }
        do {
            _ = try await recorder.finish()
        } catch {
            // Every accepted point was already stored. Stop location while
            // retaining the incomplete row so RouteKit can recover it rather
            // than deleting valid route data after a failed final flush.
            try? await recorder.markGPSUnavailable()
        }
    }

    private func replaceLiveWorkoutWithCompletedSummary(id: UUID?) {
        guard let id else {
            workoutActionError = "The completed workout identity is unavailable."
            return
        }
        workoutsPath = AppWorkoutPathTransition.replacingLiveWithCompletedSummary(
            in: workoutsPath,
            workoutID: id
        )
    }

    private func editWorkoutRecord(id: UUID, activity: ActivityType, startedAt: Date, endedAt: Date) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession else { throw WorkoutTransitionError.missingWorkout }
        let workout = try await session.edit(id: id, activity: activity, startedAt: startedAt, endedAt: endedAt)
        selectedWorkoutID = workout.id
        return workout
    }

    private func sheetAccent(for route: AppModalRoute) -> LooprColorToken {
        switch route {
        case .activeWorkout: .movement
        case .settings: selection.accent
        #if DEBUG
        case .zoneCapture: .movement
        case .designSystem: selection.accent
        #endif
        }
    }

    @ViewBuilder
    private func modal(for route: AppModalRoute) -> some View {
        switch route {
        case .settings:
            SettingsFlowRoot(
                dismiss: { router.dismiss() },
                repositories: repositories,
                initialPath: settingsInitialPath,
                focusesAge: settingsFocusAge
            )
        case .activeWorkout:
            NavigationStack {
                WorkoutLiveScreen(
                    activity: activeWorkout?.activity ?? .run,
                    session: repositories.workoutSession,
                    workoutID: selectedWorkoutID,
                    zones: activeZoneSet,
                    zoneTwo: activeZoneTwo,
                    usesPhoneCues: zoneCuesUsePhone,
                    loadRoute: liveRouteLoader(),
                    onAlertPreference: { preference in
                        Task { await configureZoneAlerts(preference) }
                    },
                    onPauseChange: { @Sendable paused in
                        try await setWorkoutPaused(id: selectedWorkoutID, paused: paused)
                    },
                    route: { destination in
                        guard destination == .finish else { return }
                        guard let finishedID = selectedWorkoutID else {
                            router.dismiss()
                            return
                        }
                        selection = .workouts
                        replaceLiveWorkoutWithCompletedSummary(id: finishedID)
                        router.dismiss()
                    },
                    onFinish: { @Sendable in
                        try await finishWorkoutRecord(id: selectedWorkoutID)
                    }
                )
                    .accessibilityIdentifier("active-workout-modal")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { router.dismiss() }
                        }
                    }
            }
        #if DEBUG
        case .zoneCapture:
            NavigationStack { DebugZoneCaptureScreen(mode: DebugCaptureFixtures.zoneMode ?? "start") }
        case .designSystem:
            NavigationStack {
                Group {
                    if DebugCaptureFixtures.siPolishGlances {
                        SIPolishGlanceGallery(state: DebugCaptureFixtures.siPolishState ?? "good")
                    } else {
                        DesignSystemGallery(initialSection: designSystemInitialSection)
                    }
                }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { router.dismiss() }
                        }
                    }
            }
        #endif
        }
    }

    #if DEBUG
    private var designSystemInitialSection: String? {
        let prefix = "--loopr-design-system-section="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }

    private func openVisualCaptureSurfaceIfNeeded() {
        if DebugCaptureFixtures.siPolishGlances { router.present(.designSystem); return }
        if DebugCaptureFixtures.zoneMode != nil { router.present(.zoneCapture); return }
        guard ProcessInfo.processInfo.arguments.contains("--loopr-open-design-system") else { return }
        router.present(.designSystem)
    }
    #else
    private func openVisualCaptureSurfaceIfNeeded() {}
    #endif

    private func applyFixtureDeepLinkIfNeeded() {
        #if DEBUG
        guard !appliedDeepLink, let link = ShellDeepLink.parse(arguments: ProcessInfo.processInfo.arguments) else { return }
        appliedDeepLink = true
        apply(link)
        #endif
    }

    private func apply(_ link: ShellDeepLink) {
        switch link {
        case .todayHome: selection = .today; todayNavigation.path = []
        case .breathing(let start, let bandPacing):
            selection = .today
            todayNavigation.path = [start ? .startBreathing(bandPacing: bandPacing, requestID: UUID()) : .stress(.breathing)]
        case .intervals: selection = .workouts; workoutsPath = [.intervals]
        case .syncBand:
            Task { @MainActor in
                do {
                    let complete = try await LooprHandsFreeRuntime.shared.syncBand()
                    handsFreeMessage = complete ? "Band sync finished." : "Sync did not finish. Connect your band and try again."
                } catch { handsFreeMessage = error.localizedDescription }
            }
        case .todayDetail: selection = .today; todayNavigation.path = [.feature(.coach)]
        case .sleepDetail: openTabHome(.sleep)
        case .heartHome: openTabHome(.heart)
        case .heartDetail: selection = .heart; heartPath = [.feature(.detail)]
        case .heartTrends: selection = .heart; heartPath = [.feature(.trends)]
        case .bodyDetail: openTabHome(.body)
        case .workoutsDetail: selection = .workouts; workoutsPath = [.detail(nil)]
        #if DEBUG
        case .zoneCapture: router.present(.zoneCapture)
        #endif
        case .habitInsights:
            selection = .today
            todayNavigation.path = [AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .journal(.habitInsights) : .journal(.history)]
        case .habitSetup:
            selection = .today
            todayNavigation.path = [AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .journal(.habitSetup) : .journal(.history)]
        case .habitManagement:
            selection = .today
            todayNavigation.path = [AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .journal(.habits) : .journal(.history)]
        case .habitHistory:
            selection = .today
            todayNavigation.path = [AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .journal(.habitHistory) : .journal(.history)]
        case .habitDetail:
            selection = .today
            todayNavigation.path = [AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .journal(.habitDetail(HabitFixtures.definition.id)) : .journal(.history)]
        case .habitCheckIn(let day):
            selection = .today
            if AppHabitFeatureGate.currentStage.exposesEntryPoints,
               let identity = DayIdentity(habitKey: day) {
                todayNavigation.path = [.journal(.checkIn(identity))]
            } else {
                todayNavigation.path = [.journal(.history)]
            }
        case .recordsDetail: selection = .today; todayNavigation.path = [.records(.records)]
        case .recordsRecap: selection = .today; todayNavigation.path = [.records(.recap)]
        case .gestureMapping:
            settingsInitialPath = [.settings(.deviceCenter), .device(.gestures)]
            router.present(.settings)
        case .coach: selection = .today; todayNavigation.path = [.feature(.coach)]
        case .goals: selection = .today; todayNavigation.path = [.feature(.goalSettings)]
        case .stress: selection = .today; todayNavigation.path = [.stress(.stress)]
        case .settings(let destination):
            settingsFocusAge = false
            settingsInitialPath = [.settings(destination)]
            router.present(.settings)
        case .wakeAlarm: selection = .today; todayNavigation.path = [.wakeAlarm]
        case .settingsHome:
            settingsFocusAge = false
            settingsInitialPath = []
            router.present(.settings)
        case .workout(let identifier):
            selection = .workouts
            selectedWorkoutID = identifier
            workoutsPath = [.detail(identifier)]
        }
    }

    /// Every tab's avatar opens Settings at its root.
    private func openSettings() {
        settingsFocusAge = false
        settingsInitialPath = []
        router.present(.settings)
    }

    /// Pull to refresh on any tab: a bounded sync with the band when it is
    /// connected, then a fresh derivation, then the visible tab reloads.
    private func refreshFromPull() async {
        await bluetoothModel?.syncNow()
        if let persistent = repositories.persistent {
            await persistent.derivedData.request()
        }
        NotificationCenter.default.post(name: looprDerivedGenerationUpdated, object: nil)
    }

    private func openProfileAge() {
        settingsInitialPath = [.settings(.profile)]
        settingsFocusAge = true
        router.present(.settings)
    }

    private func prepareActiveWorkoutIfNeeded() async {
        defer { didPrepareWorkout = true }
        guard let session = repositories.workoutSession else {
            if environment.composition == .activeWorkout {
                workoutActionError = "Workout storage is unavailable."
            }
            return
        }
        do {
            let recovered = try await session.recoverInterrupted()
            if let first = recovered.first {
                await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: nil)
                selectedWorkoutID = first.id
                selection = .workouts
                if workoutsPath.isEmpty { workoutsPath.append(.recovery(first.id)) }
                return
            }
        } catch {
            workoutActionError = error.localizedDescription
        }
        if let active = await session.activeWorkout() {
            selectedWorkoutID = active.id
            activeWorkout = active
            try? await session.reattachLiveSamples()
            await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: active)
            return
        }
        if let selected = await session.selectedWorkoutID() {
            selectedWorkoutID = selected
            if let row = await session.workout(id: selected), row.isActive { activeWorkout = row }
            try? await session.reattachLiveSamples()
            await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: activeWorkout)
            return
        }
        await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: nil)
        #if DEBUG
        guard environment.composition == .activeWorkout else { return }
        do {
            var workout = try await session.start(
                activity: .run,
                source: .live,
                sourceKey: "fixture-active",
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
            )
            switch workout.state {
            case .selectedActivity:
                _ = try await session.transition(to: .preparing)
                workout = try await session.transition(to: .active)
            case .preparing:
                workout = try await session.transition(to: .active)
            default:
                break
            }
            selectedWorkoutID = workout.id
            activeWorkout = workout
            await LooprLiveActivityRuntime.shared.synchronize(workout)
        } catch {
            workoutActionError = error.localizedDescription
        }
        #endif
    }

    private func openTabHome(_ tab: MainTab) {
        switch tab {
        case .sleep: sleepPath = []
        case .heart: heartPath = []
        case .body: bodyPath = []
        case .today: todayNavigation.path = []
        case .workouts: workoutsPath = []
        }
        tabScrollRequest[tab] = LooprTabScrollRequest()
        selection = tab
    }

    private func routeFromToday(_ route: TodayKit.TodayRoute) {
        if let tab = TodayTabOwnership.tab(for: route) { openTabHome(tab) }
        else if route == .settings { router.present(.settings) }
        else { todayNavigation.path.append(.feature(route)) }
    }

}

nonisolated enum WorkoutRecoveryPathTransition {
    static func path(after workout: WorkoutRecord, in path: [AppWorkoutRoute]) -> [AppWorkoutRoute] {
        guard path.last == .recovery(workout.id) else { return path }
        var updated = path
        if workout.state == .active, workout.source == .live {
            updated[updated.count - 1] = .live(workout.id, workout.activity)
        } else if workout.state == .discarded {
            updated.removeLast()
        }
        return updated
    }
}

private extension View {
    @ViewBuilder
    func looprTabViewBottomAccessory<Accessory: View>(
        when condition: Bool,
        @ViewBuilder content: @escaping () -> Accessory
    ) -> some View {
        if condition {
            tabViewBottomAccessory(content: content)
        } else {
            self
        }
    }
}

private struct ActiveWorkoutAccessory: View {
    let workout: WorkoutRecord?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.loopr(.movement))
                VStack(alignment: .leading, spacing: 2) {
                    LooprText(workout?.activity.displayName ?? "Active workout", style: .label)
                    LooprText(workout?.duration.map { "\($0.formatted()) active" } ?? "Recording", style: .caption, color: .inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
                    .foregroundStyle(Color.loopr(.inkSecondary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Active workout, \(workout?.activity.displayName ?? "workout")")
        .accessibilityIdentifier("active-workout-mini-player")
    }
}
