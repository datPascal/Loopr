import BluetoothKit
import DesignSystem
import DomainKit
import OnboardingKit
import ProfileKit
import SettingsKit
import SwiftUI
import UIKit

/// The app owns the AccessorySetupKit/BluetoothApplicationModel boundary. The
/// onboarding package only receives this narrow action, so the system picker
/// cannot be requested by launch inspection or by a later shell screen.
private final class ProductOnboardingPairingCoordinator: @unchecked Sendable, ContextualPairingCoordinator {
    private let bluetoothModel: BluetoothApplicationModel

    init(bluetoothModel: BluetoothApplicationModel) {
        self.bluetoothModel = bluetoothModel
    }

    func requestPairing() async throws {
        let before = await MainActor.run { bluetoothModel.status }
        switch before {
        case .pickerPresented, .preparing, .retrieving, .scanning, .connecting, .discovering, .subscribing,
             .connected, .disconnected(_, _), .removing(_):
            // A previous contextual tap already owns the picker/runtime. Do
            // not ask ASK or Core Bluetooth for a second session.
            break
        case .explanationRequired:
            await bluetoothModel.continueAfterExplanation()
        default:
            await bluetoothModel.userTappedPair()
            // The onboarding "Get your band ready" step is the ownership
            // explanation (the same pairing-mode guidance as
            // `AccessoryProvisioningController.ownershipExplanation`), and the
            // person just tapped Connect band after reading it. Showing it a
            // second time would only add a tap, so continue straight to the
            // system sheet. BluetoothKit's explicit two-call sequence is
            // unchanged: both calls still come from this one user action.
            if await MainActor.run(body: { bluetoothModel.status }) == .explanationRequired {
                await bluetoothModel.continueAfterExplanation()
            }
        }

        let after = await MainActor.run { bluetoothModel.status }
        switch after {
        case .failed(let reason): throw PairingCoordinatorError.failed(reason)
        case .cancelled: throw PairingCoordinatorError.cancelled
        case .bluetoothOff(_): throw PairingCoordinatorError.bluetoothOff
        case .explanationRequired: throw PairingCoordinatorError.explanationRequired
        case .checkingProvisioning, .needsPairing, .removed:
            throw PairingCoordinatorError.notStarted
        default:
            return
        }
    }
}

private enum PairingCoordinatorError: Error, LocalizedError, Sendable {
    case failed(String)
    case cancelled
    case bluetoothOff
    case explanationRequired
    case notStarted

    var errorDescription: String? {
        switch self {
        case .failed(let reason): reason
        case .cancelled: "Pairing was cancelled. Try again when you are ready."
        case .bluetoothOff: "Bluetooth is off. Turn it on, then try pairing again."
        case .explanationRequired: "Check the side light, then continue."
        case .notStarted: "No band was chosen. Check the side light, then try again."
        }
    }
}

/// Reaches the real HealthKit and UserNotifications prompts. Only production
/// uses it; fixture launches get `NoopPermissionCoordinator` so UI tests and
/// screenshots never raise a system prompt.
private struct ProductOnboardingPermissionCoordinator: OnboardingPermissionCoordinator {
    let healthSync: LooprHealthSyncRuntime?

    func request(_ permission: OnboardingPermission) async -> OnboardingPermissionOutcome {
        switch permission {
        case .appleHealth:
            guard let healthSync else { return .unavailable }
            // The Settings > Apple Health path: one sheet for write access to
            // the exported metrics and read access for the history import,
            // which then starts. The step listed exactly these types, from
            // `LooprHealthSyncRuntime.permissionRequest()`. HealthKit reports
            // write status, so the outcome is known; read status never is.
            await healthSync.requestPermission()
            let status = await healthSync.status()
            if status.unavailable { return .unavailable }
            if !status.allowed.isEmpty {
                // As Settings does: start the first export now instead of
                // waiting for the next background pass.
                Task { await healthSync.synchronizeNow() }
                return .granted
            }
            return status.undetermined.isEmpty ? .denied : .requested
        case .notifications:
            switch await LooprNotificationRuntime.shared.requestPermission() {
            case .available: return .granted
            case .denied: return .denied
            default: return .unavailable
            }
        }
    }
}

enum ProductOnboardingPresentationState: Equatable {
    case storageUnavailable
    case loading
    case ready(OnboardingStage)
}

struct ProductOnboardingPreparedFlow {
    let controller: OnboardingFlowController
    let snapshot: OnboardingSnapshot
}

@MainActor
enum ProductOnboardingProductionPreparation {
    static func prepare(
        environment: AppEnvironment,
        repositories: ProductRepositoryContainer,
        bluetoothModel: BluetoothApplicationModel
    ) async throws -> ProductOnboardingPreparedFlow {
        guard let persistent = repositories.persistent else {
            throw ProductRepositoryCompositionError.productionStorageUnavailable
        }
        let flow = try await OnboardingFlowController(
            repository: persistent.onboarding,
            profileRepository: persistent.profile,
            goalsRepository: persistent.profile,
            pairingCoordinator: ProductOnboardingPairingCoordinator(bluetoothModel: bluetoothModel),
            permissionCoordinator: ProductOnboardingPermissionCoordinator(healthSync: persistent.healthSync),
            dataEffects: persistent.destructiveEffects,
            dateProvider: environment.dateProvider
        )
        return ProductOnboardingPreparedFlow(controller: flow, snapshot: try await flow.resume())
    }
}

/// Maps the app's Bluetooth status onto what the onboarding pairing step
/// shows. Kept separate and static so it can be tested without a view.
enum ProductOnboardingPairingPhaseMapper {
    static func phase(
        for status: BluetoothApplicationStatus,
        strapConnected: Bool,
        pairingRequested: Bool
    ) -> OnboardingPairingPhase {
        if strapConnected { return .connected }
        switch status {
        case .checkingProvisioning, .needsPairing, .removed:
            return .idle
        case .explanationRequired:
            return .confirmReady
        case .pickerPresented:
            return .choosing
        case .preparing, .retrieving, .scanning, .connecting, .discovering, .subscribing:
            return .connecting
        case .connected:
            // Connected at the link level but the product runtime is not
            // ready yet: still connecting from the person's point of view.
            return .connecting
        case .disconnected(_, let reason):
            return pairingRequested ? .connecting : .failed(reason)
        case .bluetoothOff:
            return .bluetoothOff
        case .cancelled:
            return .cancelled
        case .removing:
            return .idle
        case .failed(let reason):
            // A stale bond has one fix, Forget This Device, and the step
            // shows those steps for it instead of the generic checklist.
            return reason == LooprBluetoothFailureCopy.bondRepair ? .bondRepair : .failed(reason)
        }
    }
}

/// App composition for the package-owned, durable onboarding state machine.
/// Bluetooth permission remains contextual: the package transition is only
/// committed after the app's provisioning flow accepts the contextual action.
@MainActor
struct ProductOnboardingRoot: View {
    let environment: AppEnvironment
    let onComplete: () -> Void
    private let bandIntroAssets: BandIntroAssets

    @EnvironmentObject private var bluetoothModel: BluetoothApplicationModel
    @StateObject private var repositories: ProductRepositoryContainer
    @State private var controller: OnboardingFlowController?
    @State private var snapshot: OnboardingSnapshot?
    @State private var errorMessage: String?
    @State private var showingDestructiveActions = false
    @State private var busy = false
    @State private var loadingViewVisible = false
    @State private var bandIntroAdvancing = false
    @State private var healthRequest: OnboardingHealthRequest = .freshInstall

    init(
        environment: AppEnvironment,
        bluetoothModel: BluetoothApplicationModel,
        bandIntroAssets: BandIntroAssets? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.environment = environment
        self.onComplete = onComplete
        self.bandIntroAssets = bandIntroAssets ?? Self.bandIntroAssets
        _repositories = StateObject(wrappedValue: ProductRepositoryContainer(
            environment: environment,
            runtimeDataDeleter: BluetoothModelRuntimeDataDeleter(model: bluetoothModel)
        ))
    }

    var body: some View {
        ZStack {
            Group {
                switch Self.presentationState(
                    storageFailure: repositories.storageFailure,
                    snapshot: snapshot
                ) {
                case .storageUnavailable:
                    if let failure = repositories.storageFailure {
                        ProductStorageUnavailableView(failure: failure, retry: retryStorage)
                            .id(repositories.graphIdentity)
                    }
                case .ready(.launching) where !showingDestructiveActions:
                    // A new user: nothing is persisted yet. The film ends in
                    // Get started, which performs the launching -> welcome
                    // transition, so killing the app mid-film replays it.
                    // Data controls opened by a DEBUG deep link take priority.
                    BandIntroView(assets: bandIntroAssets, onGetStarted: finishBandIntro)
                        .transition(.opacity)
                case .loading, .ready:
                    onboardingSurface
                        .id(repositories.graphIdentity)
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        #if DEBUG
        .preferredColorScheme(ProductOnboardingDeepLink.colorScheme())
        #endif
        .accessibilityIdentifier("root-onboarding")
        .task(id: repositories.graphIdentity) { await prepare() }
    }

    static func presentationState(
        storageFailure: ProductStorageInitializationFailure?,
        snapshot: OnboardingSnapshot?
    ) -> ProductOnboardingPresentationState {
        if storageFailure != nil { return .storageUnavailable }
        if let snapshot { return .ready(snapshot.stage) }
        return .loading
    }

    private var onboardingSurface: some View {
        NavigationStack {
            Group {
                if showingDestructiveActions {
                    OnboardingDestructiveActionsScreen(onConfirm: performDestructiveAction)
                        .overlay(alignment: .bottom) {
                            if let errorMessage {
                                LooprSurface(emphasis: .hero(.strain)) {
                                    LooprInlineMessage(errorMessage, tone: .critical)
                                }
                                .padding(.horizontal, LooprSpacing.screenGutter)
                                .padding(.bottom, LooprSpacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("onboarding-error")
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    errorMessage = nil
                                    showingDestructiveActions = false
                                }
                                .accessibilityIdentifier("onboarding-data-controls-done")
                            }
                        }
                } else if let snapshot {
                    if snapshot.stage == .launching {
                        OnboardingPreparationLoadingView()
                    } else {
                        OnboardingScreen(
                            snapshot: snapshot,
                            pairingPhase: pairingPhase(for: snapshot),
                            health: healthRequest,
                            sharedLinkHint: sharedLinkHint,
                            backgroundRefreshOff: backgroundRefreshOff,
                            bandStillConnecting: bandStillConnecting,
                            errorMessage: visibleError(for: snapshot),
                            isBusy: busy,
                            now: environment.dateProvider.now(),
                            actions: actions
                        )
                    }
                } else if let errorMessage {
                    OnboardingPreparationErrorView(message: errorMessage) {
                        Task { await retryPreparation() }
                    }
                } else {
                    // Preparation usually finishes within a frame or two. Holding
                    // the skeleton back briefly keeps it from flashing in front of
                    // the band intro or the main shell.
                    OnboardingPreparationLoadingView()
                        .opacity(loadingViewVisible ? 1 : 0)
                        .task {
                            try? await Task.sleep(for: .milliseconds(400))
                            loadingViewVisible = true
                        }
                }
            }
        }
    }

    private var actions: OnboardingActions {
        var actions = OnboardingActions()
        actions.advance = { run { try await $0.advance() } }
        actions.back = { run { try await $0.goBack() } }
        actions.requestPairing = { run { try await $0.requestContextualPairing() } }
        actions.confirmPairingSheet = {
            run { controller in
                await bluetoothModel.continueAfterExplanation()
                return try await controller.requestContextualPairing()
            }
        }
        actions.deferPairing = { run { try await $0.deferPairing() } }
        actions.setExperimentalSupport = { enabled in
            run { controller in
                let next = try await controller.setExperimentalSupport(enabled)
                try await bluetoothModel.setExperimentalSupport(enabled)
                return next
            }
        }
        actions.completeProfile = { draft in
            run { controller in
                let next = try await controller.completeProfile(draft)
                applyMeasurementSystem(draft.unitSystem)
                return next
            }
        }
        actions.requestPermission = { permission in run { try await $0.requestPermission(permission) } }
        actions.skipPermission = { permission in run { try await $0.skipPermission(permission) } }
        actions.saveSleepGoal = { hours in run { try await $0.saveSleepGoal(hours: hours) } }
        actions.skipSleepGoal = { run { try await $0.skipSleepGoal() } }
        actions.finish = { run { try await $0.finish() } }
        actions.openDataControls = {
            errorMessage = nil
            showingDestructiveActions = true
        }
        return actions
    }

    /// Runs one controller transition, keeping the buttons disabled while it
    /// is in flight so a double tap cannot fire two system prompts.
    private func run(_ transition: @escaping (OnboardingFlowController) async throws -> OnboardingSnapshot) {
        guard let controller, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                snapshot = try await transition(controller)
                errorMessage = nil
                finishIfReady()
            } catch {
                errorMessage = error.localizedDescription
                // A failed transition leaves the durable state as it was;
                // re-read it so the screen matches what is saved.
                snapshot = await controller.snapshot()
            }
        }
    }

    private func pairingPhase(for snapshot: OnboardingSnapshot) -> OnboardingPairingPhase {
        #if DEBUG
        if let override = ProductOnboardingDeepLink.pairingPhaseOverride() { return override }
        #endif
        guard environment.composition == .production else {
            // Fixture launches have no band. A pairing request there goes
            // through NoopPairingCoordinator, so show it as connected.
            return snapshot.pairingRequested ? .connected : .idle
        }
        return ProductOnboardingPairingPhaseMapper.phase(
            for: bluetoothModel.status,
            strapConnected: bluetoothModel.canReportStrapConnected,
            pairingRequested: snapshot.pairingRequested
        )
    }

    /// Whether to show the soft "another app may be connected" hint. Only a
    /// real Bluetooth runtime can observe it.
    private var sharedLinkHint: Bool {
        #if DEBUG
        if ProductOnboardingDeepLink.flag("--loopr-onboarding-shared-link-hint") { return true }
        #endif
        guard environment.composition == .production else { return false }
        return bluetoothModel.otherAppLinkHint
    }

    /// Only a real runtime can be still connecting; fixture launches have no band.
    private var bandStillConnecting: Bool {
        environment.composition == .production && !bluetoothModel.canReportStrapConnected
    }

    /// Background App Refresh is a per-app switch the person may have turned
    /// off; the finish step says so, because overnight syncs depend on it.
    private var backgroundRefreshOff: Bool {
        #if DEBUG
        if ProductOnboardingDeepLink.flag("--loopr-onboarding-background-refresh-off") { return true }
        #endif
        return UIApplication.shared.backgroundRefreshStatus == .denied
    }

    /// Pairing problems already have their own title and detail on the
    /// pairing step, so the thrown error would only repeat them.
    private func visibleError(for snapshot: OnboardingSnapshot) -> String? {
        guard let errorMessage else { return nil }
        if snapshot.stage == .pairing, pairingPhase(for: snapshot) != .idle { return nil }
        return errorMessage
    }

    /// The unit chosen on the profile step applies to every screen straight
    /// away, instead of waiting for Settings to be opened.
    private func applyMeasurementSystem(_ unitSystem: ProfileKit.UnitSystem?) {
        guard let unitSystem else { return }
        var state = DesignSystemRuntime.state()
        state.measurementSystem = unitSystem.looprMeasurementSystem
        DesignSystemRuntime.apply(state)
    }

    private func prepare() async {
        #if DEBUG
        ProductOnboardingDeepLink.applyAppearanceOverride()
        #endif
        guard controller == nil else { return }
        guard repositories.storageFailure == nil else { return }
        do {
            if environment.composition == .production {
                let prepared = try await ProductOnboardingProductionPreparation.prepare(
                    environment: environment,
                    repositories: repositories,
                    bluetoothModel: bluetoothModel
                )
                controller = prepared.controller
                snapshot = prepared.snapshot
                if let request = await repositories.persistent?.healthSync.permissionRequest() {
                    healthRequest = request
                }
            } else {
                let initial = OnboardingSnapshot(stage: initialStage, lastUpdatedAt: environment.dateProvider.now())
                let profile = InMemoryProfileRepository(
                    dateProvider: environment.dateProvider,
                    uuidProvider: environment.uuidProvider
                )
                let flow = try await OnboardingFlowController(
                    repository: InMemoryOnboardingRepository(snapshot: initial),
                    profileRepository: profile,
                    goalsRepository: profile,
                    pairingCoordinator: NoopPairingCoordinator(),
                    permissionCoordinator: NoopPermissionCoordinator(),
                    dataEffects: InMemoryOnboardingDataEffects(),
                    dateProvider: environment.dateProvider
                )
                controller = flow
                snapshot = try await flow.resume()
            }
            // A persisted main-shell snapshot is already complete. Resume must
            // use the same completion boundary as the interactive paths so a
            // relaunch does not strand the user on an onboarding loading view.
            // A `.launching` snapshot stays put: it shows the band intro, whose
            // Get started button advances it.
            finishIfReady()
            #if DEBUG
            if ProductOnboardingDeepLink.parse() == .destructiveActions {
                showingDestructiveActions = true
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retryStorage() {
        controller = nil
        snapshot = nil
        errorMessage = nil
        showingDestructiveActions = false
        repositories.retry()
    }

    private func retryPreparation() async {
        controller = nil
        snapshot = nil
        errorMessage = nil
        await prepare()
    }

    private var initialStage: OnboardingStage {
        #if DEBUG
        if let stage = ProductOnboardingDeepLink.stage() { return stage }
        #endif
        switch environment.composition {
        case .pairing: return .pairing
        case .onboarding, .production: return .launching
        default: return .mainShell
        }
    }

    private func finishBandIntro() {
        guard !bandIntroAdvancing, snapshot?.stage == .launching else { return }
        bandIntroAdvancing = true
        Task {
            defer { bandIntroAdvancing = false }
            guard let controller else { return }
            do {
                let next = try await controller.advance()
                withAnimation(.easeInOut(duration: 0.5)) { snapshot = next }
                errorMessage = nil
            } catch {
                // The intro stays up and Get started can be tapped again.
                errorMessage = error.localizedDescription
            }
        }
    }

    static var bandIntroAssets: BandIntroAssets {
        #if DEBUG
        // Screenshots and previews can point the intro at a placeholder film
        // until the rendered one ships in Resources/Onboarding.
        let prefix = "--loopr-band-intro-assets="
        if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count) {
            return BandIntroAssets(directory: URL(fileURLWithPath: String(path), isDirectory: true))
        }
        #endif
        return .bundled(in: .main)
    }

    private func finishIfReady() {
        if snapshot?.stage == .mainShell { onComplete() }
    }

    private func performDestructiveAction(_ action: OnboardingDestructiveAction) {
        Task {
            guard let controller else { return }
            do {
                try await controller.perform(action)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Shown while the durable onboarding snapshot is read. That read is usually
/// done in a few frames, so the view starts as the bare background (matching
/// the launch screen) and only shows the loading message if it takes longer
/// than `LaunchHoldView.revealDelay`.
private struct OnboardingPreparationLoadingView: View {
    @State private var revealed = false

    var body: some View {
        VStack(spacing: LooprSpacing.lg) {
            StateMessage(.loading, compact: true)
                .fixedSize()
            LooprSkeleton(height: LooprSpacing.sm)
                .frame(maxWidth: LooprSpacing.hero * 4)
        }
        .opacity(revealed ? 1 : 0)
        .task {
            do { try await Task.sleep(for: LaunchHoldView.revealDelay) } catch { return }
            withAnimation(.easeIn(duration: 0.25)) { revealed = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-loading")
    }
}

private struct OnboardingPreparationErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                HStack(spacing: LooprSpacing.sm) {
                    Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .looprTypography(.metric)
                        .foregroundStyle(Color.loopr(.strain))
                        .padding(LooprSpacing.md)
                        .background(Color.loopr(.strain).opacity(0.10), in: Circle())
                        .accessibilityHidden(true)

                    LooprText("LOOPR", style: .overline, color: .brand)
                }

                LooprText("Setup could not finish.", style: .display)

                LooprSurface(emphasis: .hero(.strain)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StateMessage(.recoverableError)
                        LooprInlineMessage(message, tone: .warning)
                        Button("Try again", action: retry)
                            .buttonStyle(LooprButtonStyle())
                            .accessibilityIdentifier("onboarding-preparation-retry")
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.xl)
            .padding(.bottom, LooprSpacing.xxl)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("onboarding-preparation-error")
    }
}

#if DEBUG
/// Debug-only launch hooks for UI tests and screenshots:
/// `--loopr-deep-link=phase06/profile`, `phase06/destructive-actions`, or
/// `onboarding/<stage raw value>` opens a fixture launch on that step, and
/// `--loopr-onboarding-pairing-phase=<idle|choosing|connecting|connected|notFound|bondRepair|failed|bluetoothOff>`
/// pins what the pairing step shows. `--loopr-onboarding-shared-link-hint`
/// and `--loopr-onboarding-background-refresh-off` show those two notices.
private enum ProductOnboardingDeepLink: Equatable {
    case profile
    case destructiveActions
    case stage(OnboardingStage)

    static func parse(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-deep-link=") })?
            .dropFirst("--loopr-deep-link=".count) else { return nil }
        switch raw {
        case "phase06/profile": return .profile
        case "phase06/destructive-actions": return .destructiveActions
        default:
            guard raw.hasPrefix("onboarding/"),
                  let stage = OnboardingStage(rawValue: String(raw.dropFirst("onboarding/".count))) else { return nil }
            return .stage(stage)
        }
    }

    static func stage(arguments: [String] = ProcessInfo.processInfo.arguments) -> OnboardingStage? {
        switch parse(arguments: arguments) {
        case .profile: .profileSetup
        case .stage(let stage): stage
        default: nil
        }
    }

    /// `--loopr-appearance=dark|light` for screenshots. The shell applies it
    /// through its Settings fixture; onboarding has no Settings yet, so it
    /// sets the design-system override and the scene's scheme here.
    static func colorScheme(arguments: [String] = ProcessInfo.processInfo.arguments) -> ColorScheme? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-appearance=") })?
            .dropFirst("--loopr-appearance=".count) else { return nil }
        return raw == "dark" ? .dark : raw == "light" ? .light : nil
    }

    static func applyAppearanceOverride() {
        guard let scheme = colorScheme() else { return }
        var state = DesignSystemRuntime.state()
        let override: LooprAppearanceOverride = scheme == .dark ? .dark : .light
        guard state.appearance != override else { return }
        state.appearance = override
        DesignSystemRuntime.apply(state)
    }

    static func flag(_ name: String, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(name)
    }

    static func pairingPhaseOverride(arguments: [String] = ProcessInfo.processInfo.arguments) -> OnboardingPairingPhase? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-onboarding-pairing-phase=") })?
            .dropFirst("--loopr-onboarding-pairing-phase=".count) else { return nil }
        switch raw {
        case "idle": return .idle
        case "confirmReady": return .confirmReady
        case "choosing": return .choosing
        case "connecting": return .connecting
        case "connected": return .connected
        case "notFound": return .notFound
        case "cancelled": return .cancelled
        case "bluetoothOff": return .bluetoothOff
        case "bondRepair": return .bondRepair
        case "failed": return .failed("The band stopped answering. Keep it next to your iPhone and try again.")
        default: return nil
        }
    }
}
#endif
