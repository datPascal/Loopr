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
import TrainKit
import WorkoutKit

@MainActor
final class TodayNavigationState: ObservableObject {
    @Published var path: [AppTodayRoute] = []
    /// The briefing a notification asked for. Cleared by any other way into
    /// the coach.
    @Published var coachChatID: UUID?
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
    let fixtureLastSyncedAt: Date?
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.looprBluetoothModel) private var bluetoothModel
    #if DEBUG
    @State private var debugBatteryPercent: Int?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.bandConnected, bandLink?.state.isConnectedOrQuiet ?? false)
            // A fixture battery stands for a paired band. Without a link the shell is not sure, so it keeps the band
            // wording only when a band was paired.
            .environment(\.bandPaired, fixtureBatteryPercent != nil || bandLink?.isPaired == true)
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
        indicator.lastSyncedAt = fixtureLastSyncedAt
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

    @State var selection: MainTab = .today
    @State private var yourDataTab: MainTab?
    #if DEBUG
    @State private var fixtureHabitStore: InMemoryHabitStore?
    #endif
    @State private var metricPins: HealthMetricPins
    @StateObject var todayNavigation = TodayNavigationState()
    /// Holds the per-batch Health export and widget snapshot requests to one
    /// per window while the band offloads a backlog.
    @StateObject private var commitCoalescer = ProductionRefreshCoordinator()
    /// Held here so the ring can be silenced when Loopr comes forward.
    @State private var phoneActionPerformer = LooprPhoneActionPerformer()
    @State var healthPath: [AppHealthRoute] = []
    /// Journal routes and the Protocol tab's own pushes (`ProtocolTabPush`).
    @State var journalPath = NavigationPath()
    @State private var askOrigin: AskOrigin?
    /// Set by the camera button in Ask. The Food tab opens photo capture and clears it.
    @State private var foodPhotoRequested = false
    /// Blood tests' "Scan a report": the Food tab opens its camera in Lab mode.
    @State private var labScanRequested = false
    @State private var tabScrollRequest: [MainTab: LooprTabScrollRequest] = [:]
    @State var workoutsPath: [AppWorkoutRoute] = []
    @State var selectedWorkoutID: UUID?
    /// True while the Train summary on top of the Fitness path was opened from a This week row, not by finishing.
    @State private var trainSummaryFromList = false
    @State private var presentedRouteWorkout: PresentedRouteWorkout?
    @State private var activeWorkout: WorkoutRecord?
    /// The strength session on top of the active workout, when it was started from a template.
    @StateObject private var trainLive = TrainLiveRuntime()
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
    @Environment(\.looprMeasurementSystem) private var measurementSystem
    @State var router = AppRouter()
    /// The weekly review sheet (LV-09.2), opened from Today, Protocol, its reminder or the DEBUG launch argument.
    @State private var weeklyReview = WeeklyReviewPresenter()
    /// "What's new in Loopr", once on the first launch after the update from build 21 (R1-UPG-2).
    @State private var showsWhatsNew = false
    /// The Protocol segment an in-app route asked for, such as Experiments from Today's strip.
    @State private var protocolSegmentRequest: ProtocolSegmentRequest?
    @State private var appliedDeepLink = false
    @State private var workoutHaptic: WorkoutHapticEvent?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.looprBluetoothModel) private var bluetoothModel
    /// The one day Today, Sleep, Heart and Body show. Switching tabs keeps it.
    @StateObject private var dayHolder: DaySelectionHolder
    var daySelection: LooprDaySelection { dayHolder.selection }
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
        #if DEBUG
        let fixturePins = environment.composition == .production ? nil : HealthMetricPins.fixturePins()
        #else
        let fixturePins: [MetricKey]? = nil
        #endif
        _metricPins = State(initialValue: HealthMetricPins(storage: environment.composition == .production ? .standard : nil,
                                                           initial: fixturePins))
        self.heartLiveRuntime = heartLiveRuntime
        self.onOnboardingIncomplete = onOnboardingIncomplete
        _repositories = StateObject(wrappedValue: ProductRepositoryContainer(
            environment: environment,
            heartLiveRuntime: heartLiveRuntime,
            runtimeDataDeleter: runtimeDataDeleter
        ))
        _dayHolder = StateObject(wrappedValue: DaySelectionHolder(environment: environment))
        #if DEBUG
        let startAt = MainTabLaunchState.startingAt(ProcessInfo.processInfo.arguments)
        #else
        let startAt: MainTabLaunchState? = nil
        #endif
        let whatsNew = WhatsNewGate().shouldShow(isProduction: environment.composition == .production)
        _showsWhatsNew = State(initialValue: whatsNew)
        // The first launch after the update opens on Today under the sheet, whatever tab build 21 saved (R1-UPG-3).
        let restored = startAt ?? MainTabLaunchState.restoring(environment.composition == .production
            ? UserDefaults.standard.string(forKey: MainTab.selectionKey) : nil, afterUpdate: whatsNew)
        _selection = State(initialValue: restored.tab)
        _healthPath = State(initialValue: restored.healthPath)
    }

    var body: some View {
        #if DEBUG
        FiveTabFixturePreparation(enabled: repositories.isFixtureComposition
            && ProcessInfo.processInfo.arguments.contains("--loopr-your-data-fixture")) {
            applicationContent
        }
        #else
        applicationContent
        #endif
    }

    private var applicationContent: some View {
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
            if environment.composition == .production {
                try? CoachBriefingRuntime.shared.configure(persistent)
                await CoachBriefingRuntime.shared.runIfDue()
                await CoachBriefingRuntime.shared.schedule()
                if let exporter = try? YourDataModel.exporter(stores: YourDataModel.stores(for: persistent), defaults: .standard) {
                    await YourDataBackupCoordinator.shared.run(exporter: exporter, ifDue: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("com.loopr.journal.route"))) { notification in
            guard let route = notification.object as? JournalKit.JournalRoute else { return }
            selection = .protocol
            journalPath.append(route)
        }
    }

    private var shellContent: some View {
        tabs
        .tint(Color.loopr(selection.accent))
        .accessibilityIdentifier("main-tab-shell")
        .looprTabViewBottomAccessory(when: ActiveWorkoutAccessoryVisibility.isShown(
            activeWorkoutID: activeWorkout?.id, selection: selection, path: workoutsPath)) {
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
        .sheet(isPresented: $showsWhatsNew, onDismiss: {
            WhatsNewGate().markSeen(isProduction: environment.composition == .production)
        }) {
            WhatsNewSheet(openProtocol: {
                showsWhatsNew = false
                openTabHome(.protocol)
            }) { showsWhatsNew = false }
                .tint(Color.loopr(.brand))
        }
        .sheet(item: $weeklyReview.sheet) { sheet in
            WeeklyReviewSheetView(sheet: sheet) { weeklyReview.close() }
                .tint(Color.loopr(.protocol))
        }
        .alert("Weekly review", isPresented: Binding(
            get: { weeklyReview.message != nil && weeklyReview.sheet == nil },
            set: { if !$0 { weeklyReview.message = nil } }
        )) {
            Button("OK", role: .cancel) { weeklyReview.message = nil }
        } message: {
            Text(weeklyReview.message ?? "")
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
            fixtureBatteryPercent: ProductFixture.bandBatteryPercent(for: environment.composition),
            fixtureLastSyncedAt: daySelection.knowledge.lastRecordAt
        ))
        .environmentObject(repositories)
        .environment(\.healthMetricPins, metricPins)
        .environment(\.metricHabitStore, metricHabitStore)
        .environment(\.sleepNeedRepository, repositories.persistent?.profile)
        .environment(\.profileAgeAction, ProfileAgeAction { openProfileAge() })
        .environment(\.looprOpenSettings, LooprShellAction { openSettings() })
        .environment(\.looprOpenYourData, LooprShellAction { openYourData() })
        .environment(\.looprOpenLabReport, LabReportLink(open: { id in openLabReport(id) }, openEntry: { openLabEntry() }))
        .environment(\.looprScanLabReport, LooprShellAction { openLabScan() })
        .environment(\.looprOpenWeeklyReview, LooprShellAction { openWeeklyReview() })
        .environment(\.looprAsk, LooprAskAction(
            run: { origin in openAsk(from: origin) },
            runWithPrompt: { origin, prompt in openAsk(from: origin, prompt: prompt) }
        ))
        .onChange(of: selection) { _, tab in
            if environment.composition == .production { UserDefaults.standard.set(tab.rawValue, forKey: MainTab.selectionKey) }
        }
        .environment(\.looprRefresh, LooprRefreshAction { await refreshFromPull() })
        .sensoryFeedback(trigger: workoutHaptic) { _, event in event?.feedback }
        .modifier(LooprDaySelectionDriver(selection: daySelection, repositories: repositories))
        .modifier(LaunchOnboardingReconciliation(repositories: repositories, onReturnToOnboarding: onOnboardingIncomplete))
    }

    private var lifecycleContent: some View {
        shellContent
        #if DEBUG
        .task {
            if repositories.isFixtureComposition, fixtureHabitStore == nil,
               ProcessInfo.processInfo.arguments.contains("--loopr-habit-insights-fixture") {
                fixtureHabitStore = try? await FiveTabHabitFixture.makeStore(endingOn: daySelection.day)
            }
        }
        #endif
        .task(id: repositories.storageGeneration) {
            await consumeBandEvents()
        }
        // The stored appearance and units apply when the shell opens, not when Settings is first opened.
        .task(id: repositories.storageGeneration) {
            await applyStoredDesignSystem(repositories)
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
            openWeeklyReviewFixtureIfRequested()
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
                    await resumeTrainSessionIfNeeded(for: workout)
                }
                let nextPath = WorkoutRecoveryPathTransition.path(after: workout, in: workoutsPath)
                if nextPath != workoutsPath { workoutsPath = nextPath }
                await LooprLiveActivityRuntime.shared.synchronize(workout, zones: activeZoneSet)
                // A discarded or otherwise ended workout takes its set log with it. A normal finish is
                // handled by the Finish action, which marks the session as finishing first.
                if workout.state == .discarded || workout.state == .completed, trainLive.workoutID == id {
                    await trainLive.abandon()
                }
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

    private var metricHabitStore: (any HabitStore)? {
        if let store = repositories.persistent?.habits { return store }
        #if DEBUG
        return fixtureHabitStore
        #else
        return nil
        #endif
    }

    private func consumeBandEvents() async {
        await LooprHeadlessBandActions.stop()
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
                    Tab(MainTab.today.title, systemImage: MainTab.today.symbol, value: MainTab.today) {
                        NavigationStack(path: $todayNavigation.path) {
                            TodayFeatureRoot(
                                environment: environment,
                                route: routeFromToday,
                                repositories: repositories,
                                openWakeAlarm: { todayNavigation.path.append(.wakeAlarm) },
                                openAgent: openFromToday
                            )
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppTodayRoute.self) { route in todayDestination(route).metricDetailNavigation() }
                                .metricDetailNavigation(zooms: true)
                        }
                        .modifier(dataHost(for: .today))
                    }
                    Tab(MainTab.food.title, systemImage: MainTab.food.symbol, value: MainTab.food) {
                        NavigationStack { FoodTabRoot(repositories: repositories, photoRequested: $foodPhotoRequested,
                                                      labScanRequested: $labScanRequested) }
                            .modifier(dataHost(for: .food))
                    }
                    Tab(MainTab.fitness.title, systemImage: MainTab.fitness.symbol, value: MainTab.fitness) {
                        NavigationStack(path: $workoutsPath) {
                            WorkoutFeatureRoot(
                                route: { destination in openWorkoutRoute(destination, id: nil) },
                                selectedRoute: { destination, workout in
                                    selectedWorkoutID = workout?.id
                                    openWorkoutRoute(destination, id: workout?.id)
                                },
                                trainRoute: { destination in
                                    // A summary opened from a This week row goes back to the tab on Done.
                                    if case .summary = destination { trainSummaryFromList = true }
                                    workoutsPath.append(.train(destination))
                                },
                                startTemplateSession: { setup in startTemplateSession(setup) },
                                startRecordingSession: { activity in requestWorkoutStart(source: .live, activity: activity) },
                                openProtocol: { openTabHome(.protocol) },
                                repositories: repositories
                            )
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppWorkoutRoute.self) { route in workoutDestination(route) }
                        }
                        .modifier(dataHost(for: .fitness))
                    }
                    Tab(MainTab.protocol.title, image: MainTab.protocol.symbol, value: MainTab.protocol) {
                        NavigationStack(path: $journalPath) {
                            JournalFeatureRoot(route: { journalPath.append($0) }, push: { journalPath.append($0) },
                                               repositories: repositories,
                                               segmentRequest: protocolSegmentRequest)
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: JournalKit.JournalRoute.self) { route in
                                    JournalDestinationFeatureRoot(route: route, repositories: repositories)
                                        .looprAskToolbar(origin: MainTab.protocol.title)
                                }
                        }
                        .modifier(dataHost(for: .protocol))
                    }
                    Tab(MainTab.data.title, systemImage: MainTab.data.symbol, value: MainTab.data) {
                        NavigationStack(path: $healthPath) {
                            HealthHomeScreen { healthPath.append($0) }
                                .toolbar(.hidden, for: .navigationBar)
                                .navigationDestination(for: AppHealthRoute.self) { route in
                                    healthDestination(route).metricDetailNavigation()
                                }
                                .metricDetailNavigation(zooms: true)
                        }
                        .environment(\.looprTabScrollRequest, tabScrollRequest[.data])
                        // Data reads the history Today reads, so both tabs agree on a day's numbers.
                        .environment(\.metricHistoryProvider, DataTabHistory.provider(
                            environment: environment, repositories: repositories, fallback: metricHistoryProvider))
                        .modifier(dataHost(for: .data))
                    }
                }
                .id(repositories.graphIdentity)
            }
        }
    }

    /// The band button. On Data, Your data is pushed on Data's stack. On another tab it covers that tab, so
    /// back returns to the screen the person came from and that tab keeps its place.
    private func openYourData() {
        if selection == .data {
            if !healthPath.contains(.yourData) { healthPath.append(.yourData) }
        } else {
            yourDataTab = selection
        }
    }

    /// Pops Your data and anything it opened.
    private func closeYourData() {
        if let index = healthPath.firstIndex(of: .yourData) { healthPath.removeSubrange(index...) }
    }

    private func dataHost(for tab: MainTab) -> YourDataTabHost {
        YourDataTabHost(isPresented: Binding(get: { yourDataTab == tab }, set: { if !$0 { yourDataTab = nil } }),
            repositories: repositories, openTab: { tab in
                yourDataTab = nil
                selection = tab
            })
    }

    @ViewBuilder
    private func todayDestination(_ route: AppTodayRoute) -> some View {
        switch route {
        case .feature(.sleep), .feature(.heart), .feature(.body):
            Color.clear.task {
                if case .feature(let feature) = route { routeFromToday(feature) }
            }
        case .feature(.coach): CoachFeatureRoot(
            environment: environment,
            repositories: repositories,
            openChatID: todayNavigation.coachChatID,
            consumeOpenChatID: { todayNavigation.coachChatID = nil }
        )
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
        case .patterns: patternsDestination(repositories: repositories)
        case .records(let route): RecordsDestinationFeatureRoot(route: route, repositories: repositories)
        case .stress(let route): StressDestinationFeatureRoot(route: route, repositories: repositories, navigate: { todayNavigation.path.append(.stress($0)) })
        case .startBreathing(let bandPacing, _):
            StressDestinationFeatureRoot(route: .breathing, repositories: repositories, autoStart: true, bandPacing: bandPacing)
        case .wakeAlarm: WakeAlarmFeatureRoot(repositories: repositories)
        }
    }

    @ViewBuilder
    private func healthDestination(_ route: AppHealthRoute) -> some View {
        switch route {
        case .allMetrics: MetricLibraryScreen()
        case .metric(let key): MetricDetailScreen(key: key)
        case .yourData:
            // Your data is a screen on Data's own stack, so back returns to Data.
            YourDataScreen(repositories: repositories, route: { healthPath.append(.settingsFlow($0)) },
                openTab: { tab in
                    closeYourData()
                    selection = tab
                })
        case .settingsFlow(let route):
            SettingsFlowRoot(repositories: repositories)
                .flowDestination(route, navigate: { healthPath.append(.settingsFlow($0)) })
        case .publish:
            PublishDashboardRoot(environment: environment, repositories: repositories)
        case .sleepHome:
            SleepFeatureRoot(environment: environment, route: { openSleepRoute($0) }, repositories: repositories)
                .looprHeaderInNavigationBar()
        case .heartHome:
            // Data shows Heart as Recovery: last night's numbers against the usual range every Data screen uses, then the
            // day's heart rate, and the live reading last (Data ICP R1-SW-10, R1-NEW-09).
            HeartFeatureRoot(environment: environment,
                             layout: HeartScreenLayout(title: "Recovery", overnight: AnyView(VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                                 // The chart leads, as on every area page; last night's rows follow (Data ICP R3).
                                 DataAreaTrend(keys: DataLastNightCard.keys, accent: .heart, identifier: "data-recovery-trend",
                                               showsLatest: true)
                                 DataLastNightCard()
                             }), liveAtBottom: true,
                                                       showsStressLink: false, advancedTitle: "More heart numbers"),
                             route: { healthPath.append(.heart(.feature($0))) }, repositories: repositories)
                .looprHeaderInNavigationBar()
        case .bodyHome, .bodyMeasures:
            BodyFeatureRoot(environment: environment, focus: route == .bodyMeasures ? .body : .strain,
                            route: { healthPath.append(.body($0)) }, repositories: repositories)
                .environment(\.bodyOpenProfile, BodyProfileAction { openProfileAge() })
                .environment(\.bodyOpenLog, BodyLogAction { healthPath.append(.bodyLog) })
                .environment(\.looprAreaTrend, AnyView(route == .bodyMeasures
                    ? DataAreaTrend(keys: [.vo2Max], accent: .brand, identifier: "data-body-trend", showsLatest: true)
                    : DataAreaTrend(keys: [.strain], accent: .strain, identifier: "data-strain-trend")))
                .looprHeaderInNavigationBar()
        case .bodyLog:
            BodyLogFeatureRoot(environment: environment, repositories: repositories)
        case .stressHome:
            StressFeatureRoot(route: { healthPath.append(.stress($0)) }, repositories: repositories)
                .environment(\.looprAreaTrend, AnyView(DataAreaTrend(keys: [.stress], accent: .heart, identifier: "data-stress-trend")))
                .looprHeaderInNavigationBar()
                .looprAskToolbar(origin: "Stress and breathing")
        case .recordsHome:
            RecordsFeatureRoot(route: { healthPath.append(.records($0)) }, repositories: repositories)
                .looprAskToolbar(origin: "Records")
        case .records(let route):
            RecordsDestinationFeatureRoot(route: route, repositories: repositories)
        case .sleep(let route): sleepDestination(route).looprAskToolbar(origin: "Sleep")
        case .heart(let route): appHeartDestination(route).looprAskToolbar(origin: "Heart")
        case .body(let route): bodyDestination(route).looprAskToolbar(origin: "Strain and load")
        case .stress(let route):
            StressDestinationFeatureRoot(route: route, repositories: repositories,
                navigate: { healthPath.append(.stress($0)) }).looprAskToolbar(origin: "Stress and breathing")
        case .labs, .labReport, .labEntry, .labClockEntry, .labMarker:
            LabsFeatureRoot(route: route, repositories: repositories, navigate: { healthPath.append($0) })
        case .method(let id): MethodRouteScreen(id: id)
        case .methods: MethodListScreen { healthPath.append(.method($0)) }
        }
    }

    @ViewBuilder
    private func sleepDestination(_ route: SleepKit.SleepRoute) -> some View {
        SleepDestinationFeatureRoot(environment: environment, route: route, repositories: repositories,
                                    navigate: { openSleepRoute($0) })
    }

    /// Sleep's coach row opens the Ask sheet, like every other way into Ask. The rest push onto Health.
    private func openSleepRoute(_ route: SleepKit.SleepRoute) {
        if case .coach = route { openAsk(from: "Sleep") } else { healthPath.append(.sleep(route)) }
    }

    @ViewBuilder
    private func appHeartDestination(_ route: AppHeartRoute) -> some View {
        switch route {
        case .feature(.stress):
            StressFeatureRoot(route: { healthPath.append(.stress($0)) }, repositories: repositories)
        case .feature(let route): heartDestination(route)
        case .stress(let route):
            StressDestinationFeatureRoot(route: route, repositories: repositories,
                navigate: { healthPath.append(.stress($0)) })
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
                        openWorkoutRoute(destination, id: id)
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
                case .doAgain: repeatWOD(from: id)
                case .delete: if case .detail = workoutsPath.last { workoutsPath.removeLast() }
                }
            }, repositories: repositories)
        case .detectedReview(let detection):
            WorkoutDetectedReviewScreen(
                detection: detection,
                onSave: { activity, startedAt, endedAt, title in
                    try await acceptDetectedWorkout(
                        detection: detection,
                        activity: activity,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        title: title
                    )
                },
                onDiscard: {
                    try await discardDetectedWorkout(detection)
                },
                onAccepted: { workout in
                    selectedWorkoutID = workout.id
                    // A band session saved as a WOD goes on to its score (R1-WOD-09).
                    workoutsPath.append(workout.activity == .crossfit ? .edit(workout.id) : .detail(workout.id))
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
                onSave: { @Sendable [repositories] finished, title in
                    guard let session = await repositories.workoutSession, let record = finished.record(title: title) else { throw HandsFreeError.storage }
                    let hooks = await repositories.workoutFinalizationHooks
                    return try await session.reconcile(record, hooks: hooks).id
                },
                onDiscard: { @Sendable [repositories] id in
                    guard let session = await repositories.workoutSession else { throw HandsFreeError.storage }
                    try await session.delete(id: id)
                },
                bandCueUnavailableReason: { @Sendable [runtime = repositories.deviceCenterRuntime] in
                    await BandCueAvailability.reason(runtime: runtime)
                }
            )
        case .catalog, .startPicker:
            startPicker(initialActivity: .run)
        case .prepare(let activity):
            startPicker(initialActivity: activity)
        case .log:
            quickLog(initialActivity: nil)
        case .logActivity(let activity):
            quickLog(initialActivity: activity)
        case .wod(let repeating):
            WODLogScreen(
                initialName: repeating,
                now: { workoutLogNow() },
                loadRecords: workoutLogRecords(),
                route: { destination in finishLogRoute(destination) },
                onSave: { entry in try await saveManualWorkout(entry) }
            )
        case .edit(let id):
            if let id {
                WorkoutEditScreen(
                    now: { workoutLogNow() },
                    loadRecords: workoutLogRecords(),
                    loadWorkout: { await repositories.workoutSession?.workout(id: id) },
                    route: { destination in
                        switch destination {
                        case .finish:
                            // Back to the detail the edit came from, or a fresh one in its place.
                            if case .detail = workoutsPath.dropLast().last { workoutsPath.removeLast() }
                            else { workoutsPath[workoutsPath.count - 1] = .detail(id) }
                        default: openWorkoutRoute(destination, id: id)
                        }
                    },
                    onSave: { entry in try await editWorkoutRecord(id: id, entry: entry) }
                )
            } else {
                ContentUnavailableView("Workout unavailable", systemImage: "figure.run", description: Text("Choose a saved workout before editing."))
                    .accessibilityIdentifier("workout-edit-unavailable")
            }
        case .finish(let id):
            WorkoutFinishScreen(
                session: repositories.workoutSession,
                workoutID: id,
                onDone: { workoutsPath.removeAll() },
                onEdit: { workoutID in workoutsPath.append(.edit(workoutID)) },
                // The page's map opens the full route, as it does from the list.
                onAction: { action in presentedRouteWorkout = PresentedRouteWorkout(id: action.workoutID) }
            )
            .environment(\.workoutHeartRateRecoveryProvider, repositories.persistent.map {
                StoredWorkoutRecoveryProvider(history: $0.historyDatabase, workouts: $0.workouts, profile: $0.profile)
            })
            .environment(\.workoutDetailContextProvider, HealthWorkoutDetailContextProvider.make(repositories: repositories))
            .environment(\.workoutPageProvider, AppWorkoutPageProvider.make(repositories: repositories, usesMiles: measurementSystem == .imperial))
        case .train(let route):
            TrainDestinationRoots(route: route, runtime: trainLive, actions: trainSessionActions(inModal: false))
        }
    }

    private func startPicker(initialActivity: ActivityType) -> some View {
        WorkoutStartPickerScreen(initialActivity: initialActivity,
                                 loadZoneContext: { @Sendable in await loadWorkoutZoneContext() }) { destination in
            switch destination {
            case .live(let activity): requestWorkoutStart(source: .live, activity: activity)
            default: openWorkoutRoute(destination, id: nil)
            }
        }
    }

    /// The quick log (R1-NEW-02). Gym opens the empty gym workout and WOD the WOD log, in place of the log.
    private func quickLog(initialActivity: ActivityType?) -> some View {
        WorkoutQuickLogScreen(
            initialActivity: initialActivity,
            now: { workoutLogNow() },
            loadRecords: workoutLogRecords(),
            route: { destination in finishLogRoute(destination) },
            onSave: { entry in try await saveManualWorkout(entry) }
        )
    }

    /// A log screen's way out: the saved workout's detail takes the log's place, so Back returns to Fitness.
    private func finishLogRoute(_ destination: WorkoutKit.WorkoutRoute) {
        switch destination {
        case .finish:
            if workoutsPath.isEmpty { workoutsPath.append(.detail(selectedWorkoutID)) }
            else { workoutsPath[workoutsPath.count - 1] = .detail(selectedWorkoutID) }
        case .gymWorkout, .wod:
            if !workoutsPath.isEmpty { workoutsPath.removeLast() }
            openWorkoutRoute(destination, id: nil)
        default:
            openWorkoutRoute(destination, id: selectedWorkoutID)
        }
    }

    /// Every record, as list rows, for the log screens' recents and benchmark history.
    private func workoutLogRecords() -> @Sendable () async -> [WorkoutRecord] {
        let session = repositories.workoutSession
        return { @Sendable in
            await session?.list(WorkoutLogQuery(range: .all, now: .distantFuture), detail: .listing) ?? []
        }
    }

    /// The clock the log screens read. The Train fixture pins it to its Tuesday, so a log lands in the fixture week.
    private func workoutLogNow() -> Date {
        #if DEBUG
        if repositories.isFixtureComposition, AppTrainFixtures.isRequested() { return AppTrainFixtures.now }
        #endif
        return repositories.environment.dateProvider.now()
    }

    /// "Do it again" on a WOD's detail: the WOD log filled from its last result with that name.
    private func repeatWOD(from id: UUID?) {
        guard let id else { return }
        Task { @MainActor in
            let name = await repositories.workoutSession?.workout(id: id)?.wod?.name
            workoutsPath.append(.wod(name))
        }
    }

    /// Pushes a package route, or starts what it asks for: the empty gym workout from the quick log's Gym chip.
    private func openWorkoutRoute(_ destination: WorkoutKit.WorkoutRoute, id: UUID?) {
        switch destination {
        case .gymWorkout:
            // Gym in the quick log is a session already done: its sets as a table, no live screen (R2-LIFT-05).
            workoutsPath.append(.train(.pastSession))
        case .logActivity(.strength):
            startEmptyGymWorkout()
        case .heartSettings:
            // The run setup's Zone 2 chip: the zones are set on the Heart screen (R2-DES-17).
            openHealth(.heartHome)
        default:
            if let route = appWorkoutRoute(destination, id: id) { workoutsPath.append(route) }
        }
    }

    private func startEmptyGymWorkout() {
        let history = ((try? repositories.makeTrainRepository().sessions()) ?? []).filter { $0.status == .completed }
        startTemplateSession(.freeform(history: history, timeZoneIdentifier: TimeZone.current.identifier))
    }

    private func appWorkoutRoute(_ destination: WorkoutKit.WorkoutRoute, id: UUID?) -> AppWorkoutRoute? {
        switch destination {
        case .catalog: .catalog
        case .intervals: .intervals
        case .log: .log
        case .edit: .edit(id)
        case .startPicker: .startPicker
        // WOD from the start sheet or the start screen opens the WOD log (R1-WOD-01).
        case .prepare(.crossfit), .logActivity(.crossfit), .wod: .wod(nil)
        case .prepare(let activity): .prepare(activity)
        case .logActivity(let activity): .logActivity(activity)
        case .repeatWOD(let name): .wod(name)
        case .gymWorkout, .heartSettings: nil
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

    private func startWorkout(source: WorkoutSource, activity: ActivityType = .run, wantsRoute: Bool = false,
                              train setup: TrainLiveSetup? = nil) {
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
                // A template session adds the set log on top of the recording. If it cannot start, the
                // plain live screen still records.
                var showsSetScreen = false
                if let setup {
                    do { try await beginTrainSession(setup, workout: workout); showsSetScreen = true }
                    catch { workoutActionError = error.localizedDescription }
                }
                await LooprLiveActivityRuntime.shared.synchronize(workout, zones: activeZoneSet)
                await LooprHeartAlertsRuntime.shared.noteWorkout(id: workout.id.uuidString, start: workout.startedAt ?? Date(), end: nil)
                if showsSetScreen {
                    workoutsPath.append(.train(.live))
                } else {
                    workoutsPath.append(source == .live ? .live(workout.id, activity) : .finish(workout.id))
                }
            } catch {
                workoutHaptic = WorkoutHapticEvent(kind: .failed)
                workoutActionError = error.localizedDescription
            }
        }
    }

    // MARK: Strength session

    /// Starts a strength session from a template on the normal live path: the workout is recorded as
    /// strength and live, so zone alerts, the Live Activity, strain, the mini-player and the Journal
    /// "trained today" answer all work as they do for any workout. The set screen opens on top.
    private func startTemplateSession(_ setup: TrainLiveSetup) {
        if trainLive.hasSession {
            // Already training: go back to the set screen instead of starting a second recording.
            if workoutsPath.last != .train(.live) { workoutsPath.append(.train(.live)) }
            return
        }
        // Check the template before a recording starts, so a bad one never leaves a workout running.
        do { _ = try TrainLiveModel(setup: setup, now: Date()) }
        catch { workoutActionError = error.localizedDescription; return }
        startWorkout(source: .live, activity: .strength, train: setup)
    }

    private func beginTrainSession(_ setup: TrainLiveSetup, workout: WorkoutRecord) async throws {
        var setup = setup
        setup.workoutID = workout.id
        let repository = repositories.makeTrainRepository()
        setup.swapPool = await TrainLiveRuntime.loadSwapPool(repository: repository)
        try trainLive.begin(setup: setup, environment: await trainLiveEnvironment(repository: repository))
    }

    private func trainLiveEnvironment(repository: AppTrainRepository) async -> TrainLiveEnvironment {
        let isFixture = repositories.isFixtureComposition
        var fixtureStart: Date?
        var restOverride: Int?
        var zoneIdentifier = environment.timeZoneProvider.timeZone.identifier
        #if DEBUG
        if isFixture, AppTrainFixtures.isRequested() {
            fixtureStart = AppTrainFixtures.now
            restOverride = AppTrainFixtures.restSecondsOverride()
            zoneIdentifier = AppTrainFixtures.zone.identifier
        }
        #endif
        let band = isFixture ? nil : repositories.deviceCenterRuntime
        let unavailable = isFixture ? nil : await BandCueAvailability.reason(runtime: band)
        return TrainLiveEnvironment(
            repository: repository, workoutSession: repositories.workoutSession, bandRuntime: band,
            bandCueAvailable: unavailable == nil, clock: TrainLiveRuntime.makeClock(fixtureStart: fixtureStart),
            restSecondsOverride: restOverride, timeZoneIdentifier: zoneIdentifier)
    }

    /// Picks the set log back up when a strength workout is still recording after a relaunch.
    private func resumeTrainSessionIfNeeded(for workout: WorkoutRecord) async {
        guard !trainLive.hasSession, workout.activity == .strength, workout.source == .live else { return }
        let repository = repositories.makeTrainRepository()
        let resumed = await trainLive.resumeIfNeeded(
            for: workout, environment: await trainLiveEnvironment(repository: repository),
            swapPool: { @Sendable in await TrainLiveRuntime.loadSwapPool(repository: repository) })
        // A recovery that opened the plain live screen opens the set screen instead.
        if resumed, workoutsPath.last == .live(workout.id, .strength) {
            workoutsPath[workoutsPath.count - 1] = .train(.live)
        }
    }

    private func trainSessionActions(inModal: Bool) -> TrainSessionActions {
        TrainSessionActions(
            finish: { @MainActor @Sendable in try await finishTrainSession(inModal: inModal) },
            pauseChange: { @MainActor @Sendable paused in
                try await setWorkoutPaused(id: trainLive.workoutID, paused: paused)
            },
            summaryDone: { @MainActor @Sendable workoutID in leaveTrainSummary(workoutID: workoutID) },
            zones: activeZoneSet,
            workoutSession: repositories.workoutSession)
    }

    /// Saves the session, finishes the recording and swaps the set screen for the summary.
    private func finishTrainSession(inModal: Bool) async throws {
        let workoutID = trainLive.workoutID
        let completed = try await trainLive.finish {
            _ = try await finishWorkoutRecord(id: workoutID)
        }
        trainSummaryFromList = false
        selection = .fitness
        workoutsPath.removeAll { $0 == .train(.live) }
        workoutsPath.append(.train(.summary(completed.id)))
        if inModal { router.dismiss() }
        // The sheet and the pushed screen read the session while they animate away.
        try? await Task.sleep(for: .milliseconds(600))
        trainLive.end()
    }

    /// Done on the summary opens the finished workout. Back from there returns to Train. A summary opened from the
    /// tab's This week list is already the session's detail, so Done goes back to the tab.
    private func leaveTrainSummary(workoutID: UUID?) {
        selection = .fitness
        if trainSummaryFromList {
            trainSummaryFromList = false
            if case .train(.summary)? = workoutsPath.last { workoutsPath.removeLast() }
            return
        }
        if let workoutID {
            selectedWorkoutID = workoutID
            workoutsPath = [.detail(workoutID)]
        } else {
            workoutsPath = []
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

    private func saveManualWorkout(_ entry: WorkoutLogEntry) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession else { throw WorkoutTransitionError.missingWorkout }
        let workout = try await session.logManual(entry, hooks: repositories.workoutFinalizationHooks)
        selectedWorkoutID = workout.id
        workoutHaptic = WorkoutHapticEvent(kind: .saved)
        await LooprNotificationRuntime.shared.workoutCompleted(id: workout.id, at: workout.endedAt ?? Date())
        return workout
    }

    private func acceptDetectedWorkout(
        detection: WorkoutKit.DetectedWorkout,
        activity: ActivityType,
        startedAt: Date,
        endedAt: Date,
        title: String?
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
            endedAt: endedAt,
            title: title
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
            let route = try await recorder.finish()
            // The list reads a session's distance from its samples, without opening the route.
            let meters = RouteAnalysis.distanceMeters(route: route)
            if meters > 0 { try? await repositories.workoutSession?.append(WorkoutSample(timestamp: Date(), distanceMeters: meters)) }
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

    private func editWorkoutRecord(id: UUID, entry: WorkoutLogEntry) async throws -> WorkoutRecord {
        guard let session = repositories.workoutSession else { throw WorkoutTransitionError.missingWorkout }
        let workout = try await session.edit(id: id, entry: entry)
        selectedWorkoutID = workout.id
        return workout
    }

    private func sheetAccent(for route: AppModalRoute) -> LooprColorToken {
        switch route {
        case .activeWorkout: .movement
        case .settings, .yourData: selection.accent
        case .ask: .brand
        #if DEBUG
        case .zoneCapture: .movement
        case .designSystem: selection.accent
        #endif
        }
    }

    @ViewBuilder
    private func modal(for route: AppModalRoute) -> some View {
        switch route {
        case .ask:
            NavigationStack {
                CoachFeatureRoot(environment: environment, repositories: repositories,
                    openChatID: todayNavigation.coachChatID, origin: askOrigin,
                    consumeOpenChatID: { todayNavigation.coachChatID = nil },
                    onDone: { @MainActor @Sendable in router.dismiss() },
                    attachPhoto: { @MainActor @Sendable in openFoodPhotoCapture() },
                    openSource: { @MainActor @Sendable link in apply(.agentSource(link)) })
            }
            .accessibilityIdentifier("ask-sheet")
        case .yourData:
            SettingsFlowRoot(dismiss: { router.dismiss() }, repositories: repositories, startsWithYourData: true, openTab: { tab in
                router.dismiss()
                selection = tab
            })
            .tint(Color.loopr(.brand))
        case .settings:
            SettingsFlowRoot(
                dismiss: { router.dismiss() },
                repositories: repositories,
                initialPath: router.settingsInitialPath,
                focusesAge: router.settingsFocusAge
            )
        case .activeWorkout where trainLive.hasSession:
            NavigationStack {
                TrainSessionRoot(route: .live, runtime: trainLive, actions: trainSessionActions(inModal: true))
                    .accessibilityIdentifier("active-workout-modal")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { router.dismiss() }
                        }
                    }
            }
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
                        selection = .fitness
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
        // `--loopr-train-fixture=live` opens the frozen live set screen. No other deep link applies to it.
        if repositories.isFixtureComposition, AppTrainFixtures.isLiveRequested() {
            appliedDeepLink = true
            selection = .fitness
            workoutsPath = [.train(.live)]
            return
        }
        guard !appliedDeepLink, let link = ShellDeepLink.parse(arguments: ProcessInfo.processInfo.arguments) else { return }
        appliedDeepLink = true
        apply(link)
        #endif
    }

    func apply(_ link: ShellDeepLink) {
        switch link {
        case .todayHome: openTabHome(.today)
        case .dataHome: openTabHome(.data)
        case .foodHome: openTabHome(.food)
        case .fitnessHome: openTabHome(.fitness)
        case .protocolHome: openTabHome(.protocol)
        case .breathing(let start, let bandPacing):
            selection = .today
            todayNavigation.path = [start ? .startBreathing(bandPacing: bandPacing, requestID: UUID()) : .stress(.breathing)]
        case .intervals: selection = .fitness; workoutsPath = [.intervals]
        case .syncBand:
            Task { @MainActor in
                do {
                    let complete = try await LooprHandsFreeRuntime.shared.syncBand()
                    handsFreeMessage = complete ? "Band sync finished." : "Sync did not finish. Connect your band and try again."
                } catch { handsFreeMessage = error.localizedDescription }
            }
        case .todayDetail: openAsk(from: "Today")
        case .sleepDetail: openHealth(.sleepHome)
        case .heartHome: openHealth(.heartHome)
        case .heartDetail: selection = .data; healthPath = [.heartHome, .heart(.feature(.detail))]
        case .heartTrends: selection = .data; healthPath = [.heartHome, .heart(.feature(.trends))]
        case .bodyDetail: openHealth(.bodyHome)
        case .workoutsDetail: selection = .fitness; workoutsPath = [.detail(nil)]
        case .trainSession(let id): selection = .fitness; workoutsPath = [.train(.summary(id))]
        #if DEBUG
        case .zoneCapture: router.present(.zoneCapture)
        #endif
        case .habitInsights:
            selection = .protocol
            journalPath = NavigationPath([AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .habitInsights : .history] as [JournalKit.JournalRoute])
        case .habitSetup:
            selection = .protocol
            journalPath = NavigationPath([AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .habitSetup : .history] as [JournalKit.JournalRoute])
        case .habitManagement:
            selection = .protocol
            journalPath = NavigationPath([AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .habits : .history] as [JournalKit.JournalRoute])
        case .habitHistory:
            selection = .protocol
            journalPath = NavigationPath([AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .habitHistory : .history] as [JournalKit.JournalRoute])
        case .habitDetail:
            selection = .protocol
            journalPath = NavigationPath([AppHabitFeatureGate.currentStage.exposesEntryPoints
                ? .habitDetail(HabitFixtures.definition.id) : .history] as [JournalKit.JournalRoute])
        case .habitCheckIn(let day):
            selection = .protocol
            if AppHabitFeatureGate.currentStage.exposesEntryPoints,
               let identity = DayIdentity(habitKey: day) {
                journalPath = NavigationPath([.checkIn(identity)] as [JournalKit.JournalRoute])
            } else {
                journalPath = NavigationPath([.history] as [JournalKit.JournalRoute])
            }
        case .recordsDetail: openHealth(.recordsHome)
        case .recordsRecap: selection = .data; healthPath = [.recordsHome, .records(.recap)]
        case .gestureMapping:
            router.settingsInitialPath = [.settings(.deviceCenter), .device(.gestures)]
            router.present(.settings)
        case .coach: openAsk(from: "Today")
        case .coachChat(let id): askOrigin = nil; todayNavigation.coachChatID = id; router.present(.ask)
        case .goals: selection = .today; todayNavigation.path = [.feature(.goalSettings)]
        case .stress: selection = .today; todayNavigation.path = [.stress(.stress)]
        case .settings(let destination):
            router.settingsFocusAge = false
            router.settingsInitialPath = [.settings(destination)]
            router.present(.settings)
        case .wakeAlarm: selection = .today; todayNavigation.path = [.wakeAlarm]
        case .patterns: if LooprPatternsRuntime.isEnabled { selection = .today; todayNavigation.path = [.patterns] }
        case .settingsHome:
            router.settingsFocusAge = false
            router.settingsInitialPath = []
            router.present(.settings)
        case .workout(let identifier):
            selection = .fitness
            selectedWorkoutID = identifier
            workoutsPath = [.detail(identifier)]
        case .agentSource(let source): openAgentSource(source)
        case .weeklyReview: openWeeklyReview()
        case .protocolSegment(let segment):
            openTabHome(.protocol)
            protocolSegmentRequest = ProtocolSegmentRequest(segment: segment)
        }
    }

    /// Opens the weekly review sheet over whatever is showing. A sheet already up closes first.
    private func openWeeklyReview() {
        guard let environment = WeeklyReviewEnvironment.live(repositories: repositories, history: metricHistoryProvider) else { return }
        router.dismiss()
        yourDataTab = nil
        Task { await weeklyReview.open(environment) }
    }

    /// `--loopr-weekly-review=open` opens the sheet on the DEBUG fixture story.
    private func openWeeklyReviewFixtureIfRequested() {
        #if DEBUG
        guard WeeklyReviewFixture.isRequested(), weeklyReview.sheet == nil else { return }
        weeklyReview.present(WeeklyReviewFixture.result(), week: WeeklyReviewFixture.week,
                             environment: WeeklyReviewFixture.environment())
        #endif
    }

    /// Every tab's avatar opens Settings at its root.
    private func openSettings() {
        router.settingsFocusAge = false
        router.settingsInitialPath = []
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
        router.settingsInitialPath = [.settings(.profile)]
        router.settingsFocusAge = true
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
                selection = .fitness
                if workoutsPath.isEmpty { workoutsPath.append(.recovery(first.id)) }
                return
            }
        } catch {
            workoutActionError = error.localizedDescription
        }
        if let active = await session.activeWorkout() {
            selectedWorkoutID = active.id
            activeWorkout = active
            await resumeTrainSessionIfNeeded(for: active)
            try? await session.reattachLiveSamples()
            await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: active)
            return
        }
        if let selected = await session.selectedWorkoutID() {
            selectedWorkoutID = selected
            if let row = await session.workout(id: selected), row.isActive {
                activeWorkout = row
                await resumeTrainSessionIfNeeded(for: row)
            }
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

    private func openAsk(from screen: String, prompt: String? = nil) {
        todayNavigation.coachChatID = nil
        let navigation = daySelection.navigation
        askOrigin = AskOrigin(screen: screen, navigation: navigation, day: daySelection.day.habitKey,
            date: LooprDays.noon(of: daySelection.day, calendar: .current) ?? Date(), prompt: prompt)
        router.present(.ask)
    }

    /// The camera button in Ask. Food owns capture and its own consent, so Ask closes and the
    /// Food tab opens the same screen "Log a meal" opens.
    private func openFoodPhotoCapture() {
        router.dismiss()
        foodPhotoRequested = true
        selection = .food
    }

    private func openHealth(_ route: AppHealthRoute) {
        healthPath = [route]
        selection = .data
    }

    /// Blood tests' "Scan a report": the Food camera opens in Lab mode. Its "See it in blood tests" comes back to Data.
    private func openLabScan() {
        labScanRequested = true
        selection = .food
    }

    /// Lab mode's "See it in blood tests": Data opens on the saved report, with the blood tests list under it.
    private func openLabReport(_ id: UUID) {
        healthPath = LabReportLink.path(for: id)
        selection = .data
    }

    /// Lab mode's "Type it in instead": Data opens typed entry, with the blood tests list under it.
    private func openLabEntry() {
        healthPath = LabReportLink.entryPath
        selection = .data
    }

    private func openTabHome(_ tab: MainTab) {
        switch tab {
        case .data: healthPath = []
        case .today: todayNavigation.path = []
        case .fitness: workoutsPath = []
        case .protocol: journalPath = NavigationPath()
        case .food: break
        }
        tabScrollRequest[tab] = LooprTabScrollRequest()
        selection = tab
    }

    /// A row, a timeline moment or the pattern card on Today. Each opens the tab that owns the data.
    private func openFromToday(_ destination: TodayAgentDestination) {
        switch destination {
        case .tab(let tab):
            switch tab {
            case .food: apply(.foodHome)
            case .fitness: apply(.fitnessHome)
            case .protocol: apply(.protocolHome)
            case .data: apply(.dataHome)
            case .today: apply(.todayHome)
            }
        case .patterns: apply(.patterns)
        case .method(let id): openHealth(.method(id))
        case .protocolSegment(let segment): apply(.protocolSegment(segment))
        case .allMetrics: openHealth(.allMetrics)
        }
    }

    private func routeFromToday(_ route: TodayKit.TodayRoute) {
        switch route {
        case .sleep: openHealth(.sleepHome)
        case .heart: openHealth(.heartHome)
        case .body: openHealth(.bodyHome)
        case .journal: openTabHome(.protocol)
        case .coach: openAsk(from: "Today")
        case .settings: openSettings()
        default: todayNavigation.path.append(.feature(route))
        }
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

/// The mini-player reopens the active workout. On that workout's own live screen it would only
/// cover the content (the set table and rest card on mock 12), so it hides there and shows everywhere else.
nonisolated enum ActiveWorkoutAccessoryVisibility {
    static func isShown(activeWorkoutID: UUID?, selection: MainTab, path: [AppWorkoutRoute]) -> Bool {
        guard let activeWorkoutID else { return false }
        guard selection == .fitness, let top = path.last else { return true }
        switch top {
        case .train(.live): return false
        case .live(let id, _): return id != activeWorkoutID
        default: return true
        }
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

/// Settings keeps its own typed path while the originating tab keeps its scroll
/// position and feature state. Both navigation stacks are siblings inside the tab.
private struct YourDataTabHost: ViewModifier {
    @Binding var isPresented: Bool
    let repositories: ProductRepositoryContainer
    let openTab: (MainTab) -> Void

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(isPresented ? 0 : 1)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            if isPresented {
                SettingsFlowRoot(dismiss: { isPresented = false }, repositories: repositories,
                    startsWithYourData: true, usesBackButton: true, openTab: openTab)
            }
        }
    }
}
