import Combine
import Foundation
import BluetoothKit
import SyncKit
import StorageKit
import HeartKit
import OnboardingKit
import ProtocolKit
#if DEBUG
import OSLog
#endif

/// The status exposed to the app surface.  There is deliberately no generic
/// "connected" fallback: the connected case is emitted only after the
/// Bluetooth session has reached the listening state (validated GATT and all
/// inbound notifications confirmed).
nonisolated enum BluetoothApplicationStatus: Equatable, Sendable {
    case checkingProvisioning
    case needsPairing
    case explanationRequired
    case pickerPresented
    case preparing(UUID)
    case retrieving
    case scanning
    case connecting
    case discovering
    case subscribing
    case connected(UUID)
    case disconnected(UUID?, reason: String)
    case bluetoothOff(UUID?)
    case cancelled
    case removing(UUID?)
    case removed
    case failed(String)

    var isProvisioned: Bool {
        switch self {
        case .preparing, .retrieving, .scanning, .connecting, .discovering,
                .subscribing, .connected, .disconnected(_, _), .bluetoothOff(_),
                .removing(_):
            true
        default:
            false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Case name only. Pairing diagnostics must not log the peripheral UUID
    /// or a raw failure reason.
    var logCase: String {
        String(String(describing: self).prefix(while: { $0 != "(" }))
    }
}

private extension ConnectionPlan {
    var generation: UInt64? {
        switch self {
        case .retrieve(let generation, _), .scan(let generation, _),
                .connect(let generation, _):
            generation
        case .none:
            nil
        }
    }
}

/// The app does not own ASK directly.  Keeping this tiny protocol around the
/// package actor makes launch, picker, cancellation, and re-pair sequencing
/// testable without presenting system UI.
nonisolated protocol LooprAccessoryProvisioningFlow: Sendable {
    func inspectExisting() async -> AccessoryProvisioningOutcome
    func userTappedPair() async -> AccessoryProvisioningOutcome
    func continueAfterExplanation() async -> AccessoryProvisioningOutcome
    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome
    func provisionedDisplayName() async -> String?
    func provisionedServiceUUID() async -> UUID?
}

extension LooprAccessoryProvisioningFlow {
    func provisionedDisplayName() async -> String? { nil }
    func provisionedServiceUUID() async -> UUID? { nil }
}

struct AccessoryProvisioningFlowAdapter: LooprAccessoryProvisioningFlow {
    let controller: AccessoryProvisioningController

    func inspectExisting() async -> AccessoryProvisioningOutcome {
        await controller.inspectExisting()
    }

    func userTappedPair() async -> AccessoryProvisioningOutcome {
        await controller.userTappedPair()
    }

    func continueAfterExplanation() async -> AccessoryProvisioningOutcome {
        await controller.continueAfterExplanation()
    }

    func removeProvisionedAccessory() async -> AccessoryProvisioningOutcome {
        await controller.removeProvisionedAccessory()
    }

    func provisionedDisplayName() async -> String? { await controller.provisionedDisplayName() }
    func provisionedServiceUUID() async -> UUID? { await controller.provisionedServiceUUID() }
}

/// Failure messages other screens recognise and answer with their own help.
nonisolated enum LooprBluetoothFailureCopy {
    /// iOS kept pairing keys the band no longer accepts. Onboarding shows the
    /// Forget This Device steps for this one failure.
    static let bondRepair = "Open Settings > Bluetooth, forget the band, then return to Loopr to pair it again."
}

/// Runtime states are intentionally transport-neutral.  The app only trusts
/// `.ready` as connected after BluetoothKit's setup barrier has completed.
enum LooprBluetoothRuntimeState: Equatable, Sendable {
    case idle
    case retrieving
    case scanning
    case connecting
    case discovering
    case subscribing
    case ready(UUID)
    case disconnected(String)
    case bluetoothOff
    case failed(String)
}

enum LooprBluetoothRuntimeCompositionError: Error, Equatable, Sendable, LocalizedError {
    case missingProductCapabilities

    var errorDescription: String? {
        "The shared Bluetooth runtime does not provide Heart and Device Center capabilities."
    }
}

/// Narrow app-facing seam for the integrated SyncKit/Bluetooth runtime.  The
/// production adapter below is useful while the package composition is being
/// finalized; a package-owned `BluetoothAdoptionRuntime` can conform through
/// the same factory without changing app state or UI code.
nonisolated protocol LooprBluetoothAdoptionRuntime: AnyObject, Sendable {
    func events() async -> AsyncStream<LooprBluetoothRuntimeState>
    func state() async -> LooprBluetoothRuntimeState
    func start() async
    func stop() async
    func enterForeground() async
    func enterBackground() async
    func runBackground(kind: BackgroundRunKind) async -> Bool
    func expireBackground() async
    /// Whether iOS listed the band as connected before Loopr opened its own
    /// link. A hint that another app holds the band, never proof.
    func otherAppLinkObserved() async -> Bool
}

extension LooprBluetoothAdoptionRuntime {
    func otherAppLinkObserved() async -> Bool { false }
}

nonisolated protocol LooprBluetoothRuntimeFactory: Sendable {
    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime
    func makeRuntime(for identifier: UUID, model: BandModel) async throws -> any LooprBluetoothAdoptionRuntime
}

extension LooprBluetoothRuntimeFactory {
    func makeRuntime(for identifier: UUID, model: BandModel) async throws -> any LooprBluetoothAdoptionRuntime {
        try await makeRuntime(for: identifier)
    }
}

/// `BluetoothAdoptionRuntimeState.lastError` is a diagnostic string built with
/// `String(describing:)`, so it carries raw values such as "outOfRange" or
/// "timedOut(20)". Those must never reach a user. Anything unrecognized falls
/// back to a message that describes the situation without guessing a cause.
nonisolated enum ConnectionErrorCopy {
    static func readable(_ rawError: String) -> String {
        if rawError.contains("outOfRange") {
            return "Your band is out of range. Bring it closer to your iPhone."
        }
        if rawError.contains("bluetoothOff") {
            return "Bluetooth is off. Turn it on, then try again."
        }
        if rawError.contains("insufficientAuthentication")
            || rawError.contains("insufficientEncryption")
            || rawError.contains("peerRemovedPairing") {
            return LooprBluetoothFailureCopy.bondRepair
        }
        if rawError.contains("timedOut") || rawError.contains("timeout") {
            return "Your band did not answer in time. Wake it until its side light pulses blue, then try again."
        }
        return "Loopr could not finish connecting to your band. Keep it near your iPhone and make sure its side light pulses blue."
    }
}

/// Turns SyncKit's runtime state into the app's link state.
///
/// SyncKit records `lastError` whenever any write fails, including a heartbeat,
/// a keep-alive, a battery read or a history refresh, and keeps it until the
/// next accepted connection event. Most of those happen on a link that is
/// still up. Checking the error before the connection reported a healthy
/// listening band as failed, tore down its live stream and showed "not
/// connected" on every tab until the link bounced. So an error only decides
/// the state when the session has ended: the runtime stopped, or it is idle
/// with no reconnect scheduled. Otherwise the connection decides and the error
/// stays a Device Center diagnostic.
nonisolated enum LooprRuntimeStateClassifier {
    static func appState(for state: BluetoothAdoptionRuntimeState) -> LooprBluetoothRuntimeState {
        if state.radioState == .poweredOff || state.connection == .bluetoothOff {
            return .bluetoothOff
        }
        if state.bondRepairRequired != nil {
            return .failed(LooprBluetoothFailureCopy.bondRepair)
        }
        if let lastError = state.lastError, sessionEnded(state) {
            return .failed(ConnectionErrorCopy.readable(lastError))
        }
        switch state.connection {
        case .idle:
            return state.running ? .disconnected("Your band isn't connected yet.") : .idle
        case .retrieving:
            return .retrieving
        case .scanning:
            return .scanning
        case .connecting:
            return .connecting
        case .discovering:
            return .discovering
        case .subscribing, .settingUp:
            return .subscribing
        case .listening(_, let peripheral):
            guard state.setupReady, state.setupComplete else { return .subscribing }
            return .ready(peripheral)
        case .reconnecting:
            return .disconnected("Lost the connection to your band. Reconnecting.")
        case .outOfRange:
            return .disconnected("Your band is out of range. Bring it closer to your iPhone.")
        case .bluetoothOff:
            return .bluetoothOff
        }
    }

    /// The experimental Gen 5 session has no setup barrier of its own, so a
    /// listening link counts once setup completed.
    static func gen5AppState(for state: BluetoothAdoptionRuntimeState) -> LooprBluetoothRuntimeState {
        if state.radioState == .poweredOff || state.connection == .bluetoothOff {
            return .bluetoothOff
        }
        if state.bondRepairRequired != nil {
            return .failed(LooprBluetoothFailureCopy.bondRepair)
        }
        if let lastError = state.lastError, sessionEnded(state) {
            return .failed(ConnectionErrorCopy.readable(lastError))
        }
        return switch state.connection {
        case .idle: .idle
        case .retrieving: .retrieving
        case .scanning: .scanning
        case .connecting: .connecting
        case .discovering: .discovering
        case .subscribing, .settingUp: .subscribing
        case .listening(_, let peripheral): state.setupComplete ? .ready(peripheral) : .subscribing
        case .reconnecting, .outOfRange: .disconnected("Lost the connection to your band. Reconnecting.")
        case .bluetoothOff: .bluetoothOff
        }
    }

    /// An error ends the session only when nothing will bring the link back
    /// without the person doing something.
    static func sessionEnded(_ state: BluetoothAdoptionRuntimeState) -> Bool {
        if !state.running { return true }
        if case .idle = state.connection, state.pendingReconnect == nil { return true }
        return false
    }
}

#if canImport(CoreBluetooth)
/// The only app-level call site for the process-wide native factory.  It is
/// invoked after ASK has returned and persisted an identifier; constructing a
/// CBCentralManager is therefore impossible during launch inspection.
struct CoreBluetoothRuntimeFactoryAdapter: LooprBluetoothRuntimeFactory {
    private let store: any BluetoothAdoptionStore
    private let factoryProvider: @Sendable () -> CoreBluetoothTransportFactory

    init(
        store: any BluetoothAdoptionStore,
        factoryProvider: @escaping @Sendable () -> CoreBluetoothTransportFactory = {
            CoreBluetoothTransportFactory.shared
        }
    ) {
        self.store = store
        self.factoryProvider = factoryProvider
    }

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime {
        try await makeRuntime(for: identifier, model: .whoop4)
    }

    func makeRuntime(for identifier: UUID, model: BandModel) async throws -> any LooprBluetoothAdoptionRuntime {
        let factory = factoryProvider()
        try factory.provision(identifier)
        let isGen5 = model == .whoop5 || model == .whoopMG || model == .unknownGen5
        let transport = try factory.makeTransport(profile: isGen5 ? .gen5 : .gen4)
        if isGen5 {
            let runtime = Gen5ExperimentalRuntime(
                transport: transport, peripheral: identifier, model: model, store: store
            )
            return Gen5ExperimentalRuntimeAdapter(transport: transport, runtime: runtime, factory: factory)
        }
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store
        )
        return BluetoothAdoptionRuntimeAdapter(
            transport: transport,
            runtime: runtime,
            factory: factory
        )
    }
}

/// Type-erases the integrated SyncKit runtime into the app's lifecycle seam.
/// SyncKit owns event consumption, reconnect policy, GATT setup, history, and
/// live-stream safety. This wrapper only projects its state to SwiftUI and
/// releases the native factory owner exactly once when pairing is removed.
actor BluetoothAdoptionRuntimeAdapter: LooprBluetoothAdoptionRuntime, LooprDeviceCenterRuntime, PersistentDataDeletionDeleter {
    private let transport: CoreBluetoothTransport
    private let runtime: BluetoothAdoptionRuntime
    private let factory: CoreBluetoothTransportFactory

    private var eventStream: AsyncStream<LooprBluetoothRuntimeState>?
    private var eventContinuation: AsyncStream<LooprBluetoothRuntimeState>.Continuation?
    private var stateObservationTask: Task<Void, Never>?
    private var currentState: LooprBluetoothRuntimeState = .idle
    private var didStart = false
    private var didRelease = false

    init(
        transport: CoreBluetoothTransport,
        runtime: BluetoothAdoptionRuntime,
        factory: CoreBluetoothTransportFactory
    ) {
        self.transport = transport
        self.runtime = runtime
        self.factory = factory
    }

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        if let eventStream { return eventStream }
        let pair = AsyncStream<LooprBluetoothRuntimeState>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
        return pair.stream
    }

    func state() async -> LooprBluetoothRuntimeState { currentState }

    func otherAppLinkObserved() async -> Bool {
        guard !didRelease else { return false }
        return await transport.otherAppLinkObservedBeforeConnect()
    }

    func start() async {
        guard !didRelease else { return }
        await installStateObserver()
        if !didStart {
            didStart = true
            _ = await runtime.start()
        }
        await refreshState()
    }

    func stop() async {
        guard !didRelease else { return }
        stateObservationTask?.cancel()
        stateObservationTask = nil
        await runtime.stop()
        didRelease = true
        factory.release(transport)
        currentState = .disconnected("Bluetooth session stopped.")
        eventContinuation?.yield(currentState)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func enterForeground() async {
        guard !didRelease else { return }
        await installStateObserver()
        await runtime.enterForeground()
        didStart = true
        await refreshState()
    }

    func enterBackground() async {
        guard !didRelease else { return }
        await runtime.enterBackground()
        await refreshState()
    }

    func runBackground(kind: BackgroundRunKind) async -> Bool {
        guard !didRelease else { return false }
        await installStateObserver()
        // An app refresh window is about thirty seconds, so twenty-five leaves
        // room for the health sync that follows. A processing window runs for
        // minutes, and a night's backlog needs minutes: at the measured rate a
        // five-hour gap is four to five minutes of draining, and cutting that
        // off at thirty seconds is what left a backlog for the morning.
        let maxDuration: TimeInterval = kind == .appRefresh ? 25 : 240
        let success = await runtime.runBackgroundSync(maxDuration: maxDuration)
        didStart = true
        await refreshState()
        return success
    }

    func expireBackground() async {
        guard !didRelease else { return }
        // Expiration fences the active background operation while retaining
        // the runtime's state stream and native factory ownership. A full
        // stop here would finish observers and break foreground restart.
        _ = await runtime.expireBackground()
        await refreshState()
    }

    // HeartKit consumes this same SyncKit runtime. No second transport or
    // protocol command path is created here; the adapter only forwards the
    // shared live-stream lease and opaque buffered frames.
    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        try await runtime.acquireLiveStream(kind: kind, consumer: consumer)
    }

    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        do {
            return try await runtime.acquireLiveEventStream(kind: kind, consumer: consumer)
        } catch {
            #if DEBUG
            print("[Loopr Bluetooth] Live acquisition failed: \(error). State: \(await runtime.currentState())")
            #endif
            throw error
        }
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        await runtime.bufferedLiveSamples(for: kind)
    }

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        await runtime.currentState()
    }

    func diagnosticsSnapshot() async -> ConnectionDiagnosticsSnapshot {
        await runtime.diagnosticsSnapshot()
    }

    // Semantic band operations. This adapter forwards them unchanged; SyncKit
    // owns framing, sequencing, the band clock, and the dangerous-opcode
    // firewall. A released adapter refuses rather than reaching a dead
    // transport.
    func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        try requireLiveRuntime()
        return try await runtime.setHeartRateSharing(enabled: enabled)
    }

    func renameBand(to name: String) async throws {
        try requireLiveRuntime()
        try await runtime.renameBand(to: name)
    }

    func buzzBand(effect: UInt8) async throws {
        try requireLiveRuntime()
        try await runtime.buzzBand(effect: effect)
    }

    func buzzBand(effect: UInt8, expectedGeneration: UInt64) async throws {
        try requireLiveRuntime()
        try await runtime.buzzBand(effect: effect, expectedGeneration: expectedGeneration)
    }

    func setBandAlarm(fireDate: Date) async throws {
        try requireLiveRuntime()
        try await runtime.setBandAlarm(fireDate: fireDate)
    }

    func readBandAlarm() async throws -> Date? {
        try requireLiveRuntime()
        return try await runtime.readBandAlarm()
    }

    func testBandAlarm() async throws {
        try requireLiveRuntime()
        try await runtime.testBandAlarm()
    }

    func disableBandAlarm() async throws {
        try requireLiveRuntime()
        try await runtime.disableBandAlarm()
    }

    func bandEvents() async -> AsyncStream<BandEventEnvelope> {
        guard !didRelease else { return AsyncStream { $0.finish() } }
        return await runtime.bandEvents()
    }

    func readSignalStrength() async -> Int? {
        guard !didRelease else { return nil }
        return await runtime.readSignalStrength()
    }

    private func requireLiveRuntime() throws {
        guard !didRelease else { throw LooprDeviceRuntimeCommandError.unavailable }
    }

    nonisolated var storeName: String { "bluetooth.runtime-cache-and-diagnostics" }

    func deleteAll() async throws {
        // Runtime ownership remains with BluetoothApplicationModel. Its
        // serialized deletion phase stops/releases this adapter first, then
        // calls this hook only to clear non-durable diagnostics.
        await runtime.diagnostics.reset()
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool {
        guard !didRelease, maxDuration > 0 else { return false }
        let success = await runtime.runBackgroundSync(maxDuration: maxDuration)
        await refreshState()
        return success
    }

    private func installStateObserver() async {
        guard stateObservationTask == nil else { return }
        let stream = await runtime.stateStream()
        stateObservationTask = Task { [weak self] in
            for await state in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.consumePackageState(state)
            }
        }
    }

    private func consumePackageState(_ state: BluetoothAdoptionRuntimeState) {
        guard !didRelease else { return }
        let nextState = appState(for: state)
        #if DEBUG
        if nextState != currentState {
            let message = "[Loopr Bluetooth] \(Date().formatted(date: .omitted, time: .standard)) State: \(nextState), setupReady=\(state.setupReady), setupComplete=\(state.setupComplete), error=\(state.lastError ?? "none")\n"
            fputs(message, stderr)
        }
        #endif
        currentState = nextState
        publish(currentState)
    }

    private func refreshState() async {
        let state = await runtime.currentState()
        consumePackageState(state)
    }

    private func publish(_ state: LooprBluetoothRuntimeState) {
        eventContinuation?.yield(state)
    }

    private func appState(for state: BluetoothAdoptionRuntimeState) -> LooprBluetoothRuntimeState {
        LooprRuntimeStateClassifier.appState(for: state)
    }
}

/// Projects the experimental fd4b session through the same app seam and the
/// same CoreBluetooth factory owner as the stable session.
actor Gen5ExperimentalRuntimeAdapter: LooprBluetoothAdoptionRuntime, LooprDeviceCenterRuntime {
    private let transport: CoreBluetoothTransport
    private let runtime: Gen5ExperimentalRuntime
    private let factory: CoreBluetoothTransportFactory
    private var observation: Task<Void, Never>?
    private var stream: AsyncStream<LooprBluetoothRuntimeState>?
    private var continuation: AsyncStream<LooprBluetoothRuntimeState>.Continuation?
    private var current: LooprBluetoothRuntimeState = .idle
    private var released = false

    init(transport: CoreBluetoothTransport, runtime: Gen5ExperimentalRuntime, factory: CoreBluetoothTransportFactory) {
        self.transport = transport
        self.runtime = runtime
        self.factory = factory
    }

    func events() async -> AsyncStream<LooprBluetoothRuntimeState> {
        if let stream { return stream }
        let pair = AsyncStream<LooprBluetoothRuntimeState>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    func state() async -> LooprBluetoothRuntimeState { current }
    func otherAppLinkObserved() async -> Bool { await transport.otherAppLinkObservedBeforeConnect() }

    func start() async {
        guard !released else { return }
        if observation == nil {
            let states = await runtime.states()
            observation = Task { [weak self] in
                for await state in states { await self?.accept(state) }
            }
        }
        await runtime.start()
        accept(await runtime.currentState())
    }

    func stop() async {
        guard !released else { return }
        released = true
        observation?.cancel()
        await runtime.stop()
        factory.release(transport)
        current = .disconnected("Bluetooth session stopped.")
        continuation?.yield(current)
        continuation?.finish()
    }

    func enterForeground() async { await runtime.enterForeground() }
    func enterBackground() async { await runtime.enterBackground() }
    func runBackground(kind: BackgroundRunKind) async -> Bool {
        await runtime.runBackgroundSync(maxDuration: kind == .appRefresh ? 25 : 240)
    }
    func expireBackground() async { await runtime.enterBackground() }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        try await runtime.acquireLiveStream(kind: kind, consumer: consumer)
    }
    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        try await runtime.acquireLiveEventStream(kind: kind, consumer: consumer)
    }
    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        await runtime.bufferedLiveSamples(for: kind)
    }
    func runtimeState() async -> BluetoothAdoptionRuntimeState { await runtime.currentState() }
    func performManualSync(maxDuration: TimeInterval) async -> Bool {
        await runtime.runBackgroundSync(maxDuration: maxDuration)
    }
    func readHeartRateSharing() async throws -> Bool? {
        guard !released else { throw LooprDeviceRuntimeCommandError.unavailable }
        return try await runtime.readHeartRateSharing()
    }
    func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        guard !released else { throw LooprDeviceRuntimeCommandError.unavailable }
        return try await runtime.setHeartRateSharing(enabled: enabled)
    }
    func bandEvents() async -> AsyncStream<BandEventEnvelope> {
        guard !released else { return AsyncStream { $0.finish() } }
        return await runtime.bandEvents()
    }
    func readSignalStrength() async -> Int? { await transport.readSignalStrength() }

    private func accept(_ state: BluetoothAdoptionRuntimeState) {
        current = LooprRuntimeStateClassifier.gen5AppState(for: state)
        continuation?.yield(current)
    }
}
#endif

struct BluetoothApplicationDependencies {
    let provisioning: any LooprAccessoryProvisioningFlow
    let runtimeFactory: any LooprBluetoothRuntimeFactory
    let startupReadiness: (@Sendable () async throws -> Void)?

    init(
        provisioning: any LooprAccessoryProvisioningFlow,
        runtimeFactory: any LooprBluetoothRuntimeFactory,
        startupReadiness: (@Sendable () async throws -> Void)? = nil
    ) {
        self.provisioning = provisioning
        self.runtimeFactory = runtimeFactory
        self.startupReadiness = startupReadiness
    }
}

@MainActor
final class BluetoothApplicationModel: ObservableObject {
    @Published private(set) var status: BluetoothApplicationStatus = .checkingProvisioning {
        didSet {
            #if DEBUG
            if status != oldValue {
                Self.pairingLogger.debug("status \(oldValue.logCase, privacy: .public) -> \(self.status.logCase, privacy: .public)")
            }
            #endif
            guard status != oldValue else { return }
            syncPresentation()
            syncLaunchGate()
        }
    }
    /// The debounced band state every screen reads. See `BandLinkPresentation`.
    let bandLink: BandLinkPresentation
    /// What RootGate needs, and nothing else, so a status tick does not
    /// rebuild the shell.
    let launchGate = LaunchGateState()
    /// The stable runtime reference handed to the shell. It survives
    /// re-pairing, so the tabs and the Settings sheet do too.
    let runtimeHandle = LooprRuntimeHandle()
    #if DEBUG
    private static let pairingLogger = Logger(subsystem: "com.loopr.ios", category: "pairing")
    #endif
    @Published private(set) var provisionedIdentifier: UUID? {
        didSet { if provisionedIdentifier != oldValue { syncPresentation() } }
    }
    @Published private(set) var isExplanationPresented = false
    /// Launch inspection is the boundary before which a persisted main-shell
    /// snapshot must not construct feature repositories. A paired identifier
    /// can be known before Core Bluetooth has finished installing the shared
    /// runtime, so the main shell also waits for `runtime` below.
    @Published private(set) var didFinishLaunchInspection = false {
        didSet { if didFinishLaunchInspection != oldValue { syncLaunchGate() } }
    }
    /// Changes whenever the product-visible runtime binding is installed or
    /// removed. RootGate uses it to rebuild repository-owning StateObjects.
    @Published private(set) var runtimeGeneration: UInt64 = 0
    @Published private(set) var startupFailureMessage: String? {
        didSet { if startupFailureMessage != oldValue { syncLaunchGate() } }
    }
    /// True while a band Loopr already knows is still bringing its link up,
    /// either at launch or after an established link drops. A paired band
    /// takes a second or two to answer, and until that attempt resolves the
    /// surface must not claim it is not connected.
    @Published private(set) var isResolvingBandLink = false
    /// Set once the band is connected if iOS reported another app's link to
    /// it first. Onboarding shows it as a soft hint; it proves nothing.
    @Published private(set) var otherAppLinkHint = false
    @Published private(set) var experimentalSupportEnabled: Bool

    /// The disconnect reason used when experimental support is switched off
    /// for a Gen 5 band. The band link reads it as something to fix, not as
    /// a link that is coming back.
    nonisolated static let experimentalSupportOffReason = "Experimental support is off. Turn it on to reconnect this band."

    var bandModelName: String? {
        guard provisionedIdentifier != nil else { return nil }
        switch activeBandModel {
        case .whoop4: return "WHOOP 4.0"
        case .whoop5: return "WHOOP 5.0"
        case .whoopMG: return "WHOOP MG"
        case .unknownGen5: return "WHOOP 5.0 or MG"
        }
    }

    var bandIsExperimental: Bool { provisionedIdentifier != nil && activeBandModel != .whoop4 }

    /// How long a known band may take to answer before the surface stops
    /// waiting and reports the link as it stands.
    nonisolated static let bandLinkGraceSeconds: TimeInterval = 10

    private(set) var provisioning: any LooprAccessoryProvisioningFlow
    private(set) var runtimeFactory: any LooprBluetoothRuntimeFactory

    private var runtime: (any LooprBluetoothAdoptionRuntime)? {
        didSet { runtimeHandle.bind(runtimeBindingReady ? runtime as? any LooprDeviceCenterRuntime : nil) }
    }
    private var activeBandModel: BandModel = .whoop4 {
        didSet { if activeBandModel != oldValue { syncPresentation() } }
    }
    private weak var backgroundHealthSync: (any LooprBackgroundHealthSynchronizing)?
    private let backgroundBudget: LooprDerivationBudget
    private var runtimeBindingReady = false {
        didSet {
            guard runtimeBindingReady != oldValue else { return }
            runtimeHandle.bind(runtimeBindingReady ? runtime as? any LooprDeviceCenterRuntime : nil)
            syncLaunchGate()
            if runtimeBindingReady { scheduleLinkActivityRefresh() }
        }
    }
    /// True while the band offloads history, read from the runtime because
    /// the app's link state does not carry it.
    private var isSyncingHistory = false
    /// True while a pull to refresh runs its bounded sync.
    private var isManualSyncing = false
    private var linkActivityTask: Task<Void, Never>?
    private var historyCommitObserver: Task<Void, Never>?
    private var runtimeEventsTask: Task<Void, Never>?
    private var launchInspectionTask: Task<Void, Never>?
    private var runtimeLifecycleTail: Task<Void, Never>?
    private var runtimeLifecycleSequence: UInt64 = 0
    private var bandLinkGraceTask: Task<Void, Never>?
    private let startupRecovery: (@MainActor () throws -> BluetoothApplicationDependencies)?
    private var startupReadiness: (@Sendable () async throws -> Void)?
    private let betaConsentStore: UserDefaultsBetaConsentStore

    init(
        provisioning: any LooprAccessoryProvisioningFlow,
        runtimeFactory: any LooprBluetoothRuntimeFactory,
        startupError: String? = nil,
        startupRecovery: (@MainActor () throws -> BluetoothApplicationDependencies)? = nil,
        startupReadiness: (@Sendable () async throws -> Void)? = nil,
        backgroundBudget: LooprDerivationBudget = .shared,
        betaConsentStore: UserDefaultsBetaConsentStore = UserDefaultsBetaConsentStore(),
        bandLinkGrace: TimeInterval = BluetoothApplicationModel.bandLinkGraceSeconds
    ) {
        self.provisioning = provisioning
        self.runtimeFactory = runtimeFactory
        self.bandLink = BandLinkPresentation(grace: bandLinkGrace)
        self.startupFailureMessage = startupError
        self.startupRecovery = startupRecovery
        self.startupReadiness = startupReadiness
        self.backgroundBudget = backgroundBudget
        self.betaConsentStore = betaConsentStore
        self.experimentalSupportEnabled = betaConsentStore.load().isGranted
        syncPresentation()
        syncLaunchGate()
        // Each committed batch is a cue that the band is offloading. The
        // runtime does not announce the offload flag itself.
        historyCommitObserver = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: looprHealthHistoryCommitted) {
                guard let self else { return }
                self.scheduleLinkActivityRefresh()
            }
        }
    }


    static func production() -> BluetoothApplicationModel {
        do {
            let dependencies = try makeProductionDependencies()
            return BluetoothApplicationModel(
                provisioning: dependencies.provisioning,
                runtimeFactory: dependencies.runtimeFactory,
                startupReadiness: dependencies.startupReadiness
            )
        } catch {
            let fallbackStore = UnavailableBluetoothAdoptionStore(error: error)
            #if canImport(AccessorySetupKit) && os(iOS)
            let client = AccessorySetupKitClient()
            #else
            let client = UnavailableAccessorySetupClient()
            #endif
            let controller = AccessoryProvisioningController(
                client: client, store: fallbackStore,
                experimentalSupportEnabled: { UserDefaultsBetaConsentStore().load().isGranted }
            )
            return BluetoothApplicationModel(
                provisioning: AccessoryProvisioningFlowAdapter(controller: controller),
                runtimeFactory: FailingBluetoothRuntimeFactory(error: error),
                startupError: startupMessage(for: error),
                startupRecovery: { try makeProductionDependencies() }
            )
        }
    }

    private static func makeProductionDependencies() throws -> BluetoothApplicationDependencies {
        let store = DeferredProductionBluetoothStore(url: try ProductionBluetoothAdoptionStore.historyDatabaseURL())
        #if canImport(AccessorySetupKit) && os(iOS)
        let client = AccessorySetupKitClient()
        #else
        let client = UnavailableAccessorySetupClient()
        #endif
        let controller = AccessoryProvisioningController(
            client: client, store: store,
            experimentalSupportEnabled: { UserDefaultsBetaConsentStore().load().isGranted }
        )
        let provisioning = AccessoryProvisioningFlowAdapter(controller: controller)
        #if canImport(CoreBluetooth)
        let factory = CoreBluetoothRuntimeFactoryAdapter(store: store)
        #else
        let factory = FailingBluetoothRuntimeFactory(
            error: ProductionBluetoothStoreError.applicationSupportUnavailable
        )
        #endif
        return BluetoothApplicationDependencies(
            provisioning: provisioning,
            runtimeFactory: factory,
            startupReadiness: { try await store.ready() }
        )
    }

    private static func startupMessage(for error: Error) -> String {
        "Loopr could not open its protected history store: \(error.localizedDescription)"
    }

    var canShowMainSurface: Bool {
        provisionedIdentifier != nil && status.isProvisioned
    }

    var canReportStrapConnected: Bool {
        status.isConnected && hasSharedProductRuntimeCapabilities
    }

    /// Pairing can be offered from the main surface only while no accessory is
    /// provisioned and no picker or explanation is already in progress.
    var canOfferPairing: Bool {
        guard provisionedIdentifier == nil else { return false }
        return switch status {
        case .needsPairing, .cancelled, .removed, .failed:
            true
        default:
            false
        }
    }

    var hasSharedProductRuntimeCapabilities: Bool {
        runtimeBindingReady
            && runtime is any LooprHeartLiveRuntime
            && runtime is any LooprDeviceCenterRuntime
    }

    /// Whether RootGate may construct the production shell. If no accessory
    /// is provisioned (or runtime construction failed), the shell is still
    /// allowed to render its explicit fail-closed unavailable states. During
    /// an in-flight paired launch, however, this remains false until the
    /// shared runtime is installed so feature StateObjects cannot capture a
    /// permanently nil live seam.
    var isMainSurfaceReady: Bool {
        didFinishLaunchInspection
            && (hasSharedProductRuntimeCapabilities || !status.isProvisioned)
    }

    /// The single shared runtime seam consumed by Heart and Device Center.
    /// It is nil until the authoritative provisioning flow installs a runtime,
    /// and becomes nil again after pairing removal stops that runtime.
    var sharedBluetoothRuntime: (any LooprDeviceCenterRuntime)? {
        guard runtimeBindingReady else { return nil }
        return runtime as? any LooprDeviceCenterRuntime
    }

    /// Called from the launch task.  This performs ASK inspection only; the
    /// CoreBluetooth runtime factory is not touched until an identifier is
    /// returned by the authoritative ASK/store reconciliation.
    func inspectProvisioningOnLaunch() async {
        if didFinishLaunchInspection { return }
        if let launchInspectionTask {
            await launchInspectionTask.value
            return
        }
        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.performLaunchInspection()
        }
        launchInspectionTask = task
        await task.value
    }

    func retryStartup() async {
        guard let startupRecovery else { return }
        launchInspectionTask?.cancel()
        launchInspectionTask = nil
        didFinishLaunchInspection = false
        status = .checkingProvisioning
        do {
            let dependencies = try startupRecovery()
            provisioning = dependencies.provisioning
            runtimeFactory = dependencies.runtimeFactory
            startupReadiness = dependencies.startupReadiness
            startupFailureMessage = nil
            await inspectProvisioningOnLaunch()
        } catch {
            let message = Self.startupMessage(for: error)
            startupFailureMessage = message
            status = .failed(message)
            didFinishLaunchInspection = true
        }
    }

    private func performLaunchInspection() async {
        defer {
            didFinishLaunchInspection = true
            launchInspectionTask = nil
        }
        if let startupFailureMessage {
            status = .failed(startupFailureMessage)
            return
        }
        status = .checkingProvisioning
        do {
            try await startupReadiness?()
        } catch {
            let message = Self.startupMessage(for: error)
            startupFailureMessage = message
            status = .failed(message)
            return
        }
        await apply(await provisioning.inspectExisting())
    }

    func userTappedPair() async {
        #if DEBUG
        Self.pairingLogger.debug("pairing request received; status=\(self.status.logCase, privacy: .public)")
        #endif
        guard runtime == nil else {
            #if DEBUG
            Self.pairingLogger.debug("pairing request ignored; runtime already installed")
            #endif
            return
        }
        let outcome = await provisioning.userTappedPair()
        #if DEBUG
        let outcomeCase = String(String(describing: outcome).prefix(while: { $0 != "(" }))
        Self.pairingLogger.debug("pairing request returned; outcome=\(outcomeCase, privacy: .public)")
        #endif
        switch outcome {
        case .explanationRequired:
            isExplanationPresented = true
            status = .explanationRequired
        case .alreadyProvisioned(let identifier), .provisioned(let identifier):
            isExplanationPresented = false
            await installRuntime(identifier)
        case .pickerAlreadyPresented:
            isExplanationPresented = false
            status = .pickerPresented
        default:
            await apply(outcome)
        }
    }

    func continueAfterExplanation() async {
        guard isExplanationPresented else { return }
        isExplanationPresented = false
        status = .pickerPresented
        await apply(await provisioning.continueAfterExplanation())
    }

    func cancelExplanation() {
        guard isExplanationPresented else { return }
        isExplanationPresented = false
        status = .cancelled
    }

    func removePairing() async {
        await enqueueRuntimeLifecycle { [weak self] in
            await self?.removePairingNow()
        }
    }

    func setExperimentalSupport(_ enabled: Bool) async throws {
        _ = try betaConsentStore.setEnabled(enabled)
        experimentalSupportEnabled = betaConsentStore.load().isGranted
        if !experimentalSupportEnabled, activeBandModel != .whoop4 {
            await enqueueRuntimeLifecycle { [weak self] in
                try? await self?.stopRuntimeNow()
                self?.status = .disconnected(
                    self?.provisionedIdentifier,
                    reason: Self.experimentalSupportOffReason
                )
            }
        } else if experimentalSupportEnabled, activeBandModel != .whoop4,
                  runtime == nil, let provisionedIdentifier {
            await installRuntime(provisionedIdentifier)
        }
    }

    /// Pair again is app-level only. Deprovisioning the accessory first is
    /// what makes the picker show the strap a second time and restores the
    /// background relaunch the OS grants provisioned accessories.
    func rePair() async {
        await removePairing()
        await userTappedPair()
    }

    func enterForeground() async {
        await inspectProvisioningOnLaunch()
        guard runtimeBindingReady, let runtime else { return }
        await runtime.enterForeground()
        applyRuntimeState(await runtime.state())
    }

    func enterBackground() async {
        await inspectProvisioningOnLaunch()
        guard runtimeBindingReady, let runtime else { return }
        await runtime.enterBackground()
    }

    func bindBackgroundHealthSync(_ healthSync: any LooprBackgroundHealthSynchronizing) {
        backgroundHealthSync = healthSync
    }

    func runBackgroundTask(identifier: String) async -> Bool {
        // iOS can hand the window to a process it launched seconds ago, while
        // provisioning inspection is still in flight and no runtime is bound
        // yet. Returning false there wasted the window and told iOS the work
        // failed, which is the worst possible input to its scheduling budget.
        await inspectProvisioningOnLaunch()
        guard runtimeBindingReady, let runtime, let backgroundHealthSync else { return false }
        let kind: BackgroundRunKind = identifier == LooprBluetoothBackgroundTaskID.refresh
            ? .appRefresh
            : .processing
        let success = await runtime.runBackground(kind: kind)
        applyRuntimeState(await runtime.state())
        guard success else { return false }
        // A processing window is the cheapest CPU Loopr will ever get: iOS
        // picked the moment, and it is the one place a derivation is allowed
        // to ignore the half-hour spacing. An app refresh gets thirty seconds
        // and stays on the normal budget.
        if kind == .processing {
            await backgroundBudget.beginProcessingWindow()
            await backgroundHealthSync.synchronize()
            await backgroundBudget.endProcessingWindow()
        } else {
            await backgroundHealthSync.synchronize()
        }
        return success
    }

    func expireBackgroundTask() async {
        guard runtimeBindingReady, let runtime else { return }
        await runtime.expireBackground()
        applyRuntimeState(await runtime.state())
    }

    /// Returns the already-running shared SyncKit runtime when pairing has
    /// completed. Heart never constructs or owns a second Bluetooth session.
    func heartLiveRuntime() -> (any LooprHeartLiveRuntime)? {
        guard runtimeBindingReady else { return nil }
        return runtime as? any LooprHeartLiveRuntime
    }

    /// Called only by PersistentOnboardingDataEffects' first deletion phase.
    /// The lifecycle queue proves stop/release and volatile clearing complete
    /// before product/history files are touched.
    func stopAndClearRuntimeForDataDeletion() async throws {
        var capturedError: Error?
        await enqueueRuntimeLifecycle { [weak self] in
            guard let self else { return }
            let identifier = self.provisionedIdentifier
            self.status = .removing(identifier)
            do {
                try await self.stopRuntimeNow(clearRuntimeData: true)
                self.provisionedIdentifier = nil
                self.status = .removed
            } catch {
                capturedError = error
                self.status = .failed(error.localizedDescription)
            }
        }
        if let capturedError { throw capturedError }
    }

    private func apply(_ outcome: AccessoryProvisioningOutcome) async {
        switch outcome {
        case .alreadyProvisioned(let identifier), .provisioned(let identifier):
            isExplanationPresented = false
            await installRuntime(identifier)
        case .explanationRequired:
            isExplanationPresented = true
            status = .explanationRequired
        case .pickerPresented, .pickerAlreadyPresented:
            isExplanationPresented = false
            status = .pickerPresented
        case .cancelled:
            isExplanationPresented = false
            status = .cancelled
        case .noResult:
            provisionedIdentifier = nil
            status = .needsPairing
        case .removed:
            provisionedIdentifier = nil
            status = .removed
        case .failed(let reason):
            status = .failed(reason)
        }
    }

    private func installRuntime(_ identifier: UUID) async {
        await enqueueRuntimeLifecycle { [weak self] in
            await self?.installRuntimeNow(identifier)
        }
    }

    private func installRuntimeNow(_ identifier: UUID) async {
        provisionedIdentifier = identifier
        otherAppLinkHint = false
        status = .preparing(identifier)
        beginBandLinkGrace()
        try? await stopRuntimeNow()

        do {
            let name = await provisioning.provisionedDisplayName()
            let service = await provisioning.provisionedServiceUUID()
            let model: BandModel
            if service == GATTProfile.gen5.service ||
                (service == nil && (name == "WHOOP 5.0" || name == "WHOOP MG")) {
                switch name?.uppercased() {
                case "WHOOP 5.0": model = .whoop5
                case "WHOOP MG": model = .whoopMG
                default: model = .unknownGen5
                }
            } else {
                model = .whoop4
            }
            activeBandModel = model
            guard model == .whoop4 || betaConsentStore.load().isGranted else {
                status = .disconnected(
                    identifier,
                    reason: Self.experimentalSupportOffReason
                )
                endBandLinkGrace()
                return
            }
            let runtime = try await runtimeFactory.makeRuntime(for: identifier, model: model)
            guard runtime is any LooprHeartLiveRuntime,
                  runtime is any LooprDeviceCenterRuntime else {
                await runtime.stop()
                throw LooprBluetoothRuntimeCompositionError.missingProductCapabilities
            }
            self.runtime = runtime
            runtimeBindingReady = false
            let stream = await runtime.events()
            runtimeEventsTask?.cancel()
            runtimeEventsTask = Task { [weak self] in
                for await state in stream {
                    guard !Task.isCancelled else { return }
                    self?.applyRuntimeState(state)
                }
            }
            await runtime.start()
            applyRuntimeState(await runtime.state())
            runtimeBindingReady = true
            runtimeGeneration &+= 1
        } catch {
            self.runtime = nil
            runtimeBindingReady = false
            #if DEBUG
            Self.pairingLogger.error("runtime install failed: \(String(describing: error), privacy: .public)")
            #endif
            status = .failed(Self.runtimeInstallFailureCopy)
            endBandLinkGrace()
        }
    }

    private func removePairingNow() async {
        let identifier = provisionedIdentifier
        otherAppLinkHint = false
        status = .removing(identifier)
        endBandLinkGrace()
        try? await stopRuntimeNow()
        let outcome = await provisioning.removeProvisionedAccessory()
        switch outcome {
        case .removed:
            provisionedIdentifier = nil
            status = .removed
        case .failed(let reason):
            status = .failed(reason)
        case .alreadyProvisioned(let identifier), .provisioned(let identifier):
            await installRuntimeNow(identifier)
        case .explanationRequired:
            isExplanationPresented = true
            status = .explanationRequired
        case .pickerPresented, .pickerAlreadyPresented:
            status = .pickerPresented
        case .cancelled:
            status = .cancelled
        case .noResult:
            provisionedIdentifier = nil
            status = .needsPairing
        }
    }

    private func stopRuntimeNow(clearRuntimeData: Bool = false) async throws {
        runtimeEventsTask?.cancel()
        runtimeEventsTask = nil
        guard let runtime else { return }
        self.runtime = nil
        runtimeBindingReady = false
        runtimeGeneration &+= 1
        await runtime.stop()
        if clearRuntimeData,
           let runtimeDataDeleter = runtime as? any PersistentDataDeletionDeleter {
            try await runtimeDataDeleter.deleteAll()
        }
    }

    private func enqueueRuntimeLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        runtimeLifecycleSequence &+= 1
        let sequence = runtimeLifecycleSequence
        let predecessor = runtimeLifecycleTail
        let task = Task { @MainActor in
            await predecessor?.value
            await operation()
        }
        runtimeLifecycleTail = task
        await task.value
        if runtimeLifecycleSequence == sequence {
            runtimeLifecycleTail = nil
        }
    }

    private func applyRuntimeState(_ state: LooprBluetoothRuntimeState) {
        let identifier = provisionedIdentifier
        let wasConnected = status.isConnected
        defer { scheduleLinkActivityRefresh() }
        switch state {
        case .idle:
            // A link that drops mid-session is given the same grace as one
            // coming up at launch, so a reconnect that takes a second does not
            // flash a status card over the rings.
            if wasConnected { beginBandLinkGrace() }
            setStatusIfChanged(.disconnected(identifier, reason: "Your band isn't connected yet."))
        case .retrieving:
            setStatusIfChanged(.retrieving)
        case .scanning:
            setStatusIfChanged(.scanning)
        case .connecting:
            setStatusIfChanged(.connecting)
        case .discovering:
            setStatusIfChanged(.discovering)
        case .subscribing:
            setStatusIfChanged(.subscribing)
        case .ready(let peripheral):
            if provisionedIdentifier != peripheral { provisionedIdentifier = peripheral }
            setStatusIfChanged(.connected(peripheral))
            endBandLinkGrace()
            refreshOtherAppLinkHint()
        case .disconnected(let reason):
            if wasConnected { beginBandLinkGrace() }
            setStatusIfChanged(.disconnected(identifier, reason: reason))
        case .bluetoothOff:
            setStatusIfChanged(.bluetoothOff(identifier))
            // Bluetooth being off is a resolved answer, and one the person can
            // act on. There is nothing left to wait for.
            endBandLinkGrace()
        case .failed(let reason):
            setStatusIfChanged(.failed(reason))
            endBandLinkGrace()
        }
    }

    /// Shown when the Bluetooth session for a paired band cannot start. The
    /// underlying error is for the debug log, not for the person.
    nonisolated static let runtimeInstallFailureCopy = "Loopr couldn't start the Bluetooth connection to your band. Close Loopr and open it again."

    // MARK: Band link presentation

    private func syncPresentation() {
        bandLink.update(
            status: status,
            isPaired: provisionedIdentifier != nil,
            isSyncing: isSyncingHistory || isManualSyncing,
            canOfferPairing: canOfferPairing,
            bandModelName: bandModelName,
            bandIsExperimental: bandIsExperimental
        )
    }

    private func syncLaunchGate() {
        launchGate.update(startupFailureMessage: startupFailureMessage, isMainSurfaceReady: isMainSurfaceReady)
    }

    /// Reads the runtime's offload flag, battery and sync time. Calls inside
    /// one window share a single read, because the runtime emits a state for
    /// nearly every frame while it offloads.
    private func scheduleLinkActivityRefresh(after delay: Duration = .milliseconds(300)) {
        guard linkActivityTask == nil else { return }
        linkActivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            defer { self.linkActivityTask = nil }
            guard self.runtimeBindingReady,
                  let runtime = self.runtime as? any LooprDeviceCenterRuntime else {
                self.setSyncingHistory(false)
                return
            }
            let state = await runtime.runtimeState()
            guard self.runtimeBindingReady, (self.runtime as AnyObject?) === (runtime as AnyObject) else { return }
            self.applyLinkActivity(state)
        }
    }

    lazy var heartRateSharing = LooprHeartRateSharingService(runtime: runtimeHandle)

    private func applyLinkActivity(_ state: BluetoothAdoptionRuntimeState) {
        Task { await heartRateSharing.reconcile() }
        let syncing = state.historyOffloadActive && status.isConnected
        setSyncingHistory(syncing)
        bandLink.updateDetails(
            batteryPercent: state.batteryPercentage.map { Int($0.rounded()) },
            charging: state.charging,
            onWrist: state.onWrist,
            lastSyncedAt: state.completedSyncAt ?? state.historyCommitAt
        )
        // The flag can drop without a state event, so an offload that is
        // running is checked again until it ends.
        if syncing {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.scheduleLinkActivityRefresh(after: .zero)
            }
        }
    }

    private func setSyncingHistory(_ syncing: Bool) {
        guard isSyncingHistory != syncing else { return }
        isSyncingHistory = syncing
        syncPresentation()
    }

    /// Pull to refresh: a bounded history sync while the band is connected.
    /// Returns false when there was nothing to sync with.
    @discardableResult
    func syncNow(maxDuration: TimeInterval = 15) async -> Bool {
        guard runtimeBindingReady, status.isConnected, !isManualSyncing,
              let runtime = runtime as? any LooprDeviceCenterRuntime else { return false }
        isManualSyncing = true
        syncPresentation()
        let success = await runtime.performManualSync(maxDuration: maxDuration)
        isManualSyncing = false
        syncPresentation()
        scheduleLinkActivityRefresh(after: .zero)
        return success
    }

    private func refreshOtherAppLinkHint() {
        guard let runtime else { return }
        Task { @MainActor [weak self] in
            let observed = await runtime.otherAppLinkObserved()
            guard let self, self.runtime === runtime else { return }
            if self.otherAppLinkHint != observed { self.otherAppLinkHint = observed }
        }
    }

    private func setStatusIfChanged(_ next: BluetoothApplicationStatus) {
        if status != next { status = next }
    }

    /// A known band is given one grace window to answer, both when its runtime
    /// is installed and when an established link drops. While the window runs,
    /// Today stays quiet instead of reporting the band as not connected. The
    /// window only restarts on a fresh drop, so a band that keeps failing to
    /// come back still surfaces after one window.
    private func beginBandLinkGrace() {
        bandLinkGraceTask?.cancel()
        isResolvingBandLink = true
        bandLinkGraceTask = Task { @MainActor [weak self] in
            let seconds = BluetoothApplicationModel.bandLinkGraceSeconds
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.endBandLinkGrace()
        }
    }

    private func endBandLinkGrace() {
        bandLinkGraceTask?.cancel()
        bandLinkGraceTask = nil
        isResolvingBandLink = false
    }
}

struct BluetoothModelRuntimeDataDeleter: PersistentDataDeletionDeleter {
    let model: BluetoothApplicationModel

    nonisolated var storeName: String {
        "bluetooth.runtime-cache-and-diagnostics"
    }

    func deleteAll() async throws {
        try await model.stopAndClearRuntimeForDataDeletion()
    }
}

/// One production store composes the durable ASK identifier with the same
/// SQLite history/ACK ledger consumed by SyncKit. This prevents provisioning,
/// reconnect, and history from silently using unrelated stores.
final class ProductionBluetoothAdoptionStore: BluetoothAdoptionStore, HistoryBatchAcknowledger, @unchecked Sendable {
    private let provisioning: UserDefaultsAccessoryProvisioningStore
    private let history: SQLiteHistoryBatchStore
    private let database: StorageDatabase

    init(
        database: StorageDatabase,
        defaults: UserDefaults = .standard
    ) {
        self.provisioning = UserDefaultsAccessoryProvisioningStore(defaults: defaults)
        self.history = SQLiteHistoryBatchStore(database: database)
        self.database = database
    }

    static func make(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ProductionBluetoothAdoptionStore {
        let url = try historyDatabaseURL(fileManager: fileManager)
        let database = try LooprProductionDatabases.shared.database(
            at: url, applicationVersion: StorageDatabase.defaultApplicationVersion
        )
        return ProductionBluetoothAdoptionStore(database: database, defaults: defaults)
    }

    static func historyDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ProductionBluetoothStoreError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent("Loopr", isDirectory: true)
        return directory.appendingPathComponent("loopr.sqlite", isDirectory: false)
    }

    func loadBluetoothIdentifier() async -> UUID? {
        await provisioning.loadBluetoothIdentifier()
    }

    func saveBluetoothIdentifier(_ identifier: UUID) async throws {
        try await provisioning.saveBluetoothIdentifier(identifier)
    }

    func removeBluetoothIdentifier() async throws {
        try await provisioning.removeBluetoothIdentifier()
    }

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        try await history.commit(
            records: records,
            archived: archived,
            boundary: boundary,
            diagnostics: diagnostics
        )
    }

    func markAcknowledged(batchID: String, updatedAt: Int64) async throws {
        try await history.markAcknowledged(batchID: batchID, updatedAt: updatedAt)
        // New history is the only thing that earns a background derivation.
        // Without this the off-screen budget never unlocks, and with it a
        // burst of batches still unlocks exactly one pass per consumer.
        await LooprDerivationBudget.shared.noteHistoryCommit()
        NotificationCenter.default.post(name: looprHealthHistoryCommitted, object: nil)
        // Heart alerts react here rather than to the notification above: the
        // notification's subscribers need a scene, and a headless Bluetooth
        // relaunch has none. The runtime coalesces a burst into one pass.
        await LooprHeartAlertsRuntime.shared.historyCommitted(database: database)
    }
}

/// StorageDatabase opens SQLite and migrates it. Those disk operations must
/// finish before provisioning inspection, but they must not run inside
/// LooprApp.init() on the main thread. The history file is opened through
/// `LooprProductionDatabases`, so the product repositories reuse this open
/// instead of opening the file a second time, and its integrity check runs
/// after launch rather than inside the open.
private final class DeferredProductionBluetoothStore: BluetoothAdoptionStore, HistoryBatchAcknowledger, @unchecked Sendable {
    private let task: Task<ProductionBluetoothAdoptionStore, Error>

    init(url: URL) {
        // The product database opens in parallel, so the shell finds both
        // files ready when it builds its repositories.
        LooprProductionDatabases.shared.prewarmLaunchStores()
        task = Task.detached {
            let database = try LooprProductionDatabases.shared.database(
                at: url, applicationVersion: StorageDatabase.defaultApplicationVersion
            )
            return await MainActor.run { ProductionBluetoothAdoptionStore(database: database) }
        }
    }

    func ready() async throws { _ = try await task.value }

    func loadBluetoothIdentifier() async -> UUID? {
        guard let store = try? await task.value else { return nil }
        return await store.loadBluetoothIdentifier()
    }

    func saveBluetoothIdentifier(_ identifier: UUID) async throws {
        try await task.value.saveBluetoothIdentifier(identifier)
    }

    func removeBluetoothIdentifier() async throws {
        try await task.value.removeBluetoothIdentifier()
    }

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        try await task.value.commit(
            records: records, archived: archived, boundary: boundary, diagnostics: diagnostics
        )
    }

    func markAcknowledged(batchID: String, updatedAt: Int64) async throws {
        try await task.value.markAcknowledged(batchID: batchID, updatedAt: updatedAt)
    }
}

enum ProductionBluetoothStoreError: Error, LocalizedError, Sendable {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable for Loopr's Bluetooth history store."
        }
    }
}

private struct UnavailableBluetoothAdoptionStore: BluetoothAdoptionStore, @unchecked Sendable {
    let error: Error

    func loadBluetoothIdentifier() async -> UUID? { nil }
    func saveBluetoothIdentifier(_ identifier: UUID) async throws { throw error }
    func removeBluetoothIdentifier() async throws { throw error }
    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        throw error
    }
}

private struct FailingBluetoothRuntimeFactory: LooprBluetoothRuntimeFactory, @unchecked Sendable {
    let error: Error

    func makeRuntime(for identifier: UUID) async throws -> any LooprBluetoothAdoptionRuntime {
        throw error
    }
}

#if !canImport(AccessorySetupKit) || !os(iOS)
private struct UnavailableAccessorySetupClient: AccessorySetupClient {
    func provisionedAccessories() async -> [ProvisionedAccessory] { [] }
    func showPicker(for descriptor: AccessoryDiscoveryDescriptor) async throws -> ProvisionedAccessory? {
        throw AccessorySetupError.unavailable
    }
    func removeAccessory(_ accessory: ProvisionedAccessory) async throws {}
}
#endif
