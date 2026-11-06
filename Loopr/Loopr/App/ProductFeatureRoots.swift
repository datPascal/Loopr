import AIKit
import Combine
import Foundation
import ProtocolKit
import SyncKit
import BodyKit
import BluetoothKit
import CycleKit
import DataKit
import ImportKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import FoodKit
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
import TrainKit
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
    /// FT-05: the Patterns screen, pushed from Today's pattern card or opened from an Ask source.
    case patterns
}

/// App-owned workout routes carry the canonical record identity across detail,
/// route, share, edit, and finish screens. WorkoutKit's package route remains
/// the feature callback type; the app adds identity at the navigation boundary.
nonisolated enum AppWorkoutRoute: Hashable {
    case catalog
    case intervals
    case log
    /// The quick log with a type chosen.
    case logActivity(ActivityType)
    /// The WOD log. A name fills it from the last result with that name.
    case wod(String?)
    case edit(UUID?)
    case startPicker
    case prepare(ActivityType)
    case live(UUID?, ActivityType)
    case finish(UUID?)
    case detail(UUID?)
    case recovery(UUID?)
    case route(UUID?)
    case sharePreview(UUID?)
    case detectedReview(DetectedWorkout)
    case train(TrainRoute)
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
    #if DEBUG
    let fixtureJournalStore = JournalRepository()
    lazy var fixtureFoodRepository = AppFoodRepository(environment: environment)
    /// The populated launch carries the Train fixture's plans, so Fitness plans the Upper A that Food's allowance and
    /// Today name for the fixture day (R2-UPG-1).
    lazy var fixtureTrainRepository = AppTrainRepository(
        environment: environment, seedsFixture: AppTrainFixtures.isRequested() || environment.composition == .populated)
    /// The launch's one profile. Profile saves into it, and Data and Fitness read it, so the birth year typed in Profile
    /// unlocks the age rulers (R2-UPG-2). The populated launch is Alex, born 1985; the other launches start without one,
    /// or with what onboarding saved in this launch (R3-NEW-1).
    lazy var fixtureProfile: InMemoryProfileRepository = ProductFixtureProfile.shellRepository(for: environment.composition)
    let fixtureHabitStore: InMemoryHabitStore = {
        if let mode = FiveTabJournalFixture.mode {
            let store = FiveTabJournalFixture.makeStore(insights: mode == "insights")
            FiveTabJournalFixture.precomputeComparisons(store)
            return store
        }
        let prefix = "--loopr-habit-insight-state="
        let state = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .flatMap { HabitInsightStatus(rawValue: String($0.dropFirst(prefix.count))) }
        return HabitFixtures.store(status: state ?? .collecting)
    }()
    #endif
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
            // A fresh launch (onboarding, pairing, empty) has recorded no workout yet (R3-NEW-3).
            let fresh = environment.composition.startsFresh
            #if DEBUG
            var workouts = FoodAssociationFixtures.enabled ? FoodAssociationFixtures.workouts(endingOn: environment.dateProvider.now())
                : DebugCaptureFixtures.siStoreFixture ? SIPolishFixtureWorld.workouts
                : fresh ? [] : [WorkoutFixtures.completedRun, WorkoutFixtures.interrupted]
            // The Train fixture's finished sessions point at these records, so the shared store needs them too.
            if AppTrainFixtures.isRequested() { workouts += AppTrainFixtures.workoutRecords + WorkoutLogFixtures.records }
            if WorkoutPageFixtures.isRequested { workouts += WorkoutPageFixtures.records }
            #else
            let workouts = fresh ? [] : [WorkoutFixtures.completedRun, WorkoutFixtures.interrupted]
            #endif
            let store = InMemoryWorkoutStore(workouts: workouts)
            workoutStore = store
            // A cold start has recorded nothing, so it has nothing to review. Only the populated fixtures carry a detection.
            let emptyComposition = fresh
            #if DEBUG
            // The absent Fitness fixture takes every source away, a detected workout included.
            let coldStart = emptyComposition || FitnessFixtures.isAbsentRequested()
            #else
            let coldStart = emptyComposition
            #endif
            detectedWorkouts = InMemoryDetectedWorkoutRepository(detections: coldStart ? [] : [WorkoutFixtures.detectedRun])
            // A Train fixture session runs on the fixture's day, so its workout record must too.
            #if DEBUG
            let workoutClock = AppTrainFixtures.isRequested() ? TrainLiveRuntime.makeClock(fixtureStart: AppTrainFixtures.now) : { Date() }
            #else
            let workoutClock: @Sendable () -> Date = { Date() }
            #endif
            workoutSession = WorkoutSessionController(store: store, now: workoutClock, liveSource: workoutLiveSampleSource)
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
            // Moves Journal habits into protocol version 1 once. A finished or empty run costs one small read.
            let routineMigrationTime = environment.dateProvider.now()
            Task { await RoutineJournalMigration.runOnce(database: repositories.database, habits: repositories.habits, now: routineMigrationTime) }
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
                meta: "Local storage",
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
                // History and the recovery split.
                contextRepository: TodayContextSourceFactory.make(environment: environment, repositories: repositories)
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

    // The pairing alert behind Today's Connect (R3-NEW-7). It names the band Loopr pairs with and has a way out for
    // someone without one.
    static let pairingTitle = "Connect a WHOOP 4.0 band?"
    static let pairingMessage = AccessoryProvisioningController.ownershipExplanationShort
        + "\n\nNo band? Food, Fitness, Protocol and Apple Health work without one."
    static let noBandButton = "I don't have a band"
    static let noBandResult = "Food, Fitness, Protocol and Apple Health work without a band. If you get one later, tap Connect band on Today, or open Settings, then Band."
    static let resultTitle = "Band"

    /// What to say once Continue hands over to the system's band picker. Nil while the picker or the connection is under
    /// way, or after the person cancelled it, since those already show themselves.
    static func result(after status: BluetoothApplicationStatus?) -> String? {
        guard let status else { return "This iPhone cannot look for a band right now. Try again after restarting Loopr." }
        switch status {
        case .pickerPresented, .preparing, .retrieving, .scanning, .connecting, .discovering, .subscribing, .connected,
             .cancelled:
            return nil
        case .bluetoothOff:
            return "Bluetooth is off. Turn it on in Control Center, then try again."
        case .failed(let reason), .disconnected(_, let reason):
            return reason
        case .checkingProvisioning, .needsPairing, .explanationRequired, .removing, .removed:
            return "Loopr could not open the band picker. Wake the band until its side light pulses blue, then try again."
        }
    }
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
    /// What happened after the pairing alert, so Continue or "I don't have a band" never just closes (R3-NEW-7).
    @State private var connectResult: String?
    /// Opens the wake alarm screen from the card under the day's content.
    private let openWakeAlarm: (() -> Void)?
    /// Opens the tab or screen behind a row, a timeline moment or the pattern card.
    private let openAgent: @MainActor (TodayAgentDestination) -> Void
    @Environment(\.metricHistoryProvider) private var metricHistory
    @Environment(\.healthMetricPins) private var pins
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.looprOpenWeeklyReview) private var openWeeklyReview
    @State private var agent = TodayAgentContent.empty
    @State private var agentLoadedOnce = false
    @State private var agentRefresh = 0
    /// The day dial's inputs and stickers (DEC-12.3), read with the rest of Today's slots.
    @State private var dial: TodayDialContent?
    /// The coach note, the protocol rail and the experiment strip under the dial (LV-04 step 3).
    @State private var companion: TodayCompanionContent?
    /// The meal a dial card's Edit opened in Food's editor, over Today.
    @State private var mealEdit: TodayMealEdit?

    init(
        environment: AppEnvironment,
        route: @escaping (TodayKit.TodayRoute) -> Void,
        repositories: ProductRepositoryContainer? = nil,
        openWakeAlarm: (() -> Void)? = nil,
        openAgent: @escaping @MainActor (TodayAgentDestination) -> Void = { _ in }
    ) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        self.openWakeAlarm = openWakeAlarm
        self.openAgent = openAgent
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
            accessory: wakeAlarmCard,
            pinnedNumbers: pins?.isCustomised == true
                ? AnyView(HealthPinnedSection(identifier: "today-numbers", limit: 4, showAll: { openAgent(.allMetrics) })) : nil,
            agent: TodayAgentSlotBuilder.withoutProtocolRow(agent),
            onAgentAction: handleAgentAction,
            dial: dial,
            dialCompanion: companion.map { AnyView(TodayCompanionView(content: $0, actions: companionActions)) },
            dialCompanionMore: companion.flatMap { content in
                TodayCompanionView.hasMore(content)
                    ? AnyView(TodayCompanionView(content: content, actions: companionActions, part: .more)) : nil
            }
        )
            .environment(\.todayDialActions, dialActions)
            .sheet(item: $mealEdit) { edit in mealEditor(edit) }
            .task(id: AgentLoadKey(day: currentDay, refresh: agentRefresh, generation: repositories?.storageGeneration, alarm: showsAlarmRow)) {
                guard repositories?.storageFailure == nil else { return }
                // The dial loads beside the rows, not after them, so its placeholder gives way as soon as it can
                // (ICP R3-PAS-1).
                async let dialLoaded: Void = loadDial()
                await loadAgent()
                await dialLoaded
                agentLoadedOnce = true
            }
            .onAppear { if agentLoadedOnce { agentRefresh += 1 } }
            .onChange(of: scenePhase) { _, phase in if phase == .active, agentLoadedOnce { agentRefresh += 1 } }
            #if canImport(UserNotifications)
            // Done or Skip today on a rule reminder while Loopr is open: Up next drops the rule at once (ICP round 4, HAB).
            .onReceive(NotificationCenter.default.publisher(for: ProtocolRuleReminderResponder.answered).receive(on: RunLoop.main)) { _ in
                if agentLoadedOnce { agentRefresh += 1 }
            }
            #endif
            .alert(
                TodayBandConnectionCopy.pairingTitle,
                isPresented: $isConnectExplanationPresented
            ) {
                Button("Continue") {
                    Task {
                        await bluetoothModel?.continueAfterExplanation()
                        isConnectExplanationPresented = false
                        connectResult = TodayBandConnectionCopy.result(after: bluetoothModel?.status)
                    }
                }
                .accessibilityIdentifier("today-connect-continue")
                Button(TodayBandConnectionCopy.noBandButton) {
                    isConnectExplanationPresented = false
                    bluetoothModel?.cancelExplanation()
                    connectResult = TodayBandConnectionCopy.noBandResult
                }
                .accessibilityIdentifier("today-connect-no-band")
                Button("Cancel", role: .cancel) {
                    isConnectExplanationPresented = false
                    bluetoothModel?.cancelExplanation()
                }
            } message: {
                Text(TodayBandConnectionCopy.pairingMessage)
            }
            .alert(
                TodayBandConnectionCopy.resultTitle,
                isPresented: Binding(get: { connectResult != nil }, set: { if !$0 { connectResult = nil } })
            ) {
                Button("OK", role: .cancel) { connectResult = nil }
            } message: {
                Text(connectResult ?? "")
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

    private struct AgentLoadKey: Hashable {
        let day: DayIdentity
        let refresh: Int
        let generation: UInt64?
        let alarm: Bool
    }

    /// The Timeline's alarm row follows the Sleep card: nowhere to open it, or an experimental band, means no row.
    private var showsAlarmRow: Bool { openWakeAlarm != nil && bandLink?.bandIsExperimental != true }

    private var agentLoader: TodayAgentLoader {
        TodayAgentLoader(environment: environment, repositories: repositories, history: metricHistory)
    }

    private func loadAgent() async {
        let isToday = daySelection.map { $0.day == $0.today } ?? true
        let loaded = await agentLoader.load(day: currentDay, isToday: isToday, includesAlarm: showsAlarmRow)
        if loaded != agent { agent = loaded }
    }

    /// The history the dial and the note read. Production uses the app's metric history; the populated fixture uses one
    /// coherent fixture series, so the readout, the dial and the note's receipt read the same nights.
    private var todayHistory: any MetricHistoryProviding {
        #if DEBUG
        if let fixture = TodayFixtureHistorySeam.history(environment: environment, repositories: repositories) { return fixture }
        #endif
        return metricHistory
    }

    private var dialLoader: TodayDialLoader {
        TodayDialLoader(environment: environment, repositories: repositories, history: todayHistory,
                        bandName: bandLink?.bandModelName ?? "")
    }

    private var noteRailLoader: TodayNoteRailLoader {
        TodayNoteRailLoader(sources: TodayNoteRailSources.live(environment: environment, repositories: repositories,
                                                              history: todayHistory, bandName: bandLink?.bandModelName ?? ""))
    }

    /// The rail evaluates the protocol once; the dial draws the same checks. The on-device rewording follows on its own,
    /// so the rule text shows at once and is replaced only by a rewording whose numbers matched.
    private func loadDial() async {
        TodayBedtimeWiring.attachIfNeeded(environment: environment, repositories: repositories)
        let day = currentDay
        let dialLoader = dialLoader
        let clock = dialLoader.clock(for: day)
        let isToday = TodayDialClock(day: day, calendar: clock.calendar)?.contains(clock.now) ?? false
        let railLoader = noteRailLoader
        let loaded = await railLoader.load(day: day, now: clock.now, calendar: clock.calendar, isToday: isToday,
                                           isClockPinned: clock.isPinned)
        dial = await dialLoader.load(day: day, protocolDay: loaded.protocolDay?.dialDay)
        var content = loaded.content
        content.weekReview = weekReviewOffer(content: content, now: clock.now, calendar: clock.calendar)
        if content != companion { companion = content }
        Task { @MainActor in
            guard var reworded = await railLoader.reworded(loaded), day == currentDay else { return }
            reworded.weekReview = companion?.weekReview
            companion = reworded
        }
    }

    /// The weekly review card's window, on today's content with a protocol, while the week is unseen.
    private func weekReviewOffer(content: TodayCompanionContent, now: Date, calendar: Calendar) -> TodayWeekReviewOffer? {
        guard openWeeklyReview != nil, content.isToday, case .rules? = content.rail else { return nil }
        let seen = WeeklyReviewSeenStore.standard(persisting: repositories?.persistent != nil)
        guard let window = WeeklyReviewSchedule.todayWindow(at: now, calendar: calendar, hasSeen: seen.hasSeen) else { return nil }
        return TodayWeekReviewOffer(weekKey: window.week.isoKey, opens: window.opens, closes: window.closes,
                                    title: WeeklyReviewCopy.todayTitle, detail: WeeklyReviewCopy.todayDetail)
    }

    private var companionActions: TodayCompanionActions {
        TodayCompanionActions(
            note: { action in
                switch TodayCompanionRouting.route(for: action) {
                case .destination(let destination): openAgent(destination)
                case .today(let today): route(today)
                case .startWindDown: Task { await BedtimeActivityPreference.set(true) }
                }
            },
            tick: { key in
                let day = currentDay
                let now = dialLoader.clock(for: day).now
                let kept = await noteRailLoader.tick(key, day: day, now: now)
                await loadDial()
                return kept
            },
            untick: { key in
                let day = currentDay
                let clock = dialLoader.clock(for: day)
                let gone = await noteRailLoader.untick(key, day: day, now: clock.now, timeZone: clock.calendar.timeZone)
                await loadDial()
                return gone
            },
            openProtocol: { openAgent(.tab(.protocol)) },
            openExperiment: { openAgent(TodayCompanionRouting.experimentStrip) },
            openWeekReview: {
                companion?.weekReview = nil
                openWeeklyReview?.run()
            },
            firstEvening: { start in
                if start {
                    Task {
                        await BedtimeActivityPreference.set(true)
                        await loadDial()
                    }
                } else {
                    TodayFirstEveningStore.dismiss(persisting: repositories?.isFixtureComposition == false)
                    companion?.offersFirstEvening = false
                }
            })
    }

    /// What the dial's cards can do in place: edit a meal in Food's editor over Today, tick a manual rule.
    private var dialActions: TodayDialActions {
        var actions = TodayDialActions()
        if foodRepository != nil {
            let edit: @MainActor (String) -> Void = { id in openMealEditor(id: id) }
            actions.editMeal = edit
        }
        let tick: @MainActor (String) async -> Bool = companionActions.tick
        actions.tickRule = tick
        return actions
    }

    private var foodRepository: AppFoodRepository? {
        if let persistent = repositories?.persistent { return AppFoodRepository(store: persistent.food, environment: environment) }
        #if DEBUG
        return repositories?.fixtureFoodRepository
        #else
        return nil
        #endif
    }

    private func openMealEditor(id: String) {
        guard let repository = foodRepository, let mealID = UUID(uuidString: id) else { return }
        Task {
            guard let draft = try? await repository.editDraft(id: mealID) else { return }
            mealEdit = TodayMealEdit(draft: draft, repository: repository)
        }
    }

    /// Food's own editor, so every change it allows works here too. Saving redraws the dial under the open card.
    private func mealEditor(_ edit: TodayMealEdit) -> some View {
        let now = environment.dateProvider.now()
        return NavigationStack {
            FoodReviewView(draft: edit.draft, repository: edit.repository, now: now,
                           fixture: repositories?.isFixtureComposition != false,
                           delete: edit.draft.expectedRevision.map { revision in { @MainActor @Sendable in
                               try await edit.repository.deleteMeal(id: edit.draft.id, expectedRevision: revision)
                               mealEdit = nil
                               await loadDial()
                           } },
                           cancel: { @MainActor @Sendable in mealEdit = nil }) { @MainActor @Sendable draft in
                try await edit.repository.confirm(draft, at: now)
                mealEdit = nil
                await loadDial()
            }
        }
    }

    private func handleAgentAction(_ action: TodayAgentAction) {
        if TodayAgentDestination.opensWakeAlarm(action) {
            openWakeAlarm?()
            return
        }
        if case .startPatternTest(let candidateID) = action {
            Task {
                _ = await agentLoader.startTest(candidateID: candidateID)
                openAgent(.patterns)
            }
            return
        }
        if let destination = TodayAgentDestination.destination(for: action) { openAgent(destination) }
    }

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
    var compact = false
    let open: () -> Void

    var body: some View {
        WakeAlarmCardFeatureRoot(
            repositories: repositories,
            suggestion: WakeAlarmSuggestion(viewModel.snapshot?.suggestedAlarm),
            accessibilityIdentifier: "sleep-wake-alarm-card",
            compact: compact,
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
    @Environment(\.looprAsk) private var ask
    @Environment(\.metricHistoryProvider) private var metricHistory
    @StateObject private var holder: SleepViewModelHolder
    /// How the night differed from the last 28 days, with the night it was worked out for.
    @State private var difference: (day: DayIdentity, comparison: SleepNightComparison)?
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
        )), tonightAccessory: bandLink?.bandIsExperimental == true ? nil : AnyView(SleepWakeAlarmAccessory(
            viewModel: viewModel, repositories: repositories, compact: true,
            open: { route(.suggestedAlarm) }
        )), differenceAccessory: differenceCard,
            // Sleep opens on the whole night. The summary that only led to it on a second tap is gone (Data ICP R1).
            showsNightDetails: true,
            footer: AnyView(NavigationLink(value: AppHealthRoute.method(.sleepStages)) {
                LooprCard(density: .flush) {
                    LooprRow(title: "How sleep is worked out", subtitle: "What goes into stages, need and debt, and where they stop being reliable",
                             symbol: "function", accent: .inkSecondary)
                        .padding(.horizontal, LooprSpacing.md)
                }
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityIdentifier("sleep-method")))
            .task(id: SleepDifferenceKey(day: looprCurrentDay(daySelection, fallback: fallbackDay), generation: repositories?.storageGeneration)) {
                guard repositories?.storageFailure == nil else { return }
                let day = looprCurrentDay(daySelection, fallback: fallbackDay)
                let loader = SleepComparisonLoader(environment: environment, repositories: repositories, history: metricHistory)
                let comparison = await loader.load(night: day)
                difference = comparison.map { (day, $0) }
            }
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

    private struct SleepDifferenceKey: Hashable {
        let day: DayIdentity
        let generation: UInt64?
    }

    /// Between Stages and Tonight, only for the night it was worked out for. Opens Ask about that night.
    private var differenceCard: AnyView? {
        guard let difference, difference.day == looprCurrentDay(daySelection, fallback: fallbackDay) else { return nil }
        return AnyView(SleepDifferenceCard(comparison: difference.comparison) {
            ask?.open("Sleep", prompt: SleepDifferenceCard.prompt)
        })
    }
}

/// Canonical detail destinations for Sleep. The shell supplies the typed route;
/// this root owns the repository read so detail screens cannot silently fall
/// back to a deterministic snapshot in production.
@MainActor
struct SleepDestinationFeatureRoot: View {
    let environment: AppEnvironment
    let route: SleepKit.SleepRoute
    let repositories: ProductRepositoryContainer?
    let navigate: (SleepKit.SleepRoute) -> Void
    @StateObject private var viewModel: SleepViewModel

    init(environment: AppEnvironment, route: SleepKit.SleepRoute, repositories: ProductRepositoryContainer? = nil,
         navigate: @escaping (SleepKit.SleepRoute) -> Void) {
        self.environment = environment
        self.route = route
        self.repositories = repositories
        self.navigate = navigate
        _viewModel = StateObject(wrappedValue: SleepNightDetails.viewModel(environment: environment, repositories: repositories))
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .coach:
                CoachFeatureRoot(environment: environment, repositories: repositories)
            case .day:
                SleepScreen(viewModel: viewModel, route: navigate, showsNightDetails: true)
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
    var layout: HeartScreenLayout = HeartScreenLayout()
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.bandConnected) private var bandConnected
    // Descendants observe only the day or live samples they render. The
    // holder publishes nothing, so this root does not re-render with the
    // view model, and its autoclosure builds the model once per identity
    // instead of on every shell re-render.
    @StateObject private var model: HeartViewModelHolder
    private var viewModel: HeartViewModel { model.viewModel }

    init(environment: AppEnvironment, layout: HeartScreenLayout = HeartScreenLayout(), route: @escaping (HeartKit.HeartRoute) -> Void = { _ in },
         repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.layout = layout
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
        HeartScreen(viewModel: viewModel, layout: layout, route: route)
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
            "Your band could not connect. Open Settings, then Band, to check the connection."
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
                confidence: result.resolvedAvailability == .insufficientQuality ? "Low confidence" : nil,
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
            return result.state == .lowConfidence ? "Low confidence" : nil
        case .insufficientQuality:
            return "Low confidence"
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
    let focus: BodyScreenFocus
    @Environment(\.looprDaySelection) private var daySelection
    @Environment(\.metricHistoryProvider) private var metricHistoryProvider
    @StateObject private var viewModel: BodyViewModel

    init(environment: AppEnvironment, focus: BodyScreenFocus = .all, route: @escaping (BodyKit.BodyRoute) -> Void = { _ in },
         repositories: ProductRepositoryContainer? = nil) {
        self.environment = environment
        self.focus = focus
        self.route = route
        self.repositories = repositories
        _viewModel = StateObject(wrappedValue: BodyViewModelFactory.make(environment: environment, repositories: repositories))
    }

    var body: some View {
        BodyScreen(viewModel: viewModel, focus: focus, route: route)
            .modifier(CardioAgeHealthSamplesModifier(enabled: environment.composition == .production,
                                                    runtime: repositories?.persistent?.healthSync))
            .modifier(BodyLogSummaryModifier(environment: environment, repositories: repositories))
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
                    .modifier(BodyLogSummaryModifier(environment: environment, repositories: repositories))
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
    /// Why the coach did not open. Both offer Try again (ICP R2-UPG-21): a store that failed to open can open on the
    /// next try, and one that was not ready yet usually is a moment later.
    fileprivate enum OpenFailure: Equatable {
        case couldNotOpen
        case noStore

        var message: String {
            switch self {
            case .couldNotOpen: "Loopr could not open your saved chats. Your chats are still on this iPhone."
            case .noStore: "Your chats are not ready yet. Try again in a moment."
            }
        }
    }

    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    /// The briefing a notification announced. The coach opens it instead of
    /// the latest chat.
    let origin: AskOrigin?
    let openChatID: UUID?
    /// Called once the coach has taken the request, so coming back to the coach later opens the latest chat.
    let consumeOpenChatID: () -> Void
    /// The sheet's Done. Nil when Ask is pushed instead of presented.
    let onDone: (@MainActor @Sendable () -> Void)?
    /// The camera button. Nil hides it.
    let attachPhoto: (@MainActor @Sendable () -> Void)?
    /// A source button under an answer. The shell closes Ask and opens the record. Nil leaves the strip out.
    let openSource: (@MainActor @Sendable (AgentSourceLink) -> Void)?
    @State private var chatModel: CoachChatViewModel?
    @State private var chatFailure: OpenFailure?
    @State private var attempt = 0
    @State private var haptic: LooprHaptic?

    init(
        environment: AppEnvironment,
        repositories: ProductRepositoryContainer? = nil,
        openChatID: UUID? = nil,
        origin: AskOrigin? = nil,
        consumeOpenChatID: @escaping () -> Void = {},
        onDone: (@MainActor @Sendable () -> Void)? = nil,
        attachPhoto: (@MainActor @Sendable () -> Void)? = nil,
        openSource: (@MainActor @Sendable (AgentSourceLink) -> Void)? = nil
    ) {
        self.environment = environment
        self.repositories = repositories
        self.openChatID = openChatID
        self.origin = origin
        self.consumeOpenChatID = consumeOpenChatID
        self.onDone = onDone
        self.attachPhoto = attachPhoto
        self.openSource = openSource
    }

    var body: some View {
        Group {
            if let chatModel { AppCoachScreen(model: chatModel, attachPhoto: attachPhoto, openSource: openSource) }
            else if let chatFailure { failureView(chatFailure) }
            else { loadingView }
        }
            .task(id: attempt) { await open() }
            // A briefing notification can arrive while the coach is open.
            .onChange(of: openChatID) { _, id in
                if let id { openRequested(id) }
            }
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { onDone() }.accessibilityIdentifier("ask-close")
                    }
                }
            }
            .looprHaptic(haptic)
            .productStorageGate(repositories)
    }

    private var loadingView: some View {
        ScrollView {
            LooprLoadingPlaceholder(.cards(3))
        }
        .scrollIndicators(.hidden)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("coach-opening")
    }

    private func failureView(_ failure: OpenFailure) -> some View {
        ScrollView {
            LooprCard(style: .warning) {
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    HStack(alignment: .top, spacing: LooprSpacing.sm) {
                        Image(systemName: "exclamationmark.bubble")
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.warning))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            LooprText("Ask did not open", style: .rowTitle)
                                .accessibilityAddTraits(.isHeader)
                            LooprText(failure.message, style: .prose, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Try again") {
                        haptic = .light
                        chatFailure = nil
                        attempt += 1
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .accessibilityIdentifier("coach-open-retry")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.brand))
        .accessibilityIdentifier("coach-open-failure")
        .onAppear {
            haptic = .error
            AccessibilityNotification.Announcement("Ask did not open. \(failure.message)").post()
        }
    }

    private func open() async {
        guard repositories?.storageFailure == nil else { return }
        if chatModel == nil, let persistent = repositories?.persistent {
            do {
                chatModel = CoachChatViewModel(repository: try SQLiteCoachConversationRepository(database: persistent.database),
                    context: LooprCoachContextBuilder(repositories: persistent), origin: origin,
                    agent: try? LooprAgentRuntime.shared.configure(persistent),
                    sharingFilter: { @Sendable (sharing: CoachSharing) -> CoachSharing in AgentAccessGate.effective(sharing, defaults: .standard) })
            } catch { chatFailure = .couldNotOpen }
        }
        #if DEBUG
        // The scripted agent (AgentUITestFixtures). Checked first, so it wins over the plain coach fixture.
        if chatModel == nil, environment.composition != .production,
           ProcessInfo.processInfo.arguments.contains("--loopr-agent-fixture") {
            chatModel = try? await AgentUITestFixtures.model(origin: origin)
        }
        if chatModel == nil, environment.composition != .production,
           ProcessInfo.processInfo.arguments.contains("--loopr-coach-fixture") {
            chatModel = try? await CoachUITestFixtures.model(origin: origin)
        }
        // Every other fixture launch has no database, so Ask used to stop at "Ask did not open" (ICP R2-NEW-1). It
        // opens on a chat store that lives for the launch and the app's own provider settings instead, so Ask looks as
        // it does on a fresh install: without a key it asks for one and links to the providers.
        if chatModel == nil, environment.composition != .production, repositories?.persistent == nil {
            chatModel = CoachChatViewModel(repository: CoachLaunchChatStore.shared,
                                           context: CoachFixtureContext(hasData: environment.composition == .populated),
                                           origin: origin)
        }
        #endif
        if chatModel == nil, chatFailure == nil { chatFailure = .noStore }
        if let openChatID { openRequested(openChatID) }
    }

    private func openRequested(_ id: UUID) {
        guard let chatModel else { return }
        chatModel.requestOpen(id)
        consumeOpenChatID()
    }
}

@MainActor
struct WorkoutFeatureRoot: View {
    let route: (WorkoutKit.WorkoutRoute) -> Void
    let selectedRoute: ((WorkoutKit.WorkoutRoute, WorkoutRecord?) -> Void)?
    /// Pushes a template, program or session screen. The shell wraps it in `AppWorkoutRoute.train`.
    let trainRoute: ((TrainRoute) -> Void)?
    /// Starts a strength session from a template. The shell starts the recording and shows the set screen.
    let startTemplateSession: ((TrainLiveSetup) -> Void)?
    /// Starts a recording for a cardio template through the same path as the start picker.
    let startRecordingSession: ((ActivityType) -> Void)?
    /// Switches to the Protocol tab, where the weekly targets are set.
    let openProtocol: (() -> Void)?
    let repositories: ProductRepositoryContainer?
    private let store: any WorkoutStore
    private let seedFixtures: Bool
    private let session: WorkoutSessionController
    @StateObject private var viewModel: WorkoutViewModel
    @StateObject private var train: TrainOverviewLoader
    @StateObject private var fitness = FitnessOverviewLoader()
    @Environment(\.looprAsk) private var ask
    @Environment(\.metricHistoryProvider) private var metricHistoryProvider
    @Environment(\.scenePhase) private var scenePhase
    @State private var trainActionError: String?

    init(
        route: @escaping (WorkoutKit.WorkoutRoute) -> Void = { _ in },
        selectedRoute: ((WorkoutKit.WorkoutRoute, WorkoutRecord?) -> Void)? = nil,
        trainRoute: ((TrainRoute) -> Void)? = nil,
        startTemplateSession: ((TrainLiveSetup) -> Void)? = nil,
        startRecordingSession: ((ActivityType) -> Void)? = nil,
        openProtocol: (() -> Void)? = nil,
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
            var workouts = repositories?.isFixtureComposition == false || repositories?.environment.composition.startsFresh == true
                ? [] : [WorkoutFixtures.completedRun, WorkoutFixtures.interrupted]
            #if DEBUG
            if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() {
                workouts += AppTrainFixtures.workoutRecords + WorkoutLogFixtures.records
                if WorkoutPageFixtures.isRequested { workouts += WorkoutPageFixtures.records }
            }
            #endif
            store = InMemoryWorkoutStore(workouts: workouts)
            seedFixtures = (repositories?.isFixtureComposition ?? true) && repositories?.environment.composition.startsFresh != true
        }
        self.store = store
        self.seedFixtures = seedFixtures
        self.route = route
        self.selectedRoute = selectedRoute
        self.trainRoute = trainRoute
        self.startTemplateSession = startTemplateSession
        self.startRecordingSession = startRecordingSession
        self.openProtocol = openProtocol
        self.repositories = repositories
        let session = repositories?.workoutSession ?? WorkoutSessionController(store: store)
        self.session = session
        let detectedRepository: (any DetectedWorkoutRepository)? = repositories?.detectedWorkouts
            ?? (seedFixtures && !(repositories.map { $0.environment.composition.startsFresh } ?? false)
                ? InMemoryDetectedWorkoutRepository(detections: [WorkoutFixtures.detectedRun]) : nil)
        _viewModel = StateObject(wrappedValue: WorkoutViewModel(
            controller: session,
            detectedRepository: detectedRepository,
            finalizationHooks: repositories?.workoutFinalizationHooks ?? .init()
        ))
        _train = StateObject(wrappedValue: TrainOverviewLoader(
            repository: Self.trainRepository(for: repositories), workouts: store))
    }

    /// Production reads the app's own database. Every other composition reads a separate temporary one.
    private static func trainRepository(for repositories: ProductRepositoryContainer?) -> AppTrainRepository {
        if let repositories, let persistent = repositories.persistent {
            return AppTrainRepository(store: persistent.train, environment: repositories.environment)
        }
        #if DEBUG
        if let repositories { return repositories.fixtureTrainRepository }
        return AppTrainRepository(environment: .make(arguments: ["--loopr-launch-mode=populated"], environment: [:]))
        #else
        return AppTrainRepository(environment: repositories?.environment ?? .production())
        #endif
    }

    /// Fixture launches pin the clock and the zone so the week and today never drift. The populated launch reads
    /// Today's clock, so Fitness, Today and Food show one day.
    private var trainClock: (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() {
            // A named clock (`--loopr-today-clock=`) moves the Train fixture's hour with Today's (ICP R3-OPT-5).
            let named = TodayDialFixtureClock.isRequested(arguments: ProcessInfo.processInfo.arguments)
            return (named ? TodayDialFixtureClock.now(sameDayAs: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar)
                          : AppTrainFixtures.now, AppTrainFixtures.calendar)
        }
        if let repositories, FitnessFixtureDaySeam.applies(environment: repositories.environment, repositories: repositories) {
            return FitnessFixtureDaySeam.clock(environment: repositories.environment, repositories: repositories)
        }
        #endif
        calendar.timeZone = repositories?.environment.timeZoneProvider.timeZone ?? .current
        return (repositories?.environment.dateProvider.now() ?? Date(), calendar)
    }

    private var trainHistory: any MetricHistoryProviding {
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() { return TrainFixtureMetricHistory() }
        if let repositories, FitnessFixtureDaySeam.applies(environment: repositories.environment, repositories: repositories),
           let history = FitnessFixtureDaySeam.history(environment: repositories.environment, repositories: repositories) {
            return history
        }
        #endif
        return metricHistoryProvider
    }

    private func loadTrain() async {
        guard repositories?.storageFailure == nil else { return }
        let clock = trainClock
        // Workouts other apps saved to Apple Health (R1-VET-01). The list loads again when the import changed it.
        if let persistent = repositories?.persistent,
           await HealthWorkoutImport.refresh(workouts: persistent.workouts, healthSync: persistent.healthSync,
                                             now: clock.now, calendar: clock.calendar).changed {
            await viewModel.load(query: WorkoutLogQuery(range: .all, now: fixtureWorkoutQueryNow), detail: .listing)
        }
        let dailyZone2 = TrainDailyZone2(rules: await fitnessSources.rules?() ?? [])
        await train.load(now: clock.now, calendar: clock.calendar, history: trainHistory, dailyZone2: dailyZone2)
        await loadFitness()
    }

    /// Where the Fitness tab's dose, gauge and capacity tests read from. Fixture launches with the Train
    /// fixture read the Fitness fixture; the populated launch reads the day Today and Food read
    /// (`FitnessFixtureDaySeam`); other fixture launches have no readings, so the tab shows its
    /// absent states.
    private var fitnessSources: FitnessSources {
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() {
            var sources = FitnessFixtures.sources
            if let repositories, !FitnessFixtures.isAbsentRequested() {
                // The Protocol tab's rules lead, so the zone 2 week is the protocol's rule (R2-OPT-16), and the age
                // bar reads the launch's one profile, the one Data reads (R2-OPT-23).
                let readProtocol = FitnessFixtureDaySeam.protocolRules(environment: repositories.environment)
                let extras = FitnessFixtures.rules
                sources.rules = { FitnessFixtureDaySeam.rules(protocol: await readProtocol(), extras: extras) }
                sources.profile = LooprAgeSource.fitnessProfile(repositories)
                sources.vo2Max = LooprAgeSource.vo2Max(repositories) ?? sources.vo2Max
            }
            return sources
        }
        if let repositories, FitnessFixtureDaySeam.applies(environment: repositories.environment, repositories: repositories) {
            return FitnessFixtureDaySeam.sources(environment: repositories.environment, repositories: repositories)
        }
        if let repositories, repositories.isFixtureComposition {
            // The other fixture launches start like a new install: no readings, the launch's one profile (what
            // onboarding saved, R3-NEW-1) and a capacity store in memory, so a first test saves as it does on a phone
            // instead of failing with "could not save" (R3-NEW-4).
            return FitnessSources(profile: LooprAgeSource.fitnessProfile(repositories), recorder: FitnessFixtures.launchRecorder)
        }
        #endif
        guard let persistent = repositories?.persistent else { return FitnessSources() }
        return .live(persistent)
    }

    /// Where the capacity tests save and which clock their timers read. Nil when this composition has no
    /// capacity store, so the tests open read only. Fixture launches time on the fixture's clock.
    private var capacityActions: FitnessCapacityActions? {
        guard repositories?.storageFailure == nil, let recorder = fitnessSources.recorder else { return nil }
        var now: @Sendable () -> Date = { Date() }
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() { now = FitnessFixtures.clock }
        else if let repositories, FitnessFixtureDaySeam.applies(environment: repositories.environment, repositories: repositories) {
            now = FitnessFixtureDaySeam.capacityClock(start: trainClock.now)
        }
        #endif
        return FitnessCapacityActions(
            saveResults: { results in
                try await recorder.save(results)
                NotificationCenter.default.post(name: looprCapacityRecordsChanged, object: nil)
            },
            saveGoal: { goal in
                try await recorder.save(goal)
                NotificationCenter.default.post(name: looprCapacityRecordsChanged, object: nil)
            },
            now: now, timeZoneIdentifier: trainClock.calendar.timeZone.identifier)
    }

    /// Rebuilds the dose, the VO₂max gauge and the capacity tiles from what is stored now, with the
    /// sessions Train and the workout list already loaded.
    private func loadFitness() async {
        guard repositories?.storageFailure == nil else { return }
        let clock = trainClock
        await fitness.load(sources: fitnessSources, now: clock.now, calendar: clock.calendar,
                           train: train.input?.sessions ?? [], workouts: viewModel.snapshot.value ?? [])
    }

    private var fixtureWorkoutQueryNow: Date {
        if repositories?.isFixtureComposition == false { return repositories?.environment.dateProvider.now() ?? Date() }
        #if DEBUG
        if DebugCaptureFixtures.siStoreFixture { return SIPolishFixtureWorld.captureNow }
        #endif
        return Date(timeIntervalSince1970: 1_700_002_000)
    }

    var body: some View {
        TrainScreen(viewModel: viewModel, overview: train.overview, fitness: fitness.overview,
                    capacityActions: capacityActions, failure: train.failure,
                    swap: { id in train.swap(to: id) }, action: handleTrainAction)
            .task { await loadTrain() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadTrain() } }
            }
            .alert("Fitness", isPresented: Binding(get: { trainActionError != nil }, set: { if !$0 { trainActionError = nil } })) {
                Button("OK", role: .cancel) { trainActionError = nil }
            } message: {
                Text(trainActionError ?? "")
            }
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixtures {
                    do {
                        try await store.save(WorkoutFixtures.completedRun)
                        try await store.save(WorkoutFixtures.interrupted)
                        #if DEBUG
                        if AppTrainFixtures.isRequested() {
                            for record in AppTrainFixtures.workoutRecords + WorkoutLogFixtures.records + (WorkoutPageFixtures.isRequested ? WorkoutPageFixtures.records : []) { try await store.save(record) }
                        }
                        #endif
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
                // Mobility sessions come from the workout list, so the dose reads it once it is in.
                await loadFitness()
            }
            // A band sync or a finished workout derives the day again; new zone minutes fly into the dose.
            .onReceive(NotificationCenter.default.publisher(for: looprDerivedGenerationUpdated).receive(on: RunLoop.main)) { _ in
                Task { await loadFitness() }
            }
            // A capacity test or a goal for 85 was saved.
            .onReceive(NotificationCenter.default.publisher(for: looprCapacityRecordsChanged).receive(on: RunLoop.main)) { _ in
                Task { await loadFitness() }
            }
            // A birth year saved in Profile places the age bar.
            .onReceive(NotificationCenter.default.publisher(for: looprProfileChanged).receive(on: RunLoop.main)) { _ in
                Task { await loadFitness() }
            }
            .onAppear {
                LooprPerformance.tabRootDidAppear()
                // Coming back from the builder, a program or a log screen, so a saved change shows. The list is read
                // again first: the dose counts logged workouts from it.
                if train.overview != nil {
                    Task {
                        await viewModel.load(query: WorkoutLogQuery(range: .all, now: fixtureWorkoutQueryNow), detail: .listing)
                        await loadTrain()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprAccountHistoryImported)) { _ in
                Task {
                    await viewModel.load(query: WorkoutLogQuery(range: .all, now: repositories?.environment.dateProvider.now() ?? Date()), detail: .listing)
                    await loadTrain()
                }
            }
            .productStorageGate(repositories)
    }

    private func handleTrainAction(_ action: TrainOverviewAction) {
        switch action {
        case .workoutRoute(let destination):
            handleRoute(destination)
        case .workout(let destination, let workout):
            handleSelectedRoute(destination, workout)
        case .startSession(let plan):
            startSession(plan)
        case .startWorkout(let templateID):
            startWorkout(templateID: templateID)
        case .startTemplate(let id):
            startTemplate(id)
        case .openSession(let id):
            openTrain(.summary(id))
        case .openExercises:
            openTrain(.exercises)
        case .openMuscleVolume:
            openTrain(.muscleVolume)
        case .openTemplate(let id):
            openTrain(.template(id))
        case .newTemplate:
            openTrain(.template(nil))
        case .openProgram(let id):
            openTrain(.program(id))
        case .newProgram:
            openTrain(.programEditor(nil))
        case .acceptDraft(let draft):
            decide(draft, accept: true)
        case .discardDraft(let draft):
            decide(draft, accept: false)
        case .openProtocol:
            openProtocol?()
        case .useStarterWeek:
            useStarterWeek()
        case .startStarterRoutine:
            startStarterRoutine()
        }
    }

    /// Saves the beginner's workout as the person's own, then starts it like any saved workout (R3-NEW-01).
    private func startStarterRoutine() {
        let clock = trainClock
        Task { @MainActor in
            do {
                let saved = try await train.saveTemplate(TrainStarterRoutine.template(now: clock.now), at: clock.now)
                await loadTrain()
                startWorkout(templateID: saved.id)
            } catch {
                trainActionError = error.localizedDescription
            }
        }
    }

    /// Saves the starter week into the protocol and reloads the dose, which then shows it as targets. A launch without
    /// stored data has nowhere to save it, so it opens Protocol instead.
    private func useStarterWeek() {
        guard let persistent = repositories?.persistent else {
            openProtocol?()
            return
        }
        let now = trainClock.now
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FitnessSources.addStarterWeek(persistent, now: now)
                }.value
                await loadTrain()
            } catch {
                trainActionError = "Could not save the starter week. \(error.localizedDescription)"
            }
        }
    }

    /// Accept or discard an agent draft from the overview. Nothing is scheduled before Accept.
    private func decide(_ draft: TrainDraftSummary, accept: Bool) {
        let clock = trainClock
        let history = trainHistory
        Task { @MainActor in
            let problem = accept
                ? await train.accept(draft, now: clock.now, calendar: clock.calendar, history: history)
                : await train.discard(draft, now: clock.now, calendar: clock.calendar, history: history)
            trainActionError = problem
        }
    }

    private func openTrain(_ destination: TrainRoute) {
        trainRoute?(destination)
    }

    /// Starts today's session. A strength template hands the shell a `TrainLiveSetup`, and the shell
    /// starts the recording on the existing live workout path and opens the set screen, so zone alerts, the
    /// Live Activity and the mini-player behave as they do for any workout. A cardio template records its
    /// activity and opens the normal live screen.
    private func startSession(_ plan: TrainTodayPlan) {
        Task { @MainActor in
            // The week's rule decisions are on record before the person trains.
            await train.recordProgramAdjustments()
            if plan.kind == .strength, let startTemplateSession {
                guard let template = train.input?.templates.first(where: { $0.id == plan.templateID }) else {
                    trainActionError = TrainError.missingRecord.localizedDescription
                    return
                }
                guard !template.exercises.isEmpty else {
                    trainActionError = TrainLiveError.emptyTemplate.localizedDescription
                    return
                }
                let history = train.input?.sessions.filter { $0.status == .completed } ?? []
                startTemplateSession(TrainLiveSetup(
                    template: template, recoveryScore: plan.recoveryScore, programID: plan.programID, programWeek: plan.programWeek,
                    history: history,
                    expectedStrain: ExpectedStrain.estimate(templateID: template.id, history: train.input?.strainSamples ?? []),
                    timeZoneIdentifier: trainClock.calendar.timeZone.identifier))
                return
            }
            let activity: ActivityType
            switch plan.kind {
            case .strength: activity = .strength
            case .cardio:
                let template = train.input?.templates.first { $0.id == plan.templateID }
                activity = template?.cardio?.activity ?? .cardio
            }
            if let startRecordingSession {
                startRecordingSession(activity)
            } else {
                await startRecording(activity: activity)
            }
        }
    }

    /// Starts a gym workout from any strength template, or an empty one built as it goes. It runs on the same
    /// live path as today's session, so heart rate, strain and the Live Activity work the same.
    private func startWorkout(templateID: UUID?) {
        guard let startTemplateSession else {
            Task { await startRecording(activity: .strength) }
            return
        }
        let history = train.input?.sessions.filter { $0.status == .completed } ?? []
        let zone = trainClock.calendar.timeZone.identifier
        guard let templateID else {
            startTemplateSession(.freeform(history: history, timeZoneIdentifier: zone))
            return
        }
        guard let template = train.input?.templates.first(where: { $0.id == templateID }) else {
            trainActionError = TrainError.missingRecord.localizedDescription
            return
        }
        guard !template.exercises.isEmpty else {
            trainActionError = TrainLiveError.emptyTemplate.localizedDescription
            return
        }
        startTemplateSession(TrainLiveSetup(
            template: template, history: history,
            expectedStrain: ExpectedStrain.estimate(templateID: template.id, history: train.input?.strainSamples ?? []),
            timeZoneIdentifier: zone))
    }

    /// Starts a saved workout from its play button: a strength one opens the set log, a cardio one records its activity.
    private func startTemplate(_ id: UUID) {
        guard let template = train.input?.templates.first(where: { $0.id == id }) else {
            trainActionError = TrainError.missingRecord.localizedDescription
            return
        }
        switch template.kind {
        case .strength:
            startWorkout(templateID: id)
        case .cardio:
            let activity = template.cardio?.activity ?? .cardio
            if let startRecordingSession {
                startRecordingSession(activity)
            } else {
                Task { await startRecording(activity: activity) }
            }
        }
    }

    /// The recording-only start, for a root with no shell listening, such as a preview.
    private func startRecording(activity: ActivityType) async {
        do {
            var workout = try await session.start(activity: activity, source: .live)
            switch workout.state {
            case .selectedActivity:
                _ = try await session.transition(to: .preparing)
                workout = try await session.transition(to: .active)
            case .preparing:
                workout = try await session.transition(to: .active)
            default:
                break
            }
            await LooprHeartAlertsRuntime.shared.noteWorkout(id: workout.id.uuidString, start: workout.startedAt ?? Date(), end: nil)
            handleSelectedRoute(.live(activity), workout)
        } catch {
            trainActionError = error.localizedDescription
        }
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
    @Environment(\.looprMeasurementSystem) private var measurementSystem
    let recovery: Bool
    let workoutID: UUID?
    let route: (WorkoutDetailRoute) -> Void
    let repositories: ProductRepositoryContainer?
    private let store: any WorkoutStore
    private let session: WorkoutSessionController
    private let fixtureWorkout: WorkoutRecord?
    private let seedFixture: Bool
    @StateObject private var viewModel: WorkoutViewModel
    /// The requested workout read by id, for one outside the list's three-month window.
    @State private var requestedWorkout: WorkoutRecord?
    @State private var hasLoaded = false

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
            } else if let workout = viewModel.snapshot.value?.first(where: matches) ?? requestedWorkout.flatMap({ matches($0) ? $0 : nil }) {
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
                requestedWorkout = try? await session.select(id: workoutID)
            }
            await viewModel.load(query: detailQuery)
            hasLoaded = true
        }
        .onAppear {
            // Back from Edit: read the record again so the detail shows the change.
            guard hasLoaded else { return }
            Task {
                if let workoutID { requestedWorkout = await session.workout(id: workoutID) }
                await viewModel.load(query: detailQuery)
            }
        }
        .productStorageGate(repositories)
    }

    private var detailQuery: WorkoutLogQuery {
        WorkoutLogQuery(range: .threeMonths, now: repositories?.isFixtureComposition == false
            ? (repositories?.environment.dateProvider.now() ?? Date()) : Date(timeIntervalSince1970: 1_700_002_000))
    }

    private func matches(_ workout: WorkoutRecord) -> Bool {
        guard workoutID == nil || workout.id == workoutID else { return false }
        return recovery ? workout.state == .interruptedAndRecoverable : workout.state == .completed
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
                .environment(\.workoutDetailContextProvider, HealthWorkoutDetailContextProvider.make(repositories: repositories))
                .environment(\.workoutPageProvider, AppWorkoutPageProvider.make(repositories: repositories, usesMiles: measurementSystem == .imperial))
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

/// A screen the Protocol tab pushes: one of JournalKit's Protocol screens, or Patterns.
enum ProtocolTabPush: Hashable {
    case screen(ProtocolRoute)
    case patterns
}

@MainActor
struct JournalFeatureRoot: View {
    let route: (JournalKit.JournalRoute) -> Void
    /// Appends a Protocol push to the host stack's path. Nil on a stack whose path cannot hold it (Today's), where the
    /// push is presented with `navigationDestination(item:)` instead.
    let push: ((ProtocolTabPush) -> Void)?
    let repositories: ProductRepositoryContainer?
    /// A segment the shell asked for, such as Experiments from Today's experiment strip.
    var segmentRequest: ProtocolSegmentRequest?
    @Environment(\.looprOpenWeeklyReview) private var openWeeklyReview
    private let repository: any JournalStore
    private let habitStore: any HabitStore
    private let seedFixture: Bool
    @StateObject private var viewModel: JournalViewModel
    @StateObject private var habitViewModel: HabitViewModel
    /// The Protocol tab root's rosettes, deck and patterns (LV-07.1). It shares the habit model with the Journal sections.
    @StateObject private var protocolModel: ProtocolTabModel
    @State private var noteDraft: JournalNoteDraft?
    /// The push on a stack without `push`.
    @State private var presentedPush: ProtocolTabPush?

    init(route: @escaping (JournalKit.JournalRoute) -> Void = { _ in }, push: ((ProtocolTabPush) -> Void)? = nil,
         repositories: ProductRepositoryContainer? = nil, segmentRequest: ProtocolSegmentRequest? = nil) {
        self.segmentRequest = segmentRequest
        self.push = push
        let repository: any JournalStore
        let habitStore: any HabitStore
        let seedFixture: Bool
        if let persistent = repositories?.persistent {
            repository = persistent.journal
            habitStore = persistent.habits
            seedFixture = false
        } else {
            #if DEBUG
            repository = repositories?.fixtureJournalStore ?? JournalRepository()
            habitStore = repositories?.fixtureHabitStore ?? InMemoryHabitStore()
            #else
            repository = JournalRepository()
            habitStore = InMemoryHabitStore()
            #endif
            seedFixture = repositories?.isFixtureComposition ?? true
        }
        self.repository = repository
        self.habitStore = habitStore
        self.seedFixture = seedFixture
        self.route = route
        self.repositories = repositories
        let autoFill: AppJournalAutoFillProvider?
        if let persistent = repositories?.persistent {
            let food = AppFoodJournalProvider(repository: AppFoodRepository(store: persistent.food, environment: repositories!.environment), sleep: persistent.sleep)
            autoFill = AppJournalAutoFillProvider(readTraining: { @Sendable [store = persistent.workouts] in
                try await store.journalAutoFillRecords()
            }, readFood: { @Sendable day, zone in try await food.foodDay(for: day, timeZoneID: zone) })
        } else if let store = repositories?.workoutStore {
            #if DEBUG
            let food = repositories.map { AppFoodJournalProvider(repository: $0.fixtureFoodRepository, sleep: nil) }
            autoFill = AppJournalAutoFillProvider(readTraining: { @Sendable [store] in await store.all() },
                readFood: food.map { provider in { @Sendable day, zone in try await provider.foodDay(for: day, timeZoneID: zone) } })
            #else
            autoFill = AppJournalAutoFillProvider(readTraining: { @Sendable [store] in await store.all() })
            #endif
        } else { autoFill = nil }
        let prepareInsights: (@Sendable () async throws -> Void)?
        if let persistent = repositories?.persistent {
            let preparation = AppJournalInsightPreparation(store: habitStore, resolver: AppHabitOutcomeResolver(
                today: persistent.today, sleep: persistent.sleep, heart: persistent.heart,
                calendar: repositories?.environment.calendarProvider ?? SystemCalendarProvider(),
                dateProvider: repositories?.environment.dateProvider ?? SystemDateProvider()))
            prepareInsights = { @Sendable in try await preparation.refresh() }
        } else {
            #if DEBUG
            // The fixture's comparisons are worked out at launch; the screen waits for them (ICP R3-HAB-04).
            prepareInsights = FiveTabJournalFixture.mode == nil ? nil : { @Sendable in await FiveTabJournalFixture.waitForComparisons() }
            #else
            prepareInsights = nil
            #endif
        }
        _viewModel = StateObject(wrappedValue: JournalViewModel(repository: repository))
        let habits = HabitViewModel(
            store: habitStore,
            dateProvider: repositories?.environment.dateProvider ?? SystemDateProvider(),
            calendarProvider: repositories?.environment.calendarProvider ?? SystemCalendarProvider(),
            timeZoneProvider: seedFixture ? SystemTimeZoneProvider(timeZone: TimeZone(identifier: "Australia/Perth")!) : repositories?.environment.timeZoneProvider ?? SystemTimeZoneProvider(),
            journalStore: repository,
            reminderScheduler: repositories?.persistent?.habitReminderScheduler ?? NoOpHabitReminderScheduler(),
            featureStageOverride: AppHabitFeatureGate.currentStage,
            autoFill: autoFill,
            prepareInsights: prepareInsights,
            ruleHabitIDs: ProtocolTabComposition.ruleHabitIDs(repositories)
        )
        _habitViewModel = StateObject(wrappedValue: habits)
        _protocolModel = StateObject(wrappedValue: ProtocolTabComposition.model(repositories: repositories, habits: habits))
    }

    var body: some View {
        // The tab root is the Protocol screen. Every Journal destination stays reachable from its Journal sections.
        let model = protocolModel
        ProtocolScreen(model: protocolModel, journal: viewModel, route: route, push: { open(.screen($0)) },
                       editNote: { entry, day, dictate in
            let now = repositories?.environment.dateProvider.now() ?? Date()
            noteDraft = JournalNoteDraft(entry: entry ?? JournalEntry(day: day.habitKey, createdAt: now), dictate: dictate)
        }, openPatterns: {
            if repositories != nil { open(.patterns) }
        }, weeklyReview: weeklyReviewEntry)
            .environment(\.protocolCheckInReminder, ProtocolTabComposition.checkInReminder(repositories: repositories))
            .onChange(of: segmentRequest, initial: true) { _, request in
                if let request { protocolModel.requestedSegment = request.segment }
            }
            #if canImport(UserNotifications)
            // A rule answered from its reminder's Done or Skip today shows the next time the tab is seen (ICP R3-HAB-02).
            .onReceive(NotificationCenter.default.publisher(for: ProtocolRuleReminderResponder.answered).receive(on: RunLoop.main)) { _ in
                Task { await protocolModel.load() }
            }
            #endif
            // Pushed by value on the Protocol tab's path. A `navigationDestination(isPresented:)` push froze the app
            // until AttributeGraph had described the destination's type, up to minutes after launch.
            .navigationDestination(for: ProtocolTabPush.self) { destination($0, model: model) }
            .navigationDestination(item: $presentedPush) { destination($0, model: model) }
            .sheet(item: $noteDraft) { draft in
                JournalNoteEditor(draft: draft) { entry in
                    var saved = entry
                    saved.updatedAt = repositories?.environment.dateProvider.now() ?? Date()
                    _ = try await repository.save(saved)
                    await viewModel.load()
                }
            }
            .task {
                guard repositories?.storageFailure == nil else { return }
                if seedFixture {
                    #if DEBUG
                    let entry = FiveTabJournalFixture.mode == nil ? JournalFixtures.privateEntry : FiveTabJournalFixture.note
                    #else
                    let entry = JournalFixtures.privateEntry
                    #endif
                    do { _ = try await repository.save(entry) } catch { }
                }
                await viewModel.load()
            }
            .productStorageGate(repositories)
    }
}

extension JournalFeatureRoot {
    private func open(_ target: ProtocolTabPush) {
        if let push { push(target) } else { presentedPush = target }
    }

    @ViewBuilder
    private func destination(_ target: ProtocolTabPush, model: ProtocolTabModel) -> some View {
        switch target {
        case .screen(let route): ProtocolRouteDestination(model: model, route: route)
        case .patterns:
            if let repositories {
                PatternsFeatureRoot(environment: repositories.environment, repositories: repositories)
            }
        }
    }

    /// "This week's review", naming the week the review covers. Nil when the shell cannot open it.
    private var weeklyReviewEntry: ProtocolWeeklyReviewEntry? {
        guard let openWeeklyReview, repositories != nil else { return nil }
        var calendar = Calendar.current
        if let zone = repositories?.environment.timeZoneProvider.timeZone { calendar.timeZone = zone }
        let now = repositories?.environment.dateProvider.now() ?? Date()
        let week = WeeklyReviewSchedule.reviewWeek(at: now, calendar: calendar)
        let monday = week.map { WeeklyReviewSchedule.mondayText($0, calendar: calendar) }
        return ProtocolWeeklyReviewEntry(
            title: WeeklyReviewCopy.protocolTitle,
            detail: monday.map(WeeklyReviewCopy.protocolDetail(monday:)) ?? WeeklyReviewCopy.todayDetail,
            monday: week?.monday,
            open: { openWeeklyReview.run() })
    }
}

/// One request for a Protocol segment. A new request with the same segment still switches, so a second tap on Today's
/// strip after the person moved to Rules opens Experiments again.
struct ProtocolSegmentRequest: Equatable {
    let segment: ProtocolSegment
    let id = UUID()
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
                await viewModel.load(today: CycleDate.localDay(Date()))
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
    @State private var preparedSpreadsheetURLs: [URL] = []
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
                        ? "Removed 1 sample Loopr wrote to Apple Health."
                        : "Removed \(removed) samples Loopr wrote to Apple Health."
                } else {
                    try await repository.removeHealthKitSamplesChecked()
                    await viewModel.load()
                    actionMessage = "Removed the samples Loopr wrote to Apple Health."
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
                            await viewModel.log(entry, today: CycleDate.localDay(Date()))
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
            await viewModel.load(today: CycleDate.localDay(Date()))
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

nonisolated enum AppHabitOutcomeResolution: Sendable, Equatable {
    case outcome(HabitOutcomeSnapshot)
    case excluded(HabitOutcomeExclusionRecord)
}

nonisolated struct AppHabitOutcomeResolver: Sendable {
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
        if let deep = typedSleepMetric(sleepSnapshot, id: "deep", expected: .minutes),
           deep >= 0, deep <= Double(session.durationMinutes) {
            metrics[.deepSleepMinutes] = deep
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
        let behaviorSnapshot = try? await today.readSummary(for: record.behaviorDay)
        let strain = behaviorSnapshot.flatMap { typedTodayMetric($0, ids: [.strain], expected: .strainScore) }
        var versions: [String: String] = [:]
        versions["today"] = todaySnapshot?.metrics.compactMap(\.algorithmVersion).sorted().joined(separator: ",") ?? "missing"
        versions["priorDayStrain"] = behaviorSnapshot?.metric(.strain)?.algorithmVersion ?? "missing"
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
            "score": .scorePoints, "duration": .minutes, "deep": .minutes,
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
            #if DEBUG
            repository = repositories?.fixtureJournalStore ?? JournalRepository()
            #else
            repository = JournalRepository()
            #endif
            #if DEBUG
            let statePrefix = "--loopr-habit-insight-state="
            let requestedState = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix(statePrefix) })
                .map { String($0.dropFirst(statePrefix.count)) }
                .flatMap(HabitInsightStatus.init(rawValue:))
            habitStore = repositories?.fixtureHabitStore ?? HabitFixtures.store(status: requestedState ?? .collecting)
            #else
            habitStore = InMemoryHabitStore()
            #endif
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
            featureStageOverride: AppHabitFeatureGate.currentStage,
            ruleHabitIDs: ProtocolTabComposition.ruleHabitIDs(repositories)
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
                HabitManagementScreen(viewModel: habitViewModel, onChoose: { navigate(.habitSetup) })
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
        return value.birthYear != nil
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
        ProfileSettings(
            displayName: profile.displayName,
            birthYear: profile.birthYear,
            heightCentimeters: profile.heightCentimeters,
            weightKilograms: profile.weightKilograms,
            biologicalSex: profile.biologicalSex?.rawValue
        )
    }

    private static func profileDraft(from value: ProfileSettings, existing: Profile?, units: SettingsKit.UnitSystem) -> ProfileDraft {
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
            birthYear: value.birthYear,
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
    if repositories?.isFixtureComposition == false {
        return InMemorySettingsRepository(initial: SettingsSnapshot())
    }
    let fixture = SettingsFixtures.darkPrivate.withAppearance(capturedAppearance ?? .system)
    #if DEBUG
    // The profile lives in the launch's one fixture profile, which Data and Fitness read too (R2-UPG-2).
    if let repositories {
        var settings = fixture
        settings.profile = ProfileSettings()
        return ProfileBackedSettingsRepository(settings: InMemorySettingsRepository(initial: settings),
                                               profile: repositories.fixtureProfile)
    }
    #endif
    return InMemorySettingsRepository(initial: fixture)
}

/// Posted after Profile saves or resets, so the screens that read the profile (the Data and Fitness age rulers) read
/// it again instead of waiting for the next sync.
nonisolated let looprProfileChanged = Notification.Name("com.loopr.profile-changed")

/// Applies what Settings stores when the shell opens, so the app starts in the appearance, units and accessibility
/// choices Settings shows. Before, they applied only once Settings was opened, and opening it flipped the whole app to
/// the fixture's Dark (R2-UPG-5). Fixture launches set the appearance only: capture fixtures own the rest of the state.
@MainActor
func applyStoredDesignSystem(_ repositories: ProductRepositoryContainer?) async {
    guard let repositories, repositories.storageFailure == nil else { return }
    let snapshot = await makeSettingsRepository(repositories).snapshot()
    if repositories.environment.composition == .production {
        try? await LooprDesignSystemTokenBridge(remembersForLaunch: true).apply(DesignSystemTokenState(snapshot))
    } else {
        var state = DesignSystemRuntime.state()
        state.appearance = LooprAppearanceOverride(rawValue: snapshot.appearance.rawValue) ?? .system
        DesignSystemRuntime.apply(state)
    }
}

extension DesignSystemTokenState {
    init(_ snapshot: SettingsSnapshot) {
        self.init(appearance: snapshot.appearance,
                  increasedContrastPreview: snapshot.accessibility.increasedContrastPreview,
                  reduceMotionOverride: snapshot.accessibility.reduceMotionOverride,
                  units: snapshot.units,
                  voiceOverHints: snapshot.accessibility.voiceOverHints)
    }
}

/// The appearance Settings last applied in production, kept in UserDefaults so the first frame of the next launch
/// already has it and a dark choice never opens on a light frame first.
nonisolated enum LooprLaunchAppearance {
    static let key = "loopr.launch-appearance"

    static func remember(_ choice: AppearanceChoice, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }

    static func remembered(defaults: UserDefaults = .standard) -> LooprAppearanceOverride? {
        defaults.string(forKey: key).flatMap(LooprAppearanceOverride.init(rawValue:))
    }

    /// The appearance a launch opens in. Production: what Settings last applied. A fixture launch: its
    /// `--loopr-appearance=` argument, the same one its Settings snapshot takes, so the argument, the in-app setting
    /// and the system setting resolve through one source (R2-LAB-23). Nil follows the system.
    static func launchAppearance(composition: AppEnvironment.Composition,
                                 arguments: [String] = ProcessInfo.processInfo.arguments,
                                 defaults: UserDefaults = .standard) -> LooprAppearanceOverride? {
        guard composition != .production else { return remembered(defaults: defaults) }
        let prefix = "--loopr-appearance="
        return arguments.first { $0.hasPrefix(prefix) }
            .flatMap { LooprAppearanceOverride(rawValue: String($0.dropFirst(prefix.count))) }
    }

    /// Applied in `LooprApp.init`, before the first frame. The root then sets the window's scheme from it
    /// (`RootGate`), so every tab and every sheet takes it.
    @MainActor
    static func applyRemembered(composition: AppEnvironment.Composition, defaults: UserDefaults = .standard) {
        guard let appearance = launchAppearance(composition: composition, defaults: defaults) else { return }
        var state = DesignSystemRuntime.state()
        guard state.appearance != appearance else { return }
        state.appearance = appearance
        DesignSystemRuntime.apply(state)
    }
}

/// The fixture settings snapshot used to pin a dark appearance override, and
/// loading it applied that override to the whole design system, so opening
/// Settings turned a light simulator's app dark. Fixture launches now follow
/// the simulator's appearance, so `simctl ui appearance` and
/// `-AppleInterfaceStyle` decide. An explicit `--loopr-appearance=` still
/// wins, which keeps the dark override testable.
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
    /// Production keeps the appearance for the next launch's first frame (`LooprLaunchAppearance`).
    private let remembersForLaunch: Bool

    init(remembersForLaunch: Bool = false) { self.remembersForLaunch = remembersForLaunch }

    func state() async -> DesignSystemTokenState { value }
    func apply(_ state: DesignSystemTokenState) async throws {
        value = state
        if remembersForLaunch { LooprLaunchAppearance.remember(state.appearance) }
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
        tokenBridge = LooprDesignSystemTokenBridge(remembersForLaunch: repositories?.environment.composition == .production)
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
    /// What every tab's band button shows, and whether the shell stands for a paired band.
    @Environment(\.looprBandIndicator) private var shownBand
    @Environment(\.bandPaired) private var bandPaired
    @State private var wakeAlarmSummary: String?

    private var bandSummary: String {
        BandLinkPresentation.settingsSummary(link: bandLink, shown: shownBand, paired: bandPaired)
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

    static let profileSavedMessage = "Profile saved."

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
                            && viewModel.snapshot.profile.birthYear != snapshot.profile.birthYear
                        try await settingsCoordinator.update(snapshot)
                        await viewModel.load()
                        if ageChanged { await HeartZonePreferences.shared.profileAgeChanged() }
                        if destination == .profile {
                            NotificationCenter.default.post(name: looprProfileChanged, object: nil)
                            // Save keeps the sheet open, so say it worked (R3-NEW-1, R3-LAB-5).
                            integrationMessage = Self.profileSavedMessage
                        }
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
                        NotificationCenter.default.post(name: looprProfileChanged, object: nil)
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
    case provider(CoachProvider)
    case settingsHome
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
    let startsWithYourData: Bool
    let usesBackButton: Bool
    let openTab: (MainTab) -> Void
    private let initialPath: [SettingsFlowRoute]

    init(dismiss: @escaping () -> Void = {}, repositories: ProductRepositoryContainer? = nil, initialPath: [SettingsFlowRoute] = [], focusesAge: Bool = false, startsWithYourData: Bool = false, usesBackButton: Bool = false, openTab: @escaping (MainTab) -> Void = { _ in }) {
        self.initialPath = initialPath
        self.dismiss = dismiss
        self.repositories = repositories
        self.focusesAge = focusesAge
        self.startsWithYourData = startsWithYourData
        self.usesBackButton = usesBackButton
        self.openTab = openTab
        _navigationModel = StateObject(wrappedValue: SettingsNavigationModel(path: initialPath))
    }

    var body: some View {
        NavigationStack(path: $navigationModel.path) {
            Group {
                if startsWithYourData {
                    YourDataScreen(repositories: repositories, route: navigationModel.navigate, openTab: openTab)
                } else {
                    SettingsFeatureRoot(route: { navigationModel.navigate(to: .settings($0)) }, repositories: repositories)
                }
            }
                .toolbar {
                    // Reset and delete lives under Advanced now; a destructive
                    // screen one tap from the sheet's corner was too easy to hit.
                    if usesBackButton, navigationModel.path.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            LooprHeaderActionButton(action: .init(symbol: "chevron.left", label: "Back", identifier: "your-data-back", run: dismiss))
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else if !usesBackButton {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: dismiss)
                        }
                    }
                }
                .navigationDestination(for: SettingsFlowRoute.self) { route in
                    flowDestination(route, navigate: navigationModel.navigate(to:))
                }
        }
        .environment(\.profileAgeFocusRequested, focusesAge)
        // A sheet presented while its path was being set could start at the root; open the requested screen.
        .task { if navigationModel.path.isEmpty, !initialPath.isEmpty { navigationModel.path = initialPath } }
    }

    @ViewBuilder
    /// The screens Settings opens. Data builds the same screens on its own stack, so `navigate` pushes wherever the host does.
    func settingsDestination(
        _ destination: SettingsRouteDestination,
        navigate: @escaping (SettingsFlowRoute) -> Void
    ) -> some View {
        switch SettingsDestinationTarget.resolve(
            destination,
            isProduction: repositories?.environment.composition == .production,
            isVisualCapture: isVisualCaptureRun
        ) {
        case .deviceCenter:
            DeviceCenterFeatureRoot(
                route: { navigate(.device($0)) },
                repositories: repositories
            )
        case .wakeAlarm:
            WakeAlarmFeatureRoot(repositories: repositories)
        case .cycle:
            CycleFeatureRoot(
                route: { navigate(.cycle($0)) },
                repositories: repositories
            )
        case .data:
            DataFeatureRoot(
                route: { navigate(.data($0)) },
                repositories: repositories
            )
        case .dataDiagnostics:
            DataDestinationFeatureRoot(route: .diagnostics, repositories: repositories)
        case .heartAlerts:
            HeartAlertsSettingsScreen()
        case .notifications:
            LooprNotificationSettingsScreen(openHeartAlerts: { navigate(.settings(.heartAlerts)) })
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
    func flowDestination(
        _ route: SettingsFlowRoute,
        navigate: @escaping (SettingsFlowRoute) -> Void
    ) -> some View {
        switch route {
        case .settings(let destination):
            settingsDestination(destination, navigate: navigate)
        case .device(let destination):
            DeviceCenterDestinationFeatureRoot(route: destination, repositories: repositories)
        case .cycle(let destination):
            CycleDestinationFeatureRoot(
                route: destination,
                repositories: repositories,
                navigate: { navigate(.cycle($0)) }
            )
        case .data(let destination):
            DataDestinationFeatureRoot(route: destination, repositories: repositories)
        case .settingsHome:
            SettingsFeatureRoot(route: { navigate(.settings($0)) }, repositories: repositories)
        case .provider(let provider):
            AppAIProviderSettingsScreen(initialProvider: provider)
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

/// A meal open in Food's editor from a Today dial card.
struct TodayMealEdit: Identifiable {
    let draft: FoodMealDraft
    let repository: AppFoodRepository
    var id: UUID { draft.id }
}
