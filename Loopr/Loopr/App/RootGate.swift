import Combine
import Observation
import SwiftUI
import DesignSystem
import BluetoothKit
import NotificationKit

/// The two facts RootGate decides on. Kept apart from the Bluetooth model so
/// a status tick, a grace window or a battery read does not re-run the gate and
/// rebuild the shell below it.
@MainActor
@Observable
final class LaunchGateState {
    private(set) var startupFailureMessage: String?
    private(set) var isMainSurfaceReady = false

    func update(startupFailureMessage: String?, isMainSurfaceReady: Bool) {
        if self.startupFailureMessage != startupFailureMessage { self.startupFailureMessage = startupFailureMessage }
        if self.isMainSurfaceReady != isMainSurfaceReady { self.isMainSurfaceReady = isMainSurfaceReady }
    }
}

struct RootGate: View {
    let environment: AppEnvironment
    /// Held without observation. The gate reads `launchGate` only.
    let bluetoothModel: BluetoothApplicationModel
    @State private var onboardingCompleted: Bool
    /// Set once the shell has been on screen. After that a re-pair or an
    /// experimental-support switch never sends the person back to the blank
    /// launch screen; the shell stays and the band state says what is going on.
    @State private var didShowMainSurface = false
    /// Mirrors what Settings last applied. Held in state so a change in the
    /// unit or hint preference redraws the whole tree.
    @State private var designSystem = DesignSystemRuntime.state()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onboardingFlag: LaunchOnboardingFlagStore

    init(
        environment: AppEnvironment,
        bluetoothModel: BluetoothApplicationModel,
        onboardingFlag: LaunchOnboardingFlagStore = LaunchOnboardingFlagStore()
    ) {
        self.environment = environment
        self.bluetoothModel = bluetoothModel
        self.onboardingFlag = onboardingFlag
        // A returning user opens straight into the shell. The durable
        // onboarding snapshot is checked once the shell's repositories are
        // open (see LaunchOnboardingReconciliation).
        _onboardingCompleted = State(initialValue: LaunchRootDecision.initialOnboardingCompleted(
            root: environment.root,
            composition: environment.composition,
            cachedOnboardingCompleted: onboardingFlag.isOnboardingCompleted
        ))
    }

    private var gate: LaunchGateState { bluetoothModel.launchGate }

    private var showsShell: Bool {
        environment.composition != .production || gate.isMainSurfaceReady || didShowMainSurface
    }

    var body: some View {
        Group {
            if environment.composition == .production,
               let startupFailure = gate.startupFailureMessage {
                BluetoothStartupUnavailableView(message: startupFailure) {
                    Task { await bluetoothModel.retryStartup() }
                }
            } else if onboardingCompleted {
                if showsShell {
                    // No identity tied to the Bluetooth runtime: the shell is
                    // handed a stable runtime handle, so swapping the runtime
                    // keeps every tab, path and sheet where it was.
                    MainTabShell(
                        environment: environment,
                        heartLiveRuntime: bluetoothModel.runtimeHandle,
                        runtimeDataDeleter: BluetoothModelRuntimeDataDeleter(model: bluetoothModel),
                        onOnboardingIncomplete: onboardingIncompleteHandler
                    )
                    .transition(.opacity)
                    .onAppear { didShowMainSurface = true }
                } else {
                    LaunchHoldView()
                        .transition(.opacity)
                }
            } else {
                ProductOnboardingRoot(environment: environment, bluetoothModel: bluetoothModel) {
                    if environment.composition == .production {
                        onboardingFlag.markOnboardingCompleted()
                    }
                    onboardingCompleted = true
                }
            }
        }
        // The launch screen hands over with a short fade instead of a cut.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showsShell)
        // Finishing onboarding fades into the shell the same way.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: onboardingCompleted)
        .looprMeasurementSystem(designSystem.measurementSystem)
        .looprVoiceOverHints(designSystem.voiceOverHints)
        .background(Color.loopr(.background).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: DesignSystemRuntime.didChangeNotification)) { _ in
            designSystem = DesignSystemRuntime.state()
        }
    }

    private var onboardingIncompleteHandler: (() -> Void)? {
        guard environment.composition == .production else { return nil }
        return { returnToOnboarding() }
    }

    /// The durable store says onboarding has not finished (for example it was
    /// wiped), so the cached flag was stale. Onboarding decides from here.
    private func returnToOnboarding() {
        onboardingFlag.clear()
        onboardingCompleted = false
    }
}

private struct BluetoothStartupUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                HStack(spacing: LooprSpacing.sm) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .looprTypography(.metric)
                        .foregroundStyle(Color.loopr(.strain))
                        .padding(LooprSpacing.md)
                        .background(Color.loopr(.strain).opacity(0.10), in: Circle())
                        .accessibilityHidden(true)

                    LooprText("LOOPR", style: .overline, color: .brand)
                }

                LooprText("Bluetooth startup is unavailable.", style: .display)

                LooprSurface(emphasis: .hero(.strain)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        StateMessage(.recoverableError)
                        LooprInlineMessage(message, tone: .warning)
                        LooprText(
                            "Try again to reopen the Bluetooth history store.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        Button("Try again", action: retry)
                            .buttonStyle(LooprButtonStyle())
                            .accessibilityIdentifier("bluetooth-startup-retry")
                    }
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.xl)
            .padding(.bottom, LooprSpacing.xxl)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("bluetooth-startup-error")
    }
}

private struct OnboardingFoundation: View {
    let composition: AppEnvironment.Composition
    @EnvironmentObject private var bluetoothModel: BluetoothApplicationModel
    @State private var showingRemovePairingConfirmation = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                    HStack(spacing: LooprSpacing.sm) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .looprTypography(.metric)
                            .foregroundStyle(Color.loopr(.brand))
                            .padding(LooprSpacing.md)
                            .background(Color.loopr(.brandSoft), in: Circle())
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            LooprText("LOOPR", style: .overline, color: .brand)
                            LooprText(
                                composition == .pairing ? "CONNECT" : "GETTING READY",
                                style: .caption,
                                color: .inkSecondary
                            )
                        }
                    }

                    LooprText(
                        composition == .pairing ? "Connect your band." : "Your health, on this iPhone.",
                        style: .display
                    )
                    LooprText(
                        composition == .pairing
                            ? "Wake your band until its side light pulses blue, then tap Connect band."
                            : "Loopr works offline and does not require an account.",
                        style: .prose,
                        color: .inkSecondary
                    )

                    LooprSectionGroup(title: "Connection") {
                        bluetoothStatus
                    }

                    if bluetoothModel.status == .explanationRequired {
                        LooprSectionGroup(title: "Before you pair") {
                            LooprSurface(emphasis: .hero(.brand)) {
                                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                                    LooprText(AccessoryProvisioningController.ownershipExplanation, style: .prose, color: .inkSecondary)
                                    HStack(spacing: LooprSpacing.sm) {
                                        Button("Cancel") { bluetoothModel.cancelExplanation() }
                                            .buttonStyle(LooprButtonStyle(prominent: false))
                                        Button("Continue") {
                                            Task { await bluetoothModel.continueAfterExplanation() }
                                        }
                                        .buttonStyle(LooprButtonStyle())
                                    }
                                }
                            }
                        }
                    } else {
                        LooprSectionGroup(title: "Pairing") {
                            pairingAction
                        }
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.xl)
                .padding(.bottom, LooprSpacing.xxl)
            }
            .accessibilityIdentifier("root-onboarding")
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .confirmationDialog(
            "Remove this pairing?",
            isPresented: $showingRemovePairingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove pairing", role: .destructive) {
                Task { await bluetoothModel.removePairing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the paired band from Loopr. You can pair it again at any time.")
        }
    }

    @ViewBuilder
    private var pairingAction: some View {
        if !bluetoothModel.canShowMainSurface
            || bluetoothModel.status == .cancelled
            || bluetoothModel.status == .needsPairing
            || bluetoothModel.status == .removed {
            Button {
                Task { await bluetoothModel.userTappedPair() }
            } label: {
                Label("Connect band", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(LooprButtonStyle())
            .accessibilityIdentifier("pair-whoop")
        } else {
            Button(role: .destructive) {
                showingRemovePairingConfirmation = true
            } label: {
                Label("Remove pairing", systemImage: "trash")
            }
            .buttonStyle(LooprDestructiveButtonStyle())
            .accessibilityIdentifier("remove-pairing")
        }
    }

    @ViewBuilder
    private var bluetoothStatus: some View {
        LooprSurface(emphasis: statusEmphasis) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                statusChip

                switch bluetoothModel.status {
                case .checkingProvisioning, .preparing, .retrieving, .scanning, .connecting, .discovering, .subscribing, .removing:
                    StateMessage(.loading, compact: true)
                case .bluetoothOff:
                    StateMessage(.bluetoothOff)
                case .disconnected(_, let reason):
                    LooprInlineMessage(reason, tone: .warning)
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText(
                            "Try pairing again.",
                            style: .prose,
                            color: .inkSecondary
                        )
                        LooprInlineMessage(reason, tone: .critical)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private var statusChip: StatusChip {
        switch bluetoothModel.status {
        case .checkingProvisioning:
            StatusChip("Checking pairing", symbol: "arrow.trianglehead.2.clockwise.rotate.90", tone: .brand)
        case .needsPairing, .removed:
            StatusChip("Not paired", symbol: "antenna.radiowaves.left.and.right.slash", tone: .neutral)
        case .explanationRequired:
            StatusChip("Pairing explanation", symbol: "info.circle", tone: .brand)
        case .pickerPresented:
            StatusChip("Choose your band", symbol: "hand.tap", tone: .brand)
        case .preparing:
            StatusChip("Preparing Bluetooth", symbol: "antenna.radiowaves.left.and.right", tone: .brand)
        case .retrieving:
            StatusChip("Finding paired band", symbol: "magnifyingglass", tone: .brand)
        case .scanning:
            StatusChip("Scanning for bands", symbol: "dot.radiowaves.left.and.right", tone: .brand)
        case .connecting:
            StatusChip("Connecting", symbol: "link", tone: .brand)
        case .discovering, .subscribing:
            StatusChip("Validating strap", symbol: "checkmark.shield", tone: .brand)
        case .connected:
            StatusChip("Connected", symbol: "checkmark.circle", tone: .positive)
        case .disconnected:
            StatusChip(MetricState.disconnected.title, symbol: "link.badge.plus", tone: .warning)
        case .bluetoothOff:
            StatusChip(
                MetricState.bluetoothOff.title,
                symbol: MetricState.bluetoothOff.symbol,
                accent: .strain
            )
        case .cancelled:
            StatusChip("Pairing cancelled", symbol: "xmark.circle", tone: .warning)
        case .removing:
            StatusChip("Removing pairing", symbol: "trash", tone: .warning)
        case .failed:
            StatusChip(
                "Pairing failed",
                symbol: MetricState.recoverableError.symbol,
                tone: .critical
            )
        }
    }

    private var statusEmphasis: SurfaceEmphasis {
        switch bluetoothModel.status {
        case .bluetoothOff, .disconnected, .failed, .removing:
            .hero(.strain)
        case .connected:
            .hero(.brand)
        default:
            .standard
        }
    }
}
