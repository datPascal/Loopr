import Combine
import Foundation
import ProtocolKit
import SyncKit
import BodyKit
import BluetoothKit
import CoachKit
import CycleKit
import DataKit
import ImportKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import HeartKit
import HealthKitBridge
import JournalKit
import NotificationKit
import OnboardingKit
import RecordsKit
import RouteKit
import ProfileKit
import SettingsKit
import SleepKit
import StorageKit
import StressKit
import SwiftUI
import TodayKit
import UniformTypeIdentifiers
#if DEBUG
import OSLog
#endif
import WorkoutKit

enum AppTodayRoute: Hashable {
    case feature(TodayKit.TodayRoute)
    case sleep(SleepKit.SleepRoute)
    case heart(HeartKit.HeartRoute)
    case body(BodyKit.BodyRoute)
    case journal(JournalKit.JournalRoute)
    case records(RecordsKit.RecordsRoute)
    case stress(StressKit.StressRoute)
    case startBreathing(bandPacing: Bool, requestID: UUID)
    case wakeAlarm
}

/// App-owned workout routes carry the canonical record identity across detail,
/// route, share, edit, and finish screens. WorkoutKit's package route remains
/// the feature callback type; the app adds identity at the navigation boundary.
nonisolated enum AppWorkoutRoute: Hashable {
    case catalog
    case intervals
    case log
    case edit(UUID?)
    case startPicker
    case live(UUID?, ActivityType)
    case finish(UUID?)
    case detail(UUID?)
    case recovery(UUID?)
    case route(UUID?)
    case sharePreview(UUID?)
    case detectedReview(DetectedWorkout)
}

enum AppWorkoutPathTransition {
    static func replacingLiveWithCompletedSummary(
        in path: [AppWorkoutRoute],
        workoutID: UUID
    ) -> [AppWorkoutRoute] {
        var updated = path
        if let lastIndex = updated.indices.last,
           case .live = updated[lastIndex] {
            updated[lastIndex] = .finish(workoutID)
        } else {
            updated.append(.finish(workoutID))
        }
        return updated
    }

    static func detailDestination(for action: WorkoutFinishSummaryAction) -> AppWorkoutRoute {
        .detail(action.workoutID)
    }
}

struct ProductStorageInitializationFailure: Error, Equatable, Sendable, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum ProductRepositoryGraphIdentity: Hashable {
    case fixture
    case unavailable(UInt64)
    case persistent(UInt64)
}

/// The app owns one durable repository graph for production. DEBUG launch
/// modes intentionally leave this nil so every deterministic visual fixture
/// continues to use its in-memory package seam. A production open failure is
/// exposed as one recoverable dependency instead of silently falling back to
/// fixture records.
@MainActor
final class ProductRepositoryContainer: ObservableObject {
    typealias ProductionFactory = @MainActor (
        AppEnvironment,
        (any LooprHeartLiveRuntime)?,
        (any PersistentDataDeletionDeleter)?
    ) throws -> PersistentProductRepositories

    let environment: AppEnvironment
    let heartLiveRuntime: (any LooprHeartLiveRuntime)?
    let heartLiveHistory = HeartLiveHistoryStore()
    @Published private(set) var persistent: PersistentProductRepositories?
    @Published private(set) var storageFailure: ProductStorageInitializationFailure?
    /// Changes whenever production storage is reopened. Storage-gated roots
    /// use this token as their SwiftUI identity so a successful retry cannot
    /// retain StateObjects that were initialized against the fail-closed
    /// fallback repositories from the failed attempt.
    @Published private(set) var storageGeneration: UInt64 = 0
    @Published private(set) var workoutStore: (any WorkoutStore)?
    @Published private(set) var workoutSession: WorkoutSessionController?
    @Published private(set) var detectedWorkouts: (any DetectedWorkoutRepository)?
    let workoutLiveSampleSource: (any WorkoutLiveSampleSource)?
    var workoutFinalizationHooks: WorkoutFinalizationHooks {
        guard let persistent else { return WorkoutFinalizationHooks() }
        let surfaceHooks = LooprWorkoutIntegrationRuntime.shared.hooks()
        return WorkoutFinalizationHooks(
            enqueueHealthKit: { workout in await persistent.healthSync.workoutFinalized(workout) },
            // Finishing a workout changes today's strain, so the widgets, the
            // Watch and the complications need the whole derived snapshot, not
            // a snapshot carrying only the workout's end time.
            publishSnapshot: { _ in await persistent.derivedData.publishNow() },
            updateLiveActivity: surfaceHooks.updateLiveActivity
        )
    }
    private let runtimeDataDeleter: (any PersistentDataDeletionDeleter)?
    private let productionFactory: ProductionFactory

    var storageError: String? { storageFailure?.localizedDescription }
    var isFixtureComposition: Bool { environment.composition != .production }
    /// Production composes one runtime for Heart and Device Center, so the
    /// device seam is the same object rather than a second transport owner.
    var deviceCenterRuntime: (any LooprDeviceCenterRuntime)? {
        heartLiveRuntime as? any LooprDeviceCenterRuntime
    }
    var graphIdentity: ProductRepositoryGraphIdentity {
        if isFixtureComposition { return .fixture }
        if persistent != nil { return .persistent(storageGeneration) }
        return .unavailable(storageGeneration)
    }

    init(
        environment: AppEnvironment,
        heartLiveRuntime: (any LooprHeartLiveRuntime)? = nil,
        runtimeDataDeleter: (any PersistentDataDeletionDeleter)? = nil,
        productionFactory: @escaping ProductionFactory = { environment, runtime, runtimeDataDeleter in
            try PersistentProductRepositories(
                environment: environment,
                heartLiveRuntime: runtime,
                runtimeDataDeleter: runtimeDataDeleter
            )
        }
    ) {
        self.environment = environment
        self.heartLiveRuntime = heartLiveRuntime
        self.runtimeDataDeleter = runtimeDataDeleter
        self.productionFactory = productionFactory
        #if DEBUG
        let fixtureLiveSource = environment.composition == .production ? nil : DebugCaptureFixtures.intervalLiveSource
        #else
        let fixtureLiveSource: (any WorkoutLiveSampleSource)? = nil
        #endif
        self.workoutLiveSampleSource = environment.composition == .production
            ? (heartLiveRuntime.map(SyncKitWorkoutLiveSampleSource.init) ?? UnavailableWorkoutLiveSampleSource())
            : fixtureLiveSource
        guard environment.composition == .production else {
            persistent = nil
            storageFailure = nil
            #if DEBUG
            let workouts = DebugCaptureFixtures.siStoreFixture ? SIPolishFixtureWorld.workouts : [WorkoutFixtures.completedRun, WorkoutFixtures.interrupted]
            #else
            let workouts = [WorkoutFixtures.completedRun, WorkoutFixtures.interrupted]
            #endif
            let store = InMemoryWorkoutStore(workouts: workouts)
            workoutStore = store
            detectedWorkouts = InMemoryDetectedWorkoutRepository(detections: [WorkoutFixtures.detectedRun])
            workoutSession = WorkoutSessionController(store: store, liveSource: workoutLiveSampleSource)
            return
        }
        persistent = nil
        storageFailure = nil
        workoutStore = nil
        workoutSession = nil
        detectedWorkouts = nil
        openProductionStore()
        LooprHandsFreeRuntime.shared.repositories = self
    }

    func retry() {
        guard environment.composition == .production else { return }
        openProductionStore()
    }

    private func openProductionStore() {
        storageGeneration &+= 1
        let signpost = LooprPerformance.begin("OpenProductionStore")
        defer { LooprPerformance.end(signpost) }
        do {
            let repositories = try productionFactory(
                environment,
                heartLiveRuntime,
                runtimeDataDeleter
            )
            persistent = repositories
            let liveSeed = HeartLiveHistorySeed(database: repositories.historyDatabase)
            heartLiveHistory.configureSeed { await liveSeed.samples() }
            Task { await self.heartLiveHistory.seedIfNeeded() }
            workoutStore = repositories.workouts
            detectedWorkouts = repositories.workouts
            workoutSession = WorkoutSessionController(store: repositories.workouts, liveSource: workoutLiveSampleSource)
            if !AppHabitFeatureGate.currentStage.exposesEntryPoints {
                Task { try? await repositories.habitReminderScheduler.cancel() }
            }
            storageFailure = nil
        } catch {
            persistent = nil
            workoutStore = nil
            workoutSession = nil
            detectedWorkouts = nil
            storageFailure = ProductStorageInitializationFailure(message: error.localizedDescription)
        }
    }
}

struct ProductStorageUnavailableView: View {
    let failure: ProductStorageInitializationFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: LooprSpacing.none) {
            StickyHeader(
                title: "Loopr",
                meta: "LOCAL STORAGE",
                status: StatusChip(
                    MetricState.destructiveFailure.title,
                    symbol: MetricState.destructiveFailure.symbol,
                    tone: .critical,
                    accent: .critical
                )
            )
            .zIndex(1)

            LooprDetailScaffold {
                LooprSurface(emphasis: .hero(.critical)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StateMessage(.destructiveFailure)

                        LooprText("Loopr could not open its local storage.", style: .title)
                        LooprInlineMessage(
                            "Nothing was deleted by this error. Your records, profile, and settings remain on this device, but Loopr cannot read them yet.",
                            tone: .neutral
                        )
                        LooprText(
                            "Apple Health data is separate and was not changed.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }

                LooprSectionGroup(title: "What you can do") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText(
                                "Try again now. If storage still will not open, keep Loopr installed and contact support. Include this message if they ask what happened.",
                                style: .prose,
                                color: .inkSecondary
                            )
                            LooprText(
                                "Details to share with support: \(failure.localizedDescription)",
                                style: .caption,
                                color: .inkMuted
                            )
                            Button("Try again", action: retry)
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .accessibilityIdentifier("product-storage-retry")
                        }
                    }
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("product-storage-error")
    }
}

private struct ProductInlineMessageToast<Accessory: View>: View {
    let text: String
    let tone: ChipTone
    let messageIdentifier: String
    let accessory: Accessory

    init(
        _ text: String,
        tone: ChipTone,
        accessibilityIdentifier: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.text = text
        self.tone = tone
        messageIdentifier = accessibilityIdentifier
        self.accessory = accessory()
    }

    var body: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprInlineMessage(text, tone: tone)
                    .accessibilityIdentifier(messageIdentifier)
                accessory
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.bottom, LooprSpacing.sm)
    }
}

private extension ProductInlineMessageToast where Accessory == EmptyView {
    init(_ text: String, tone: ChipTone, accessibilityIdentifier: String) {
        self.init(text, tone: tone, accessibilityIdentifier: accessibilityIdentifier) {
            EmptyView()
        }
    }
}

private func productMessageTone(_ message: String) -> ChipTone {
    let lowercased = message.lowercased()
    let failureWords = ["failed", "could not", "cannot", "unavailable", "error", "denied"]
    return failureWords.contains(where: { lowercased.contains($0) }) ? .critical : .positive
}

/// Shared destructive-action surface used by onboarding and Settings. The
/// package view owns three independent confirmation dialogs; this app root
/// owns the canonical flow controller and therefore never widens one action
/// into another effect.
@MainActor
struct OnboardingDestructiveActionsFeatureRoot: View {
    let repositories: ProductRepositoryContainer?
    @State private var controller: OnboardingFlowController?
    @State private var errorMessage: String?

    var body: some View {
        OnboardingDestructiveActionsScreen(onConfirm: perform)
            .buttonStyle(LooprDestructiveButtonStyle())
            .tint(Color.loopr(.critical))
            .background(Color.loopr(.background).ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    ProductInlineMessageToast(
                        errorMessage,
                        tone: .critical,
                        accessibilityIdentifier: "onboarding-error"
                    )
                }
            }
            .task { await prepare() }
            .productStorageGate(repositories)
    }

    private func prepare() async {
        guard controller == nil else { return }
        do {
            let onboarding: any OnboardingRepository
            let profile: any ProfileRepository
            let effects: any OnboardingDataEffects
            if let persistent = repositories?.persistent {
                onboarding = persistent.onboarding
                profile = persistent.profile
                effects = persistent.destructiveEffects
            } else {
                onboarding = InMemoryOnboardingRepository()
                profile = InMemoryProfileRepository()
                effects = InMemoryOnboardingDataEffects()
            }
            controller = try await OnboardingFlowController(
                repository: onboarding,
                profileRepository: profile,
                dataEffects: effects,
                dateProvider: repositories?.environment.dateProvider ?? SystemDateProvider()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ action: OnboardingDestructiveAction) {
        Task {
            guard let controller else {
                errorMessage = "Data controls are still loading."
                return
            }
            do {
                try await controller.perform(action)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    @ViewBuilder
    func productStorageGate(_ repositories: ProductRepositoryContainer?) -> some View {
        let storageGeneration = repositories?.storageGeneration ?? 0
        if let failure = repositories?.storageFailure {
            ProductStorageUnavailableView(failure: failure, retry: { repositories?.retry() })
                .id(storageGeneration)
        } else {
            // Rebuild the feature root after a retry so its @StateObjects
            // select the newly opened persistent repositories in init.
            self.id(storageGeneration)
        }
    }
}

/// Shared construction seam for repository-owning feature roots. Tests use
/// the same factory to prove a post-retry graph reads durable data rather than
/// the fail-closed in-memory fallback that existed before the identity swap.
@MainActor
enum ProductFeatureViewModelFactory {
    static func makeToday(
        environment: AppEnvironment,
        repositories: ProductRepositoryContainer?
    ) -> TodayViewModel {
        if let persistent = repositories?.persistent {
            return TodayViewModel(
                repository: persistent.today,
                goalsRepository: persistent.todayGoals,
                coachPlanRepository: persistent.coach,
                // Today redesign: history, recovery split and pinned numbers.
                contextRepository: TodayContextSourceFactory.make(environment: environment, repositories: repositories),
                preferencesStore: TodayPreferencesStore()
            )
        }
        let summary = ProductFixture.summary(for: environment.composition)
        let values = repositories?.isFixtureComposition == false ? [:] : ProductFixture.days(summary, day: TodayFixtures.day, composition: environment.composition)
        let goals = values.mapValues(\.goals)
        return TodayViewModel(
            repository: InMemoryTodayRepository(values: values),
            goalsRepository: InMemoryTodayGoalsRepository(values: goals),
            contextRepository: TodayContextSourceFactory.make(environment: environment, repositories: repositories)
        )
    }
}

/// The Today card about the band link.
///
/// A band Loopr already knows takes a second or two to answer, both at launch
/// and after a link drops. While that attempt is in flight the card stays away
/// entirely: a person who owns a working band saw a status card above their
/// rings on every launch, and it almost always resolved on its own. Only a
/// link that is still down once the grace window closes is worth saying.
nonisolated enum TodayBandConnectionCopy {
    static let title = "Band not connected"
    static let bluetoothOffTitle = "Bluetooth is off"
    static let bluetoothOffMessage = "Turn on Bluetooth to sync your band."

    static func message(isPaired: Bool, isConnected: Bool, isResolvingLink: Bool) -> String? {
        guard isPaired, !isConnected, !isResolvingLink else { return nil }
        return "Your band is paired but has not connected yet. Keep it near your iPhone. If it stays disconnected, wake the band until its side light pulses blue."
    }

    /// The card for a debounced band state. Nothing shows while the band is
    /// linked or inside its grace window.
    static func card(for state: BandLinkState, isPaired: Bool) -> (title: String, message: String)? {
        guard isPaired else { return nil }
        switch state {
        case .disconnected:
            return message(isPaired: true, isConnected: false, isResolvingLink: false).map { (title, $0) }
        case .bluetoothOff:
            return (bluetoothOffTitle, bluetoothOffMessage)
        case .needsAttention(let message):
            return (title, message)
        case .connected, .syncing, .reconnecting, .notPaired:
            return nil
        }
    }
}

/// Runs the live heart stream while the band is linked, and keeps it running
/// through a short reconnect so a blip does not tear the stream down.
private struct ConnectedHeartLiveModifier: ViewModifier {
    let viewModel: HeartViewModel
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.scenePhase) private var scenePhase
    let enabled: Bool

    private var shouldRun: Bool {
        enabled && bandLink?.keepsLiveSession == true && scenePhase == .active
    }

    func body(content: Content) -> some View {
        content.task(id: shouldRun) {
            guard shouldRun else { return }
            await viewModel.runLive()
        }
    }
}

@MainActor
struct TodayFeatureRoot: View {
    #if DEBUG
    private static let pairingLogger = Logger(subsystem: "com.loopr.ios", category: "pairing")
    #endif
    let environment: AppEnvironment
    let route: (TodayKit.TodayRoute) -> Void
    let repositories: ProductRepositoryContainer?
    /// Read for actions only; it does not subscribe Today to the model.
    @Environment(\.looprBluetoothModel) private var bluetoothModel
    /// The debounced band state. Today reads a few of its properties and
    /// redraws only when those change.
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.looprDaySelection) private var daySelection
    private let deviceRepository: (any DeviceCenterRepository)?
    @StateObject private var viewModel: TodayViewModel
    @State private var externalHabitInsight: TodayExternalInsight?
    @State private var isConnectExplanationPresented = false
    /// Opens the wake alarm screen from the card under the day's content.
    private let openWakeAlarm: (() -> Void)?

    init(
        environment: AppEnvironment,
        route: @escaping (TodayKit.TodayRoute) -> Void,
        repositories: ProductRepositoryContainer? = nil,
        openWakeAlarm: (() -> Void)? = nil
    ) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        self.openWakeAlarm = openWakeAlarm
        self.deviceRepository = repositories?.persistent?.device
        _viewModel = StateObject(wrappedValue: ProductFeatureViewModelFactory.makeToday(
            environment: environment,
            repositories: repositories
        ))
    }

    var body: some View {
        TodayScreen(
            viewModel: viewModel,
            route: route,
            externalInsight: externalHabitInsight,
            onExternalInsight: openHabitInsight,
            // The populated fixture stands for a paired band with history.
            showsConnectBand: (bandLink?.canOfferPairing ?? false) && environment.composition != .populated,
            bandConnectionMessage: bandConnectionCard?.message,
            bandConnectionTitle: bandConnectionCard?.title ?? TodayBandConnectionCopy.title,
            bandModelName: bandLink?.bandModelName,
            bandIsExperimental: bandLink?.bandIsExperimental ?? false,
            onConnectBand: connectBand,
            accessory: wakeAlarmCard
        )
            .alert(
                "Connect your band?",
                isPresented: $isConnectExplanationPresented
            ) {
                Button("Cancel", role: .cancel) {
                    isConnectExplanationPresented = false
                    bluetoothModel?.cancelExplanation()
                }
                Button("Continue") {
                    Task {
                        await bluetoothModel?.continueAfterExplanation()
                        isConnectExplanationPresented = false
                    }
                }
                .accessibilityIdentifier("today-connect-continue")
            } message: {
                Text(AccessoryProvisioningController.ownershipExplanationShort)
            }
            .looprDayScopedLoad(enabled: repositories?.storageFailure == nil, fallbackDay: fallbackDay) { day in
                await viewModel.load(day: day)
            }
            .task {
                guard repositories?.storageFailure == nil else { return }
                await loadBattery()
                await loadHabitInsight()
            }
            .onAppear {
                guard viewModel.summary != nil, repositories?.storageFailure == nil else { return }
                Task { await viewModel.refreshProjections(for: currentDay) }
            }
            .onReceive(NotificationCenter.default.publisher(for: SleepNeed.didChange)) { _ in
                Task { await viewModel.refreshGoals(for: currentDay) }
            }
            .onChange(of: bandLink?.indicator) { _, _ in
                Task {
                    await loadBattery()
                    await repositories?.persistent?.derivedData.request()
                }
            }
            .onChange(of: bandLink?.isPaired) { _, _ in
                Task { await loadBattery() }
            }
            .productionRefresh(environment: environment) {
                guard repositories?.storageFailure == nil, daySelection?.isResolving != true else { return }
                await viewModel.load(day: currentDay)
                await loadBattery()
            }
            .productStorageGate(repositories)
    }

    private var fallbackDay: DayIdentity { environment.productDay(fixture: TodayFixtures.day) }
    private var currentDay: DayIdentity { looprCurrentDay(daySelection, fallback: fallbackDay) }

    /// Only a link still down after the grace window, Bluetooth being off, or
    /// something to fix earns a card. A blip shows nothing.
    private var bandConnectionCard: (title: String, message: String)? {
        guard let bandLink else { return nil }
        return TodayBandConnectionCopy.card(for: bandLink.state, isPaired: bandLink.isPaired)
    }

    private var wakeAlarmCard: AnyView? {
        guard let openWakeAlarm, bandLink?.bandIsExperimental != true else { return nil }
        return AnyView(WakeAlarmCardFeatureRoot(
            repositories: repositories,
            accessibilityIdentifier: "today-wake-alarm-card",
            open: openWakeAlarm
        ))
    }

    private func connectBand() {
        guard let bluetoothModel else { return }
        #if DEBUG
        Self.pairingLogger.debug("Today Connect action reached; status=\(bluetoothModel.status.logCase, privacy: .public)")
        #endif
        Task {
            await bluetoothModel.userTappedPair()
            #if DEBUG
            Self.pairingLogger.debug("Today Connect request finished; status=\(bluetoothModel.status.logCase, privacy: .public)")
            #endif
            if bluetoothModel.status == .explanationRequired {
                isConnectExplanationPresented = true
                #if DEBUG
                Self.pairingLogger.debug("Today Connect explanation presented")
                #endif
            }
        }
    }

    /// Reads the band's battery and sync time into the shell's band state,
    /// which every tab's band button shows. The band link clears the battery
    /// itself when the band is unpaired.
    private func loadBattery() async {
        guard let deviceRepository, let bandLink, bandLink.isPaired else { return }
        let previous = bandLink.indicator
        // A failed or empty read keeps the last known value. Clearing it made
        // the ring vanish and come back on every reconnect.
        guard let status = try? await deviceRepository.readStatus() else { return }
        let measuredPercent: Int? = if case .measured(let value) = status.batteryPercent { value } else { nil }
        bandLink.updateDetails(
            batteryPercent: measuredPercent,
            charging: status.charging,
            onWrist: status.wristState == .unknown ? nil : status.wristState == .worn,
            lastSyncedAt: status.completedSyncAt ?? status.historyCommitAt
        )
        // The band battery is the one number the Battery widget and the
        // complication exist for, so a new reading republishes the snapshot.
        if bandLink.indicator != previous, let derivedData = repositories?.persistent?.derivedData {
            await derivedData.request()
        }
    }

    private func loadHabitInsight() async {
        guard AppHabitFeatureGate.currentStage.enablesToday,
              let habits = repositories?.persistent?.habits,
              let definitions = try? await habits.definitions(includeArchived: false),
              let estimates = try? await habits.estimates() else { return }
        let definitionByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let rankedCandidates = HabitTodaySelectionPolicy.ranked(
            estimates.filter { definitionByID[$0.habitID] != nil }
        )
        let now = Date()
        let storedSelection = try? await habits.todaySelection()
        let retained = storedSelection.flatMap { selection -> HabitTodayCandidate? in
            guard HabitTodaySelectionPolicy.shouldRetain(selection, at: now) else { return nil }
            return rankedCandidates.first { $0.estimate.habitID == selection.habitID }
        }
        guard let selected = retained ?? rankedCandidates.first,
              let definition = definitionByID[selected.estimate.habitID],
              let difference = selected.metric.adjustedDifference else { return }
        if retained == nil {
            try? await habits.saveTodaySelection(HabitTodaySelection(
                habitID: selected.estimate.habitID,
                selectedAt: now
            ))
        }
        let direction = difference < 0 ? "lower" : "higher"
        let detail: String
        if selected.metric.metricID == .recoveryScore {
            detail = "Recovery was \(abs(difference).formatted(.number.precision(.fractionLength(1)))) points \(direction) on nights you answered Yes."
        } else {
            detail = "No clear Recovery association. \(selected.metric.metricID.title) was \(abs(difference).formatted(.number.precision(.fractionLength(1)))) \(direction) on nights you answered Yes."
        }
        externalHabitInsight = TodayExternalInsight(
            id: selected.estimate.habitID.rawValue.uuidString,
            title: definition.name,
            detail: detail,
            accessibilityText: "Habit insight, \(definition.name). \(detail)",
            calculatedAt: selected.estimate.calculatedAt,
            routeToken: selected.estimate.habitID.rawValue.uuidString
        )
    }

    private func openHabitInsight(_ routeToken: String) {
        guard let id = UUID(uuidString: routeToken) else { return }
        NotificationCenter.default.post(
            name: Notification.Name("com.loopr.journal.route"),
            object: JournalRoute.habitDetail(HabitID(rawValue: id))
        )
    }
}

/// Holds Sleep's view model without observing it. `SleepScreen` and the wake
/// alarm card observe it themselves, so a new night re-renders those and not
/// the root, which used to rebuild its `AnyView` card on every publish.
@MainActor
private final class SleepViewModelHolder: ObservableObject {
    let viewModel: SleepViewModel

    init(_ viewModel: SleepViewModel) {
        self.viewModel = viewModel
    }
}

/// The wake alarm card under the night, with tonight's suggested time.
private struct SleepWakeAlarmAccessory: View {
    @ObservedObject var viewModel: SleepViewModel
    let repositories: ProductRepositoryContainer?
    let open: () -> Void

    var body: some View {
        WakeAlarmCardFeatureRoot(
            repositories: repositories,
            suggestion: WakeAlarmSuggestion(viewModel.snapshot?.suggestedAlarm),
            accessibilityIdentifier: "sleep-wake-alarm-card",
            open: open
        )
    }
}

@MainActor
struct SleepFeatureRoot: View {
    let environment: AppEnvironment
    let route: (SleepKit.SleepRoute) -> Void
    let repositories: ProductRepositoryContainer?
    /// The debounced band state; the root reads only `bandIsExperimental`.
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.looprDaySelection) private var daySelection
    @StateObject private var holder: SleepViewModelHolder
    private var viewModel: SleepViewModel { holder.viewModel }

    init(environment: AppEnvironment, route: @escaping (SleepKit.SleepRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _holder = StateObject(wrappedValue: SleepViewModelHolder(
            SleepNightDetails.viewModel(environment: environment, repositories: repositories)
        ))
    }

    var body: some View {
        SleepScreen(viewModel: viewModel, route: route, accessory: bandLink?.bandIsExperimental == true ? nil : AnyView(SleepWakeAlarmAccessory(
            viewModel: viewModel,
            repositories: repositories,
            // The suggested alarm route is the wake alarm screen now.
            open: { route(.suggestedAlarm) }
        )))
            .environment(\.connectedEmptyDetail, "Your band is connected. Wear it while you sleep, then open Loopr after you wake up to sync your night.")
            .looprDayScopedLoad(enabled: repositories?.storageFailure == nil, fallbackDay: fallbackDay) { day in
                await viewModel.load(day: day)
            }
            .productionRefresh(environment: environment) {
                guard repositories?.storageFailure == nil, daySelection?.isResolving != true else { return }
                await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay))
            }
            .onReceive(NotificationCenter.default.publisher(for: SleepNeed.didChange)) { _ in
                Task { await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay)) }
            }
            .productStorageGate(repositories)
    }

    private var fallbackDay: DayIdentity { environment.productDay(fixture: SleepFixtures.day) }
}

/// Canonical detail destinations for Sleep. The shell supplies the typed route;
/// this root owns the repository read so detail screens cannot silently fall
/// back to a deterministic snapshot in production.
@MainActor
struct SleepDestinationFeatureRoot: View {
    let environment: AppEnvironment
    let route: SleepKit.SleepRoute
    let repositories: ProductRepositoryContainer?
    @StateObject private var viewModel: SleepViewModel

    init(environment: AppEnvironment, route: SleepKit.SleepRoute, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: SleepNightDetails.viewModel(environment: environment, repositories: repositories))
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .coach:
                CoachFeatureRoot(environment: environment, repositories: repositories)
            case .day:
                SleepScreen(viewModel: viewModel)
                    .looprHeaderInNavigationBar()
            case .hypnogram:
                if let snapshot = viewModel.snapshot { SleepHypnogramScreen(snapshot: snapshot, heartRate: viewModel.heartRate) }
                else { detailPlaceholder(title: "No sleep recorded") }
            case .trends:
                if let snapshot = viewModel.snapshot { SleepTrendsScreen(snapshot: snapshot) }
                else { detailPlaceholder(title: "No sleep trends yet") }
            case .suggestedAlarm:
                // One alarm screen for every entry point. The suggestion is
                // offered there as a wake time; it never applies itself.
                WakeAlarmFeatureRoot(
                    repositories: repositories,
                    suggestion: WakeAlarmSuggestion(viewModel.snapshot?.suggestedAlarm)
                )
            case .corrections:
                SleepCorrectionsScreen(corrections: viewModel.corrections)
            }
        }
        .looprDayScopedLoad(enabled: repositories?.storageFailure == nil,
                            fallbackDay: environment.productDay(fixture: SleepFixtures.day),
                            swipes: route == .day) { day in
            await viewModel.load(day: day)
        }
        .productStorageGate(repositories)
    }

    private func detailPlaceholder(title: String) -> some View {
        ProductDetailPlaceholder(
            isLoading: viewModel.loadState == .idle || viewModel.loadState == .loading,
            title: title,
            detail: "Loopr has no sleep for this night. Wear your band overnight and it shows up here after the next sync."
        )
    }
}

private var productDataFixture: DataRecord {
    #if DEBUG
    if DebugCaptureFixtures.siStoreFixture { return SIPolishFixtureWorld.dataRecord }
    #endif
    return DataFixtures.importedRecord
}

private func heartFixtureConnected(_ environment: AppEnvironment) -> Bool {
    #if DEBUG
    environment.composition != .production
        && ProcessInfo.processInfo.arguments.contains("--loopr-heart-connected-fixture")
    #else
    false
    #endif
}

@MainActor
struct HeartFeatureRoot: View {
    let environment: AppEnvironment
    let route: (HeartKit.HeartRoute) -> Void
    let repositories: ProductRepositoryContainer?
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.bandConnected) private var bandConnected
    // Descendants observe only the day or live samples they render. The
    // holder publishes nothing, so this root does not re-render with the
    // view model, and its autoclosure builds the model once per identity
    // instead of on every shell re-render.
    @StateObject private var model: HeartViewModelHolder
    private var viewModel: HeartViewModel { model.viewModel }

    init(environment: AppEnvironment, route: @escaping (HeartKit.HeartRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _model = StateObject(wrappedValue: HeartViewModelHolder(HeartViewModelFactory.make(
            environment: environment,
            repositories: repositories,
            sharesLiveHistory: true,
            fallbackLiveClient: HeartTabServicesModifier.fixtureLiveClient
        )))
    }

    var body: some View {
        HeartScreen(viewModel: viewModel, route: route)
            #if DEBUG
            .modifier(SIHeartnavAccessibilityCapture())
            #endif
            .environment(\.bandConnected, bandConnected || heartFixtureConnected(environment))
            .modifier(HeartTabServicesModifier(environment: environment, repositories: repositories, viewModel: viewModel))
            .environment(\.connectedEmptyDetail, "Your band is connected. Live heart rate appears above as readings arrive. Wear your band overnight for resting heart rate and HRV.")
            .modifier(ConnectedHeartLiveModifier(viewModel: viewModel, enabled: environment.composition == .production))
            .task { await viewModel.loadLiveHistory() }
            .task {
                if environment.composition != .production, HeartTabServicesModifier.fixtureLiveClient != nil {
                    await viewModel.runLive()
                }
            }
            .looprDayScopedLoad(enabled: repositories?.storageFailure == nil, fallbackDay: fallbackDay) { day in
                await viewModel.load(day: day)
            }
            .productionRefresh(environment: environment) {
                guard repositories?.storageFailure == nil, daySelection?.isResolving != true else { return }
                await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay))
            }
            .productStorageGate(repositories)
    }

    private var fallbackDay: DayIdentity { environment.productDay(fixture: HeartFixtures.day) }
}

/// What a pushed detail destination shows until its snapshot is ready.
///
/// A destination builds a fresh view model, so its snapshot is nil for the
/// first frames. That used to render "… unavailable" and then pop to content.
/// Now it is a skeleton while the load is pending, and the empty message only
/// once the load finished with nothing.
struct ProductDetailPlaceholder: View {
    let isLoading: Bool
    let title: String
    let detail: String

    var body: some View {
        LooprDetailScaffold {
            if isLoading {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprSkeleton(height: 14).frame(maxWidth: 120)
                            LooprSkeleton(height: 28).frame(maxWidth: 200)
                            LooprSkeleton(height: 160)
                        }
                    }
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprSkeleton(height: 14)
                            LooprSkeleton(height: 14).frame(maxWidth: 240)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .accessibilityIdentifier("detail-loading")
            } else {
                LooprSurface {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText(title, style: .title)
                        LooprText(detail, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail-empty")
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
    }
}

/// Holds a Heart view model for a root that must not observe it.
@MainActor
final class HeartViewModelHolder: ObservableObject {
    let viewModel: HeartViewModel
    init(_ viewModel: HeartViewModel) { self.viewModel = viewModel }
}

/// Builds the Heart view model for a root. Called from a `StateObject`
/// autoclosure, so it runs once per root identity. Fixture snapshots are
/// built only for fixture compositions.
@MainActor
enum HeartViewModelFactory {
    static func make(
        environment: AppEnvironment,
        repositories: ProductRepositoryContainer?,
        sharesLiveHistory: Bool,
        fallbackLiveClient: (any HeartLiveEventStreamClient)?
    ) -> HeartViewModel {
        let liveHistory = sharesLiveHistory ? repositories?.heartLiveHistory : nil
        if let persistent = repositories?.persistent {
            return HeartViewModel(
                repository: persistent.heart,
                spotCheckRepository: persistent.spotCheckService == nil ? nil : persistent.heart,
                spotCheckRunner: persistent.spotCheckService.map(CanonicalHeartSpotCheckRunner.init),
                liveEventClient: persistent.heartLiveEventClient,
                liveHistory: liveHistory
            )
        }
        let isFixture = repositories?.isFixtureComposition != false
        let values: [DayIdentity: HeartDaySnapshot] = isFixture
            ? ProductFixture.days(
                HeartFixtures.snapshot(for: ProductFixture.metricState(for: environment.composition)),
                day: HeartFixtures.day, composition: environment.composition)
            : [:]
        #if DEBUG
        let capturedValues = values.mapValues {
            DebugCaptureFixtures.siPolishSurfaceSnapshot(DebugCaptureFixtures.siHeartnavSnapshot($0),
                state: DebugCaptureFixtures.siSurfacesState)
        }
        #else
        let capturedValues = values
        #endif
        let spotCheck = isFixture
            ? HeartFixtures.spotCheck
            : HeartSpotCheckResult(state: .absent, heartRateBPM: nil, rmssdMilliseconds: nil, sdnnMilliseconds: nil, durationSeconds: 0, source: "storage-unavailable")
        return HeartViewModel(
            repository: InMemoryHeartRepository(values: capturedValues),
            spotCheckRepository: InMemoryHeartSpotCheckRepository(result: spotCheck),
            liveEventClient: fallbackLiveClient,
            liveHistory: liveHistory
        )
    }
}

private struct CanonicalHeartSpotCheckRunner: HeartSpotCheckRunner {
    let service: CanonicalLiveSpotCheckService

    func runSpotCheck() async throws -> HeartSpotCheckResult {
        try await service.runHeartSpotCheck(duration: .seconds(60))
    }
}

/// Canonical detail destinations for Heart. Live samples are read through the
/// injected HeartLiveStreamClient when one exists; production never receives a
/// hardcoded sample from this root.
@MainActor
struct HeartDestinationFeatureRoot: View {
    let environment: AppEnvironment
    let route: HeartKit.HeartRoute
    let repositories: ProductRepositoryContainer?
    @Environment(\.bandConnected) private var bandConnected
    @StateObject private var viewModel: HeartViewModel

    init(environment: AppEnvironment, route: HeartKit.HeartRoute, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: HeartViewModelFactory.make(
            environment: environment,
            repositories: repositories,
            sharesLiveHistory: true,
            fallbackLiveClient: repositories?.isFixtureComposition == false ? nil : HeartTabServicesModifier.fixtureLiveClient
        ))
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .spotCheck:
                ProductHeartSpotCheckPresentation(viewModel: viewModel, requiresConnection: environment.composition == .production || environment.composition == .disconnected)
            case .live:
                HeartLiveScreen(samples: viewModel.liveSamples, stats: viewModel.liveStats,
                                state: viewModel.snapshot?.liveState ?? .absent)
                    .environment(\.bandConnected, bandConnected || heartFixtureConnected(environment))
                    .modifier(HeartTabServicesModifier(environment: environment, repositories: repositories,
                                                       viewModel: viewModel))
                    .modifier(ConnectedHeartLiveModifier(viewModel: viewModel, enabled: environment.composition == .production))
                    .task {
                        await viewModel.loadLiveHistory()
                        if environment.composition != .production { await viewModel.startLive() }
                    }
            case .stress:
                StressFeatureRoot(repositories: repositories)
            case .detail:
                if let snapshot = viewModel.snapshot { HeartDetailScreen(snapshot: snapshot) }
                else { detailPlaceholder(title: "No heart data for this day") }
            case .trends:
                if let snapshot = viewModel.snapshot { HeartTrendsScreen(snapshot: snapshot) }
                else { detailPlaceholder(title: "No heart trends yet") }
            }
        }
        .looprDayScopedLoad(enabled: repositories?.storageFailure == nil,
                            fallbackDay: environment.productDay(fixture: HeartFixtures.day),
                            swipes: false) { day in
            await viewModel.load(day: day)
        }
        .productStorageGate(repositories)
    }

    private func detailPlaceholder(title: String) -> some View {
        ProductDetailPlaceholder(
            isLoading: viewModel.loadState == .idle || viewModel.loadState == .loading,
            title: title,
            detail: "Loopr has no heart readings for this day. Wear your band and they show up here after the next sync."
        )
    }
}

@MainActor
struct HeartSpotCheckFeature: View {
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    @StateObject private var viewModel: HeartViewModel

    init(environment: AppEnvironment, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: HeartViewModelFactory.make(
            environment: environment,
            repositories: repositories,
            sharesLiveHistory: false,
            fallbackLiveClient: nil
        ))
    }

    var body: some View {
        ProductHeartSpotCheckPresentation(viewModel: viewModel, requiresConnection: environment.composition == .production || environment.composition == .disconnected)
            .task {
                guard repositories?.storageFailure == nil else { return }
                await viewModel.load(day: environment.productDay(fixture: HeartFixtures.day))
            }
            .productStorageGate(repositories)
    }
}

@MainActor
private struct ProductHeartSpotCheckPresentation: View {
    @ObservedObject var viewModel: HeartViewModel
    let requiresConnection: Bool
    /// The debounced band state. A blip inside the grace window keeps the
    /// screen as it is instead of flashing "Waiting for your band".
    @Environment(\.looprBandLink) private var bandLink

    private var connectionReady: Bool {
        !requiresConnection || bandLink?.state.isLinked == true
            || (bandLink?.state == .reconnecting && bandLink?.hasBeenLinked == true)
    }

    @State private var runTask: Task<Void, Never>?
    @State private var measurementStartedAt: Date?
    /// Bumped when a measurement ends, so the result plays one haptic.
    @State private var completedResult: HeartSpotCheckResult?

    private let durationSeconds = 60

    var body: some View {
        LooprDetailScaffold {
            // A running measurement stays on screen through a blip; its task
            // keeps going, so hiding it only made the screen jump.
            if measurementStartedAt != nil {
                measuringSurface
            } else if !connectionReady {
                LooprSectionGroup(title: "Connection") {
                    LooprSurface(emphasis: .hero(.heart)) {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Waiting for your band", style: .cardTitle)
                            LooprText(connectionMessage, style: .prose, color: .inkSecondary)
                        }
                    }
                }
            } else if let result = viewModel.spotCheck {
                resultContent(result)
            } else if case .loading = viewModel.loadState {
                loadingSurface
            } else if case .failed = viewModel.loadState {
                unavailableSurface
            } else {
                readySurface
            }

            if connectionReady, case .failed(let message) = viewModel.loadState {
                LooprSectionGroup(title: "Status") {
                    LooprFormCard {
                        LooprInlineMessage(message, tone: .critical)
                            .accessibilityIdentifier("heart-spot-check-error")
                    }
                }
            }

            LooprSectionGroup(title: "Actions") {
                Button(actionTitle) {
                    startMeasurement()
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .disabled(!connectionReady || measurementStartedAt != nil || isLoadInProgress)
                .accessibilityIdentifier("heart-spot-check-start")
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Spot check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.heart))
        .animation(LooprMotion.stateChange, value: measurementStartedAt == nil)
        .sensoryFeedback(trigger: completedResult) { _, result in
            guard let result else { return nil }
            return result.resolvedAvailability == .complete ? .success : .warning
        }
        .accessibilityIdentifier("heart-spot-check-screen")
        .onDisappear {
            runTask?.cancel()
            runTask = nil
            measurementStartedAt = nil
        }
    }

    private var connectionMessage: String {
        switch bandLink?.state {
        case .bluetoothOff:
            "Turn on Bluetooth on your iPhone to reconnect your band."
        case .notPaired:
            "Connect your band from Today, then return here to start a measurement."
        case .needsAttention:
            "Your band could not connect. Open Settings, then Device Center to check the connection."
        default:
            "Loopr is connecting to your band. Keep it near your iPhone. You can start a measurement once it is ready."
        }
    }

    private var actionTitle: String {
        if !connectionReady { return "Waiting for connection" }
        if measurementStartedAt != nil { return "Measuring" }
        if case .failed = viewModel.loadState { return "Try again" }
        return "Start spot check"
    }

    private var isLoadInProgress: Bool {
        if case .loading = viewModel.loadState { return true }
        return false
    }

    private var loadingSurface: some View {
        LooprSectionGroup(title: "Measurement") {
            LooprSurface(emphasis: .hero(.heart)) {
                StateMessage(.loading)
            }
        }
    }

    private var unavailableSurface: some View {
        LooprSectionGroup(title: "Measurement") {
            LooprSurface(emphasis: .hero(.heart)) {
                StateMessage(.recoverableError)
            }
        }
    }

    private var readySurface: some View {
        LooprSectionGroup(title: "Measurement") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSurface(emphasis: .hero(.heart)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StatusChip("Ready", symbol: "timer", accent: .heart)
                        LooprText("Measure for one minute", style: .cardTitle)
                        LooprText(
                            "Sit still and keep the strap snug while Loopr reads your heart signal.",
                            style: .prose,
                            color: .inkSecondary
                        )
                    }
                }

                LooprFormCard {
                    StateMessage(.absent)
                }
            }
        }
    }

    private var measuringSurface: some View {
        LooprSectionGroup(title: "Measurement") {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let elapsed = elapsedSeconds(at: context.date)
                let remaining = max(durationSeconds - elapsed, 0)

                LooprSurface(emphasis: .hero(.heart)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StatusChip("Measuring", symbol: "waveform.path.ecg", accent: .heart)
                        LooprText("Keep still", style: .cardTitle)
                        LooprText(
                            "Loopr is collecting the heart signal. The result will appear when the reading ends.",
                            style: .prose,
                            color: .inkSecondary
                        )

                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            MetricNumeral(String(remaining), compact: true)
                            LooprText("seconds remaining", style: .metricUnit, color: .inkSecondary)
                        }

                        ProgressView(value: Double(elapsed), total: Double(durationSeconds))
                            .tint(Color.loopr(.heart))
                            .accessibilityLabel("Spot check progress")
                            .accessibilityValue("\(elapsed) of \(durationSeconds) seconds")
                    }
                }
                .accessibilityIdentifier("heart-spot-check-progress")
            }
        }
    }

    @ViewBuilder
    private func resultContent(_ result: HeartSpotCheckResult) -> some View {
        LooprSectionGroup(title: "Latest reading") {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSurface(emphasis: .hero(.heart)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StatusChip(
                            resultStatusTitle(for: result),
                            symbol: resultStatusSymbol(for: result),
                            accent: .heart
                        )
                        LooprText("One-minute spot check", style: .cardTitle)
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            LooprText("Captured for", style: .metricUnit, color: .inkSecondary)
                            MetricNumeral(String(result.durationSeconds), compact: true)
                            LooprText("seconds", style: .metricUnit, color: .inkSecondary)
                        }
                    }
                }

                HairlineMetricList(rows: metricRows(for: result))

                if result.resolvedAvailability == .insufficientQuality {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StateMessage(.lowConfidence)
                                .accessibilityIdentifier("heart-spot-check-insufficient-quality")
                            LooprInlineMessage(
                                result.qualityDetail ?? "The signal was not clean enough for a reliable heart-rate variability result. Keep the strap snug, sit still, and try again.",
                                tone: .neutral
                            )
                        }
                    }
                } else if let detail = result.qualityDetail {
                    LooprFormCard {
                        LooprInlineMessage(detail, tone: .neutral)
                    }
                }
            }
        }
    }

    private func metricRows(for result: HeartSpotCheckResult) -> [HairlineMetricRow] {
        let state = resultMetricState(for: result)
        let heartRate = result.heartRateBPM.flatMap { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : nil
        }
        let rmssd = result.rmssdMilliseconds.flatMap { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : nil
        }
        let sdnn = result.sdnnMilliseconds.flatMap { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : nil
        }

        return [
            HairlineMetricRow(
                id: "heart-spot-check-heart-rate",
                title: "Heart rate",
                confidence: resultConfidence(for: result),
                value: heartRate ?? state.title,
                unit: heartRate == nil ? nil : "bpm",
                accent: heartRate == nil ? .inkSecondary : .heart
            ),
            HairlineMetricRow(
                id: "heart-spot-check-rmssd",
                title: "HRV",
                confidence: resultConfidence(for: result),
                value: rmssd ?? state.title,
                unit: rmssd == nil ? nil : "ms",
                accent: rmssd == nil ? .inkSecondary : .heart
            ),
            HairlineMetricRow(
                id: "heart-spot-check-sdnn",
                title: "SDNN",
                confidence: result.resolvedAvailability == .insufficientQuality ? "LOW CONFIDENCE" : nil,
                value: sdnn ?? state.title,
                unit: sdnn == nil ? nil : "ms",
                accent: sdnn == nil ? .inkSecondary : .heart
            )
        ]
    }

    private func resultMetricState(for result: HeartSpotCheckResult) -> MetricState {
        switch result.resolvedAvailability {
        case .complete:
            result.state
        case .insufficientQuality:
            .lowConfidence
        case .unavailable:
            .absent
        }
    }

    private func resultConfidence(for result: HeartSpotCheckResult) -> String? {
        switch result.resolvedAvailability {
        case .complete:
            return result.state == .lowConfidence ? "LOW CONFIDENCE" : nil
        case .insufficientQuality:
            return "LOW CONFIDENCE"
        case .unavailable:
            return nil
        }
    }

    private func resultStatusTitle(for result: HeartSpotCheckResult) -> String {
        switch result.resolvedAvailability {
        case .complete: "Complete"
        case .insufficientQuality: "Low confidence"
        case .unavailable: "Not available"
        }
    }

    private func resultStatusSymbol(for result: HeartSpotCheckResult) -> String {
        switch result.resolvedAvailability {
        case .complete: "checkmark.circle"
        case .insufficientQuality: "waveform.badge.exclamationmark"
        case .unavailable: "minus.circle"
        }
    }

    private func startMeasurement() {
        guard connectionReady, measurementStartedAt == nil else { return }
        runTask?.cancel()
        measurementStartedAt = Date()
        let model = viewModel
        runTask = Task { @MainActor in
            await model.runSpotCheck()
            guard !Task.isCancelled else { return }
            measurementStartedAt = nil
            runTask = nil
            completedResult = model.spotCheck
        }
    }

    private func elapsedSeconds(at date: Date) -> Int {
        guard let measurementStartedAt else { return 0 }
        return min(
            durationSeconds,
            max(0, Int(date.timeIntervalSince(measurementStartedAt)))
        )
    }
}

/// Builds the Body view model for a root. Called from a `StateObject`
/// autoclosure, so it runs once per root identity. Fixture snapshots are
/// built only for fixture compositions.
@MainActor
enum BodyViewModelFactory {
    static func make(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> BodyViewModel {
        if let persistent = repositories?.persistent {
            return BodyViewModel(repository: persistent.body)
        }
        let values: [DayIdentity: BodyDaySnapshot] = repositories?.isFixtureComposition == false
            ? [:]
            : ProductFixture.days(
                BodyFixtures.snapshot(for: ProductFixture.metricState(for: environment.composition)),
                day: BodyFixtures.day, composition: environment.composition)
        return BodyViewModel(repository: InMemoryBodyRepository(values: values))
    }
}

@MainActor
struct BodyFeatureRoot: View {
    let environment: AppEnvironment
    let route: (BodyKit.BodyRoute) -> Void
    let repositories: ProductRepositoryContainer?
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.metricHistoryProvider) private var metricHistoryProvider
    @StateObject private var viewModel: BodyViewModel

    init(environment: AppEnvironment, route: @escaping (BodyKit.BodyRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: BodyViewModelFactory.make(environment: environment, repositories: repositories))
    }

    var body: some View {
        BodyScreen(viewModel: viewModel, route: route)
            .modifier(CardioAgeHealthSamplesModifier(enabled: environment.composition == .production,
                                                    runtime: repositories?.persistent?.healthSync))
            .environment(\.connectedEmptyDetail, "Your band is connected. Keep wearing it during the day and overnight. Body estimates appear once enough activity and sleep data has been collected.")
            .looprDayScopedLoad(enabled: repositories?.storageFailure == nil, fallbackDay: fallbackDay) { day in
                viewModel.historyProvider = historyProvider
                await viewModel.load(day: day)
            }
            .productionRefresh(environment: environment) {
                guard repositories?.storageFailure == nil, daySelection?.isResolving != true else { return }
                viewModel.historyProvider = historyProvider
                await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay))
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHeartZonesChanged).receive(on: RunLoop.main)) { _ in
                Task { await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHeartZoneHistoryUpdated).receive(on: RunLoop.main)) { _ in
                Task { await viewModel.load(day: looprCurrentDay(daySelection, fallback: fallbackDay)) }
            }
            .productStorageGate(repositories)
    }

    private var fallbackDay: DayIdentity { environment.productDay(fixture: BodyFixtures.day) }

    /// The week, the load and "vs usual" read the metric history.
    private var historyProvider: (any BodyHistoryProviding)? {
        BodyHistorySource.provider(repositories: repositories, composition: environment.composition, metricHistory: metricHistoryProvider)
    }
}

/// Canonical Body detail destinations backed by the same repository as the
/// Body tab root.
@MainActor
struct BodyDestinationFeatureRoot: View {
    let environment: AppEnvironment
    let route: BodyKit.BodyRoute
    let repositories: ProductRepositoryContainer?
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.metricHistoryProvider) private var metricHistoryProvider
    @StateObject private var viewModel: BodyViewModel

    init(environment: AppEnvironment, route: BodyKit.BodyRoute, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: BodyViewModelFactory.make(environment: environment, repositories: repositories))
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .day:
                BodyScreen(viewModel: viewModel)
                    .looprHeaderInNavigationBar()
            case .load:
                if let snapshot = viewModel.snapshot { BodyLoadScreen(snapshot: snapshot, history: viewModel.history) }
                else { detailPlaceholder(title: "No body load for this day") }
            case .cardioAge:
                if let snapshot = viewModel.snapshot {
                    BodyAgeScreen(title: "Cardio Age", presentation: snapshot.cardioAgePresentation,
                                  cardioFitness: snapshot.cardioFitness,
                                  requirements: BodyAgeLock.cardio(snapshot: snapshot, presentation: snapshot.cardioAgePresentation).requirements)
                }
                else { detailPlaceholder(title: "No Cardio Age yet") }
            case .looprAge:
                if let snapshot = viewModel.snapshot {
                    BodyAgeScreen(
                        title: "Loopr Age",
                        presentation: snapshot.looprAgePresentation,
                        looprAge: snapshot.looprAge
                    )
                }
                else { detailPlaceholder(title: "No Loopr Age yet") }
            }
        }
        .modifier(CardioAgeHealthSamplesModifier(enabled: environment.composition == .production,
                                                runtime: repositories?.persistent?.healthSync))
        .looprDayScopedLoad(enabled: repositories?.storageFailure == nil,
                            fallbackDay: environment.productDay(fixture: BodyFixtures.day),
                            swipes: route == .day) { day in
            viewModel.historyProvider = BodyHistorySource.provider(repositories: repositories,
                composition: environment.composition, metricHistory: metricHistoryProvider)
            await viewModel.load(day: day)
        }
        .onReceive(NotificationCenter.default.publisher(for: looprHeartZonesChanged).receive(on: RunLoop.main)) { _ in
            Task { await viewModel.load(day: looprCurrentDay(daySelection,
                fallback: environment.productDay(fixture: BodyFixtures.day))) }
        }
        .onReceive(NotificationCenter.default.publisher(for: looprHeartZoneHistoryUpdated).receive(on: RunLoop.main)) { _ in
            Task { await viewModel.load(day: looprCurrentDay(daySelection,
                fallback: environment.productDay(fixture: BodyFixtures.day))) }
        }
        .productStorageGate(repositories)
    }

    private func detailPlaceholder(title: String) -> some View {
        ProductDetailPlaceholder(
            isLoading: viewModel.loadState == .idle || viewModel.loadState == .loading,
            title: title,
            detail: "Loopr has no body numbers for this day. They need a day and a night of wear."
        )
    }
}

@MainActor
struct CoachFeatureRoot: View {
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    @StateObject private var viewModel: CoachViewModel

    init(environment: AppEnvironment, repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.repositories = repositories
        let input = CoachFixtures.input(for: ProductFixture.metricState(for: environment.composition))
        let service: CoachService
        if let persistent = repositories?.persistent {
            service = CoachService(inputs: persistent.coach, history: persistent.coach)
        } else {
            let values = repositories?.isFixtureComposition == false ? [:] : [CoachFixtures.day: input]
            service = CoachService(inputs: InMemoryCoachInputRepository(values: values), history: InMemoryCoachRecommendationHistoryRepository())
        }
        _viewModel = StateObject(wrappedValue: CoachViewModel(service: service))
    }

    var body: some View {
        CoachScreen(viewModel: viewModel)
            .task {
                guard repositories?.storageFailure == nil else { return }
                await viewModel.load(day: environment.productDay(fixture: CoachFixtures.day))
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct WorkoutFeatureRoot: View {
    let route: (WorkoutKit.WorkoutRoute) -> Void
    let selectedRoute: ((WorkoutKit.WorkoutRoute, WorkoutRecord?) -> Void)?
    let repositories: ProductRepositoryContainer?
    private let store: any WorkoutStore
    private let seedFixtures: Bool
    private let session: WorkoutSessionController
    @StateObject private var viewModel: WorkoutViewModel

    init(
        route: @escaping (WorkoutKit.WorkoutRoute) -> Void = { _ in },
        selectedRoute: ((WorkoutKit.WorkoutRoute, WorkoutRecord?) -> Void)? = nil,
        repositories: ProductRepositoryContainer? = nil
    ) {
        // Seed before SwiftUI creates the observed view model. A tab's task can
        // be cancelled while the tab is off-screen, which previously left the
        // canonical Workouts root permanently showing an empty state.
        let store: any WorkoutStore
        let seedFixtures: Bool
        if let sharedStore = repositories?.workoutStore {
            store = sharedStore
            seedFixtures = false
        } else {
            let workouts = repositories?.isFixtureComposition == false ? [] : [
                WorkoutFixtures.completedRun,
                WorkoutFixtures.interrupted,
            ]
            store = InMemoryWorkoutStore(workouts: workouts)
            seedFixtures = repositories?.isFixtureComposition ?? true
        }
        self.store = store
        self.seedFixtures = seedFixtures
        self.route = route
        self.selectedRoute = selectedRoute
        self.repositories = repositories
        let session = repositories?.workoutSession ?? WorkoutSessionController(store: store)
        self.session = session
        let detectedRepository: (any DetectedWorkoutRepository)? = repositories?.detectedWorkouts
            ?? (seedFixtures ? InMemoryDetectedWorkoutRepository(detections: [WorkoutFixtures.detectedRun]) : nil)
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            controller: session,
            detectedRepository: detectedRepository,
            finalizationHooks: repositories?.workoutFinalizationHooks ?? .init()
        ))
    }

    private var fixtureWorkoutQueryNow: Date {
        if repositories?.isFixtureComposition == false { return repositories?.environment.dateProvider.now() ?? Date() }
        #if DEBUG
        if DebugCaptureFixtures.siStoreFixture { return SIPolishFixtureWorld.captureNow }
        #endif
        return Date(timeIntervalSince1970: 1_700_002_000)
    }

    var body: some View {
        WorkoutScreen(viewModel: viewModel, route: handleRoute, selectedRoute: handleSelectedRoute)
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixtures {
                    do {
                        try await store.save(WorkoutFixtures.completedRun)
                        try await store.save(WorkoutFixtures.interrupted)
                    } catch {
                        // Fixture stores are only used by DEBUG launch modes.
                    }
                }
                // The list reads rows without samples; detail screens load
                // the full record by id.
                await viewModel.load(
                    query: WorkoutLogQuery(range: .all, now: fixtureWorkoutQueryNow),
                    detail: .listing
                )
            }
            .onAppear { LooprPerformance.tabRootDidAppear() }
            .onReceive(NotificationCenter.default.publisher(for: looprAccountHistoryImported)) { _ in
                Task {
                    await viewModel.load(query: WorkoutLogQuery(range: .all, now: repositories?.environment.dateProvider.now() ?? Date()), detail: .listing)
                }
            }
            .productStorageGate(repositories)
    }

    private func handleRoute(_ destination: WorkoutKit.WorkoutRoute) {
        switch destination {
        case .detail, .recovery:
            Task { @MainActor in
                let selectedID = await session.selectedWorkoutID()
                let selected = selectedID.flatMap { id in
                    viewModel.snapshot.value?.first(where: { $0.id == id })
                } ?? viewModel.snapshot.value?.first(where: {
                    destination == .detail ? $0.state == .completed : $0.state == .interruptedAndRecoverable
                })
                if let selectedRoute {
                    selectedRoute(destination, selected)
                } else {
                    route(destination)
                }
            }
        default:
            if let selectedRoute {
                selectedRoute(destination, nil)
            } else {
                route(destination)
            }
        }
    }

    private func handleSelectedRoute(_ destination: WorkoutKit.WorkoutRoute, _ workout: WorkoutRecord) {
        Task { @MainActor in
            do {
                _ = try await session.select(id: workout.id)
            } catch {
                // The row was read from this same snapshot, but a concurrent
                // deletion must still fail closed rather than inventing an ID.
                if let selectedRoute {
                    selectedRoute(destination, nil)
                } else {
                    route(destination)
                }
                return
            }
            if let selectedRoute {
                selectedRoute(destination, workout)
            } else {
                route(destination)
            }
        }
    }
}

@MainActor
struct WorkoutDestinationFeatureRoot: View {
    let recovery: Bool
    let workoutID: UUID?
    let route: (WorkoutDetailRoute) -> Void
    let repositories: ProductRepositoryContainer?
    private let store: any WorkoutStore
    private let session: WorkoutSessionController
    private let fixtureWorkout: WorkoutRecord?
    private let seedFixture: Bool
    @StateObject private var viewModel: WorkoutViewModel

    init(recovery: Bool, workoutID: UUID? = nil, route: @escaping (WorkoutDetailRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        let store: any WorkoutStore
        let seedFixture: Bool
        let fixtureWorkout: WorkoutRecord?
        if let sharedStore = repositories?.workoutStore {
            store = sharedStore
            seedFixture = false
            fixtureWorkout = nil
        } else {
            store = InMemoryWorkoutStore()
            seedFixture = repositories?.isFixtureComposition ?? true
            fixtureWorkout = seedFixture ? (recovery ? WorkoutFixtures.interrupted : WorkoutFixtures.completedRun) : nil
        }
        self.recovery = recovery
        self.workoutID = workoutID
        self.route = route
        self.repositories = repositories
        self.store = store
        self.fixtureWorkout = fixtureWorkout
        self.seedFixture = seedFixture
        let session = repositories?.workoutSession ?? WorkoutSessionController(store: store)
        self.session = session
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            controller: session,
            finalizationHooks: repositories?.workoutFinalizationHooks ?? .init()
        ))
    }

    var body: some View {
        Group {
            if let fixtureWorkout {
                destination(for: fixtureWorkout)
            } else if let workout = viewModel.snapshot.value?.first(where: { workout in
                guard workoutID == nil || workout.id == workoutID else { return false }
                return recovery ? workout.state == .interruptedAndRecoverable : workout.state == .completed
            }) {
                destination(for: workout)
            } else if viewModel.snapshot.state == .loading {
                ProgressView("Loading workout")
                    .accessibilityIdentifier(recovery ? "workout-recovery-loading" : "workout-detail-loading")
            } else {
                ContentUnavailableView(
                    recovery ? "No workout needs recovery" : "No completed workout",
                    systemImage: "figure.run.circle",
                    description: Text("This screen appears after a workout is saved.")
                )
                .accessibilityIdentifier(recovery ? "workout-recovery-unavailable" : "workout-detail-unavailable")
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            if seedFixture, let fixtureWorkout {
                do { try await store.save(fixtureWorkout) } catch { }
            }
            if let workoutID {
                _ = try? await session.select(id: workoutID)
            }
            await viewModel.load(query: WorkoutLogQuery(range: .threeMonths, now: repositories?.isFixtureComposition == false ? (repositories?.environment.dateProvider.now() ?? Date()) : Date(timeIntervalSince1970: 1_700_002_000)))
        }
        .productStorageGate(repositories)
    }

    private var workoutRecoveryProvider: (any WorkoutHeartRateRecoveryProviding)? {
        #if DEBUG
        if let fixture = DebugCaptureFixtures.siBodyWorkoutProvider { return fixture }
        #endif
        guard let persistent = repositories?.persistent else { return nil }
        return StoredWorkoutRecoveryProvider(history: persistent.historyDatabase, workouts: persistent.workouts, profile: persistent.profile)
    }

    @ViewBuilder
    private func destination(for workout: WorkoutRecord) -> some View {
        if recovery {
            WorkoutRecoveryScreen(workout: workout, viewModel: viewModel)
        } else {
            WorkoutDetailScreen(workout: workout, viewModel: viewModel, route: route)
                .environment(\.workoutHeartRateRecoveryProvider, workoutRecoveryProvider)
                .modifier(WorkoutGPXShareAction(workout: workout, routes: repositories?.persistent?.routes))
        }
    }
}

/// The share flow always resolves its input from the workout store.  In
/// production that is the durable SQLite-backed repository; DEBUG fixture
/// compositions use the same repository seam with a deterministic seed.  The
/// screen therefore never relies on WorkoutSharePreviewScreen's package
/// default record.
@MainActor
struct WorkoutShareDestinationFeatureRoot: View {
    let workoutID: UUID?
    let repositories: ProductRepositoryContainer?
    private let store: any WorkoutStore
    @State private var workout: WorkoutRecord?
    @State private var isLoading = true

    init(workoutID: UUID? = nil, repositories: ProductRepositoryContainer? = nil) {
        self.workoutID = workoutID
        self.repositories = repositories
        if let sharedStore = repositories?.workoutStore {
            store = sharedStore
        } else if repositories?.isFixtureComposition ?? true {
            store = InMemoryWorkoutStore(workouts: [WorkoutFixtures.completedRun])
        } else {
            store = InMemoryWorkoutStore()
        }
    }

    var body: some View {
        Group {
            if let workout {
                WorkoutSharePreviewScreen(workout: workout, exporter: LocalWorkoutShareExporter())
            } else if isLoading {
                ProgressView("Loading workout")
                    .accessibilityIdentifier("workout-share-loading")
            } else {
                ContentUnavailableView(
                    "No completed workout",
                    systemImage: "square.and.arrow.up",
                    description: Text("A completed workout is required before creating a share preview.")
                )
                .accessibilityIdentifier("workout-share-unavailable")
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            let rows = await store.all()
            workout = rows
                .filter { $0.state == .completed }
                .sorted { ($0.endedAt ?? $0.createdAt) > ($1.endedAt ?? $1.createdAt) }
                .first { workoutID == nil || $0.id == workoutID }
            isLoading = false
        }
        .productStorageGate(repositories)
    }

}

@MainActor
struct JournalFeatureRoot: View {
    let route: (JournalKit.JournalRoute) -> Void
    let repositories: ProductRepositoryContainer?
    private let repository: any JournalStore
    private let habitStore: any HabitStore
    private let seedFixture: Bool
    @StateObject private var viewModel: JournalViewModel
    @StateObject private var habitViewModel: HabitViewModel

    init(route: @escaping (JournalKit.JournalRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        let repository: any JournalStore
        let habitStore: any HabitStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.journal
            habitStore = persistent.habits
            seedFixture = false
        } else {
            repository = JournalRepository()
            habitStore = InMemoryHabitStore()
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.repository = repository
        self.habitStore = habitStore
        self.seedFixture = seedFixture
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: JournalViewModel(repository: repository))
        _habitViewModel = StateObject(wrappedValue: HabitViewModel(
            store: habitStore,
            journalStore: repository,
            reminderScheduler: repositories?.persistent?.habitReminderScheduler ?? NoOpHabitReminderScheduler(),
            featureStageOverride: AppHabitFeatureGate.currentStage
        ))
    }

    var body: some View {
        JournalScreen(viewModel: viewModel, habitViewModel: habitViewModel, route: route)
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixture {
                    do { _ = try await repository.save(JournalFixtures.privateEntry) } catch { }
                }
                await viewModel.load()
                await habitViewModel.load()
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct RecordsFeatureRoot: View {
    let route: (RecordsKit.RecordsRoute) -> Void
    let repositories: ProductRepositoryContainer?
    private let repository: any RecordsStore
    private let seedFixture: Bool
    @StateObject private var viewModel: RecordsViewModel

    init(route: @escaping (RecordsKit.RecordsRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        let repository: any RecordsStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.records
            seedFixture = false
        } else {
            repository = RecordsRepository()
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.repository = repository
        self.seedFixture = seedFixture
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: RecordsViewModel(repository: repository))
    }

    var body: some View {
        RecordsScreen(viewModel: viewModel, route: route)
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixture {
                    await repository.save(MetricSnapshot(day: "2026-08-18", metric: "readiness", value: 82, algorithmVersion: 1))
                    await repository.save(RecordsFixtures.correctionEvent)
                }
                await viewModel.load()
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct CycleFeatureRoot: View {
    let route: (CycleKit.CycleRoute) -> Void
    let repositories: ProductRepositoryContainer?
    @StateObject private var viewModel: CycleViewModel

    init(route: @escaping (CycleKit.CycleRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.route = route
        self.repositories = repositories
        let repository: any CycleStore = repositories?.persistent?.cycle ?? CycleRepository()
        let reminderScheduler: any CycleReminderScheduler = repositories?.persistent?.cycleReminderScheduler
            ?? UnavailableCycleReminderScheduler()
        _viewModel = StateObject(wrappedValue: CycleViewModel(
            repository: repository,
            reminderScheduler: reminderScheduler
        ))
    }

    var body: some View {
        CycleScreen(viewModel: viewModel, route: handleRoute)
            .task {
                guard repositories?.storageFailure == nil else { return }
                await viewModel.load(today: CycleDate.string(Date()))
            }
            .productStorageGate(repositories)
    }

    private func handleRoute(_ destination: CycleKit.CycleRoute) {
        guard destination == .overview else {
            route(destination)
            return
        }
        Task { @MainActor in
            if await viewModel.optIn() {
                route(destination)
            }
        }
    }
}

@MainActor
struct StressFeatureRoot: View {
    let route: (StressKit.StressRoute) -> Void
    let repositories: ProductRepositoryContainer?
    @StateObject private var viewModel: StressViewModel

    init(route: @escaping (StressKit.StressRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.route = route
        self.repositories = repositories
        if let persistent = repositories?.persistent {
            let breathing = persistent.breathingSession
            let spotCheck = SpotCheckController(
                mechanism: persistent.stressSpotCheckMechanism,
                history: SpotCheckHistory(),
                consumer: persistent.stressLiveConsumer
            )
            _viewModel = StateObject(wrappedValue: StressViewModel(
                breathing: breathing,
                spotCheck: spotCheck,
                store: persistent.stress
            ))
        } else if repositories?.isFixtureComposition ?? true {
            let day = TodayFixtures.day
            let fixture = LooprFixtureMetrics.today(LooprMetricLinkID.stress).map { value in
                StressObservation(
                    day: String(format: "%04d-%02d-%02d", day.year, day.month, day.day),
                    value: value,
                    coverage: 0.85,
                    confidence: 0.8
                )
            }
            let store = InMemoryStressStore(observations: fixture.map { [$0] } ?? [])
            #if DEBUG
            _viewModel = StateObject(wrappedValue: StressViewModel(store: DebugCaptureFixtures.stressStore(store)))
            #else
            _viewModel = StateObject(wrappedValue: StressViewModel(store: store))
            #endif
        } else {
            _viewModel = StateObject(wrappedValue: StressViewModel())
        }
    }

    var body: some View {
        StressScreen(viewModel: viewModel, route: route)
            .task {
                guard repositories?.storageFailure == nil else { return }
                await viewModel.refresh()
            }
            .productionRefresh(environment: repositories?.environment ?? AppEnvironment.production()) { @MainActor @Sendable [viewModel] in
                await viewModel.refresh()
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct RouteFeatureRoot: View {
    let route: (RouteKit.RouteRoute) -> Void
    let repositories: ProductRepositoryContainer?
    let workoutID: String?
    private let store: any RouteStore
    private let recorder: RouteRecorder
    private let locationSource: (any RouteLocationFixSource)?
    private let seedFixture: Bool
    @StateObject private var viewModel: RouteViewModel
    @State private var path: [RouteKit.RouteRoute] = []
    @State private var showingDeleteConfirmation = false

    init(route: @escaping (RouteKit.RouteRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil, workoutID: String? = nil) {
        let store: any RouteStore
        let recorder: RouteRecorder
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            store = persistent.routes
            recorder = RouteRecorder(store: store, location: persistent.routeLocation)
            self.locationSource = persistent.routeLocation
            seedFixture = false
        } else {
            store = InMemoryRouteStore()
            recorder = RouteRecorder(store: store)
            self.locationSource = nil
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.route = route
        self.repositories = repositories
        self.workoutID = workoutID
        self.store = store
        self.recorder = recorder
        self.seedFixture = seedFixture
        _viewModel = StateObject(wrappedValue: RouteViewModel(recorder: recorder))
    }

    var body: some View {
        NavigationStack(path: $path) {
            RouteScreen(viewModel: viewModel, route: { destination in
                path.append(destination)
                route(destination)
            })
            .navigationDestination(for: RouteKit.RouteRoute.self) { destination in
                if let record = viewModel.route {
                    RouteDestinationFeatureRoot(route: destination, record: record, viewModel: viewModel)
                } else {
                    ContentUnavailableView("Route unavailable", systemImage: "map", description: Text("No route is available for this workout."))
                        .accessibilityIdentifier("route-\(destination)-unavailable")
                }
            }
        }
        .toolbar {
            if viewModel.route != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete route", role: .destructive) { showingDeleteConfirmation = true }
                        .accessibilityIdentifier("route-delete")
                }
            }
        }
        .confirmationDialog("Delete this route?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete route", role: .destructive) {
                Task {
                    guard let receipt = await viewModel.deleteLoadedRoute(), receipt.removed else { return }
                    path.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the route for this workout. The workout record remains.")
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            if seedFixture {
                let fixture = RouteFixtures.completedWalk
                try? await store.save(RouteRecord(
                    workoutID: workoutID ?? fixture.workoutID,
                    activity: fixture.activity,
                    points: fixture.points,
                    segments: fixture.segments,
                    bufferedWrites: fixture.bufferedWrites,
                    completed: fixture.completed,
                    gapStartIndices: fixture.gapStartIndices
                ))
            }
            let routeID: String
            if let workoutID {
                routeID = workoutID
            } else {
                routeID = (try? await store.all().sorted { $0.workoutID < $1.workoutID }.first?.workoutID) ?? ""
            }
            await viewModel.load(workoutID: routeID)
        }
        // The Core Location adapter owns permission and interruption semantics;
        // this app-side pump only forwards validated points while the injected
        // RouteRecorder is actively recording. SwiftUI cancels the task when
        // this route is dismissed, and the recorder itself stops the adapter
        // on finish/revocation.
        .task { await consumeLocationFixes() }
        .productStorageGate(repositories)
    }

    private func consumeLocationFixes() async {
        guard let locationSource else { return }
        let points = locationSource.locationFixes()
        let appendTask = Task { @MainActor in
            for await point in points {
                guard !Task.isCancelled else { return }
                guard Self.isFinite(point), await recorder.currentState() == .recording else { continue }
                do {
                    _ = try await recorder.append(point)
                } catch {
                    viewModel.reportRecordingFailure()
                    return
                }
            }
        }

        var hasRecorded = false
        defer { appendTask.cancel() }
        while !Task.isCancelled {
            let state = await recorder.currentState()
            hasRecorded = hasRecorded || state == .recording || state == .suspended
            if hasRecorded, state == .idle || state == .permissionDenied || state == .ineligible {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
        }
    }

    private static func isFinite(_ point: RoutePoint) -> Bool {
        guard point.timestamp.timeIntervalSinceReferenceDate.isFinite,
              point.latitude.isFinite,
              point.longitude.isFinite,
              point.latitude >= -90,
              point.latitude <= 90,
              point.longitude >= -180,
              point.longitude <= 180,
              point.horizontalAccuracy.isFinite,
              point.horizontalAccuracy >= 0 else { return false }
        if let altitude = point.altitude, !altitude.isFinite { return false }
        if let speed = point.speedMetersPerSecond, (!speed.isFinite || speed < 0) { return false }
        return true
    }
}

@MainActor
private struct RouteDestinationFeatureRoot: View {
    let route: RouteKit.RouteRoute
    let record: RouteRecord
    let viewModel: RouteViewModel

    var body: some View {
        switch route {
        case .map, .splits:
            RouteDestinationScreen(route: route, record: record)
        case .sharePreview:
            RouteShareActionScreen(record: record, viewModel: viewModel)
        }
    }
}

private struct RouteShareActionScreen: View {
    let record: RouteRecord
    let viewModel: RouteViewModel
    @State private var includeLocation = false
    @State private var didPrepare = false
    @State private var exportPayload: RouteExportPayload?
    @State private var errorMessage: String?

    var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Preview") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        id: "route-share-points",
                        title: "Route points",
                        value: String(record.points.count),
                        unit: "points",
                        accent: .movement
                    ),
                    HairlineMetricRow(
                        id: "route-share-location",
                        title: "Location",
                        value: includeLocation ? "Included" : "Excluded",
                        accent: includeLocation ? .movement : .inkSecondary
                    )
                ])
            }

            LooprSectionGroup(title: "Privacy") {
                LooprFormCard(padding: LooprSpacing.none) {
                    LooprToggleRow(
                        title: "Include location",
                        subtitle: "Location is off by default and must be selected explicitly.",
                        isOn: $includeLocation
                    )
                }
            }

            LooprSectionGroup(title: "Actions") {
                Button("Create route preview") {
                    Task { @MainActor in
                        do {
                            exportPayload = try await viewModel.exportLoadedRoute(includeLocation: includeLocation)
                            errorMessage = nil
                            didPrepare = true
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("route-share-create")
            }

            if didPrepare, let exportPayload {
                LooprSectionGroup(title: "Ready") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprInlineMessage("Route preview prepared locally.", tone: .positive)
                            HairlineMetricList(rows: [
                                HairlineMetricRow(
                                    id: "route-share-ready-location",
                                    title: "Location",
                                    value: exportPayload.includesLocation ? "Included" : "Excluded",
                                    accent: exportPayload.includesLocation ? .movement : .inkSecondary
                                ),
                                HairlineMetricRow(
                                    id: "route-share-ready-points",
                                    title: "Route points",
                                    value: String(exportPayload.points.count),
                                    unit: "points",
                                    accent: .movement
                                )
                            ])

                            if let sharePayload {
                                ShareLink(
                                    item: sharePayload,
                                    subject: Text("Route preview"),
                                    message: Text("Route preview prepared locally")
                                ) {
                                    Label("Share route preview", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .accessibilityIdentifier("route-share-share")
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                LooprSectionGroup(title: "Status") {
                    LooprFormCard {
                        LooprInlineMessage(errorMessage, tone: .critical)
                            .accessibilityIdentifier("route-share-error")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Route share preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.movement))
        .accessibilityIdentifier("route-share-preview-screen")
    }

    private var sharePayload: String? {
        guard let exportPayload,
              let data = try? JSONEncoder().encode(exportPayload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct DataImportFeatureScreen: View {
    let records: [DataRecord]
    let onImport: (Data) -> Void
    let accountImport: WHOOPImportStore?
    let legacyMigrationState: LegacyMigrationState
    let onRunLegacyMigration: () -> Void
    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var accountPickerPresented = false
    @State private var importProgress: String?
    #if DEBUG
    @State private var accountResult: WHOOPImportResult? = DebugCaptureFixtures.whoopImportResult
    #else
    @State private var accountResult: WHOOPImportResult?
    #endif

    var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Import") {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Review before importing", style: .cardTitle)
                            LooprText(
                                "Choose a Loopr JSON backup to restore saved records.",
                                style: .prose,
                                color: .inkSecondary
                            )
                        }
                    }

                    HairlineMetricList(rows: [
                        HairlineMetricRow(
                            id: "data-import-existing-records",
                            title: "Existing records",
                            value: records.count.formatted(.number.grouping(.automatic)),
                            accent: .brand
                        ),
                        HairlineMetricRow(
                            id: "data-import-legacy-state",
                            title: "Older Loopr data",
                            value: legacyMigrationState.displayName,
                            accent: .brand
                        )
                    ])

                    if legacyMigrationState == .ready {
                        Button("Migrate legacy data", action: onRunLegacyMigration)
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("data-legacy-migration-run")
                    } else if legacyMigrationState != .notAvailable {
                        LooprFormCard {
                            LooprInlineMessage(
                                "Older Loopr data cannot be migrated right now.",
                                tone: .neutral
                            )
                        }
                    }

                    Button("Choose backup") { isImporterPresented = true }
                        .buttonStyle(LooprPrimaryButtonStyle())
                        .accessibilityIdentifier("data-import-choose")
                }
            }

            LooprSectionGroup(title: "Account history") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        LooprText("Import WHOOP data", style: .cardTitle)
                        LooprText("In the WHOOP app, go to More, then App Settings, then Data Export. Request the export and save the emailed zip to Files. Then choose the zip, its folder or the CSV files here.", style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprText("Band recordings take priority when dates or sessions overlap.", style: .caption, color: .inkSecondary)
                        Button("Import WHOOP data") { accountPickerPresented = true }
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .disabled(accountImport == nil || importProgress != nil)
                            .accessibilityIdentifier("data-import-account-choose")
                        if let importProgress {
                            HStack(spacing: LooprSpacing.sm) {
                                ProgressView().accessibilityLabel("Importing history")
                                LooprText(importProgress, style: .prose, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("data-import-account-progress")
                        }
                        if let accountResult {
                            LooprInlineMessage(accountResult.summary, tone: .positive)
                                .accessibilityIdentifier("data-import-account-result")
                        }
                    }
                }
            }

            if let importError {
                LooprSectionGroup(title: "Status") {
                    LooprFormCard {
                        LooprInlineMessage(importError, tone: .critical)
                            .accessibilityIdentifier("data-import-error")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Import data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("data-import-preview-screen")
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json, .commaSeparatedText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                Task {
                    do {
                        let data = try await Task.detached {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: url)
                        }.value
                        onImport(data)
                        importError = nil
                    } catch { importError = error.localizedDescription }
                }
            } catch {
                importError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $accountPickerPresented, allowedContentTypes: [.zip, .folder, .commaSeparatedText], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard let accountImport, !urls.isEmpty else { return }
                importError = nil; accountResult = nil; importProgress = "Reading export"
                Task {
                    do {
                        let update: @MainActor @Sendable (String) -> Void = { text in importProgress = text }
                        let importer = WHOOPExportImporter(store: accountImport)
                        accountResult = try await importer.importFiles(urls, progress: { @Sendable [update] text in
                            await update(text)
                        })
                        NotificationCenter.default.post(name: looprDerivedGenerationUpdated, object: nil)
                        NotificationCenter.default.post(name: looprAccountHistoryImported, object: nil)
                    } catch { importError = error.localizedDescription }
                    importProgress = nil
                }
            } catch { importError = error.localizedDescription }
        }
        .sensoryFeedback(.success, trigger: accountResult != nil)
    }
}

private struct CycleExportActionScreen: View {
    let export: CycleExport
    let onExport: () async throws -> CycleExport
    @State private var preparedExport: CycleExport?
    @State private var preparedURL: URL?
    @State private var exportError: String?

    var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Private export") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        id: "cycle-export-entries",
                        title: "Entries",
                        value: String(export.entries.count),
                        accent: .cycle
                    ),
                    HairlineMetricRow(
                        id: "cycle-export-reminders",
                        title: "Reminders",
                        value: export.settings.remindersEnabled ? "Enabled" : "Off",
                        accent: .cycle
                    )
                ])
            }

            LooprSectionGroup(title: "Privacy") {
                LooprFormCard {
                    LooprText(
                        "Cycle history is included only after you explicitly choose export.",
                        style: .prose,
                        color: .inkSecondary
                    )
                }
            }

            LooprSectionGroup(title: "Actions") {
                Button("Prepare export") {
                    Task { @MainActor in
                        do {
                            let value = try await onExport()
                            preparedExport = value
                            preparedURL = try await LocalCycleExportWriter().write(value)
                            exportError = nil
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("cycle-export-create")
            }

            if let preparedExport, let preparedURL {
                LooprSectionGroup(title: "Ready") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprInlineMessage("Cycle export prepared locally.", tone: .positive)
                            HairlineMetricList(rows: [
                                HairlineMetricRow(
                                    id: "cycle-export-prepared-entries",
                                    title: "Exported entries",
                                    value: String(preparedExport.entries.count),
                                    accent: .cycle
                                )
                            ])
                            ShareLink(item: preparedURL) {
                                Label("Share export", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .accessibilityIdentifier("cycle-export-share")
                        }
                    }
                }
            }

            if let exportError {
                LooprSectionGroup(title: "Status") {
                    LooprFormCard {
                        LooprInlineMessage(exportError, tone: .critical)
                            .accessibilityIdentifier("cycle-export-error")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Cycle export")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.cycle))
        .accessibilityIdentifier("cycle-export-screen")
    }
}

private struct RecordsShareActionScreen: View {
    let shareCard: RecordsShareCard
    let onShare: (RecordsShareOptions) -> Void
    @State private var includeRoute = false
    @State private var includeJournal = false
    @State private var includeLocation = false
    @State private var didPrepare = false

    var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Preview") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText("Share only committed records", style: .cardTitle)
                        LooprInlineMessage(
                            "Your share card contains only committed records by default.",
                            tone: .neutral
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Share contents") {
                HairlineMetricList(rows: [
                    HairlineMetricRow(
                        id: "records-share-metrics",
                        title: "Metrics",
                        value: String(shareCard.recap.metrics.count),
                        unit: "records",
                        accent: .brand
                    ),
                    HairlineMetricRow(
                        id: "records-share-period",
                        title: "Period",
                        value: "\(shareCard.recap.startDay) to \(shareCard.recap.endDay)",
                        accent: .brand
                    )
                ])
            }

            LooprSectionGroup(title: "Optional private content") {
                LooprFormCard(padding: LooprSpacing.none) {
                    VStack(spacing: LooprSpacing.none) {
                        LooprToggleRow(
                            title: "Include route",
                            subtitle: "Adds the recorded route to the share preview.",
                            isOn: $includeRoute
                        )
                        LooprHairline()
                        LooprToggleRow(
                            title: "Include journal",
                            subtitle: "Adds journal content to the share preview.",
                            isOn: $includeJournal
                        )
                        LooprHairline()
                        LooprToggleRow(
                            title: "Include location",
                            subtitle: "Adds location details to the share preview.",
                            isOn: $includeLocation
                        )
                    }
                }
            }

            LooprSectionGroup(title: "Actions") {
                Button("Create share preview") {
                    onShare(RecordsShareOptions(includeRoute: includeRoute, includeJournal: includeJournal, includeLocation: includeLocation))
                    didPrepare = true
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("records-share-create")
            }

            if didPrepare {
                LooprSectionGroup(title: "Ready") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprInlineMessage("Share preview prepared locally.", tone: .positive)
                            if let sharePayload {
                                ShareLink(
                                    item: sharePayload,
                                    subject: Text("Records share preview"),
                                    message: Text("Records share preview prepared locally")
                                ) {
                                    Label("Share records preview", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .accessibilityIdentifier("records-share-share")
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Share preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("records-share-preview-screen")
    }

    private var sharePayload: String? {
        guard let data = try? JSONEncoder().encode(shareCard) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
struct DataFeatureRoot: View {
    let route: (DataKit.DataRoute) -> Void
    let repositories: ProductRepositoryContainer?
    private let repository: any DataStore
    private let seedFixture: Bool
    @StateObject private var viewModel: DataViewModel

    init(route: @escaping (DataKit.DataRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        let repository: any DataStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.data
            seedFixture = false
        } else {
            repository = DataRepository()
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.route = route
        self.repositories = repositories
        self.repository = repository
        self.seedFixture = seedFixture
        _viewModel = StateObject(wrappedValue: DataViewModel(repository: repository))
    }

    var body: some View {
        DataScreen(viewModel: viewModel, route: route)
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixture {
                    do { try await repository.insert(productDataFixture) } catch { }
                }
                await viewModel.load()
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct DataDestinationFeatureRoot: View {
    let route: DataKit.DataRoute
    let repositories: ProductRepositoryContainer?
    private let repository: any DataStore
    private let seedFixture: Bool
    @StateObject private var viewModel: DataViewModel
    @State private var actionMessage: String?
    @State private var preparedBackupURL: URL?
    @State private var legacyMigrationState: LegacyMigrationState = .notAvailable

    init(route: DataKit.DataRoute, repositories: ProductRepositoryContainer? = nil) {
        let repository: any DataStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.data
            seedFixture = false
        } else {
            repository = DataRepository()
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.route = route
        self.repositories = repositories
        self.repository = repository
        self.seedFixture = seedFixture
        _viewModel = StateObject(wrappedValue: DataViewModel(repository: repository))
    }

    var body: some View {
        Group {
            if route == .importPreview {
                DataImportFeatureScreen(
                    records: viewModel.records,
                    onImport: importBackup,
                    accountImport: repositories?.persistent?.accountImport,
                    legacyMigrationState: legacyMigrationState,
                    onRunLegacyMigration: runLegacyMigration
                )
            } else {
                DataDestinationScreen(
                    route: route,
                    records: viewModel.records,
                    inventory: viewModel.inventory,
                    onDeleteAll: deleteAllData,
                    onDeleteHealthKitSamples: deleteHealthKitSamples,
                    onExport: exportData,
                    onExportDiagnostics: exportDiagnostics,
                    onRunReanalysis: runReanalysis,
                    onExportDay: exportDay,
                    onDeleteDay: deleteDay,
                    onRunDayReanalysis: runDayReanalysis,
                    legacyMigrationState: legacyMigrationState,
                    onRunLegacyMigration: runLegacyMigration
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let actionMessage {
                ProductInlineMessageToast(
                    actionMessage,
                    tone: productMessageTone(actionMessage),
                    accessibilityIdentifier: "data-action-message"
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let preparedBackupURL {
                ShareLink(item: preparedBackupURL) {
                    Label("Share backup", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LooprPrimaryButtonStyle())
                .padding(LooprSpacing.screenGutter)
                .accessibilityIdentifier("data-share-backup")
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            if seedFixture {
                do { try await repository.insert(productDataFixture) } catch { }
            }
            await viewModel.load()
            legacyMigrationState = await repository.legacyMigrationState()
        }
        .productStorageGate(repositories)
    }

    private func deleteAllData() {
        Task { @MainActor in
            do {
                // Clear the feature namespace first, then run the complete
                // onboarding destructive-effects cascade in production. The
                // latter also removes profile, device, onboarding, and every
                // other product namespace from the canonical local ledger.
                try await viewModel.deleteAllOrThrow()
                if let persistent = repositories?.persistent {
                    _ = try ReleaseActionAuditStore(database: persistent.database).record(
                        .deletion,
                        scope: "all-loopr-owned-data",
                        performedAt: Date(),
                        userConfirmed: true
                    )
                    // Record the confirmed boundary before executing it. Full
                    // deletion intentionally clears the audit row along with
                    // every other local ledger; retaining it afterward would
                    // contradict the user's request to remove all local data.
                    try await persistent.destructiveEffects.deleteAllData()
                }
                preparedBackupURL = nil
                await viewModel.load()
                actionMessage = "All Loopr data was deleted locally."
            } catch {
                actionMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func deleteHealthKitSamples() {
        Task { @MainActor in
            do {
                if let sqlite = repository as? SQLiteDataRepository {
                    let removed = try await sqlite.removeHealthKitSamplesReportingCount()
                    await viewModel.load()
                    actionMessage = removed == 1
                        ? "Removed 1 sample Loopr wrote to Health."
                        : "Removed \(removed) samples Loopr wrote to Health."
                } else {
                    try await repository.removeHealthKitSamplesChecked()
                    await viewModel.load()
                    actionMessage = "Removed the samples Loopr wrote to Health."
                }
            } catch {
                actionMessage = "HealthKit removal failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportData() {
        Task {
            do {
                if let database = repositories?.persistent?.database {
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("loopr-export-\(UUID().uuidString).sqlite")
                    let exported = try database.export(to: destination)
                    _ = try ReleaseActionAuditStore(database: database).record(
                        .export,
                        scope: "full-database",
                        performedAt: Date(),
                        userConfirmed: true
                    )
                    actionMessage = "Full database backup prepared locally (\(exported.lastPathComponent))."
                    preparedBackupURL = exported
                } else {
                    let data = try await repository.exportJSON()
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("loopr-export-\(UUID().uuidString).json")
                    try data.write(to: destination, options: .atomic)
                    preparedBackupURL = destination
                    actionMessage = "Backup ready to share."
                }
            } catch {
                actionMessage = "Backup failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportDiagnostics() {
        Task {
            do {
                let data = try await repository.exportRuntimeDiagnosticsJSON()
                actionMessage = "Redacted diagnostics prepared locally (" + String(data.count) + " bytes)."
            } catch {
                actionMessage = "Diagnostics failed: " + error.localizedDescription
            }
        }
    }

    private func runReanalysis() {
        Task {
            do {
                let statuses = try await repository.reanalyzeAllChecked(algorithmVersion: 1)
                await viewModel.load()
                actionMessage = statuses.isEmpty ? "No records require re-analysis." : "Re-analysis completed for " + String(statuses.count) + " day(s)."
            } catch {
                actionMessage = "Re-analysis failed: " + error.localizedDescription
            }
        }
    }

    private func exportDay(_ day: String) {
        Task {
            do {
                let backup: DataBackup
                if let checked = repository as? any CheckedDataStore {
                    backup = try await checked.exportDayChecked(day)
                } else {
                    backup = await repository.exportDay(day)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(backup)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("loopr-export-\(day)-\(UUID().uuidString).json")
                try data.write(to: destination, options: .atomic)
                preparedBackupURL = destination
                actionMessage = "Day backup ready to share."
            } catch {
                actionMessage = "Day export failed: " + error.localizedDescription
            }
        }
    }

    private func deleteDay(_ day: String) {
        Task {
            do {
                try await repository.deleteDayChecked(day)
                await viewModel.load()
                actionMessage = "Deleted saved data records for " + day + "."
            } catch {
                actionMessage = "Day deletion failed: " + error.localizedDescription
            }
        }
    }

    private func runDayReanalysis(_ day: String) {
        Task {
            do {
                _ = try await repository.reanalyzeChecked(day: day, algorithmVersion: 1)
                await viewModel.load()
                actionMessage = "Re-analysis completed for " + day + "."
            } catch {
                actionMessage = "Day re-analysis failed: " + error.localizedDescription
            }
        }
    }

    private func runLegacyMigration() {
        Task {
            do {
                // A production adapter must supply legacy candidates through
                // its own verified source. Empty candidates are rejected by
                // DataKit rather than reported as a successful migration.
                let candidates = seedFixture ? [productDataFixture] : []
                _ = try await repository.runLegacyMigration(records: candidates)
                await viewModel.load()
                legacyMigrationState = await repository.legacyMigrationState()
                actionMessage = "Legacy data migration completed locally."
            } catch {
                actionMessage = "Legacy migration failed: " + error.localizedDescription
            }
        }
    }

    private func importBackup(_ data: Data) {
        Task {
            do {
                if let text = String(data: data, encoding: .utf8),
                   text.split(whereSeparator: { $0.isNewline }).first?.hasPrefix("id,day,table") == true {
                    let parsed = try WHOOPCSVParser.parse(data)
                    let preview: ImportPreview
                    if let checked = repository as? any CheckedDataStore {
                        preview = try await checked.validatedPreviewChecked(source: .whoopCSV, incoming: parsed)
                    } else {
                        preview = try await repository.validatedPreview(source: .whoopCSV, incoming: parsed)
                    }
                    _ = try await repository.beginImport(preview)
                } else {
                    let backup = try JSONDecoder().decode(DataBackup.self, from: data)
                    if let checked = repository as? any CheckedDataStore {
                        try await checked.restoreChecked(backup)
                    } else {
                        try await repository.restore(backup)
                    }
                }
                await viewModel.load()
                actionMessage = "Import applied locally after validation."
            } catch {
                actionMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

@MainActor
struct CycleDestinationFeatureRoot: View {
    let route: CycleKit.CycleRoute
    let repositories: ProductRepositoryContainer?
    private let navigate: (CycleKit.CycleRoute) -> Void
    private let repository: any CycleStore
    @StateObject private var viewModel: CycleViewModel

    init(
        route: CycleKit.CycleRoute,
        repositories: ProductRepositoryContainer? = nil,
        navigate: @escaping (CycleKit.CycleRoute) -> Void = { _ in }
    ) {
        let repository: any CycleStore = repositories?.persistent?.cycle ?? CycleRepository(
            enabled: true,
            entries: [CycleEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000911")!,
                day: "2026-08-01",
                kind: .periodStart,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )
        self.route = route
        self.repositories = repositories
        self.navigate = navigate
        self.repository = repository
        let reminderScheduler: any CycleReminderScheduler = repositories?.persistent?.cycleReminderScheduler
            ?? UnavailableCycleReminderScheduler()
        _viewModel = StateObject(wrappedValue: CycleViewModel(
            repository: repository,
            reminderScheduler: reminderScheduler
        ))
    }

    var body: some View {
        Group {
            if route == .overview {
                CycleScreen(viewModel: viewModel, route: handleCycleRoute)
            } else if route == .export {
                CycleExportActionScreen(
                    export: CycleExport(entries: viewModel.history, settings: viewModel.settings),
                    onExport: { try await repository.export() }
                )
            } else {
                CycleDestinationScreen(
                    route: route,
                    export: CycleExport(entries: viewModel.history, settings: viewModel.settings),
                    onLog: { entry in
                        Task {
                            await viewModel.log(entry, today: CycleDate.string(Date()))
                        }
                    },
                    onExport: {},
                    repository: repository,
                    settings: viewModel.settings,
                    actionError: viewModel.actionError?.localizedDescription,
                    onSaveReminders: { enabled, hour in
                        await viewModel.updateReminders(enabled: enabled, hour: hour)
                    },
                    onDisable: { await viewModel.disable() }
                )
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            await viewModel.load(today: CycleDate.string(Date()))
        }
        .productStorageGate(repositories)
    }

    private func handleCycleRoute(_ destination: CycleKit.CycleRoute) {
        guard destination == .overview else {
            navigate(destination)
            return
        }
        Task { @MainActor in
            if await viewModel.optIn() {
                navigate(destination)
            }
        }
    }

}

enum AppHabitOutcomeResolution: Sendable, Equatable {
    case outcome(HabitOutcomeSnapshot)
    case excluded(HabitOutcomeExclusionRecord)
}

struct AppHabitOutcomeResolver: Sendable {
    let today: any TodayRepository
    let sleep: any SleepRepository
    let heart: any HeartRepository
    let calendar: any CalendarProviding
    let dateProvider: any DateProviding

    init(
        today: any TodayRepository,
        sleep: any SleepRepository,
        heart: any HeartRepository,
        calendar: any CalendarProviding = SystemCalendarProvider(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.today = today
        self.sleep = sleep
        self.heart = heart
        self.calendar = calendar
        self.dateProvider = dateProvider
    }

    func resolve(record: HabitDayRecord) async -> AppHabitOutcomeResolution {
        let now = dateProvider.now()
        func excluded(_ reason: HabitExclusionReason) -> AppHabitOutcomeResolution {
            .excluded(.init(behaviorDay: record.behaviorDay, reason: reason, resolvedAt: now))
        }
        guard let timeZone = TimeZone(identifier: record.behaviorTimeZoneID),
              let outcomeDay = nextDay(after: record.behaviorDay, timeZone: timeZone)
        else { return excluded(.unresolvedTimeZone) }
        guard let sleepSnapshot = try? await sleep.readSleepDay(for: outcomeDay),
              let session = sleepSnapshot.mainSleep else { return excluded(.missingMainSleep) }
        guard session.isMainSleep else { return excluded(.ambiguousMainSleep) }
        guard !session.isPartial else { return excluded(.partialSleep) }
        guard usable(sleepSnapshot.state), usable(session.state) else { return excluded(.invalidMetric) }
        guard session.end > session.start else { return excluded(.invalidMetric) }
        let todaySnapshot = try? await today.readSummary(for: outcomeDay)
        let heartSnapshot = try? await heart.readHeartDay(for: outcomeDay)

        var metrics: [HabitOutcomeMetricID: Double] = [:]
        if let todaySnapshot, let recovery = typedTodayMetric(todaySnapshot, ids: [.recovery, .readiness], expected: .scorePoints) {
            metrics[.recoveryScore] = recovery
        }
        if let sleepScore = typedSleepMetric(sleepSnapshot, id: "score", expected: .scorePoints) {
            metrics[.sleepScore] = sleepScore
        }
        if let heartSnapshot, let hrv = typedHeartMetric(heartSnapshot, id: .rmssd, expected: .milliseconds) {
            metrics[.hrvRMSSD] = hrv
        }
        if let heartSnapshot, let heartRate = typedHeartMetric(heartSnapshot, id: .restingHeartRate, expected: .beatsPerMinute) {
            metrics[.restingHeartRate] = heartRate
        }
        if let duration = typedSleepMetric(sleepSnapshot, id: "duration", expected: .minutes) {
            metrics[.sleepDuration] = duration
        }
        if let efficiency = typedSleepMetric(sleepSnapshot, id: "efficiency", expected: .percentagePoints) {
            metrics[.sleepEfficiency] = efficiency
        }
        if let consistency = typedSleepMetric(sleepSnapshot, id: "consistency", expected: .scorePoints) {
            metrics[.sleepConsistency] = consistency
        }
        guard !metrics.isEmpty else {
            return excluded(hasIncompatibleUnit(today: todaySnapshot, sleep: sleepSnapshot, heart: heartSnapshot) ? .incompatibleMetricVersion : .missingMetric)
        }
        let strain = todaySnapshot.flatMap { typedTodayMetric($0, ids: [.strain], expected: .strainScore) }
        var versions: [String: String] = [:]
        versions["today"] = todaySnapshot?.metrics.compactMap(\.algorithmVersion).sorted().joined(separator: ",") ?? "missing"
        versions["sleep"] = sleepSnapshot.algorithmVersion ?? "unknown"
        versions["heart"] = heartSnapshot?.algorithmVersion ?? "missing"
        return .outcome(HabitOutcomeSnapshot(
            behaviorDay: record.behaviorDay,
            behaviorTimeZoneID: record.behaviorTimeZoneID,
            sleepSessionID: session.id,
            sleepStartedAt: session.start,
            sleepEndedAt: session.end,
            outcomeDay: outcomeDay,
            metrics: metrics,
            priorDayStrain: strain,
            sourceVersions: versions,
            builtAt: now
        ))
    }

    private func nextDay(after day: DayIdentity, timeZone: TimeZone) -> DayIdentity? {
        var components = DateComponents()
        components.era = day.era
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let date = calendar.date(from: components, in: timeZone),
              let next = calendar.date(byAdding: .day, value: 1, to: date, in: timeZone) else { return nil }
        let output = calendar.components(in: timeZone, from: next)
        guard let year = output.year, let month = output.month, let day = output.day else { return nil }
        return DayIdentity(era: output.era ?? 1, year: year, month: month, day: day)
    }

    private func typedTodayMetric(_ snapshot: TodaySummary, ids: [TodayMetricID], expected: TodayMetricUnitID) -> Double? {
        ids.lazy.compactMap { id -> Double? in
            guard let metric = snapshot.metric(id), metric.numericUnit == expected,
                  let value = metric.numericValue, value.isFinite, usable(metric.state) else { return nil }
            return value
        }.first
    }

    private func typedSleepMetric(_ snapshot: SleepDaySnapshot, id: String, expected: SleepMetricUnitID) -> Double? {
        guard let metric = snapshot.metric(id), metric.numericUnit == expected,
              let value = metric.numericValue, value.isFinite, usable(metric.state) else { return nil }
        return value
    }

    private func typedHeartMetric(_ snapshot: HeartDaySnapshot, id: HeartMetricID, expected: HeartMetricUnitID) -> Double? {
        guard let metric = snapshot.metric(id), metric.numericUnit == expected,
              let value = metric.numericValue, value.isFinite, usable(metric.state) else { return nil }
        return value
    }

    private func usable(_ state: MetricState) -> Bool {
        switch state {
        case .measuredZero, .partial, .lowConfidence: true
        default: false
        }
    }

    private func hasIncompatibleUnit(today: TodaySummary?, sleep: SleepDaySnapshot, heart: HeartDaySnapshot?) -> Bool {
        let todayMismatch = today?.metrics.contains {
            $0.numericValue != nil && [TodayMetricID.recovery, .readiness].contains($0.id) && $0.numericUnit != .scorePoints
        } == true
        let sleepExpected: [String: SleepMetricUnitID] = [
            "score": .scorePoints, "duration": .minutes,
            "efficiency": .percentagePoints, "consistency": .scorePoints
        ]
        let sleepMismatch = sleep.metrics.contains { metric in
            guard metric.numericValue != nil, let expected = sleepExpected[metric.id] else { return false }
            return metric.numericUnit != expected
        }
        let heartMismatch = heart?.metrics.contains { metric in
            guard metric.numericValue != nil else { return false }
            switch metric.id {
            case .rmssd: return metric.numericUnit != .milliseconds
            case .restingHeartRate: return metric.numericUnit != .beatsPerMinute
            default: return false
            }
        } == true
        return todayMismatch || sleepMismatch || heartMismatch
    }
}

@MainActor
struct JournalDestinationFeatureRoot: View {
    let route: JournalKit.JournalRoute
    let repositories: ProductRepositoryContainer?
    private let repository: any JournalStore
    private let habitStore: any HabitStore
    private let seedFixture: Bool
    @StateObject private var viewModel: JournalViewModel
    @StateObject private var habitViewModel: HabitViewModel
    @State private var exportMessage: String?
    @State private var editingEntry: JournalEntry?
    /// One tap when a journal entry is saved, updated or removed.
    @State private var journalHaptic: LooprHaptic?

    init(route: JournalKit.JournalRoute, repositories: ProductRepositoryContainer? = nil) {
        let repository: any JournalStore
        let habitStore: any HabitStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.journal
            habitStore = persistent.habits
            seedFixture = false
        } else {
            repository = JournalRepository()
            #if DEBUG
            let statePrefix = "--loopr-habit-insight-state="
            let requestedState = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix(statePrefix) })
                .map { String($0.dropFirst(statePrefix.count)) }
                .flatMap(HabitInsightStatus.init(rawValue:))
            #else
            let requestedState: HabitInsightStatus? = nil
            #endif
            habitStore = HabitFixtures.store(status: requestedState ?? .collecting)
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.route = route
        self.repositories = repositories
        self.repository = repository
        self.habitStore = habitStore
        self.seedFixture = seedFixture
        _viewModel = StateObject(wrappedValue: JournalViewModel(repository: repository))
        _habitViewModel = StateObject(wrappedValue: HabitViewModel(
            store: habitStore,
            journalStore: repository,
            reminderScheduler: repositories?.persistent?.habitReminderScheduler ?? NoOpHabitReminderScheduler(),
            featureStageOverride: AppHabitFeatureGate.currentStage
        ))
    }

    var body: some View {
        Group {
            switch route {
            case .history:
                JournalHistoryScreen(
                    entries: viewModel.snapshot.entries,
                    onEdit: { editingEntry = $0 },
                    onDelete: { deleteJournalEntry($0) }
                )
            case .compose:
                JournalComposeScreen(onSave: saveJournalEntry)
            case .entry(let id):
                JournalEntryScreen(
                    entry: viewModel.snapshot.entries.first { $0.id == id },
                    onEdit: { editingEntry = $0 },
                    onDelete: { deleteJournalEntry($0) }
                )
            case .habits:
                HabitManagementScreen(viewModel: habitViewModel)
            case .habitSetup:
                HabitSetupScreen(viewModel: habitViewModel)
            case .checkIn(let day):
                HabitCheckInScreen(viewModel: habitViewModel, day: day)
            case .habitHistory:
                HabitHistoryScreen(viewModel: habitViewModel, route: navigate)
            case .habitInsights:
                HabitInsightsScreen(viewModel: habitViewModel, route: navigate)
            case .habitDetail(let habitID):
                HabitDetailScreen(viewModel: habitViewModel, habitID: habitID)
            case .privacy:
                JournalPrivacyScreen(
                    onExportFile: { includeContent in
                        var export = await repository.export(includeContent: includeContent)
                        if includeContent {
                            export = export.includingHabits(
                                definitions: (try? await habitStore.definitions(includeArchived: true)) ?? [],
                                dayRecords: (try? await habitStore.dayRecords()) ?? []
                            )
                        }
                        return try await LocalJournalExportWriter().write(export)
                    },
                    onRestorePreview: restorePreview,
                    onRestore: restoreJournal
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let exportMessage {
                ProductInlineMessageToast(
                    exportMessage,
                    tone: productMessageTone(exportMessage),
                    accessibilityIdentifier: "journal-export-success"
                )
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                JournalComposeScreen(entry: entry, onSave: saveEditedJournalEntry)
            }
        }
        .looprHaptic(journalHaptic)
        .task {
            guard repositories?.storageFailure == nil else { return }
            if seedFixture {
                do { _ = try await repository.save(JournalFixtures.privateEntry) } catch { }
            }
            await viewModel.load()
            await habitViewModel.load()
            if route == .habitInsights || route.isHabitDetail {
                await refreshHabitInsights()
            }
        }
        .productStorageGate(repositories)
    }

    private func saveJournalEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            do {
                _ = try await repository.save(entry)
                await viewModel.load()
                exportMessage = "Journal entry saved locally."
                journalHaptic = .success
            } catch {
                exportMessage = "Journal entry could not be saved: \(error.localizedDescription)"
                journalHaptic = .error
            }
        }
    }

    private func saveEditedJournalEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            do {
                _ = try await repository.edit(
                    id: entry.id,
                    behaviors: entry.behaviors,
                    tags: entry.tags,
                    note: entry.note,
                    now: Date()
                )
                editingEntry = nil
                await viewModel.load()
                exportMessage = "Journal entry updated locally."
                journalHaptic = .success
            } catch {
                exportMessage = "Journal entry could not be updated: \(error.localizedDescription)"
                journalHaptic = .error
            }
        }
    }

    private func deleteJournalEntry(_ entry: JournalEntry) {
        Task { @MainActor in
            do {
                try await repository.delete(id: entry.id)
                await viewModel.load()
                exportMessage = "Journal entry deleted."
                journalHaptic = LooprHaptic(.impact(weight: .medium))
            } catch {
                exportMessage = "Journal entry could not be deleted: \(error.localizedDescription)"
                journalHaptic = .error
            }
        }
    }

    private func navigate(_ destination: JournalRoute) {
        NotificationCenter.default.post(
            name: Notification.Name("com.loopr.journal.route"),
            object: destination
        )
    }

    private func refreshHabitInsights() async {
        guard let persistent = repositories?.persistent else { return }
        guard AppHabitFeatureGate.currentStage.exposesEntryPoints else { return }
        let resolver = AppHabitOutcomeResolver(
            today: persistent.today,
            sleep: persistent.sleep,
            heart: persistent.heart
        )
        if let records = try? await habitStore.dayRecords() {
            for record in records {
                switch await resolver.resolve(record: record) {
                case .outcome(let outcome):
                    try? await habitStore.saveOutcome(outcome)
                    try? await habitStore.removeOutcomeExclusion(for: record.behaviorDay)
                case .excluded(let exclusion):
                    try? await habitStore.removeOutcome(for: record.behaviorDay)
                    try? await habitStore.saveOutcomeExclusion(exclusion)
                }
            }
        }
        let store = habitStore
        _ = try? await Task.detached(priority: .utility) {
            try await HabitInsightEngine().recalculateAll(store: store, calculatedAt: Date())
        }.value
        await habitViewModel.load()
    }

    private func restorePreview(_ url: URL) async throws -> JournalRestorePreview {
        let archive = try decodeJournalArchive(url)
        try validateJournalArchive(archive)
        return JournalRestorePreview(
            entryCount: archive.entries.count,
            habitCount: archive.habitDefinitions.count,
            dayCount: archive.habitDayRecords.count
        )
    }

    private func restoreJournal(_ url: URL) async throws {
        let archive = try decodeJournalArchive(url)
        try validateJournalArchive(archive)
        if let persistent = repositories?.persistent {
            let store = try StorageDocumentStore(database: persistent.database, namespace: "journal")
            var mutations = try store.keys().filter {
                $0.hasPrefix("entry.") || $0.hasPrefix("habit.")
            }.map { StorageDocumentMutation.remove(key: $0) }
            mutations += try archive.entries.map {
                try StorageDocumentMutation.write($0, key: "entry.\($0.id.uuidString)")
            }
            mutations += try archive.habitDefinitions.map {
                try StorageDocumentMutation.write($0, key: "habit.definition.\($0.id.rawValue.uuidString.lowercased())")
            }
            mutations += try archive.habitDayRecords.map {
                try StorageDocumentMutation.write($0, key: "habit.day.\($0.behaviorDay.habitKey)")
            }
            try store.mutate(mutations)
        } else {
            await repository.deleteAll()
            for entry in archive.entries { _ = try await repository.save(entry) }
            try await habitStore.replaceSourceRecords(
                definitions: archive.habitDefinitions,
                dayRecords: archive.habitDayRecords
            )
        }
        try await habitStore.deleteDerivedData()
        await viewModel.load()
        await habitViewModel.load()
        await refreshHabitInsights()
        exportMessage = "Journal restored. Habit insights were rebuilt from local health data."
    }

    private func decodeJournalArchive(_ url: URL) throws -> JournalExport {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        return try JSONDecoder().decode(JournalExport.self, from: Data(contentsOf: url))
    }

    private func validateJournalArchive(_ archive: JournalExport) throws {
        guard (1...2).contains(archive.schemaVersion) else { throw JournalRestoreError.unsupportedSchema }
        guard archive.includesJournalContent else { throw JournalRestoreError.contentMissing }
        let entryIDs = archive.entries.map(\.id)
        guard Set(entryIDs).count == entryIDs.count else { throw JournalRestoreError.invalidArchive }
        guard archive.entries.allSatisfy({ DayIdentity(habitKey: $0.day) != nil }) else {
            throw JournalRestoreError.invalidArchive
        }
        try HabitStoreValidator.validateRestore(
            definitions: archive.habitDefinitions,
            records: archive.habitDayRecords
        )
    }
}

private extension JournalRoute {
    var isHabitDetail: Bool {
        if case .habitDetail = self { return true }
        return false
    }
}

@MainActor
struct RecordsDestinationFeatureRoot: View {
    let route: RecordsKit.RecordsRoute
    let repositories: ProductRepositoryContainer?
    private let repository: any RecordsStore
    private let seedFixture: Bool
    @StateObject private var viewModel: RecordsViewModel
    @State private var shareCard: RecordsShareCard?

    init(route: RecordsKit.RecordsRoute, repositories: ProductRepositoryContainer? = nil) {
        let repository: any RecordsStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.records
            seedFixture = false
        } else {
            repository = RecordsRepository()
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.route = route
        self.repositories = repositories
        self.repository = repository
        self.seedFixture = seedFixture
        _viewModel = StateObject(wrappedValue: RecordsViewModel(repository: repository))
    }

    var body: some View {
        Group {
            if route == .sharePreview, let shareCard {
                RecordsShareActionScreen(shareCard: shareCard) { options in
                    Task {
                        self.shareCard = await repository.shareCard(
                            period: .week,
                            startDay: viewModel.recap?.startDay ?? LocalDayNavigator.dayString(for: LocalDayNavigator.addingDays(-6, to: Date(), calendar: .autoupdatingCurrent), calendar: .autoupdatingCurrent),
                            endDay: viewModel.recap?.endDay ?? LocalDayNavigator.dayString(for: Date(), calendar: .autoupdatingCurrent),
                            options: options
                        )
                    }
                }
            } else {
                RecordsDestinationScreen(
                    route: route,
                    timeline: viewModel.snapshot.timeline,
                    shareCard: shareCard,
                    streak: viewModel.streak,
                    journey: viewModel.journey,
                    recap: viewModel.recap,
                    onShare: { options in
                        Task { @MainActor in
                            shareCard = await repository.shareCard(
                                period: .week,
                                startDay: viewModel.recap?.startDay ?? LocalDayNavigator.dayString(for: LocalDayNavigator.addingDays(-6, to: Date(), calendar: .autoupdatingCurrent), calendar: .autoupdatingCurrent),
                                endDay: viewModel.recap?.endDay ?? LocalDayNavigator.dayString(for: Date(), calendar: .autoupdatingCurrent),
                                options: options
                            )
                        }
                    }
                )
            }
        }
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixture {
                    await repository.save(MetricSnapshot(day: "2026-08-18", metric: "readiness", value: 82, algorithmVersion: 1))
                    await repository.save(RecordsFixtures.correctionEvent)
                }
                await viewModel.load()
                if route == .sharePreview {
                    shareCard = await repository.shareCard(
                        period: .week,
                        startDay: viewModel.recap?.startDay ?? LocalDayNavigator.dayString(for: LocalDayNavigator.addingDays(-6, to: Date(), calendar: .autoupdatingCurrent), calendar: .autoupdatingCurrent),
                        endDay: viewModel.recap?.endDay ?? LocalDayNavigator.dayString(for: Date(), calendar: .autoupdatingCurrent),
                        options: .init()
                    )
                }
            }
            .productStorageGate(repositories)
    }
}

@MainActor
struct StressDestinationFeatureRoot: View {
    let route: StressKit.StressRoute
    let navigate: (StressKit.StressRoute) -> Void
    let autoStart: Bool
    let bandPacing: Bool
    let repositories: ProductRepositoryContainer?
    private let breathing: BreathingSessionController?
    private let spotCheck: SpotCheckController?
    @StateObject private var viewModel: StressViewModel

    init(route: StressKit.StressRoute, repositories: ProductRepositoryContainer? = nil, navigate: @escaping (StressKit.StressRoute) -> Void = { _ in }, autoStart: Bool = false, bandPacing: Bool = false) {
        self.navigate = navigate
        self.autoStart = autoStart
        self.bandPacing = bandPacing
        self.route = route
        self.repositories = repositories
        if let persistent = repositories?.persistent {
            let breathing = persistent.breathingSession
            let spotCheck = SpotCheckController(
                mechanism: persistent.stressSpotCheckMechanism,
                history: SpotCheckHistory(),
                consumer: persistent.stressLiveConsumer
            )
            _viewModel = StateObject(wrappedValue: StressViewModel(
                breathing: breathing,
                spotCheck: spotCheck,
                store: persistent.stress
            ))
            self.breathing = breathing
            self.spotCheck = spotCheck
        } else {
            self.breathing = nil
            self.spotCheck = nil
            if repositories?.isFixtureComposition ?? true {
                let day = TodayFixtures.day
                let date = Calendar.current.date(from: DateComponents(
                    year: day.year, month: day.month, day: day.day, hour: 9
                )) ?? Date(timeIntervalSince1970: 1_700_000_000)
                let result = SpotCheckResult(
                    startedAt: date,
                    endedAt: date.addingTimeInterval(60),
                    rmssd: LooprFixtureMetrics.today(LooprMetricLinkID.rmssd),
                    heartRate: LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate),
                    quality: 0.8
                )
                let breath = BreathingResult(
                    startedAt: date.addingTimeInterval(-3_600),
                    endedAt: date.addingTimeInterval(-3_300),
                    cadence: 6,
                    samples: 30,
                    averageHeartRate: nil
                )
                let observations = LooprFixtureMetrics.today(LooprMetricLinkID.stress).map { value in
                    [StressObservation(
                        day: String(format: "%04d-%02d-%02d", day.year, day.month, day.day),
                        value: value,
                        coverage: 0.85,
                        confidence: 0.8
                    )]
                } ?? []
                let store = InMemoryStressStore(observations: observations, spotChecks: [result], breathingHistory: [breath])
                #if DEBUG
                _viewModel = StateObject(wrappedValue: StressViewModel(store: DebugCaptureFixtures.stressStore(store)))
                #else
                _viewModel = StateObject(wrappedValue: StressViewModel(store: store))
                #endif
            } else {
                _viewModel = StateObject(wrappedValue: StressViewModel())
            }
        }
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .stress:
                StressScreen(viewModel: viewModel, route: navigate)
            case .breathing:
                if let breathing {
                    StressBreathingScreen(
                        controller: breathing,
                        onFinishResult: { @Sendable [viewModel] result in
                            try await viewModel.saveBreathingResult(result)
                            await LooprNotificationRuntime.shared.breathingCompleted(id: result.id, at: result.endedAt)
                        },
                        paceWithBand: bandPacing, autoStart: autoStart,
                        bandPacingUnavailableReason: { @Sendable [runtime = repositories?.deviceCenterRuntime] in
                            await BandCueAvailability.reason(runtime: runtime)
                        }
                    )
                } else {
                    #if DEBUG
                    if DebugCaptureFixtures.bandConnected {
                        StressBreathingScreen(
                            controller: DebugCaptureFixtures.breathingController,
                            paceWithBand: true
                        ).environment(\.bandConnected, true)
                    } else {
                        StressBreathingScreen()
                    }
                    #else
                    StressBreathingScreen()
                    #endif
                }
            case .spotCheck:
                StressSpotCheckScreen(
                    controller: spotCheck,
                    latestResult: viewModel.spotChecks.last,
                    errorMessage: viewModel.spotCheckErrorMessage,
                    onRun: { Task { await viewModel.runSpotCheck() } }
                )
            case .history:
                StressHistoryScreen(results: viewModel.spotChecks, breathingHistory: viewModel.breathingHistory)
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            await viewModel.refresh()
        }
        .productionRefresh(environment: repositories?.environment ?? AppEnvironment.production()) { @MainActor @Sendable [viewModel] in
            await viewModel.refresh()
        }
        .productStorageGate(repositories)
    }
}

enum AppDeviceRoute: Hashable { case find, alarm, alarmStatus, gestures }

@MainActor
struct DeviceCenterFeatureRoot: View {
    let route: (AppDeviceRoute) -> Void
    let repositories: ProductRepositoryContainer?
    @State private var fixtureDiagnosticsMessage: String?
    #if DEBUG
    @State private var fixtureSharing = DebugCaptureFixtures.sharing
    private var fixtureSharingShown: Bool { DebugCaptureFixtures.bandStateEnabled }
    private var fixtureStatus: DeviceStatusSnapshot {
        DebugCaptureFixtures.siStoreFixture ? SIPolishFixtureWorld.deviceStatus : DebugCaptureFixtures.deviceStatus(DeviceCenterStateFixtures.populatedStatus)
    }
    private var fixtureIdentity: DeviceIdentity { DebugCaptureFixtures.siStoreFixture ? SIPolishFixtureWorld.device : DeviceCenterStateFixtures.sampleDevice }
    private var fixtureModelLabel: String? { DebugCaptureFixtures.siStoreFixture ? "Gen 4 band" : nil }
    #else
    @State private var fixtureSharing = false
    private var fixtureSharingShown: Bool { false }
    private var fixtureStatus: DeviceStatusSnapshot { DeviceCenterStateFixtures.populatedStatus }
    private var fixtureIdentity: DeviceIdentity { DeviceCenterStateFixtures.sampleDevice }
    private var fixtureModelLabel: String? { nil }
    #endif

    init(route: @escaping (AppDeviceRoute) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.route = route
        self.repositories = repositories
    }

    var body: some View {
        Group {
            if let persistent = repositories?.persistent {
                ProductionDeviceCenterFeature(
                    repository: persistent.device,
                    onboarding: persistent.onboarding,
                    commandWriter: persistent.deviceCommandWriter,
                    route: route
                )
            } else {
                DeviceCenterScreen(
                    viewState: DeviceCenterViewState(
                        universalState: .ready,
                        identity: fixtureIdentity,
                        status: fixtureStatus,
                        message: "Connected and ready."
                    ),
                    modelLabel: fixtureModelLabel,
                    onCommand: { command in
                        switch command.action {
                        case .findMyStrap: route(.find)
                        case .strapAlarmSetup: route(.alarm)
                        case .strapAlarmReadback: route(.alarmStatus)
                        case .displayGestureMapping: route(.gestures)
                        default: break
                        }
                    },
                    onExportDiagnostics: { fixtureDiagnosticsMessage = "Fixture redacted diagnostics export prepared locally." },
                    heartRateSharingEnabled: fixtureSharingShown ? fixtureSharing : nil,
                    onHeartRateSharingChange: { @MainActor value in fixtureSharing = value }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let fixtureDiagnosticsMessage {
                ProductInlineMessageToast(
                    fixtureDiagnosticsMessage,
                    tone: productMessageTone(fixtureDiagnosticsMessage),
                    accessibilityIdentifier: "device-diagnostics-result"
                )
            }
        }
        .productStorageGate(repositories)
    }
}

@MainActor
private struct ProductionDeviceCenterFeature: View {
    let route: (AppDeviceRoute) -> Void
    let repository: any DeviceCenterRepository
    let onboarding: any OnboardingRepository
    @EnvironmentObject private var bluetoothModel: BluetoothApplicationModel
    @Environment(\.looprBandLink) private var bandLink
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: DeviceCenterViewModel
    @State private var diagnosticsPayload: String?
    @State private var diagnosticsMessage: String?
    @State private var actionMessage: String?

    init(
        repository: any DeviceCenterRepository,
        onboarding: any OnboardingRepository,
        commandWriter: any DeviceCommandWriter,
        route: @escaping (AppDeviceRoute) -> Void
    ) {
        self.route = route
        self.repository = repository
        self.onboarding = onboarding
        let actions = CapabilityGatedDeviceActionService(repository: repository, writer: commandWriter)
        _viewModel = StateObject(wrappedValue: DeviceCenterViewModel(repository: repository, actionService: actions))
    }

    var body: some View {
        DeviceCenterScreen(
            viewState: viewModel.viewState,
            onCommand: { command in
                switch command.action {
                case .findMyStrap: route(.find)
                case .strapAlarmSetup: route(.alarm)
                case .strapAlarmReadback: route(.alarmStatus)
                case .displayGestureMapping: route(.gestures)
                case .forgetBand, .deprovision:
                    // Deleting the stored records alone leaves the accessory,
                    // its saved identifier, and the running connection in
                    // place, so the old band would reconnect by itself.
                    viewModel.send(command) { await bluetoothModel.removePairing() }
                case .rePair:
                    // No band opcode exists. Loopr drops the accessory record
                    // and reopens the picker.
                    viewModel.send(command) { await bluetoothModel.rePair() }
                default: viewModel.send(command)
                }
            },
            onExportDiagnostics: prepareDiagnostics,
            experimentalSupportEnabled: bluetoothModel.experimentalSupportEnabled,
            onExperimentalSupportChange: { enabled in
                Task {
                    do {
                        try await bluetoothModel.setExperimentalSupport(enabled)
                        try await onboarding.setExperimentalSupport(enabled)
                    } catch {
                        #if DEBUG
                        print("[Loopr Device Center] experimental support change failed: \(error)")
                        #endif
                        actionMessage = "Loopr couldn't change experimental support. Try again."
                    }
                }
            },
            heartRateSharingEnabled: bluetoothModel.heartRateSharing.enabled,
            heartRateSharingMessage: bluetoothModel.heartRateSharing.message,
            onHeartRateSharingChange: { @Sendable [bluetoothModel] enabled in
                Task { await bluetoothModel.heartRateSharing.setEnabled(enabled) }
            }
        )
        .task {
            viewModel.load()
        }
        // The screen follows the band while it is open: once when the band
        // state settles, then every five seconds. The current state stays on
        // screen until the new one is read, so nothing flashes.
        .task(id: liveReloadKey) {
            guard scenePhase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            while !Task.isCancelled {
                await bluetoothModel.heartRateSharing.reconcile()
                await viewModel.reload()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: viewModel.viewState, initial: true) { _, state in
            publishNotificationSignals(state)
        }
        .onChange(of: viewModel.lastActionError) { _, error in
            actionMessage = error
        }
        .sensoryFeedback(.error, trigger: viewModel.lastActionError) { _, error in error != nil }
        .task(id: actionMessage) {
            guard actionMessage != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            actionMessage = nil
        }
        .overlay(alignment: .bottom) {
            if let actionMessage {
                ProductInlineMessageToast(
                    actionMessage,
                    tone: productMessageTone(actionMessage),
                    accessibilityIdentifier: "device-action-result"
                )
            } else if let diagnosticsMessage {
                ProductInlineMessageToast(
                    diagnosticsMessage,
                    tone: productMessageTone(diagnosticsMessage),
                    accessibilityIdentifier: "device-diagnostics-result"
                ) {
                    if let diagnosticsPayload {
                        ShareLink(
                            item: diagnosticsPayload,
                            subject: Text("Loopr diagnostics"),
                            message: Text("Redacted local device diagnostics")
                        ) {
                            Label("Share redacted diagnostics", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(LooprButtonStyle(prominent: false))
                        .accessibilityIdentifier("device-share-diagnostics")
                    }
                }
            }
        }
    }

    private var liveReloadKey: String {
        "\(String(describing: bandLink?.indicator.link)):\(scenePhase == .active)"
    }

    private func prepareDiagnostics() {
        Task { @MainActor in
            let identity = try? await repository.readIdentity()
            let name = identity?.displayName ?? identity?.modelName ?? "Unknown strap"
            let report = viewModel.viewState.diagnostics ?? .empty
            diagnosticsPayload = DeviceFirstSessionDiagnosticsTextExporter.make(
                report: report,
                deviceName: name,
                generatedAt: Date()
            )
            diagnosticsMessage = "Redacted diagnostics are ready to share."
        }
    }

    private func publishNotificationSignals(_ state: DeviceCenterViewState) {
        guard let identity = state.identity else { return }
        let targetID = identity.id.rawValue.uuidString
        Task {
            // Disconnects are posted once by the band link after its grace
            // window. Posting here as well sent one for every blip.
            if state.universalState == .stale {
                await LooprNotificationRuntime.shared.deviceStateChanged(family: .staleData, targetID: targetID)
            }
            if case .measured(let percent) = state.status?.batteryPercent, percent <= 20 {
                await LooprNotificationRuntime.shared.deviceStateChanged(family: .battery, targetID: targetID)
            }
            if state.status?.charging == true {
                await LooprNotificationRuntime.shared.deviceStateChanged(family: .chargeGuidance, targetID: targetID)
            }
        }
    }

    private static func redactedIdentity(_ identity: DeviceIdentity) -> DeviceIdentity {
        DeviceIdentity(
            id: DeviceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
            peripheralIdentifier: nil,
            generation: identity.generation,
            modelName: identity.modelName,
            displayName: nil,
            modelConfidence: identity.modelConfidence,
            firmwareVersion: identity.firmwareVersion,
            serialNumber: nil,
            betaStatus: identity.betaStatus,
            capabilities: identity.capabilities
        )
    }
}

/// Production routes drive the shared SyncKit runtime: a buzz, an alarm write,
/// an alarm readback, and the locally stored double-tap choice.  Signal-strength
/// guidance stays unavailable because nothing reads RSSI yet, and an invented
/// number would send the user walking the wrong way.  DEBUG compositions retain
/// deterministic controls for route and accessibility coverage.
@MainActor
struct DeviceCenterDestinationFeatureRoot: View {
    let route: AppDeviceRoute
    let repositories: ProductRepositoryContainer?
    @Environment(\.looprBandLink) private var bandLink
    @State private var fixtureActionMessage: String?

    var body: some View {
        Group {
            if route == .alarm {
                // Band settings opens the same wake alarm screen as Today,
                // Sleep, and Settings. It also works with no band connected,
                // because the phone layer does not need one.
                WakeAlarmFeatureRoot(repositories: repositories)
            } else if repositories?.isFixtureComposition ?? true {
                fixtureDestination
            } else if bandLink?.isPaired == true, let runtime = repositories?.deviceCenterRuntime {
                ProductionDeviceDestination(
                    route: route,
                    runtime: runtime,
                    alarmRepository: repositories?.persistent?.device as? any StrapAlarmConfigurationRepository
                )
            } else {
                unavailableDestination
            }
        }
        .overlay(alignment: .bottom) {
            if let fixtureActionMessage {
                ProductInlineMessageToast(
                    fixtureActionMessage,
                    tone: productMessageTone(fixtureActionMessage),
                    accessibilityIdentifier: "device-fixture-action-message"
                )
            }
        }
        .productStorageGate(repositories)
    }

    @ViewBuilder
    private var fixtureDestination: some View {
        switch route {
        case .find:
            FindMyStrapScreen(
                feedback: FindMyStrapGuidanceCalculator.feedback(currentRSSI: -48, previousRSSI: -58),
                onFind: { fixtureActionMessage = "Fixture scan requested; no physical command was sent." }
            )
        case .alarm, .alarmStatus:
            StrapAlarmStatusScreen(reading: .noAlarmReported, savedFireDate: nil) {
                fixtureActionMessage = "Fixture alarm status refreshed locally; no physical command was sent."
            }
        case .gestures:
            GestureMappingScreen(mappings: [DeviceGestureMapping(gesture: .doubleTap, action: .markMoment)])
        }
    }

    private var unavailableDestination: some View {
        ContentUnavailableView {
            Label(unavailableTitle, systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(unavailableDescription)
        }
        .accessibilityIdentifier(unavailableIdentifier)
    }

    private var unavailableTitle: String {
        switch route {
        case .find: "Find my strap unavailable"
        case .alarm: "Strap alarm unavailable"
        case .alarmStatus: "Alarm status unavailable"
        case .gestures: "Gesture controls unavailable"
        }
    }

    private var unavailableDescription: String {
        switch route {
        case .find: "Loopr has no Bluetooth session for this strap, so it cannot buzz it."
        case .alarm: "Loopr has no Bluetooth session for this strap, so it cannot set an alarm."
        case .alarmStatus: "Loopr has no Bluetooth session for this strap, so it cannot ask about its alarm."
        case .gestures: "Loopr has no paired strap, so there is no double tap to map."
        }
    }

    private var unavailableIdentifier: String {
        switch route {
        case .find: "find-my-strap-screen"
        case .alarm: "wake-alarm-screen"
        case .alarmStatus: "strap-alarm-status-screen"
        case .gestures: "gesture-mapping-screen"
        }
    }
}

/// Drives the three live destinations against the shared runtime. Each action
/// reports what actually happened instead of dismissing optimistically.
@MainActor
private struct ProductionDeviceDestination: View {
    let route: AppDeviceRoute
    let runtime: any LooprDeviceCenterRuntime
    let alarmRepository: (any StrapAlarmConfigurationRepository)?

    @State private var message: String?
    @State private var savedFireDate: Date?
    @State private var assurance: StrapAlarmAssurance?
    @State private var statusReading: StrapAlarmStatusReading = .loading
    @State private var mappingSelection: DeviceAction?
    @State private var currentRSSI: Int?
    @State private var previousRSSI: Int?
    /// Bumped when the band confirms a buzz.
    @State private var buzzConfirmations = 0

    private let mappingStore = LooprGestureMappingStore()

    /// Carries the phone layer so the status screen can say what is set on
    /// this iPhone, not only on the band.
    private var alarmService: LooprStrapAlarmService? {
        alarmRepository.map {
            LooprStrapAlarmService(runtime: runtime, repository: $0, phoneAlarm: PhoneAlarmFallback())
        }
    }

    var body: some View {
        Group {
            switch route {
            case .find:
                FindMyStrapScreen(
                    feedback: FindMyStrapGuidanceCalculator.feedback(
                        currentRSSI: currentRSSI,
                        previousRSSI: previousRSSI
                    ),
                    message: message,
                    onFind: buzz
                )
                // One reading a second, and only while this screen is open.
                // Closing it cancels the task, so nothing polls in the
                // background.
                .task {
                    await FindMyStrapSignalPoll().run(
                        reading: { await runtime.readSignalStrength() },
                        emit: { value in
                            await MainActor.run {
                                previousRSSI = currentRSSI
                                currentRSSI = value
                            }
                        }
                    )
                }
            case .alarm, .alarmStatus:
                StrapAlarmStatusScreen(
                    reading: statusReading,
                    savedFireDate: savedFireDate,
                    assurance: assurance,
                    onRefresh: refreshAlarmStatus
                )
                .task { await loadAlarmStatus() }
            case .gestures:
                GestureMappingScreen(
                    selectedAction: mappingSelection,
                    options: LooprGestureMappingStore.doubleTapOptions,
                    onSelect: selectDoubleTapAction
                )
                .onAppear { mappingSelection = mappingStore.doubleTapAction() }
            }
        }
        .overlay(alignment: .bottom) {
            if route != .find, let message {
                ProductInlineMessageToast(
                    message,
                    tone: productMessageTone(message),
                    accessibilityIdentifier: "device-action-result"
                )
            }
        }
        .sensoryFeedback(.success, trigger: buzzConfirmations)
        .task(id: message) {
            // A result line is about the tap that just happened. Leaving it
            // on screen makes it look like the current state.
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    private func buzz() {
        Task {
            do {
                try await runtime.buzzBand(effect: 2)
                message = "The strap buzzed twice."
                buzzConfirmations += 1
            } catch {
                message = BandActionCopy.readable(error)
            }
        }
    }

    private func refreshAlarmStatus() {
        Task { await loadAlarmStatus() }
    }

    private func loadAlarmStatus() async {
        statusReading = .loading
        savedFireDate = try? await alarmService?.plannedFireDate()
        assurance = await alarmService?.assurance()
        do {
            if let fireDate = try await runtime.readBandAlarm() {
                statusReading = .armed(fireDate)
            } else {
                statusReading = .noAlarmReported
            }
        } catch {
            statusReading = .failed(BandActionCopy.readable(error))
        }
    }

    private func selectDoubleTapAction(_ action: DeviceAction?) {
        mappingStore.setDoubleTapAction(action)
        mappingSelection = mappingStore.doubleTapAction()
        message = switch action {
        case .markMoment: "A double tap now marks a moment."
        case .ringPhone: "A double tap now rings this iPhone."
        case .torch: "A double tap now switches the flashlight."
        default: "A double tap now does nothing."
        }
    }
}

/// SettingsKit owns presentation preferences, while ProfileKit owns the
/// canonical identity and anthropometric profile. This adapter keeps the
/// package API unchanged but makes Settings reads/writes flow through the
/// APP-02A ProfileRepository instead of treating SettingsSnapshot.profile as a
/// second source of truth.
actor ProfileBackedSettingsRepository: SettingsRepository {
    private let settings: any SettingsRepository
    private let profile: any ProfileRepository

    init(settings: any SettingsRepository, profile: any ProfileRepository) {
        self.settings = settings
        self.profile = profile
    }

    func snapshot() async -> SettingsSnapshot {
        var value = await settings.snapshot()
        if let canonical = try? await profile.readProfile() {
            value.profile = Self.settingsProfile(from: canonical)
            // The unit chosen during onboarding lives on the canonical profile.
            // Without this the Settings picker always read "metric", whatever
            // the person picked.
            value.units = canonical.unitSystem == .imperial ? .imperial : .metric
        }
        return value
    }

    func update(_ snapshot: SettingsSnapshot) async throws {
        let existing = try await profile.readProfile()
        if existing != nil || Self.carriesProfileData(snapshot.profile) {
            // A canonical profile requires a display name. Saving through
            // this path without one must report that instead of dropping the
            // person's height, weight, or age on the floor.
            let draft = Self.profileDraft(from: snapshot.profile, existing: existing, units: snapshot.units)
            _ = try await profile.saveProfile(draft)
        }
        try await settings.update(snapshot)
    }

    /// True when the settings snapshot carries any profile value at all.
    /// Saving Appearance on a fresh install must not fail on a missing name,
    /// so a completely empty profile section stays a no-op.
    private static func carriesProfileData(_ value: ProfileSettings) -> Bool {
        if value.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        return value.age != nil
            || value.heightCentimeters != nil
            || value.weightKilograms != nil
            || value.biologicalSex != nil
    }

    func resetProfile() async {
        _ = try? await resetProfileChecked()
    }

    func resetProfileChecked() async throws {
        try await profile.resetProfile()
        try await settings.resetProfileChecked()
    }

    func resetAll() async {
        _ = try? await resetAllChecked()
    }

    func resetAllChecked() async throws {
        try await profile.deleteAllData()
        try await settings.resetAllChecked()
    }

    private static func settingsProfile(from profile: Profile) -> ProfileSettings {
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return ProfileSettings(
            displayName: profile.displayName,
            age: profile.birthYear.map { max(0, currentYear - $0) },
            heightCentimeters: profile.heightCentimeters,
            weightKilograms: profile.weightKilograms,
            biologicalSex: profile.biologicalSex?.rawValue
        )
    }

    private static func profileDraft(from value: ProfileSettings, existing: Profile?, units: SettingsKit.UnitSystem) -> ProfileDraft {
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let unitSystem: ProfileKit.UnitSystem = units == .metric ? .metric : .imperial
        // Settings owns every field it carries, so a nil here is an explicit
        // clear and must not fall back to the stored value; otherwise an age
        // or weight can be entered once and never removed. The display name
        // is the exception: it is required, and SettingsKit maps an empty
        // field to nil, so falling back keeps the stored name rather than
        // failing validation on a field the person did not touch. Timezone
        // has no Settings field at all and is likewise preserved.
        return ProfileDraft(
            displayName: value.displayName ?? existing?.displayName,
            birthYear: value.age.map { currentYear - $0 },
            biologicalSex: value.biologicalSex.flatMap(BiologicalSex.init(rawValue:)),
            heightCentimeters: value.heightCentimeters,
            weightKilograms: value.weightKilograms,
            timezoneIdentifier: existing?.timezoneIdentifier,
            unitSystem: unitSystem
        )
    }
}

private func makeSettingsRepository(_ repositories: ProductRepositoryContainer?) -> any SettingsRepository {
    if let persistent = repositories?.persistent {
        return ProfileBackedSettingsRepository(settings: persistent.settings, profile: persistent.profile)
    }
    let settings = repositories?.isFixtureComposition == false ? SettingsSnapshot() : SettingsFixtures.darkPrivate
    return InMemorySettingsRepository(initial: capturedAppearance.map(settings.withAppearance) ?? settings)
}

/// The fixture settings snapshot pins a dark appearance override, and loading
/// it applies that override to the whole design system. That makes every screen
/// behind Settings render dark whatever the device is set to, so the light
/// appearance of a third of the app could never be screenshotted.
///
/// A visual capture run always passes `--loopr-phase06-screen=`. Under that
/// argument the fixture stops overriding the appearance and the app follows the
/// simulator, so `simctl ui appearance` controls the capture. An explicit
/// `--loopr-appearance=` still wins, which keeps the dark override testable.
/// Normal launches pass neither and keep the fixture exactly as it was.
/// True when the process was launched by the Phase 06 visual capture lane.
var isVisualCaptureRun: Bool {
    ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--loopr-phase06-screen=") }
}

private var capturedAppearance: AppearanceChoice? {
    let prefix = "--loopr-appearance="
    let arguments = ProcessInfo.processInfo.arguments
    if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
        return AppearanceChoice(rawValue: String(argument.dropFirst(prefix.count)))
    }
    guard arguments.contains(where: { $0.hasPrefix("--loopr-phase06-screen=") }) else {
        return nil
    }
    return .system
}

private extension SettingsSnapshot {
    func withAppearance(_ appearance: AppearanceChoice) -> SettingsSnapshot {
        SettingsSnapshot(
            profile: profile,
            units: units,
            appearance: appearance,
            accessibility: accessibility,
            goals: goals,
            surfacePrivacy: surfacePrivacy
        )
    }
}

/// The app composition owns the SettingsKit seams.  The platform adapters are
/// deliberately explicit unavailable states until their owning integrations
/// are present; a missing adapter must never look like granted permission.
actor LooprDesignSystemTokenBridge: DesignSystemTokenBridge {
    private var value = DesignSystemTokenState()

    func state() async -> DesignSystemTokenState { value }
    func apply(_ state: DesignSystemTokenState) async throws {
        value = state
        DesignSystemRuntime.apply(.init(
            appearance: LooprAppearanceOverride(rawValue: state.appearance.rawValue) ?? .system,
            increasedContrast: state.increasedContrastPreview,
            reduceMotion: state.reduceMotionOverride,
            measurementSystem: state.units.looprMeasurementSystem,
            voiceOverHints: state.voiceOverHints
        ))
    }

    func reset() async throws {
        value = DesignSystemTokenState()
        DesignSystemRuntime.reset()
    }
}

nonisolated enum LooprSettingsVersionSource {
    /// These are the app-level generations, independent of the marketing
    /// version stored in AppEnvironment.  Bumping either requires an explicit
    /// migration/re-analysis decision in the owning package.
    ///
    /// The algorithm generation is read from the daily analytics version
    /// ("loopr.daily.6" is 6). It used to be a hardcoded 1, so Settings kept
    /// showing v1 through five analytics generations.
    static let algorithmVersion = algorithmGeneration(CanonicalDailyAnalytics.version)
    static let protocolVersion = "loopr.protocol.v1"

    static func algorithmGeneration(_ version: String) -> Int {
        version.split(separator: ".").last.flatMap { Int($0) } ?? 0
    }
}

private struct AppSettingsComposition {
    let repository: any SettingsRepository
    let canonicalRepositories: CanonicalSettingsRepositories?
    let versions: VersionRegistry
    let integrations: SettingsIntegrationClients
    let tokenBridge: any DesignSystemTokenBridge
    let releaseBuild: Bool

    init(repositories: ProductRepositoryContainer?) {
        repository = makeSettingsRepository(repositories)
        tokenBridge = LooprDesignSystemTokenBridge()
        if repositories?.environment.composition == .production {
            integrations = SettingsIntegrationClients(
                healthKit: LooprHealthKitSettingsEntryPoint(runtime: repositories?.persistent?.healthSync),
                notifications: LooprNotificationRuntime.shared,
                aiPrivacy: LooprAISettingsRuntime.shared
            )
        } else {
            integrations = SettingsIntegrationClients(
                healthKit: UnavailableHealthKitSettingsEntryPoint(),
                notifications: UnavailableNotificationSettingsEntryPoint(),
                aiPrivacy: UnavailableAIPrivacySettingsEntryPoint()
            )
        }

        if let persistent = repositories?.persistent {
            canonicalRepositories = CanonicalSettingsRepositories(
                profile: persistent.profile,
                goals: persistent.profile
            )
            versions = VersionRegistry(
                appVersion: repositories?.environment.applicationVersion ?? "Unavailable",
                algorithmVersion: LooprSettingsVersionSource.algorithmVersion,
                protocolVersion: LooprSettingsVersionSource.protocolVersion
            )
        } else {
            canonicalRepositories = nil
            versions = VersionRegistry(
                appVersion: repositories?.environment.applicationVersion ?? "DEBUG Fixture",
                algorithmVersion: LooprSettingsVersionSource.algorithmVersion,
                protocolVersion: LooprSettingsVersionSource.protocolVersion
            )
        }
        releaseBuild = repositories?.environment.composition == .production
    }
}

@MainActor
struct SettingsFeatureRoot: View {
    let route: (SettingsRouteDestination) -> Void
    let repositories: ProductRepositoryContainer?
    private let composition: AppSettingsComposition
    @StateObject private var viewModel: SettingsScreenViewModel
    /// The debounced band state, so the row does not flip to "Not connected"
    /// on a reconnect that takes a second.
    @Environment(\.looprBandLink) private var bandLink
    @State private var wakeAlarmSummary: String?

    private var bandSummary: String {
        bandLink?.settingsSummary ?? "Not paired"
    }

    init(route: @escaping (SettingsRouteDestination) -> Void = { _ in }, repositories: ProductRepositoryContainer? = nil) {
        self.route = route
        self.repositories = repositories
        let composition = AppSettingsComposition(repositories: repositories)
        self.composition = composition
        _viewModel = StateObject(wrappedValue: SettingsScreenViewModel(
            repository: composition.repository,
            tokenBridge: composition.tokenBridge
        ))
    }

    #if DEBUG
    @State private var replaysOnboarding = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            SettingsScreen(
                viewModel: viewModel,
                route: route,
                releaseBuild: composition.releaseBuild,
                bandSummary: bandSummary,
                wakeAlarmSummary: wakeAlarmSummary,
                appVersion: composition.versions.appVersion,
                developerRows: developerRows
            )
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            await viewModel.load()
        }
        // Runs again when the sheet comes back from the alarm screen, so the
        // row shows what was just saved.
        .task {
            guard repositories?.storageFailure == nil,
                  let controller = WakeAlarmControllerFactory.make(repositories: repositories) else { return }
            wakeAlarmSummary = await controller.snapshot().settingsSummary(formatter: WakeAlarmFormatter())
        }
        .productStorageGate(repositories)
        #if DEBUG
        .fullScreenCover(isPresented: $replaysOnboarding) {
            OnboardingReplayRoot { replaysOnboarding = false }
        }
        #endif
    }

    private var developerRows: [LooprMenuItem] {
        #if DEBUG
        [
            LooprMenuItem(
                title: "Replay onboarding",
                accessibilityIdentifier: "settings-replay-onboarding",
                action: { replaysOnboarding = true }
            )
        ]
        #else
        []
        #endif
    }
}

#if DEBUG
/// Runs onboarding from the band intro as a fresh install would, on in-memory
/// state. Finishing it, or Close, returns to Settings with nothing changed.
@MainActor
private struct OnboardingReplayRoot: View {
    let onDone: () -> Void
    @EnvironmentObject private var bluetoothModel: BluetoothApplicationModel

    var body: some View {
        ProductOnboardingRoot(
            environment: .onboardingReplay(),
            bluetoothModel: bluetoothModel,
            onComplete: onDone
        )
        .overlay(alignment: .topLeading) {
            // Onboarding has no way out before the profile step; this one is
            // for the developer and stays out of the film's text area.
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(10)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .padding(.leading, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.xs)
            .accessibilityLabel("Close replay")
            .accessibilityIdentifier("onboarding-replay-close")
        }
    }
}
#endif

@MainActor
struct SettingsDestinationFeatureRoot: View {
    let destination: SettingsRouteDestination
    let repositories: ProductRepositoryContainer?
    private let composition: AppSettingsComposition
    private let settingsCoordinator: SettingsViewModel
    @StateObject private var viewModel: SettingsScreenViewModel
    @State private var integrationState: SettingsIntegrationState = .unavailable
    @State private var integrationMessage: String?
    @State private var notificationPreferences: [NotificationPreferenceSetting] = []

    init(destination: SettingsRouteDestination, repositories: ProductRepositoryContainer? = nil) {
        let composition = AppSettingsComposition(repositories: repositories)
        self.destination = destination
        self.repositories = repositories
        self.composition = composition
        self.settingsCoordinator = SettingsViewModel(
            repository: composition.repository,
            versions: composition.versions,
            releaseBuild: composition.releaseBuild,
            integrationClients: composition.integrations,
            tokenBridge: composition.tokenBridge,
            canonicalRepositories: composition.canonicalRepositories
        )
        _viewModel = StateObject(wrappedValue: SettingsScreenViewModel(
            repository: composition.repository,
            tokenBridge: composition.tokenBridge
        ))
    }

    @ViewBuilder
    var body: some View {
        if destination == .healthKit {
            AppleHealthSettingsScreen(runtime: repositories?.persistent?.healthSync)
                .productStorageGate(repositories)
        } else {
            destinationScreen
        }
    }

    private var destinationScreen: some View {
        SettingsDestinationScreen(
            destination: destination,
            snapshot: viewModel.snapshot,
            versions: composition.versions,
            integrationState: integrationState,
            onSave: { snapshot in
                Task {
                    do {
                        let ageChanged = destination == .profile
                            && viewModel.snapshot.profile.age != snapshot.profile.age
                        try await settingsCoordinator.update(snapshot)
                        await viewModel.load()
                        if ageChanged { await HeartZonePreferences.shared.profileAgeChanged() }
                    } catch {
                        integrationMessage = "Settings could not be saved: \(error.localizedDescription)"
                    }
                }
            },
            onResetProfile: {
                Task {
                    do {
                        try await settingsCoordinator.resetProfileChecked()
                        await viewModel.load()
                        await HeartZonePreferences.shared.profileAgeChanged()
                        integrationMessage = "Your profile and goals were reset."
                    } catch {
                        integrationMessage = "Profile reset failed: \(error.localizedDescription)"
                    }
                }
            },
            onResetAll: {
                Task {
                    do {
                        if let persistent = repositories?.persistent {
                            _ = try ReleaseActionAuditStore(database: persistent.database).record(
                                .deletion,
                                scope: "all-loopr-owned-data",
                                performedAt: Date(),
                                userConfirmed: true
                            )
                            try await persistent.destructiveEffects.deleteAllData()
                        } else {
                            try await settingsCoordinator.resetAllChecked()
                        }
                        await viewModel.load()
                        integrationMessage = "All Loopr data was deleted from this device. Restart Loopr to set it up again."
                    } catch {
                        integrationMessage = "Delete failed: \(error.localizedDescription)"
                    }
                }
            },
            onRequestPermission: {
                Task { await requestIntegrationPermission() }
            },
            onSetAIPrivacy: { enabled in
                Task { await setAIPrivacy(enabled) }
            },
            notificationPreferences: notificationPreferences,
            onSetNotificationPreference: { id, enabled in
                Task { await setNotificationPreference(id: id, enabled: enabled) }
            },
            releaseBuild: composition.releaseBuild,
            canonicalGoalsRepository: composition.canonicalRepositories?.goals,
            isLoading: viewModel.isLoading
        )
        .overlay(alignment: .bottom) {
            if let integrationMessage {
                ProductInlineMessageToast(
                    integrationMessage,
                    tone: productMessageTone(integrationMessage),
                    accessibilityIdentifier: "settings-integration-result"
                )
            }
        }
        .task {
            guard repositories?.storageFailure == nil else { return }
            await viewModel.load()
            await loadIntegrationState()
        }
        .productStorageGate(repositories)
    }

    private var integration: SettingsIntegration? {
        switch destination {
        case .healthKit: .healthKit
        case .notifications: .notifications
        case .aiPrivacy: .aiPrivacy
        default: nil
        }
    }

    private func loadIntegrationState() async {
        guard let integration else {
            integrationState = .unavailable
            return
        }
        integrationState = await settingsCoordinator.integrationState(for: integration)
        if integration == .notifications {
            notificationPreferences = await settingsCoordinator.notificationPreferences()
        }
    }

    private func requestIntegrationPermission() async {
        guard let integration else { return }
        integrationState = await settingsCoordinator.requestPermission(for: integration)
        integrationMessage = "\(integrationState.title): \(integrationState.detail)"
    }

    private func setAIPrivacy(_ enabled: Bool) async {
        guard destination == .aiPrivacy else { return }
        do {
            integrationState = try await settingsCoordinator.setAIPrivacyEnabled(enabled)
            integrationMessage = "\(integrationState.title): \(integrationState.detail)"
        } catch {
            integrationMessage = "AI privacy is unavailable: \(error.localizedDescription)"
        }
    }

    private func setNotificationPreference(id: String, enabled: Bool) async {
        guard destination == .notifications else { return }
        do {
            try await settingsCoordinator.setNotificationPreference(id: id, enabled: enabled)
            notificationPreferences = await settingsCoordinator.notificationPreferences()
        } catch {
            integrationMessage = "Notification preference could not be saved: \(error.localizedDescription)"
        }
    }
}

/// What the Settings flow opens for each destination. Kept out of the view
/// switch so a test can prove every Settings row lands on a real screen.
nonisolated enum SettingsDestinationTarget: Equatable {
    case deviceCenter
    case wakeAlarm
    case cycle
    case data
    case dataDiagnostics
    case aiProvider
    case goals
    case dataControls
    case heartAlerts
    case notifications
    case hiddenDiagnosticsUnavailable
    /// `SettingsDestinationFeatureRoot` renders Apple Health as its own screen.
    case appleHealth
    /// A SettingsKit form: profile, units, appearance, and the rest.
    case settingsForm

    /// Destinations whose SettingsKit form has real content. Any other
    /// destination reaching `.settingsForm` would show the package's
    /// "owned by its package" filler.
    static let formDestinations: Set<SettingsRouteDestination> = [
        .profile, .units, .appearance, .accessibility, .privacy, .surfacePrivacy,
        .versions, .legal, .support, .aiPrivacy
    ]

    static func resolve(
        _ destination: SettingsRouteDestination,
        isProduction: Bool,
        isVisualCapture: Bool
    ) -> Self {
        switch destination {
        case .deviceCenter: .deviceCenter
        case .wakeAlarm: .wakeAlarm
        case .cycle: .cycle
        case .dataHistory, .importExport: .data
        case .diagnostics: .dataDiagnostics
        case .aiPrivacy: isProduction || isVisualCapture ? .aiProvider : .settingsForm
        case .hiddenDiagnostics: isProduction ? .hiddenDiagnosticsUnavailable : .dataDiagnostics
        case .goals: .goals
        case .dataControls: .dataControls
        case .heartAlerts: .heartAlerts
        case .notifications: .notifications
        case .healthKit: .appleHealth
        case .profile, .units, .appearance, .accessibility, .privacy, .surfacePrivacy,
             .versions, .legal, .support:
            .settingsForm
        }
    }
}

enum SettingsFlowRoute: Hashable {
    case settings(SettingsRouteDestination)
    case device(AppDeviceRoute)
    case cycle(CycleKit.CycleRoute)
    case data(DataKit.DataRoute)
    case destructiveActions
}

/// Owns the sheet's typed navigation path independently of the value view.
///
/// `SettingsFlowRoot` is presented from an `item` sheet. A child button can
/// invalidate that sheet content while the parent's value view is being
/// rebuilt, so storing the route array only in the view and capturing its
/// `State` wrapper in a callback is not a reliable navigation boundary. A
/// stable reference model gives every package-owned callback the same path
/// for the lifetime of the sheet.
@MainActor
private final class SettingsNavigationModel: ObservableObject {
    @Published var path: [SettingsFlowRoute]

    init(path: [SettingsFlowRoute] = []) {
        self.path = path
    }

    func navigate(to route: SettingsFlowRoute) {
        path.append(route)
    }
}

@MainActor
struct SettingsFlowRoot: View {
    @StateObject private var navigationModel: SettingsNavigationModel
    let dismiss: () -> Void
    let repositories: ProductRepositoryContainer?
    let focusesAge: Bool

    init(dismiss: @escaping () -> Void = {}, repositories: ProductRepositoryContainer? = nil, initialPath: [SettingsFlowRoute] = [], focusesAge: Bool = false) {
        self.dismiss = dismiss
        self.repositories = repositories
        self.focusesAge = focusesAge
        _navigationModel = StateObject(wrappedValue: SettingsNavigationModel(path: initialPath))
    }

    var body: some View {
        NavigationStack(path: $navigationModel.path) {
            SettingsFeatureRoot(route: { navigationModel.navigate(to: .settings($0)) }, repositories: repositories)
                .toolbar {
                    // Reset and delete lives under Advanced now; a destructive
                    // screen one tap from the sheet's corner was too easy to hit.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismiss)
                    }
                }
                .navigationDestination(for: SettingsFlowRoute.self) { route in
                    flowDestination(route, navigationModel: navigationModel)
                }
        }
        .environment(\.profileAgeFocusRequested, focusesAge)
    }

    @ViewBuilder
    private func settingsDestination(
        _ destination: SettingsRouteDestination,
        navigationModel: SettingsNavigationModel
    ) -> some View {
        switch SettingsDestinationTarget.resolve(
            destination,
            isProduction: repositories?.environment.composition == .production,
            isVisualCapture: isVisualCaptureRun
        ) {
        case .deviceCenter:
            DeviceCenterFeatureRoot(
                route: { navigationModel.navigate(to: .device($0)) },
                repositories: repositories
            )
        case .wakeAlarm:
            WakeAlarmFeatureRoot(repositories: repositories)
        case .cycle:
            CycleFeatureRoot(
                route: { navigationModel.navigate(to: .cycle($0)) },
                repositories: repositories
            )
        case .data:
            DataFeatureRoot(
                route: { navigationModel.navigate(to: .data($0)) },
                repositories: repositories
            )
        case .dataDiagnostics:
            DataDestinationFeatureRoot(route: .diagnostics, repositories: repositories)
        case .heartAlerts:
            HeartAlertsSettingsScreen()
        case .notifications:
            LooprNotificationSettingsScreen(openHeartAlerts: { navigationModel.navigate(to: .settings(.heartAlerts)) })
        case .aiProvider:
            // The provider screen is production only, which meant the visual
            // capture lane never reached it: a form that takes an API key and
            // makes three claims about where data goes was shipping unreviewed.
            // A capture run renders the real screen so it can be screenshotted.
            AppAIProviderSettingsScreen()
        case .goals:
            GoalsFeatureRoot(repositories: repositories)
        case .dataControls:
            OnboardingDestructiveActionsFeatureRoot(repositories: repositories)
        case .hiddenDiagnosticsUnavailable:
            ContentUnavailableView {
                Label("Hidden diagnostics unavailable", systemImage: "lock.slash")
            } description: {
                Text("Developer diagnostics are not part of the release surface.")
            }
            .accessibilityIdentifier("settings-hidden-diagnostics-unavailable")
        case .appleHealth, .settingsForm:
            SettingsDestinationFeatureRoot(destination: destination, repositories: repositories)
        }
    }

    @ViewBuilder
    private func flowDestination(
        _ route: SettingsFlowRoute,
        navigationModel: SettingsNavigationModel
    ) -> some View {
        switch route {
        case .settings(let destination):
            settingsDestination(destination, navigationModel: navigationModel)
        case .device(let destination):
            DeviceCenterDestinationFeatureRoot(route: destination, repositories: repositories)
        case .cycle(let destination):
            CycleDestinationFeatureRoot(
                route: destination,
                repositories: repositories,
                navigate: { navigationModel.navigate(to: .cycle($0)) }
            )
        case .data(let destination):
            DataDestinationFeatureRoot(route: destination, repositories: repositories)
        case .destructiveActions:
            OnboardingDestructiveActionsFeatureRoot(repositories: repositories)
        }
    }
}

enum ProductFixture {
    /// The band battery a fixture launch shows, standing for a paired band.
    /// Nil for production and for fixtures without a band.
    static func bandBatteryPercent(for composition: AppEnvironment.Composition) -> Int? {
        switch composition {
        case .populated, .activeWorkout, .connectedMixedCapabilities:
            guard case .measured(let value) = DeviceCenterStateFixtures.populatedStatus.batteryPercent else {
                return nil
            }
            return value
        default:
            return nil
        }
    }

    static func metricState(for composition: AppEnvironment.Composition) -> MetricState {
        switch composition {
        case .empty: .noRecords
        case .populated, .activeWorkout, .connectedMixedCapabilities: .partial
        case .stale: .stale
        case .disconnected: .disconnected
        case .onboarding, .pairing, .production: .loading
        }
    }

    static func summary(for composition: AppEnvironment.Composition) -> TodaySummary {
        #if DEBUG
        if let summary = DebugCaptureFixtures.siMorningSummary() { return summary }
        if let summary = DebugCaptureFixtures.siVitalsTodaySummary(composition: composition) { return summary }
        #endif
        return composition == .populated || composition == .activeWorkout || composition == .connectedMixedCapabilities
            ? TodayFixtures.populated
            : TodayFixtures.summary(for: metricState(for: composition))
    }
}
