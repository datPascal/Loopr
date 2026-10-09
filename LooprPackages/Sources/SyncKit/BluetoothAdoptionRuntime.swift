import Foundation
import BluetoothKit
import ProtocolKit
import StorageKit

/// The single store seam used by the adoption runtime.
///
/// Provisioning and history persistence intentionally share one injected value
/// so a connection cannot accidentally read an accessory identifier from one
/// store while committing history into another store.
public protocol BluetoothAdoptionStore: AccessoryProvisioningStore, HistoryBatchStore, Sendable {}

/// One clock is injected into the complete runtime.  The date/interval half is
/// used by SyncKit and the monotonic half is used by BluetoothKit's connection
/// watchdogs.  Keeping both views on one value prevents test and production
/// paths from silently using different notions of time.
public protocol BluetoothAdoptionClock: BLEClock, BluetoothClock, Sendable {}

public struct SystemBluetoothAdoptionClock: BluetoothAdoptionClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public var supportsAutonomousSleep: Bool { true }

    public func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// A compact, truthful snapshot of the composed runtime.  `setupReady` is
/// the GATT notification barrier; `setupComplete` additionally proves that
/// SET_CLOCK/GET_CLOCK and all five initialization writes have completed.
public struct BluetoothAdoptionRuntimeState: Equatable, Sendable {
    public let running: Bool
    public let generation: UInt64?
    public let connection: BluetoothConnectionState
    public let setupReady: Bool
    public let setupComplete: Bool
    public let radioState: ConnectionRadioState
    public let health: ConnectionHealthReport
    public let pendingReconnect: ReconnectRequest?
    public let liveConsumerCount: Int
    public let pendingHistoryReplayCount: Int
    public let validFrameCount: UInt64
    public let corruptFrameCount: UInt64
    public let writeTimeoutCount: UInt64
    public let lastError: String?
    public let charging: Bool?
    public let onWrist: Bool?
    public let batteryPercentage: Double?
    public let advertisingName: String?
    public let lastPacketAt: Date?
    public let historyCommitAt: Date?
    public let completedSyncAt: Date?
    public let historyOffloadActive: Bool
    public let bondRepairRequired: BluetoothBondRepairReason?
    public let bandModel: BandModel?

    public init(
        running: Bool,
        generation: UInt64?,
        connection: BluetoothConnectionState,
        setupReady: Bool,
        setupComplete: Bool,
        radioState: ConnectionRadioState,
        health: ConnectionHealthReport,
        pendingReconnect: ReconnectRequest?,
        liveConsumerCount: Int,
        pendingHistoryReplayCount: Int,
        validFrameCount: UInt64,
        corruptFrameCount: UInt64,
        writeTimeoutCount: UInt64,
        lastError: String?,
        charging: Bool? = nil,
        onWrist: Bool? = nil,
        batteryPercentage: Double? = nil,
        advertisingName: String? = nil,
        lastPacketAt: Date? = nil,
        historyCommitAt: Date? = nil,
        completedSyncAt: Date? = nil,
        historyOffloadActive: Bool = false,
        bondRepairRequired: BluetoothBondRepairReason? = nil,
        bandModel: BandModel? = nil
    ) {
        self.running = running
        self.generation = generation
        self.connection = connection
        self.setupReady = setupReady
        self.setupComplete = setupComplete
        self.radioState = radioState
        self.health = health
        self.pendingReconnect = pendingReconnect
        self.liveConsumerCount = liveConsumerCount
        self.pendingHistoryReplayCount = pendingHistoryReplayCount
        self.validFrameCount = validFrameCount
        self.corruptFrameCount = corruptFrameCount
        self.writeTimeoutCount = writeTimeoutCount
        self.lastError = lastError
        self.charging = charging
        self.onWrist = onWrist
        self.batteryPercentage = batteryPercentage
        self.advertisingName = advertisingName
        self.lastPacketAt = lastPacketAt
        self.historyCommitAt = historyCommitAt
        self.completedSyncAt = completedSyncAt
        self.historyOffloadActive = historyOffloadActive
        self.bondRepairRequired = bondRepairRequired
        self.bandModel = bandModel
    }

    public var needsRepair: Bool { bondRepairRequired != nil }
    public var autoReconnectPaused: Bool { bondRepairRequired != nil }
}

/// The runtime-owned live command adapter.  Foreground/background transitions
/// are aggregate operations because Edge's WHOOP path controls optical, R10,
/// IMU, and compact-HR streams as one paced sequence.  Every command still
/// enters the same generation-pinned writer; no raw opcode is synthesized.
private actor AdoptionLiveSequenceAllocator {
    private var allocator = SeqAllocator()

    func next() -> UInt8 { allocator.nextLive() }
    func reset() { allocator.reset() }
}

private actor AdoptionGenerationBox {
    private var generation: UInt64?

    func set(_ generation: UInt64?) { self.generation = generation }
    func value() -> UInt64? { generation }
}

/// The runtime owns physical disconnects through BluetoothConnectionSession.
/// The command writer still needs a disconnect hook to invalidate queued
/// commands, but forwarding that hook to the native transport would issue a
/// second CoreBluetooth disconnect for the same callback. Keep the command
/// seam firewalled while making its disconnect operation a state-only no-op.
private struct AdoptionCommandTransport: CommandWriteTransport {
    let base: any BLETransport

    func writeCommand(_ data: Data) async throws {
        try CommandFirewall.validateEncodedFrame(data)
        try await base.write(data, to: HarvardBluetoothProfile.command)
    }

    func disconnect() async {}
}

private enum AdoptionLiveWireMode: Equatable, Sendable {
    case none
    case full
    case heartRateOnly
}

private actor AdoptionLiveWireController {
    let writer: SerializedGenerationPinnedWriter
    let generation: AdoptionGenerationBox
    let sequences: AdoptionLiveSequenceAllocator
    let clock: any BLEClock
    private var mode: AdoptionLiveWireMode = .none
    /// Mirrors the runtime's degradation latch. The runtime owns the lifetime
    /// of the latch; the controller only reads it when choosing a wire state.
    private var degraded = false

    init(
        writer: SerializedGenerationPinnedWriter,
        generation: AdoptionGenerationBox,
        sequences: AdoptionLiveSequenceAllocator,
        clock: any BLEClock
    ) {
        self.writer = writer
        self.generation = generation
        self.sequences = sequences
        self.clock = clock
    }

    func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws {
        // Compatibility path for callers that hold only LiveStreamCommandSink.
        // The LiveStreamManager uses reconcileLiveStreams for this controller,
        // but keeping this mapping closed prevents an unsafe fallback.
        switch kind {
        case .compactHeartRateRR:
            try await write(.toggleRealtimeHR(sequence: next(), enabled: enabled))
        case .realtimeRaw:
            try await write(.sendR10R11Realtime(sequence: next(), enabled: enabled))
        case .realtimeIMU:
            try await write(.toggleIMUMode(sequence: next(), enabled: enabled))
        }
    }

    func reconcile(
        previousEffectiveKinds _: Set<LiveStreamKind>,
        requestedKinds: Set<LiveStreamKind>,
        effectiveKinds: Set<LiveStreamKind>,
        policy: LiveStreamBackgroundPolicy
    ) async throws {
        let target: AdoptionLiveWireMode
        if effectiveKinds.isEmpty || requestedKinds.isEmpty {
            target = .none
        } else if policy == .ordinaryBackground {
            target = .heartRateOnly
        } else if effectiveKinds.isSubset(of: [.compactHeartRateRR]) {
            // Arming the full flood for a compact heart rate lease puts raw
            // R10/R11 and IMU packets on the wire that LiveStreamManager then
            // drops because nobody consumes them. That load is what the band
            // pays for in supervision timeouts, so derive the wire state from
            // the leases rather than from the policy alone.
            target = .heartRateOnly
        } else if degraded {
            // Edge's standardHrFallback: a link that has already proven noisy
            // this session never goes back above heart rate only.
            target = .heartRateOnly
        } else {
            // Edge's foreground enable path arms the complete live set when a
            // feature actually holds a raw or IMU lease.
            target = .full
        }
        guard target != mode else { return }

        // On a real WHOOP 4.0 the stream-off toggles stop a historical drain
        // in flight: the band ends the burst and sends nothing more. Hold
        // any step down until the drain is over. Arming heart rate from
        // nothing sends no disables, so it may go ahead.
        let sendsDisables = target == .none || (target == .heartRateOnly && mode == .full)
        if historyDrainActive, sendsDisables {
            heldStepDown = true
            return
        }

        switch target {
        case .none:
            try await disableAll()
        case .full:
            try await enableFull()
        case .heartRateOnly:
            try await enableHeartRateOnly(from: mode)
        }
        mode = target
    }

    private var historyDrainActive = false
    private var heldStepDown = false

    /// Returns true when a step down was held and should now be replayed.
    func setHistoryDrainActive(_ active: Bool) -> Bool {
        historyDrainActive = active
        guard !active, heldStepDown else { return false }
        heldStepDown = false
        return true
    }

    func disableAllLiveStreams() async throws {
        guard mode != .none else { return }
        // Clear first. Teardown runs after the link is down, so the disable
        // writes throw; leaving `mode` armed made every later session skip
        // its enable writes and no live heart rate ever returned.
        mode = .none
        try await disableAll()
    }

    /// A new connection starts with every stream off on the band's side.
    /// The degradation latch deliberately survives, because a reconnect is
    /// usually the consequence of the noise that set it.
    ///
    /// The drain flag is cleared here too. A link that dropped in the middle of
    /// a historical drain used to leave it set, and every later step down was
    /// held forever, so the band kept streaming raw and IMU packets all night.
    func resetForNewGeneration() {
        heldStepDown = false
        historyDrainActive = false
        mode = .none
    }

    func setDegraded(_ value: Bool) {
        degraded = value
    }

    func currentMode() -> String {
        switch mode {
        case .none: return "none"
        case .full: return "full"
        case .heartRateOnly: return "heartRateOnly"
        }
    }

    func rearm(effectiveKinds: Set<LiveStreamKind>) async throws {
        guard mode != .none, !effectiveKinds.isEmpty else { return }
        try await write(.toggleRealtimeHR(sequence: next(), enabled: true))
        // A degraded link never re-asserts the raw stream on the 30 s cadence;
        // that re-assert is the periodic half of the flood.
        if mode == .full, !degraded {
            try await write(.sendR10R11Realtime(sequence: next(), enabled: true))
        }
    }

    private func enableFull() async throws {
        try await write(.toggleRealtimeHR(sequence: next(), enabled: true))
        try await pace(0.100)
        try await write(.sendR10R11Realtime(sequence: next(), enabled: true))
        try await pace(0.100)
        try await write(.toggleIMUMode(sequence: next(), enabled: true))
        try await pace(0.100)
        try await write(.enableOpticalData(sequence: next(), enabled: true))
    }

    private func enableHeartRateOnly(from previous: AdoptionLiveWireMode) async throws {
        try await write(.toggleRealtimeHR(sequence: next(), enabled: true))
        // On a fresh generation nothing else is armed, so there is nothing
        // to switch off. Edge's enable path sends no disables either, and
        // the four toggles below land in the middle of the historical drain
        // that INIT has just started.
        guard previous == .full else { return }
        try await pace(0.060)
        try await write(.toggleOpticalMode(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.enableOpticalData(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.sendR10R11Realtime(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.toggleIMUMode(sequence: next(), enabled: false))
    }

    private func disableAll() async throws {
        try await write(.toggleOpticalMode(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.enableOpticalData(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.sendR10R11Realtime(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.toggleIMUMode(sequence: next(), enabled: false))
        try await pace(0.060)
        try await write(.toggleRealtimeHR(sequence: next(), enabled: false))
    }

    private func next() async -> UInt8 { await sequences.next() }

    private func write(_ command: ProductionCommand) async throws {
        guard let generation = await generation.value() else {
            throw SerializedWriterError.noActiveGeneration
        }
        try await writer.write(command, generation: generation)
    }

    private func pace(_ interval: TimeInterval) async throws {
        try await clock.sleep(for: interval)
    }
}

private struct AdoptionLiveCommandSink: LiveStreamPolicyCommandSink {
    let controller: AdoptionLiveWireController

    func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws {
        try await controller.setLiveStream(kind, enabled: enabled)
    }

    func reconcileLiveStreams(
        previousEffectiveKinds: Set<LiveStreamKind>,
        requestedKinds: Set<LiveStreamKind>,
        effectiveKinds: Set<LiveStreamKind>,
        policy: LiveStreamBackgroundPolicy
    ) async throws {
        try await controller.reconcile(
            previousEffectiveKinds: previousEffectiveKinds,
            requestedKinds: requestedKinds,
            effectiveKinds: effectiveKinds,
            policy: policy
        )
    }

    func disableAllLiveStreams() async throws {
        try await controller.disableAllLiveStreams()
    }
}

/// Schedules one delayed reconnect task per request.  The scheduler never
/// performs a connect itself; the runtime callback consumes the request and
/// starts a fresh BluetoothConnectionSession generation.  Tasks are bounded by
/// the ReconnectController's one-pending-request rule.
private actor AdoptionReconnectScheduler: ReconnectScheduling {
    private let clock: any BLEClock
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var handler: (@Sendable (ReconnectRequest) async -> Void)?

    init(clock: any BLEClock) { self.clock = clock }

    func setHandler(_ handler: @escaping @Sendable (ReconnectRequest) async -> Void) {
        self.handler = handler
    }

    func scheduleReconnect(_ request: ReconnectRequest) async {
        tasks[request.id]?.cancel()
        let clock = self.clock
        tasks[request.id] = Task { [weak self] in
            do { try await clock.sleep(for: request.delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.fire(request)
        }
    }

    func cancelReconnect(_ request: ReconnectRequest) async {
        tasks.removeValue(forKey: request.id)?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(keepingCapacity: true)
    }

    private func fire(_ request: ReconnectRequest) async {
        tasks.removeValue(forKey: request.id)
        await handler?(request)
    }
}

private final class AdoptionBackgroundWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }
            result = value
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }

    func wait() async -> Bool {
        if let result = lock.withLock({ result }) { return result }
        return await withCheckedContinuation { continuation in
            let resume: Bool? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let resume { continuation.resume(returning: resume) }
        }
    }
}

/// Bridges CoreBluetooth restoration onto the runtime's own connection path.
///
/// The driver creates no second central owner and no second parser set of its
/// own; it hands both decisions back to the runtime actor, which already owns
/// the single `BluetoothConnectionSession`. The closures hold the runtime
/// weakly because the runtime owns the coordinator that owns this driver.
private struct AdoptionRestorationDriver: RestorationSessionDriver {
    let validateAction: @Sendable (AdoptionRestorationSnapshot) async -> AdoptionRestorationValidation
    let resumeAction: @Sendable (AdoptionRestorationResumeContext) async -> Void

    func validateOrRediscover(
        snapshot: AdoptionRestorationSnapshot,
        generation _: UInt64,
        ownerToken _: UUID
    ) async throws -> AdoptionRestorationValidation {
        await validateAction(snapshot)
    }

    func resume(
        snapshot _: AdoptionRestorationSnapshot,
        context: AdoptionRestorationResumeContext
    ) async throws {
        await resumeAction(context)
    }
}

private struct AdoptionBackgroundDriver: BackgroundWorkDriver {
    let expiration: @Sendable (BackgroundExpirationAction) async -> Void
    let stale: @Sendable () async -> Void

    func performExpiration(_ action: BackgroundExpirationAction) async {
        await expiration(action)
    }

    func markConnectionStale() async {
        await stale()
    }
}

/// The sequence range reserved for band-action command exchanges.
///
/// It is disjoint from `SeqAllocator`'s live range (0xA0...0xFF), which the
/// clock exchange, the maintenance cadence, and the live wire all draw from,
/// and from the five fixed initialization sequences 0...4.  The low sync-ACK
/// range starts at 5 and only reaches this range after ninety-one ACKs in one
/// session, and even then a collision would also have to carry the same
/// opcode, which the ACK never does.
private enum BandExchangeSequences {
    static let first: UInt8 = 0x60
    static let last: UInt8 = 0x7F

    static func contains(_ value: UInt8) -> Bool {
        (first...last).contains(value)
    }
}

/// Identity of one outstanding band-action exchange.  The generation is part
/// of the key so a reply that arrives after a reconnect can never resume a
/// caller that belongs to the previous link.
private struct BandExchangeKey: Hashable, Sendable {
    let generation: UInt64
    let sequence: UInt8
    let opcode: UInt8
}

/// Transport-neutral composition of the production Bluetooth and SyncKit
/// seams.  The runtime owns the event stream and is the only place where a
/// decoded frame is allowed to cross from GATT into history/live policy.
public actor BluetoothAdoptionRuntime {
    public static let defaultHistoryBufferLimit = 10_000

    private let transport: any BLETransport
    private let clock: any BluetoothAdoptionClock
    private let connection: BluetoothConnectionSession
    private let writer: SerializedGenerationPinnedWriter
    private let clockExchange: ClockExchange
    private let history: HistoryCoordinator
    private let live: LiveStreamManager
    private let liveWireController: AdoptionLiveWireController
    private let reconnect: ReconnectController
    private let reconnectScheduler: AdoptionReconnectScheduler
    private let background = BackgroundCoordinator()
    private let generationBox: AdoptionGenerationBox
    private let liveSequences: AdoptionLiveSequenceAllocator
    private let healthEvaluator = ConnectionHealthEvaluator()
    public let diagnostics: ConnectionDiagnosticsRecorder

    private let historyBufferLimit: Int
    private var eventTask: Task<Void, Never>?
    private var startupEvents: [TransportEvent] = []
    private var eventsReady = false
    private var setupTask: Task<Void, Never>?
    private var running = false
    private var currentGeneration: UInt64?
    /// The runtime owns the physical disconnect boundary. Writer/history
    /// teardown uses a state-only command transport, so this guard prevents
    /// stop/failure/expiration paths from issuing a second native disconnect
    /// when their async callbacks interleave.
    private var transportDisconnectIssued = false
    private var setupCompleteGeneration: UInt64?
    private var pendingClockGet: (generation: UInt64, sequence: UInt8, wallDate: Date)?
    private var clockDiscipline = ClockDiscipline()
    private var clockRecheckTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var lastHeartbeatAt: Date?
    private var lastKeepAliveAt: Date?
    private var lastHistoryRefreshAt: Date?
    private var historyOffloadActive = false
    private var historyBufferedItems = 0
    private var radioState: ConnectionRadioState = .unknown
    private var lastValidFrameAt: Date?
    private var lastInboundPacketAt: Date?
    private var lastHistoryActivityAt: Date?
    private var lastHistoricalCommitAt: Date?
    private var lastHistoricalAcknowledgementAt: Date?
    private var lastHistoryCompletedAt: Date?
    private var charging: Bool?
    private var onWrist: Bool?
    private var batteryPercentage: Double?
    private var advertisingName: String?
    private var validFrameCount: UInt64 = 0
    private var corruptFrameCount: UInt64 = 0
    private var writeTimeoutCount: UInt64 = 0
    private var setupBondRecovery = SetupBondRecoveryPolicy()
    private var setupFirstWritePending = false
    private var rollingCorruption = RollingCorruptionDetector()
    private var lastError: String?
    private var stateContinuations: [UUID: AsyncStream<BluetoothAdoptionRuntimeState>.Continuation] = [:]
    private var pendingBandExchanges: [BandExchangeKey: CheckedContinuation<Data, Error>] = [:]
    private var bandExchangeCursor: UInt8 = BandExchangeSequences.first
    private var bandEventContinuations: [UUID: AsyncStream<BandEventEnvelope>.Continuation] = [:]
    /// Edge's `standardHrFallback`. Once the link has proven noisy this
    /// session it stays latched, so reconcile and the 30 s rearm never put the
    /// raw and IMU streams back on the wire. Only stop() or an explicit user
    /// start clears it.
    private var degradedLiveModeLatched = false
    private var packetTypeCountsSinceTick: [UInt8: Int] = [:]
    private var lastLoggedLiveWireMode: String?
    /// Orders the unstructured mirror of `historyOffloadActive` into the live
    /// wire controller.
    private var historyDrainSequence: UInt64 = 0
    /// Set by the host lifecycle. Only logging and the event-driven top-up read
    /// it; the connection coordinator keeps its own copy for the connect bound.
    private var applicationIsBackgrounded = false
    /// The restoration seam. It is constructed lazily on the first
    /// `willRestoreState` so a runtime that never gets relaunched for the band
    /// allocates nothing.
    private var restoration: RestorationCoordinator?

    public init(
        transport: any BLETransport,
        store: any BluetoothAdoptionStore,
        clock: any BluetoothAdoptionClock = SystemBluetoothAdoptionClock(),
        diagnostics: ConnectionDiagnosticsRecorder = ConnectionDiagnosticsRecorder(),
        historyBufferLimit: Int = BluetoothAdoptionRuntime.defaultHistoryBufferLimit
    ) {
        self.transport = transport
        self.clock = clock
        self.diagnostics = diagnostics
        self.historyBufferLimit = max(1, historyBufferLimit)

        let generationBox = AdoptionGenerationBox()
        let liveSequences = AdoptionLiveSequenceAllocator()
        let commandTransport = AdoptionCommandTransport(base: transport)
        let writer = SerializedGenerationPinnedWriter(
            transport: commandTransport,
            clock: clock,
            // The runtime only ever talks to a Gen 4 band, so it confirms the
            // Gen 4 families here. Without this the writer keeps the default
            // deny-all capabilities and every rename/haptic/alarm encode
            // throws capabilityNotConfirmed before it reaches the firewall.
            commandWriter: ProductionCommandWriter(capabilities: BandProfile.gen4.commands)
        )
        let reconnectScheduler = AdoptionReconnectScheduler(clock: clock)
        let liveWireController = AdoptionLiveWireController(
            writer: writer,
            generation: generationBox,
            sequences: liveSequences,
            clock: clock
        )

        self.generationBox = generationBox
        self.liveSequences = liveSequences
        self.writer = writer
        self.clockExchange = ClockExchange(writer: writer)
        self.liveWireController = liveWireController
        self.connection = BluetoothConnectionSession(
            transport: transport,
            store: store,
            clock: clock
        )
        self.history = HistoryCoordinator(
            store: store,
            transport: commandTransport,
            clock: clock,
            generationPinnedACKWriter: { [writer] sequence, token, generation in
                try await writer.write(
                    .historyAcknowledgement(sequence: sequence, token: token),
                    generation: generation
                )
            }
        )
        self.live = LiveStreamManager(
            commandSink: AdoptionLiveCommandSink(
                controller: liveWireController
            )
        )
        self.reconnectScheduler = reconnectScheduler
        self.reconnect = ReconnectController(scheduler: reconnectScheduler)
    }

    /// Starts one event-stream consumer and begins the provisioning/retrieve /
    /// scan flow. Calling start while already running is intentionally a no-op
    /// so a UI lifecycle duplicate cannot allocate a second stream consumer.
    @discardableResult
    public func start() async -> ConnectionPlan {
        guard !running else { return .none }
        running = true
        eventsReady = false
        // An explicit user start is the only thing besides stop() that gives
        // the link its raw and IMU streams back after a degradation latch.
        degradedLiveModeLatched = false
        await liveWireController.setDegraded(false)
        lastLoggedLiveWireMode = nil
        startupEvents.removeAll(keepingCapacity: true)
        await connection.setTimeoutHandler { [weak self] generation in
            await self?.connectionTimedOut(generation: generation)
        }
        await reconnectScheduler.setHandler { [weak self] request in
            await self?.performReconnect(request)
        }
        // Create the stream before touching CoreBluetooth.  CBCentralManager
        // may report poweredOn synchronously, and a transport is allowed to
        // deliver a buffered callback as soon as its stream is requested.
        installEventConsumer()
        // Allocate the coordinator generation before subscribing to the
        // transport stream. A native callback can arrive immediately after
        // connect(), and scripted transports may already have buffered their
        // first event; neither is allowed to be stamped with generation zero.
        let plan = await connection.start()
        await adoptConnectionGeneration()
        // Keep direct delivery closed until every event buffered across the
        // reentrant connection-start boundary has been handled in order. New
        // callbacks may arrive while an event is awaiting the connection
        // actor, so drain in batches and only flip the gate after an empty
        // observation made on this actor.
        while !startupEvents.isEmpty {
            let buffered = startupEvents
            startupEvents.removeAll(keepingCapacity: true)
            for event in buffered {
                await handle(event)
            }
        }
        eventsReady = true
        return plan
    }

    /// Stops the runtime and fences all pending work. The two underlying
    /// owners have separate disconnect state (GATT and command writer), so
    /// both are explicitly released; each native adapter is expected to make
    /// its disconnect operation idempotent.
    public func stop() async {
        running = false
        eventTask?.cancel()
        eventTask = nil
        setupTask?.cancel()
        setupTask = nil
        clockRecheckTask?.cancel()
        clockRecheckTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        startupEvents.removeAll(keepingCapacity: true)
        eventsReady = false
        setHistoryOffloadActive(false, reason: "runtime stopped")
        setupCompleteGeneration = nil
        pendingClockGet = nil
        clockDiscipline.disconnect()
        historyBufferedItems = 0
        charging = nil
        onWrist = nil
        failBandExchanges()
        // An explicit stop is the only place besides a user start that clears
        // the degradation latch; a reconnect alone must not re-arm the flood.
        degradedLiveModeLatched = false
        // Keep the active generation pinned until the aggregate live-disable
        // sequence has completed.  Clearing it first makes the controller's
        // final optical/R10/IMU/HR-off commands fail closed and leaves a
        // physical accessory in a stale live mode until its link happens to
        // drop.
        await live.reset()
        await writer.disconnect()
        await disconnectConnectionIfNeeded()
        currentGeneration = nil
        await generationBox.set(nil)
        await reconnect.reset()
        await reconnectScheduler.cancelAll()
        if let restoration {
            // Releases the restoration owner token so a later relaunch can
            // acquire it again instead of failing with ownerAlreadyHeld.
            await restoration.invalidateCurrentRestoration()
        }
        restoration = nil
        finishStateStreams()
        finishBandEventStreams()
    }

    /// Returns an independent, newest-value-bounded state stream. The runtime
    /// remains the sole BLETransport event consumer; observers never subscribe
    /// to CoreBluetooth callbacks directly.
    public func stateStream() async -> AsyncStream<BluetoothAdoptionRuntimeState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BluetoothAdoptionRuntimeState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateStream(id: id) }
        }
        // Seed this observer before returning. A detached seed task could be
        // starved behind the test/host timeout, and it also left a narrow gap
        // where setup completed before this continuation observed any state.
        continuation.yield(await currentState())
        return stream
    }

    /// Alias for hosts that model observer registration as a plural stream.
    public func states() async -> AsyncStream<BluetoothAdoptionRuntimeState> {
        await stateStream()
    }

    public func enterForeground() async {
        applicationIsBackgrounded = false
        await connection.setApplicationBackgrounded(false)
        Self.debugLog("app entered foreground")
        _ = try? await background.runForeground { [weak self] in
            guard let self else { return }
            await self.ensureStarted()
            await self.reviveParkedConnectionIfNeeded()
            await self.live.setBackgroundPolicy(.foreground)
        }
        await emitState()
    }

    public func enterBackground() async {
        applicationIsBackgrounded = true
        // Tell the connect watchdog first. A connect that is already in flight
        // must stop being bounded by a timer the moment the app can be
        // suspended, otherwise it is cancelled and nothing stays outstanding
        // for iOS to complete when the band comes back.
        await connection.setApplicationBackgrounded(true)
        Self.debugLog("app entered background; live policy=ordinaryBackground")
        await live.setBackgroundPolicy(.ordinaryBackground)
        await emitState()
    }

    /// Runs the already-started/restarted session for a bounded interval. A
    /// successful run requires setup plus a durable history commit after this
    /// invocation began; setup alone never reports success.
    public func runBackgroundSync(maxDuration: TimeInterval) async -> Bool {
        guard maxDuration > 0 else { return false }
        let waiter = AdoptionBackgroundWaiter()
        let completion = BackgroundTaskCompletion { success in
            waiter.finish(success)
        }
        let handle = await background.startBackground(
            kind: .processing,
            completion: completion
        ) { [weak self] in
            guard let self else {
                _ = completion.complete(success: false)
                return
            }
            let result = await self.performBackgroundSync(maxDuration: maxDuration)
            _ = completion.complete(success: result)
        }
        guard handle != nil else { return false }
        return await waiter.wait()
    }

    /// Applies the shared background coordinator's expiration ordering. The
    /// coordinator itself owns the timeout for non-cooperative work; the BLE
    /// action only fences this runtime's setup/history/transport owners.
    @discardableResult
    public func expireBackground() async -> Bool {
        let driver = AdoptionBackgroundDriver(
            expiration: { [weak self] action in
                await self?.performBackgroundExpiration(action)
            },
            stale: { [weak self] in
                await self?.markBackgroundStale()
            }
        )
        let result = await background.expireActive(driver: driver)
        await emitState()
        return result
    }

    /// Handles a single callback for tests and native adapters that already
    /// own an event loop. When `generation` is omitted, the current connection
    /// generation is stamped at the seam; callers replaying an old stream can
    /// pass its captured generation to prove stale rejection.
    @discardableResult
    public func handle(
        _ event: TransportEvent,
        generation: UInt64? = nil
    ) async -> ConnectionTransitionResult {
        // Restoration is a process-level callback, not a session transition.
        // The state machine has no generation for it and correctly rejects it,
        // so it is consumed here instead of being dropped on the floor.
        if case .restored(let snapshot) = event {
            await handleRestoration(snapshot)
            await emitState()
            return .accepted(await connection.state())
        }
        updateRadioState(for: event)
        let stampedGeneration: UInt64
        if let generation {
            stampedGeneration = generation
        } else {
            stampedGeneration = await connection.generation()
        }
        let transition = await connection.handle(
            event,
            generation: stampedGeneration,
            atNanoseconds: clock.nowNanoseconds()
        )

        switch transition {
        case .accepted(let state):
            lastError = nil
            await adoptGeneration(state.generation)
            await processAccepted(event, generation: stampedGeneration)
        case .ignoredStaleGeneration,
             .rejected(.staleGeneration),
             .rejected(.staleSession):
            await record(.staleConnection, generation: stampedGeneration)
        case .rejected(let error):
            // BluetoothConnectionSession aborts GATT validation by calling
            // its coordinator disconnect path. Remember that native call so
            // a later stop/expiration does not disconnect the same attempt
            // again.
            if case .gattValidationFailed = error {
                transportDisconnectIssued = true
                await failSetup(generation: stampedGeneration, error: error)
            } else if case .managerState(.poweredOn) = event {
                // If start() ran while CoreBluetooth was still powered off,
                // the coordinator may already be parked in `.scanning` when
                // the first poweredOn callback arrives.  The state machine
                // intentionally rejects that global callback; restart the
                // attempt here so the initial scan is never lost.
                await restartAfterPoweredOnIfNeeded()
            }
        }
        await emitState()
        return transition
    }

    /// Returns a state computed from live GATT/health/reconnect actors. The
    /// result never claims setup is complete before the final initialization
    /// write has returned from the transport seam.
    public func currentState() async -> BluetoothAdoptionRuntimeState {
        let connectionState = await connection.state()
        let ready = await connection.setupReady()
        let health = healthReport(now: clock.now())
        return BluetoothAdoptionRuntimeState(
            running: running,
            generation: currentGeneration,
            connection: connectionState,
            setupReady: ready,
            setupComplete: isSetupComplete,
            radioState: radioState,
            health: health,
            pendingReconnect: await reconnect.pendingRequest(),
            liveConsumerCount: await live.totalConsumerCount(),
            pendingHistoryReplayCount: await history.pendingReplayCount(),
            validFrameCount: validFrameCount,
            corruptFrameCount: corruptFrameCount,
            writeTimeoutCount: writeTimeoutCount,
            lastError: lastError,
            charging: charging,
            onWrist: onWrist,
            batteryPercentage: batteryPercentage,
            advertisingName: advertisingName,
            lastPacketAt: lastInboundPacketAt,
            historyCommitAt: lastHistoricalCommitAt,
            completedSyncAt: lastHistoryCompletedAt,
            historyOffloadActive: historyOffloadActive,
            bondRepairRequired: setupBondRecovery.requiredRepair,
            // This runtime only drives the Gen 4 Harvard profile. Gen 5 and
            // MG bands use Gen5ExperimentalRuntime, which reports its own model.
            bandModel: .whoop4
        )
    }

    public func setBackgroundPolicy(_ policy: LiveStreamBackgroundPolicy) async {
        await live.setBackgroundPolicy(policy)
    }

    public func backgroundPolicy() async -> LiveStreamBackgroundPolicy {
        await live.currentBackgroundPolicy()
    }

    public func acquireLiveStream(
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer
    ) async throws -> LiveStreamConsumerHandle {
        try await live.acquire(kind: kind, consumer: consumer)
    }

    public func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        await live.bufferedSamples(for: kind)
    }

    /// Acquires the generation-pinned typed live event stream. Unlike the
    /// legacy buffered API, this stream carries the accepted connection
    /// generation on every event so feature sessions can reject late frames
    /// after reconnect or interruption.
    public func acquireLiveEventStream(
        kind: LiveStreamKind,
        consumer: LiveStreamConsumer
    ) async throws -> LiveStreamEventSubscription {
        guard let generation = currentGeneration else {
            throw LiveStreamError.generationUnavailable
        }
        return try await live.acquireEventStream(
            kind: kind,
            consumer: consumer,
            generation: generation
        )
    }

    public func diagnosticsSnapshot() async -> ConnectionDiagnosticsSnapshot {
        await diagnostics.snapshot()
    }

    // MARK: - Band actions

    /// How long a band action waits for its command response before it gives
    /// up. The value is deliberately distinct from every other interval the
    /// runtime sleeps on so a deterministic clock can single it out.
    public static let bandCommandTimeout: TimeInterval = 6

    /// A newest-value-bounded stream of asynchronous band events, one per
    /// subscriber, in the same shape as `stateStream()`.
    public func bandEvents() -> AsyncStream<BandEventEnvelope> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BandEventEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        bandEventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeBandEventStream(id: id) }
        }
        return stream
    }

    /// Opcode 14 and its boolean payload are supplied by the band-link brief;
    /// opcode support is documented in NOOP docs/PROTOCOL_COMMANDS.md.
    /// Gen 4 has no confirming response for this write.
    public func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        try await exchange(expectingOpcode: nil) { sequence in
            .heartRateSharing(HeartRateSharingCommand(sequence: sequence, enabled: enabled))
        }
        return nil
    }

    /// Renames the band and re-reads the advertising name so runtime state
    /// reflects what the band now advertises.
    ///
    /// The reference has no command response for 0x4D: Edge writes it and
    /// immediately issues GET_ADVERTISING_NAME (0x4C). A failed readback does
    /// not undo the rename, so it is reported through state rather than as a
    /// thrown error.
    public func renameBand(to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate before the readiness gate so a bad name is reported as a
        // bad name even when the band happens to be disconnected.
        guard (try? RenameCommand(sequence: 0, name: trimmed)) != nil else {
            throw BandCommandError.invalidName
        }
        try await exchange(expectingOpcode: nil) { sequence in
            .rename(try RenameCommand(sequence: sequence, name: trimmed))
        }
        // Edge updates its UI optimistically before the readback lands.
        advertisingName = trimmed
        if let response = try? await exchange(expectingOpcode: 0x4C, { sequence in
            .identity(IdentityCommand.advertisingName(sequence: sequence))
        }), let decoded = try? IdentityCommand.decodeAdvertisingNameResponse(response) {
            advertisingName = decoded
        }
        await emitState()
    }

    /// Plays one haptic waveform effect on the band.
    ///
    /// Effect 1 latches and buzzes until the user taps the band, so call sites
    /// use the short double buzz (2). There is no command response for 0x4F in
    /// the reference, so a completed GATT write is the success signal.
    public func buzzBand(effect: UInt8 = HapticCommand.defaultPattern) async throws {
        try await exchange(expectingOpcode: nil) { sequence in
            .haptic(HapticCommand.run(sequence: sequence, pattern: effect))
        }
    }

    /// Session-owned cues must name the connection they started on. Readiness
    /// and exchange capture that generation on this actor before any await;
    /// the existing serialized writer then rejects a later generation swap.
    public func buzzBand(effect: UInt8, expectedGeneration: UInt64) async throws {
        guard currentGeneration == expectedGeneration else { throw BandCommandError.notReady }
        try await buzzBand(effect: effect)
    }

    /// Arms the band's own wake alarm.
    ///
    /// The rich twenty-byte form is the only form the reference says fires,
    /// and the epoch is shifted into the band's clock frame first because the
    /// band runs the alarm autonomously on its own RTC. The readback is
    /// attempted afterwards but is not allowed to fail the set: the reference
    /// parks GET_ALARM_TIME as unconfirmed on real firmware.
    public func setBandAlarm(fireDate: Date) async throws {
        let drift = await readBandClockDriftSeconds()
        let frame: BandAlarmFrame
        do {
            frame = try BandAlarmFrame(fireDate: fireDate, driftSeconds: drift)
        } catch {
            throw BandCommandError.rejected(String(describing: error))
        }
        // Clear first. On a WHOOP 4 an arm over an alarm the band is already
        // holding ACKs and reads back correctly and then never buzzes, which
        // is consistent with the slot refusing to be overwritten in place.
        // DISABLE_ALARM is cheap and a failed clear must not block the arm,
        // so its outcome is logged and dropped.
        do {
            try await exchange(expectingOpcode: nil) { sequence in
                .alarm(AlarmCommand.disable(sequence: sequence))
            }
            Self.debugLog("band alarm cleared before arming")
        } catch {
            Self.debugLog("band alarm pre-clear failed: \(error)")
        }
        try await exchange(expectingOpcode: nil) { sequence in
            .alarm(AlarmCommand.setup(
                sequence: sequence,
                epochSeconds: frame.epochSeconds,
                subsecondTicks: frame.subsecondTicks
            ))
        }
        Self.debugLog("band alarm armed; drift=\(drift)s epoch=\(frame.epochSeconds) ticks=\(frame.subsecondTicks)")
        _ = try? await readBandAlarm(driftSeconds: drift)
    }

    /// Reads the alarm the band currently holds.  Returns nil when the band
    /// reports no armed alarm or answers in a shape the hardware capture does
    /// not cover; the decoder never guesses an epoch offset.
    ///
    /// The reply carries no subsecond field this decoder can justify, so the
    /// returned date sits on the whole second.
    ///
    /// The answer is a band-clock epoch, so it is shifted back into wall time
    /// before it leaves here. A caller comparing the readback against the time
    /// it asked for is then comparing two wall instants.
    public func readBandAlarm() async throws -> Date? {
        try await readBandAlarm(driftSeconds: await readBandClockDriftSeconds())
    }

    private func readBandAlarm(driftSeconds: Int64) async throws -> Date? {
        let response = try await exchange(expectingOpcode: 0x43) { sequence in
            .alarm(AlarmCommand.readback(sequence: sequence))
        }
        guard let readback = try? AlarmCommand.decodeReadbackResponse(response) else {
            Self.debugLog("band alarm readback unrecognised")
            return nil
        }
        guard readback.isArmed else {
            Self.debugLog("band alarm readback reports no armed alarm")
            return nil
        }
        let wall = BandAlarmFrame.wallDate(
            fromBandEpochSeconds: readback.epochSeconds,
            driftSeconds: driftSeconds
        )
        Self.debugLog("band alarm readback epoch=\(readback.epochSeconds) drift=\(driftSeconds)s wall=\(wall.timeIntervalSince1970)")
        return wall
    }

    /// Fires the alarm haptics immediately (RUN_ALARM, `0x44` body `0x01`).
    /// The reference has no command response for 0x44; the band reports it as
    /// event 58.  This is both the "test alarm" button and the write the smart
    /// wake window uses to buzz early, so it must stay free of side effects on
    /// the scheduled alarm.
    public func testBandAlarm() async throws {
        try await exchange(expectingOpcode: nil) { sequence in
            .alarm(AlarmCommand.test(sequence: sequence))
        }
    }

    /// Cancels the on-device alarm.  The payload is the revision-1 byte; the
    /// reference records that a `0x00` body is ACKed but does not clear.
    public func disableBandAlarm() async throws {
        try await exchange(expectingOpcode: nil) { sequence in
            .alarm(AlarmCommand.disable(sequence: sequence))
        }
    }

    #if DEBUG
    /// Sends an arbitrary inner packet body for byte-level alarm experiments
    /// on real hardware. DEBUG builds only, driven from the debug alarm
    /// request file. The dangerous-opcode firewall still runs twice on the
    /// way out, in `ProductionCommandWriter.encode` and again in the
    /// transport adapter.
    ///
    /// `body` starts at the opcode, so `[0x42, 0x04, ...]` is a SET_ALARM.
    @discardableResult
    public func sendDebugRawBandCommand(
        body: Data,
        expectingOpcode: UInt8? = nil
    ) async throws -> Data {
        Self.debugLog("debug raw band command body=\(body.map { String(format: "%02x", $0) }.joined())")
        return try await exchange(expectingOpcode: expectingOpcode) { sequence in
            .debugRaw(sequence: sequence, body: body)
        }
    }
    #endif

    /// The connected band's signal strength in dBm, for "Find my strap".
    ///
    /// This is a link-level read, not a command: it does not take a sequence
    /// number, it does not go through the serialized writer, and it returns
    /// nil rather than throwing when the link drops mid-hunt, because the
    /// person is walking around the room while it is being called.
    public func readSignalStrength() async -> Int? {
        await connection.readSignalStrength()
    }

    /// Correlates wall time against the band RTC for the alarm shift.
    ///
    /// A fresh GET_CLOCK is preferred. When it does not answer, the session's
    /// existing correlation is used, and when there is none the drift is zero,
    /// which arms the raw wall epoch exactly as the reference does before its
    /// first correlation of a session.
    private func readBandClockDriftSeconds() async -> Int64 {
        let wallDate = clock.now()
        if let response = try? await exchange(expectingOpcode: 0x0B, { sequence in
            .getClock(sequence: sequence)
        }), let parsed = try? ClockResponse.parse(response, wallDate: wallDate) {
            let drift = wallDate.timeIntervalSince(parsed.bandDate)
            if drift.isFinite {
                return Int64(drift.rounded(.towardZero))
            }
        }
        guard let correlation = clockDiscipline.correlation,
              correlation.offsetSeconds.isFinite else { return 0 }
        return Int64(correlation.offsetSeconds.rounded(.towardZero))
    }

    /// The single seam every band action writes through.
    ///
    /// It allocates a sequence from the reserved band range, registers the
    /// continuation under (generation, sequence, opcode) before the write so a
    /// fast reply cannot arrive with nobody waiting, writes through the
    /// existing serialized writer, and times out on the injected clock.
    /// `expectingOpcode` is nil for the commands the reference decodes no
    /// response for; those resolve when the GATT write completes.
    @discardableResult
    private func exchange(
        expectingOpcode opcode: UInt8?,
        timeout: TimeInterval = BluetoothAdoptionRuntime.bandCommandTimeout,
        _ makeCommand: (UInt8) throws -> ProductionCommand
    ) async throws -> Data {
        let generation = try requireBandCommandReadiness()
        let sequence = nextBandExchangeSequence()
        let command: ProductionCommand
        do {
            command = try makeCommand(sequence)
        } catch let error as CommandFamilyError {
            if case .invalidRename = error { throw BandCommandError.invalidName }
            throw BandCommandError.rejected(String(describing: error))
        } catch {
            throw BandCommandError.rejected(String(describing: error))
        }

        guard let opcode else {
            do {
                try await writer.write(command, generation: generation)
            } catch {
                Self.debugLog("band command failed; opcode=write-only outcome=\(error)")
                throw BandCommandError.rejected(String(describing: error))
            }
            Self.debugLog("band command written; sequence=0x\(String(sequence, radix: 16)) outcome=ok")
            return Data()
        }

        let key = BandExchangeKey(generation: generation, sequence: sequence, opcode: opcode)
        return try await withCheckedThrowingContinuation { continuation in
            pendingBandExchanges[key] = continuation
            Task { [weak self] in
                await self?.driveBandExchange(key: key, command: command, timeout: timeout)
            }
        }
    }

    /// Performs the write for a response-expecting exchange and then arms its
    /// timeout. Both outcomes route through `finishBandExchange`, which is a
    /// no-op once route() or a teardown has already resumed the caller.
    private func driveBandExchange(
        key: BandExchangeKey,
        command: ProductionCommand,
        timeout: TimeInterval
    ) async {
        do {
            try await writer.write(command, generation: key.generation)
        } catch {
            Self.debugLog("band command failed; opcode=0x\(String(key.opcode, radix: 16)) outcome=\(error)")
            finishBandExchange(key, throwing: .rejected(String(describing: error)))
            return
        }
        guard pendingBandExchanges[key] != nil else { return }
        do {
            try await clock.sleep(for: timeout)
        } catch {
            finishBandExchange(key, throwing: .timedOut)
            return
        }
        if pendingBandExchanges[key] != nil {
            Self.debugLog("band command timed out; opcode=0x\(String(key.opcode, radix: 16))")
        }
        finishBandExchange(key, throwing: .timedOut)
    }

    private func finishBandExchange(_ key: BandExchangeKey, throwing error: BandCommandError) {
        guard let continuation = pendingBandExchanges.removeValue(forKey: key) else { return }
        continuation.resume(throwing: error)
    }

    /// Fails every outstanding band exchange. Called from every path that
    /// tears a generation down, so a caller can never be left waiting on a
    /// link that no longer exists.
    private func failBandExchanges(_ error: BandCommandError = .notReady) {
        guard !pendingBandExchanges.isEmpty else { return }
        let pending = pendingBandExchanges
        pendingBandExchanges.removeAll(keepingCapacity: true)
        Self.debugLog("band exchanges failed; count=\(pending.count) reason=\(error)")
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    /// Every band action gates on the same four conditions. Anything short of
    /// all four is `.notReady`; no action is ever attempted on a half-open
    /// link in the hope that it lands.
    private func requireBandCommandReadiness() throws -> UInt64 {
        guard running,
              let generation = currentGeneration,
              setupCompleteGeneration == generation,
              radioState == .poweredOn else {
            throw BandCommandError.notReady
        }
        return generation
    }

    private func nextBandExchangeSequence() -> UInt8 {
        let value = bandExchangeCursor
        bandExchangeCursor = value == BandExchangeSequences.last
            ? BandExchangeSequences.first
            : value &+ 1
        return value
    }

    private func removeBandEventStream(id: UUID) {
        bandEventContinuations.removeValue(forKey: id)
    }

    private func finishBandEventStreams() {
        for continuation in bandEventContinuations.values { continuation.finish() }
        bandEventContinuations.removeAll(keepingCapacity: true)
    }

    /// Decodes a `0x30` event packet and publishes it to every subscriber.
    /// Only typed state is decoded; no raw body reaches
    /// diagnostics or storage here, which is what the previous discard of
    /// these packets guaranteed.
    private func routeBandEvent(_ payload: Data, generation: UInt64) {
        let inner = Data([BandEventPacket.packetType]) + payload
        guard let packet = try? BandEventPacket.decode(inner) else {
            Self.debugLog("band event dropped; truncated or malformed packet")
            return
        }
        Self.debugLog("band event id=\(packet.eventID) generation=\(generation)")
        if let value = packet.batteryPercentage { batteryPercentage = value }
        if let value = packet.charging { charging = value }
        if let value = packet.onWrist { onWrist = value }
        guard !bandEventContinuations.isEmpty else { return }
        let envelope = BandEventEnvelope(
            eventID: packet.eventID,
            generation: generation,
            receivedAt: clock.now(),
            bandEpochSeconds: packet.bandEpochSeconds,
            batteryPercentage: batteryPercentage, charging: charging, onWrist: onWrist
        )
        for continuation in bandEventContinuations.values {
            continuation.yield(envelope)
        }
    }

    private func installEventConsumer() {
        let transport = self.transport
        eventTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in transport.events() {
                guard !Task.isCancelled else { return }
                await self?.consumeTransportEvent(event)
            }
            await self?.eventStreamEnded()
        }
    }

    private func consumeTransportEvent(_ event: TransportEvent) async {
        guard eventsReady else {
            // Keep startup bounded.  A radio can emit a handful of manager and
            // retrieval callbacks before the connection generation is adopted;
            // retaining only the newest bounded tail prevents an unbounded
            // startup queue while preserving the important poweredOn edge.
            startupEvents.append(event)
            if startupEvents.count > 32 {
                startupEvents.removeFirst(startupEvents.count - 32)
            }
            return
        }
        await handle(event)
    }

    private func ensureStarted() async {
        if !running { _ = await start() }
    }

    /// `running` stays true after a background expiration or a refused start,
    /// so `ensureStarted()` alone cannot bring the link back.
    private func reviveParkedConnectionIfNeeded() async {
        guard running, radioState != .poweredOff else { return }
        if eventTask == nil { installEventConsumer() }
        switch await connection.state() {
        case .idle, .outOfRange:
            guard await reconnect.pendingRequest() == nil else { return }
            transportDisconnectIssued = false
            _ = await connection.start()
            await adoptConnectionGeneration()
        case .reconnecting:
            // A `.reconnecting` park with nothing scheduled never recovers on
            // its own: the state machine refuses a fresh start while the
            // attempt looks in flight, and `requestReconnect` is skipped
            // whenever the radio was off at the time of the drop.
            guard await reconnect.pendingRequest() == nil else { return }
            Self.debugLog("reviving parked reconnect; no request was scheduled")
            await connection.disconnect()
            transportDisconnectIssued = false
            _ = await connection.start()
            await adoptConnectionGeneration()
        default:
            break
        }
    }

    private func performBackgroundSync(maxDuration: TimeInterval) async -> Bool {
        let startedAt = clock.now()
        let storedAtStart = historicalRecordsStoredThisSession
        Self.debugLog(String(
            format: "background run start; budget=%.0fs backgrounded=%@",
            maxDuration,
            applicationIsBackgrounded ? "yes" : "no"
        ))
        if !running { _ = await start() }
        // A window that opens on a parked link has to bring the link back
        // itself. `start()` returns early when `running` is already true, so a
        // connection parked in `.reconnecting` or `.outOfRange` would otherwise
        // sit there for the whole budget and the window would bank nothing.
        await reviveParkedConnectionIfNeeded()
        // Only a real background run narrows the live policy. A foreground
        // manual sync used to be demoted to ordinaryBackground here and
        // nothing ever restored it, so live heart rate stayed off for the
        // rest of the foreground session.
        if await live.currentBackgroundPolicy() != .foreground {
            await live.setBackgroundPolicy(.ordinaryBackground)
        }
        let deadline = startedAt.addingTimeInterval(maxDuration)
        let pollInterval: TimeInterval = 0.250
        // Waiting past the first acknowledgement is bounded by poll count as
        // well as by the deadline. A host clock that never advances, which is
        // how the deterministic package tests are wired, would otherwise leave
        // this loop spinning for as long as the band keeps a burst open.
        let maximumDrainPolls = Int(maxDuration / pollInterval) + 64
        var drainPolls = 0
        var refreshRequestedGeneration: UInt64?
        var didAcknowledge = false

        while !Task.isCancelled {
            if isSetupComplete,
               let generation = currentGeneration,
               refreshRequestedGeneration != generation {
                do {
                    try await requestHistoryRefresh(generation: generation)
                    refreshRequestedGeneration = generation
                } catch {
                    lastError = String(describing: error)
                    refreshRequestedGeneration = generation
                }
            }
            if isSetupComplete,
               let acknowledgement = lastHistoricalAcknowledgementAt,
               acknowledgement >= startedAt {
                didAcknowledge = true
                // The first acknowledgement used to end the run. The band sends
                // a night in tokenized chunks, so stopping there banked one
                // chunk and left the rest for whenever the app next opened.
                // Keep the window until the drain says it is finished.
                if !historyOffloadActive { break }
                drainPolls += 1
                if drainPolls >= maximumDrainPolls { break }
            }
            let remaining = deadline.timeIntervalSince(clock.now())
            guard remaining > 0 else { break }
            do {
                try await clock.sleep(for: min(pollInterval, remaining))
            } catch {
                break
            }
        }
        let stored = historicalRecordsStoredThisSession - storedAtStart
        Self.debugLog(String(
            format: "background run end; stored=%d acknowledged=%@ elapsed=%.0fs offloadActive=%@",
            stored,
            didAcknowledge ? "yes" : "no",
            clock.now().timeIntervalSince(startedAt),
            historyOffloadActive ? "yes" : "no"
        ))
        await emitState()
        return didAcknowledge
    }

    private func performBackgroundExpiration(_ action: BackgroundExpirationAction) async {
        switch action {
        case .completeOrRollbackTransaction:
            // HistoryCoordinator owns its commit transaction; cancellation is
            // fenced below before transport work is stopped.
            break
        case .preserveTokenAndCursor:
            // Pending replay snapshots remain in HistoryCoordinator and are
            // never cleared by expiration.
            break
        case .stopBLEWork:
            // The band stays connected. A BGTask expiring says only that this
            // one scheduled run is over; it says nothing about the link, and
            // dropping the link here is what ended overnight syncing after the
            // first expired task. BackgroundCoordinator has already cancelled
            // the run's own task, so no further BLE work is issued by it.
            // Setup, maintenance, history, and the reconnect policy all keep
            // running on the live generation.
            Self.debugLog("background task expired; BLE link retained")
        case .checkpointActiveWorkout:
            break
        case .deferAnalyticsHealthWidgetsNotifications:
            break
        }
        await emitState()
    }

    /// A scheduled background run ran out of time. That is an ordinary outcome
    /// and is not a connection error, so it never becomes `lastError`: the app
    /// surface maps any `lastError` to a user-facing failure message, and an
    /// expired BGTask on a healthy link must not look like a failed band.
    private func markBackgroundStale() async {
        Self.debugLog("background run marked stale; connection untouched")
        await emitState()
    }

    private func removeStateStream(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func finishStateStreams() {
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll(keepingCapacity: true)
    }

    private func emitState() async {
        guard !stateContinuations.isEmpty else { return }
        let value = await currentState()
        for continuation in stateContinuations.values {
            continuation.yield(value)
        }
    }

    private func eventStreamEnded() {
        eventTask = nil
        Task { [weak self] in await self?.emitState() }
    }

    private func adoptConnectionGeneration() async {
        let generation = await connection.generation()
        await adoptGeneration(generation == 0 ? nil : generation)
    }

    private func adoptGeneration(_ generation: UInt64?) async {
        if generation != currentGeneration,
           let generation {
            // A fresh session starts with a clean link-health window. The
            // durable commit timestamp is intentionally retained so UI and
            // background policy can still report historical progress.
            lastValidFrameAt = nil
            validFrameCount = 0
            corruptFrameCount = 0
            writeTimeoutCount = 0
            rollingCorruption.reset()
            clockDiscipline.disconnect()
            pendingClockGet = nil
            // A band action pinned to the previous generation can never be
            // answered on this one, so wake its caller here rather than
            // leaving it to the timeout.
            charging = nil
            onWrist = nil
            failBandExchanges()
            transportDisconnectIssued = false
            lastHeartbeatAt = nil
            lastKeepAliveAt = nil
            lastHistoryRefreshAt = nil
            setHistoryOffloadActive(false, reason: "new generation")
            lastHistoryActivityAt = nil
            packetTypeCountsSinceTick.removeAll(keepingCapacity: true)
            await liveWireController.resetForNewGeneration()
            _ = generation
        }
        currentGeneration = generation
        await generationBox.set(generation)
    }

    private func processAccepted(
        _ event: TransportEvent,
        generation: UInt64
    ) async {
        switch event {
        case .discovered(_, let services):
            await record(
                .advertisementSeen,
                generation: generation,
                label: "Advertisement",
                detail: "WHOOP strap found with \(services.count) advertised service(s)"
            )

        case .discoveredWithAdvertisement(_, let name, let services):
            await record(
                .advertisementSeen,
                generation: generation,
                label: "Advertisement",
                detail: "\(name ?? "WHOOP strap"); \(services.count) advertised service(s)"
            )

        case .connected, .connectedInSession:
            radioState = .poweredOn

        case .servicesDiscovered(let services),
             .servicesDiscoveredInSession(_, let services):
            await record(
                .gattDiscovery,
                generation: generation,
                label: "GATT discovery",
                detail: "\(services.count) service(s) found"
            )

        case .characteristicsDiscovered(let characteristics),
             .characteristicsDiscoveredInSession(_, let characteristics):
            await record(
                .gattDiscovery,
                generation: generation,
                label: "GATT discovery",
                detail: "\(characteristics.count) characteristic(s) found"
            )

        case .value, .valueInSession:
            logBackgroundWakeIfNeeded()
            let frames = await connection.drainFrames()
            // One accepted value callback has exactly one drain. This keeps
            // stale callbacks and duplicate drains out of the integrated path.
            await process(frames: frames, generation: generation)
            // Timers do not run while iOS has the app suspended, so an inbound
            // packet is the only moment a background app can notice that the
            // periodic history top-up is due.
            await evaluateEventDrivenMaintenance(generation: generation)

        case .notificationStateChanged(let characteristic, let enabled),
             .notificationStateChangedInSession(_, let characteristic, let enabled):
            await record(
                .notificationSubscription,
                generation: generation,
                label: diagnosticName(for: characteristic),
                detail: enabled ? "Subscribed" : "Subscription disabled"
            )
            // BluetoothConnectionSession advances the coordinator to
            // `.listening` only after its GATT handler accepts the third
            // notification. The transition returned for that callback still
            // reflects the pre-barrier `.subscribing` state, so read the
            // composed state after the barrier rather than trusting it.
            if case .listening(let setupGeneration, _) = await connection.state() {
                beginSetup(generation: setupGeneration)
            }

        case .disconnected, .disconnectedInSession:
            await handleDisconnect(event, generation: generation)

        case .managerState(.poweredOff):
            setupTask?.cancel()
            setupTask = nil
            setupCompleteGeneration = nil
            charging = nil
            onWrist = nil
            failBandExchanges()
            historyBufferedItems = 0
            // The Edge disable order is part of the teardown contract; keep
            // the session generation valid until that command sequence is
            // accepted by the same serialized writer.
            await live.reset()
            await writer.disconnect()
            await reconnect.reset()
            await disconnectConnectionIfNeeded()
            currentGeneration = nil
            await generationBox.set(nil)

        case .managerState(.poweredOn):
            // A powered-on transition is the only radio event that may restart
            // a previously powered-off runtime.
            if running, case .idle = await connection.state() {
                let plan = await connection.start()
                _ = plan
                await adoptConnectionGeneration()
            } else if running {
                await restartAfterPoweredOnIfNeeded()
            }

        default:
            break
        }
    }

    // MARK: - CoreBluetooth restoration

    /// iOS relaunched the app for the band. The snapshot names the peripherals
    /// the central still owns; it never carries the discovered GATT table, so
    /// the work here is to fence anything left over from before the relaunch
    /// and put the connection session back on the restored peripheral.
    private func handleRestoration(_ snapshot: RestorationSnapshot) async {
        Self.debugLog(
            "restored by iOS; peripherals=\(snapshot.peripherals.count) managerState=\(snapshot.managerState) running=\(running)"
        )
        // A restored central can report `.unknown` before its first real state
        // callback. That is not evidence about the radio, so it must not
        // overwrite a known one.
        if snapshot.managerState != .unknown {
            updateRadioState(for: .managerState(snapshot.managerState))
        }
        let adoption = AdoptionRestorationSnapshot(
            generation: .gen4,
            shape: snapshot.peripherals.isEmpty ? .unknownPeripheral : .midConnect,
            peripheralIdentifier: snapshot.peripherals.first,
            hadActiveHistoryBurst: historyOffloadActive
        )
        let coordinator = restoration ?? RestorationCoordinator(
            driver: AdoptionRestorationDriver(
                validateAction: { [weak self] snapshot in
                    guard let self else {
                        return AdoptionRestorationValidation(
                            serviceValidated: false,
                            characteristicsValidated: false
                        )
                    }
                    return await self.restorationValidateOrRediscover(snapshot)
                },
                resumeAction: { [weak self] context in
                    await self?.restorationResume(context)
                }
            )
        )
        restoration = coordinator
        do {
            let outcome = try await coordinator.restore(adoption)
            Self.debugLog(
                "restore finished; resumed=\(outcome.resumed) ignoredUnknownPeripheral=\(outcome.ignoredUnknownPeripheral) generation=\(outcome.generation)"
            )
        } catch {
            Self.debugLog("restore failed; \(error)")
        }
    }

    private func restorationValidateOrRediscover(
        _ snapshot: AdoptionRestorationSnapshot
    ) async -> AdoptionRestorationValidation {
        let validation = AdoptionRestorationGATT.validate(snapshot)
        if validation.isReady {
            Self.debugLog("restore: the pinned GATT table survived restoration")
            return validation
        }
        // A restored central carries peripherals only, so rediscovery is the
        // normal path rather than a fault. The connection session runs the
        // same discover/subscribe barrier as a cold connect, and the native
        // transport short-circuits to didConnect when iOS kept the link up.
        Self.debugLog("restore: rediscovering GATT for the restored peripheral")
        return AdoptionRestorationValidation(
            serviceValidated: true,
            characteristicsValidated: true
        )
    }

    private func restorationResume(_ context: AdoptionRestorationResumeContext) async {
        if context.historyBurstDiscarded {
            // Records buffered before the relaunch are not ACK eligible. The
            // band's cursor has not advanced, so it redelivers them; replaying
            // them here could emit an ACK from a generation that no longer
            // exists.
            if let generation = currentGeneration {
                try? await history.discardBurst(generation: generation)
            }
            setHistoryOffloadActive(false, reason: "restoration discards the pre-relaunch burst")
        }
        guard running else {
            Self.debugLog("restore: runtime not started; the host's start() will adopt the peripheral")
            return
        }
        switch await connection.state() {
        case .idle, .outOfRange, .bluetoothOff, .reconnecting:
            // Restoration outranks the backoff timer: the band is here now.
            await reconnect.reset()
            await reconnectScheduler.cancelAll()
            await connection.disconnect()
            transportDisconnectIssued = false
            let plan = await connection.start()
            await adoptConnectionGeneration()
            Self.debugLog("restore: re-adopt plan=\(plan)")
        case .retrieving, .scanning, .connecting, .discovering, .subscribing,
             .settingUp, .listening:
            Self.debugLog("restore: an attempt is already in flight; keeping it")
        }
    }

    private func beginSetup(generation: UInt64) {
        guard setupCompleteGeneration != generation else { return }
        if let existing = setupTask, !existing.isCancelled { return }
        setupTask = Task { [weak self] in
            await self?.performSetup(generation: generation)
        }
    }

    private func restartAfterPoweredOnIfNeeded() async {
        guard running else { return }
        switch await connection.state() {
        case .scanning, .retrieving, .outOfRange, .bluetoothOff, .idle:
            await disconnectConnectionIfNeeded()
            // A poweredOn callback can arrive while the previous attempt's
            // native disconnect is still unwinding.  The connection actor
            // serializes that boundary before allocating the new scan.
            let plan = await connection.start()
            _ = plan
            await adoptConnectionGeneration()
        case .connecting, .discovering, .subscribing, .settingUp, .listening, .reconnecting:
            break
        }
    }

    private func performSetup(generation: UInt64) async {
        do {
            await liveSequences.reset()
            try await writer.begin(generation: generation)
            try? await history.replaceGeneration(generation)

            // GATTSession has already confirmed response/events/data notify
            // state before this method is called. ClockExchange owns the exact
            // SET_CLOCK -> GET_CLOCK order, then the writer emits the five
            // pinned commands with write-completion pacing.
            let setSequence = await liveSequences.next()
            let getSequence = await liveSequences.next()
            let wallDate = clock.now()
            pendingClockGet = (
                generation: generation,
                sequence: getSequence,
                wallDate: wallDate
            )
            setupFirstWritePending = true
            _ = try await clockExchange.send(
                wallDate: wallDate,
                generation: generation,
                setSequence: setSequence,
                getSequence: getSequence,
                setupFirstWrite: true,
                onSetClockWritten: { [weak self] in
                    await self?.recordSetupFirstWriteSuccess(generation: generation)
                }
            )
            await record(
                .clockSet,
                generation: generation,
                label: "SET_CLOCK",
                detail: "Write response received"
            )
            await record(
                .clockGet,
                generation: generation,
                label: "GET_CLOCK",
                detail: "Write response received"
            )
            setHistoryOffloadActive(true, reason: "initialization historical request")
            _ = try await writer.runInitialization(
                generation: generation,
                onWriteCompleted: { [weak self] command in
                    await self?.recordInitializationWrite(command, generation: generation)
                }
            )

            guard currentGeneration == generation,
                  await connection.setupReady(),
                  !Task.isCancelled else { return }
            setupCompleteGeneration = generation
            // Edge seeds link freshness at the moment the fully subscribed
            // session enters listening.  A real inbound frame then advances
            // this timestamp; maintenance can distinguish a silent link from
            // a setup that simply has no historical payload yet.
            lastValidFrameAt = clock.now()
            lastHeartbeatAt = clock.now()
            lastKeepAliveAt = clock.now()
            lastHistoryRefreshAt = clock.now()
            await live.markHistorySafetyPassed()
            await reconnect.connected(generation: generation)
            scheduleClockRecheckIfSupported(generation: generation)
            scheduleMaintenanceIfSupported(generation: generation)
            await emitState()
        } catch is CancellationError {
            return
        } catch let error as SerializedWriterError {
            if case .timedOut(let seconds) = error {
                writeTimeoutCount &+= 1
                if setupFirstWritePending,
                   seconds == Int(SerializedGenerationPinnedWriter.firstSetupWriteTimeout) {
                    _ = setupBondRecovery.recordFirstWriteTimeout()
                }
            } else if case .bondFailure(let transportError) = error {
                _ = setupBondRecovery.recordTransportFailure(transportError)
            }
            await failSetup(generation: generation, error: error)
        } catch {
            await failSetup(generation: generation, error: error)
        }
    }

    private func failSetup(generation: UInt64, error: Error) async {
        guard currentGeneration == generation else { return }
        setupFirstWritePending = false
        // A completed Task is not cancelled. Leaving it here prevents
        // beginSetup from initializing the next connection after a write fails.
        setupTask = nil
        setHistoryOffloadActive(false, reason: "setup failed")
        lastError = String(describing: error)
        await record(
            .error,
            generation: generation,
            label: "Setup error",
            detail: String(describing: error)
        )
        setupCompleteGeneration = nil
        pendingClockGet = nil
        charging = nil
        onWrist = nil
        failBandExchanges()
        clockRecheckTask?.cancel()
        clockRecheckTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await live.reset()
        await writer.disconnect()
        await disconnectConnectionIfNeeded()
        currentGeneration = nil
        await generationBox.set(nil)
        if setupBondRecovery.requiredRepair == nil {
            await requestReconnect(generation: generation)
        }
        await emitState()
    }

    private func recordSetupFirstWriteSuccess(generation: UInt64) {
        guard currentGeneration == generation else { return }
        setupFirstWritePending = false
        setupBondRecovery.recordFirstWriteSuccess()
    }

    private func handleDisconnect(_ event: TransportEvent, generation: UInt64) async {
        setupTask?.cancel()
        setupTask = nil
        clockRecheckTask?.cancel()
        clockRecheckTask = nil
        pendingClockGet = nil
        charging = nil
        onWrist = nil
        failBandExchanges()
        clockDiscipline.disconnect()
        setupCompleteGeneration = nil
        setHistoryOffloadActive(false, reason: "disconnect")
        historyBufferedItems = 0
        await live.reset()
        await writer.disconnect()
        currentGeneration = nil
        await generationBox.set(nil)

        if case .disconnected(_, let error) = event,
           error == .outOfRange {
            radioState = .outOfRange
        }
        if case .disconnectedInSession(_, let error) = event,
           error == .outOfRange {
            radioState = .outOfRange
        }
        // iOS refuses every connect while it holds a bond the band dropped.
        // Latch the repair state instead of retrying forever.
        let linkError: TransportError?
        switch event {
        case .disconnected(_, let error), .disconnectedInSession(_, let error): linkError = error
        default: linkError = nil
        }
        if let linkError, linkError.isBondFailure {
            _ = setupBondRecovery.recordTransportFailure(linkError)
            await record(
                .error,
                generation: generation,
                label: "Pairing error",
                detail: String(describing: linkError)
            )
        }
        if setupBondRecovery.requiredRepair == nil {
            await requestReconnect(generation: generation)
        }
        await emitState()
    }

    private func scheduleClockRecheckIfSupported(generation: UInt64) {
        guard clock.supportsAutonomousSleep else { return }
        clockRecheckTask?.cancel()
        let interval = ClockDiscipline.recheckInterval
        clockRecheckTask = Task { [weak self] in
            do { try await self?.clock.sleep(for: interval) }
            catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.checkClockRecheck(generation: generation)
        }
    }

    private func scheduleMaintenanceIfSupported(generation: UInt64) {
        guard clock.supportsAutonomousSleep else { return }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.clock.sleep(for: 10) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self.maintenanceTick(generation: generation)
            }
        }
    }

    /// Runs Edge's three maintenance cadences against a deterministic clock.
    /// Production invokes this every ten seconds; tests and background hosts
    /// can call it directly after advancing their injected clock.
    @discardableResult
    public func maintenanceTick() async -> Bool {
        guard let generation = currentGeneration else { return false }
        return await maintenanceTick(generation: generation)
    }

    @discardableResult
    private func maintenanceTick(generation: UInt64) async -> Bool {
        guard running,
              currentGeneration == generation,
              setupCompleteGeneration == generation else { return false }
        let now = clock.now()

        // Edge's keep-alive watchdog treats link freshness separately from
        // durable history progress.  It bounces a zombie link only after the
        // 120-second active-session fuse; a 30-second link-freshness window is
        // exposed by ConnectionHealthEvaluator for BG trust decisions.
        if let lastValidFrameAt,
           now.timeIntervalSince(lastValidFrameAt) > ReconnectTimingDefaults.livenessBounce {
            await recoverTransport(generation: generation)
            return true
        }

        // Edge pauses keep-alive traffic during a history burst too, but it
        // aborts a burst that has been idle for 60 seconds. Without that
        // escape the flag stayed set and LINK_VALID was never written again.
        // Clearing the flag alone leaves the band still believing it owes us
        // a transfer, so send ABORT_HISTORICAL_TRANSMITS first, as Edge does
        // in _abortAndRetryHistorical.
        if historyOffloadActive,
           healthEvaluator.offloadIsStalled(
               startedAt: historyStallReference,
               now: now
           ) {
            let abortSequence = await liveSequences.next()
            do {
                try await writer.write(
                    .abortHistoricalData(sequence: abortSequence),
                    generation: generation
                )
            } catch {
                lastError = String(describing: error)
            }
            setHistoryOffloadActive(false, reason: "stalled offload aborted")
        }

        var performed = false
        if !historyOffloadActive,
           (lastHeartbeatAt == nil || now.timeIntervalSince(lastHeartbeatAt!) >= 10) {
            let sequence = await liveSequences.next()
            do {
                try await writer.write(.linkValid(sequence: sequence), generation: generation)
                lastHeartbeatAt = now
                performed = true
            } catch {
                lastError = String(describing: error)
            }
        }

        if !historyOffloadActive,
           (lastKeepAliveAt == nil || now.timeIntervalSince(lastKeepAliveAt!) >= 30) {
            do {
                let batterySequence = await liveSequences.next()
                try await writer.write(
                    .getBatteryLevel(sequence: batterySequence),
                    generation: generation
                )
                let effective = await live.effectiveEnabledKinds()
                try await liveWireController.rearm(effectiveKinds: effective)
                lastKeepAliveAt = now
                performed = true
            } catch {
                lastError = String(describing: error)
            }
        }

        if !historyOffloadActive,
           (lastHistoryRefreshAt == nil ||
            now.timeIntervalSince(lastHistoryRefreshAt!) >= ReconnectTimingDefaults.periodicHistoryRequest) {
            do {
                try await requestHistoryRefresh(generation: generation)
                performed = true
            } catch {
                lastError = String(describing: error)
            }
        }
        logMaintenanceSummary()
        await logLiveWireModeIfChanged()
        await emitState()
        return performed
    }

    /// When the active offload last made progress, for the sixty-second stall
    /// fuse.
    ///
    /// This used to read `lastHistoryActivityAt ?? lastHistoryRefreshAt`, which
    /// is wrong the moment a new request follows an old drain: the activity
    /// stamp from fifteen minutes ago won, the brand-new burst looked stalled
    /// on the very next tick, and Loopr sent ABORT_HISTORICAL_TRANSMITS about a
    /// second after asking for the data. The band ends the burst on that abort.
    /// The request that opened the burst is progress, so take the later stamp.
    private var historyStallReference: Date? {
        switch (lastHistoryActivityAt, lastHistoryRefreshAt) {
        case let (activity?, refresh?):
            return max(activity, refresh)
        case let (activity?, nil):
            return activity
        case let (nil, refresh?):
            return refresh
        case (nil, nil):
            return lastValidFrameAt
        }
    }

    /// The wake-driven half of the maintenance cadence.
    ///
    /// `scheduleMaintenanceIfSupported` sleeps on a timer, and a timer does not
    /// fire while iOS has the app suspended, so overnight the ten-second tick
    /// simply never runs. A notification from the band does wake the app for a
    /// few seconds, and this runs in that window: it clears a drain that died
    /// while the app was asleep and asks for the next history chunk once the
    /// fifteen-minute floor has passed. It is safe in the foreground too, where
    /// it only ever agrees with the tick.
    @discardableResult
    public func evaluateEventDrivenMaintenance() async -> Bool {
        guard let generation = currentGeneration else { return false }
        return await evaluateEventDrivenMaintenance(generation: generation)
    }

    @discardableResult
    private func evaluateEventDrivenMaintenance(generation: UInt64) async -> Bool {
        guard running,
              currentGeneration == generation,
              setupCompleteGeneration == generation else { return false }
        let now = clock.now()

        if historyOffloadActive,
           healthEvaluator.offloadIsStalled(
               startedAt: historyStallReference,
               now: now
           ) {
            let abortSequence = await liveSequences.next()
            do {
                try await writer.write(
                    .abortHistoricalData(sequence: abortSequence),
                    generation: generation
                )
            } catch {
                lastError = String(describing: error)
            }
            setHistoryOffloadActive(false, reason: "stalled offload aborted on wake")
        }

        guard !historyOffloadActive,
              healthEvaluator.shouldRequestPeriodicHistory(
                  lastRequestAt: lastHistoryRefreshAt,
                  now: now
              ) else { return false }
        let age = lastHistoryRefreshAt.map { now.timeIntervalSince($0) } ?? -1
        Self.debugLog(String(
            format: "background top-up requested; backgrounded=%@ sinceLastRefresh=%.0fs",
            applicationIsBackgrounded ? "yes" : "no",
            age
        ))
        do {
            try await requestHistoryRefresh(generation: generation)
            await emitState()
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// One line whenever a packet arrives after enough silence that iOS had
    /// almost certainly suspended the app. This is the overnight evidence that
    /// the band is still waking Loopr.
    private func logBackgroundWakeIfNeeded() {
        guard applicationIsBackgrounded else { return }
        let now = clock.now()
        guard let previous = lastInboundPacketAt else {
            Self.debugLog("background wake; first inbound packet of this session")
            return
        }
        let silence = now.timeIntervalSince(previous)
        guard silence >= 15 else { return }
        Self.debugLog(String(format: "background wake; inbound packet after %.0fs of silence", silence))
    }

    /// One DEBUG line per maintenance tick with the inbound packet mix and
    /// the rolling corruption rate. This is the on-device signal that tells a
    /// supervision-timeout drop apart from a quiet link.
    private func logMaintenanceSummary() {
        let counts = packetTypeCountsSinceTick
        packetTypeCountsSinceTick.removeAll(keepingCapacity: true)
        let named: [UInt8] = [0x28, 0x2B, 0x33, 0x2F]
        let other = counts.reduce(into: 0) { total, entry in
            if !named.contains(entry.key) { total += entry.value }
        }
        let otherTypes = counts.filter { !named.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { String(format: "0x%02x=%d", $0.key, $0.value) }
            .joined(separator: " ")
        if !otherTypes.isEmpty { Self.debugLog("tick other types \(otherTypes)") }
        let corruption = rollingCorruption.snapshot()
        Self.debugLog(String(
            format: "tick packets 0x28=%d 0x2B=%d 0x33=%d 0x2F=%d other=%d corruption=%.2f offload=%@",
            counts[0x28] ?? 0,
            counts[0x2B] ?? 0,
            counts[0x33] ?? 0,
            counts[0x2F] ?? 0,
            other,
            corruption.corruptionRate,
            historyOffloadActive ? "on" : "off"
        ))
    }

    /// Re-kicks Edge's current-session historical path: GET_DATA_RANGE, the
    /// pinned 120 ms inter-command gap, then SEND_HISTORICAL_DATA.  The
    /// HistoryCoordinator still owns burst parsing/commit/ACK; this method is
    /// only the transport request and never invents a cursor or token.
    private func requestHistoryRefresh(generation: UInt64) async throws {
        guard currentGeneration == generation,
              setupCompleteGeneration == generation else {
            throw SerializedWriterError.noActiveGeneration
        }
        // Reserve the transfer before the first await so foreground and
        // background callers cannot enqueue two requests for the same band.
        guard !historyOffloadActive else { return }
        setHistoryOffloadActive(true, reason: "history refresh requested")
        // Stamp the refresh here rather than only at the maintenance call
        // site. A manual sync followed immediately by the maintenance
        // boundary otherwise sent two SEND_HISTORICAL_DATA within seconds;
        // Edge floors 0x16 at five seconds for the same reason.
        lastHistoryRefreshAt = clock.now()
        do {
            let rangeSequence = await liveSequences.next()
            try await writer.write(.dataRange(sequence: rangeSequence), generation: generation)
            try await clock.sleep(for: 0.120)
            guard currentGeneration == generation,
                  setupCompleteGeneration == generation else {
                throw SerializedWriterError.staleGeneration(
                    expected: generation,
                    actual: currentGeneration
                )
            }
            let historySequence = await liveSequences.next()
            try await writer.write(
                .startHistoricalData(sequence: historySequence),
                generation: generation
            )
        } catch {
            if currentGeneration == generation {
                setHistoryOffloadActive(false, reason: "history refresh failed")
            }
            throw error
        }
    }

    /// Deterministic/test and host lifecycle hook for the six-hour clock
    /// discipline check. It emits only a typed GET_CLOCK command when due.
    @discardableResult
    public func checkClockRecheck() async -> Bool {
        guard let generation = currentGeneration else { return false }
        return await checkClockRecheck(generation: generation)
    }

    private func checkClockRecheck(generation: UInt64) async -> Bool {
        guard currentGeneration == generation,
              setupCompleteGeneration == generation,
              clockDiscipline.shouldRecheck(now: clock.now()) else { return false }
        let sequence = await liveSequences.next()
        pendingClockGet = (
            generation: generation,
            sequence: sequence,
            wallDate: clock.now()
        )
        do {
            try await writer.write(.getClock(sequence: sequence), generation: generation)
            await record(
                .clockGet,
                generation: generation,
                label: "GET_CLOCK",
                detail: "Write response received"
            )
            return true
        } catch {
            pendingClockGet = nil
            lastError = String(describing: error)
            await record(
                .error,
                generation: generation,
                label: "Clock error",
                detail: String(describing: error)
            )
            return false
        }
    }

    private func performReconnect(_ request: ReconnectRequest) async {
        // Consume first. A request that stays pending because the runtime was
        // briefly stopped blocks every later `disconnected()` call, and nothing
        // would ever schedule another reconnect.
        guard await reconnect.consume(request) else { return }
        guard running else {
            Self.debugLog("reconnect dropped; runtime is not running")
            return
        }
        // The connection coordinator intentionally remains in `.reconnecting`
        // after a callback. Release that attempt before allocating the new
        // generation; otherwise start() would correctly refuse a duplicate
        // in-flight attempt. The backoff counter is deliberately left alone:
        // only a completed setup resets it, as in Edge.
        await disconnectConnectionIfNeeded()
        var plan = await connection.start()
        if plan == .none {
            // start() refuses while an attempt looks in flight. Nothing else
            // would ever retry, so force the coordinator back to idle.
            await connection.disconnect()
            plan = await connection.start()
        }
        await adoptConnectionGeneration()
        Self.debugLog("reconnect performed; plan=\(plan)")
        if plan == .none {
            await record(
                .error,
                generation: request.generation,
                label: "Reconnect error",
                detail: "Connection start refused"
            )
            await requestReconnect(generation: request.generation)
        }
        await emitState()
    }

    private func connectionTimedOut(generation: UInt64) async {
        guard running, currentGeneration == generation else { return }
        if case .outOfRange = await connection.state() { radioState = .outOfRange }
        await failSetup(generation: generation, error: TransportError.outOfRange)
    }

    /// Runs the same deadline check as the autonomous connection watchdog.
    @discardableResult
    public func expireConnectionWatchdogIfNeeded() async -> Bool {
        await connection.expireWatchdogIfNeeded()
    }

    private func requestReconnect(generation: UInt64) async {
        guard running, radioState != .poweredOff else {
            Self.debugLog("reconnect not requested; running=\(running), radio=\(radioState)")
            return
        }
        let request = await reconnect.disconnected(generation: generation, now: clock.now())
        Self.debugLog("reconnect requested; generation=\(generation), delay=\(request.map { String($0.delay) } ?? "already pending or stale")")
    }

    private static func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[Loopr Runtime] \(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        fputs(line, stderr)
        #endif
    }

    private func process(frames: [Frame], generation: UInt64) async {
        guard !frames.isEmpty else { return }
        let decoder = PacketDecoder()
        for frame in frames {
            guard currentGeneration == generation else {
                await record(.staleConnection, generation: generation)
                continue
            }
            do {
                let packet = try decoder.decode(frame)
                validFrameCount &+= 1
                await applyCorruptionSample(validFrame: true)
                lastValidFrameAt = clock.now()
                lastInboundPacketAt = clock.now()
                countInboundPacket(frame)
                await record(.validFrame, generation: generation)
                await route(packet, rawFrame: frame, generation: generation)
            } catch {
                corruptFrameCount &+= 1
                await applyCorruptionSample(validFrame: false)
                countInboundPacket(frame)
                await record(.corruptFrame, generation: generation)
                await record(
                    .error,
                    generation: generation,
                    label: "Protocol error",
                    detail: String(describing: error)
                )
                if frame.paddedInner.first == PacketType.historicalRecord.rawValue {
                    await routeArchive(
                        raw: frame.paddedInner,
                        version: frame.paddedInner.count > 1 ? frame.paddedInner[1] : nil,
                        reason: String(describing: error),
                        generation: generation
                    )
                }
            }
        }
    }

    /// Records one frame against the rolling corruption window and latches the
    /// degraded live mode the first time the window crosses its threshold.
    /// The latch is deliberately sticky even though the detector is not: a
    /// link that has already proven noisy this session does not earn the raw
    /// and IMU streams back by going quiet for fifty frames.
    private func applyCorruptionSample(validFrame: Bool) async {
        let state = rollingCorruption.record(validFrame: validFrame)
        guard state.thresholdExceeded, !degradedLiveModeLatched else { return }
        degradedLiveModeLatched = true
        await liveWireController.setDegraded(true)
        Self.debugLog(String(
            format: "live mode degraded; corruption rate %.2f over %d samples",
            state.corruptionRate,
            state.sampleCount
        ))
        // Bring the wire down to heart rate only now rather than waiting for
        // the next lease change to reconcile.
        let effective = await live.effectiveEnabledKinds()
        let requested = await live.enabledKinds()
        let policy = await live.currentBackgroundPolicy()
        try? await liveWireController.reconcile(
            previousEffectiveKinds: effective,
            requestedKinds: requested,
            effectiveKinds: effective,
            policy: policy
        )
        await logLiveWireModeIfChanged()
    }

    /// Counts inbound packet families for the per-tick DEBUG summary. Only
    /// the discriminator byte is retained; no payload bytes are kept.
    private func countInboundPacket(_ frame: Frame) {
        guard let type = frame.paddedInner.first else { return }
        packetTypeCountsSinceTick[type, default: 0] += 1
    }

    private func logLiveWireModeIfChanged() async {
        let mode = await liveWireController.currentMode()
        guard mode != lastLoggedLiveWireMode else { return }
        lastLoggedLiveWireMode = mode
        Self.debugLog("live wire mode=\(mode) degraded=\(degradedLiveModeLatched)")
    }

    /// The single writer for the historical-offload flag, so every change can
    /// be attributed in DEBUG builds.
    private func setHistoryOffloadActive(_ value: Bool, reason: String) {
        guard historyOffloadActive != value else { return }
        historyOffloadActive = value
        // The mirror into the live wire runs on an unstructured task, so two
        // quick toggles could land out of order and leave the controller
        // believing a drain is still running. A stale token is dropped.
        historyDrainSequence &+= 1
        let sequence = historyDrainSequence
        Self.debugLog("historyOffloadActive=\(value) reason=\(reason)")
        Task { [weak self] in
            await self?.applyHistoryDrainToLiveWire(value, sequence: sequence)
        }
    }

    /// Tells the live wire whether a drain is running, and replays any step
    /// down that was held while it ran.
    private func applyHistoryDrainToLiveWire(_ active: Bool, sequence: UInt64) async {
        guard sequence == historyDrainSequence else { return }
        let replay = await liveWireController.setHistoryDrainActive(active)
        guard replay, currentGeneration != nil else { return }
        let effective = await live.effectiveEnabledKinds()
        let requested = await live.enabledKinds()
        let policy = await live.currentBackgroundPolicy()
        try? await liveWireController.reconcile(
            previousEffectiveKinds: effective,
            requestedKinds: requested,
            effectiveKinds: effective,
            policy: policy
        )
        await logLiveWireModeIfChanged()
    }

    private func route(
        _ packet: DecodedPacket,
        rawFrame: Frame,
        generation: UInt64
    ) async {
        switch packet {
        case .historyMetadata(let payload):
            lastHistoryActivityAt = clock.now()
            await routeHistoryMetadata(payload, generation: generation)

        case .historicalRecord(let record):
            lastHistoryActivityAt = clock.now()
            switch record {
            case .decoded(let decoded):
                await routeDecodedRecord(decoded, generation: generation)
            case .unsupported(let version, let raw, let reason):
                await routeArchive(
                    raw: raw,
                    version: version,
                    reason: reason.description,
                    generation: generation
                )
            }

        case .compactLiveHeartRate(let payload):
            await live.ingest(
                kind: .compactHeartRateRR,
                payload: payload,
                receivedAt: clock.now(),
                generation: generation
            )
        case .realtimeRaw(let payload):
            await live.ingest(
                kind: .realtimeRaw,
                payload: payload,
                receivedAt: clock.now(),
                generation: generation
            )
        case .realtimeIMU(let payload):
            await live.ingest(
                kind: .realtimeIMU,
                payload: payload,
                receivedAt: clock.now(),
                generation: generation
            )

        case .commandResponse(let payload):
            let inner = Data([PacketType.commandResponse.rawValue]) + payload
            // Band actions are resolved first so a caller waiting on an
            // exchange is woken before the battery/name/clock handling below,
            // which stays exactly as it was for the commands it owns.
            if !pendingBandExchanges.isEmpty {
                let waiting = pendingBandExchanges.keys
                    .map { "0x" + String($0.sequence, radix: 16) + "/0x" + String($0.opcode, radix: 16) }
                    .joined(separator: ",")
                Self.debugLog("cmd response while waiting; head=\(payload.prefix(32).map { String(format: "%02x", $0) }.joined()) waiting=\(waiting)")
            }
            // payload[0] is the band's own rolling packet counter, not the
            // sequence we sent. Our sequence comes back at payload[2]. Keying
            // on payload[0] matched nothing, so every exchange that expected a
            // reply timed out even though the band had already answered.
            if payload.count >= 3 {
                let key = BandExchangeKey(
                    generation: generation,
                    sequence: payload[2],
                    opcode: payload[1]
                )
                if let continuation = pendingBandExchanges.removeValue(forKey: key) {
                    Self.debugLog("band command response; opcode=0x\(String(key.opcode, radix: 16)) outcome=ok")
                    continuation.resume(returning: inner)
                }
            }
            if payload.count >= 2 {
                switch payload[1] {
                case BatteryCommand.opcode:
                    if let response = try? BatteryCommand.decodeResponse(inner) { batteryPercentage = response.percentage }
                case 0x4C:
                    if let name = try? IdentityCommand.decodeAdvertisingNameResponse(inner) { advertisingName = name }
                case 0x22:
                    routeDataRangeResponse(payload)
                default: break
                }
            }
            await routeClockResponse(payload, generation: generation)

        case .unknown:
            // Unknown packet types are retained as bounded protocol errors.
            // The packet bytes never enter diagnostics.
            await record(
                .error,
                generation: generation,
                label: "Protocol error",
                detail: "Unknown packet type"
            )

        case .event(let payload):
            // Event bodies are never retained. Typed state and event metadata
            // cross into the runtime.
            routeBandEvent(payload, generation: generation)

        case .console(let bytes):
            // A valid link observation, but not history, a live sample, or an
            // event. Its bytes stay out of diagnostics and storage.
            _ = rawFrame
            _ = bytes
        }
    }

    private func routeClockResponse(_ payload: Data, generation: UInt64) async {
        // All command replies share this packet type. SET_CLOCK and the
        // initialization commands can reply while GET_CLOCK is outstanding.
        // Only the matching clock reply belongs to the clock parser.
        let bytes = Array(payload)
        guard bytes.count >= 3, bytes[1] == 0x0B else { return }
        // bytes[0] is the band's rolling packet counter; the echo of the
        // sequence we sent is bytes[2].
        let sequenceEcho = bytes[2]
        // A GET_CLOCK issued by a band action carries a sequence from the
        // reserved band range and has already been handed to its caller.
        // Treating it as an unexpected clock reply would log a false stale
        // observation on every alarm set.
        guard !BandExchangeSequences.contains(sequenceEcho) else { return }
        guard let pending = pendingClockGet,
              pending.generation == generation else {
            await record(.staleConnection, generation: generation)
            return
        }
        guard sequenceEcho == pending.sequence else {
            await record(.staleConnection, generation: generation)
            return
        }
        do {
            let response = try ClockResponse.parse(Data([PacketType.commandResponse.rawValue]) + payload, wallDate: pending.wallDate)
            pendingClockGet = nil
            let delta = pending.wallDate.timeIntervalSince(response.bandDate)
            await record(
                .clockGet,
                generation: generation,
                label: "GET_CLOCK",
                detail: String(format: "Readback delta %+.3f s", delta)
            )
            let decision = clockDiscipline.evaluate(
                response: response,
                wallDate: pending.wallDate
            )
            switch decision {
            case .accepted, .rejectedFuture, .rejectedPreEpoch:
                if case .rejectedFuture = decision {
                    lastError = "GET_CLOCK response is too far in the future"
                    await record(.error, generation: generation, label: "Clock error", detail: lastError)
                } else if case .rejectedPreEpoch = decision {
                    lastError = "GET_CLOCK response is before the supported epoch"
                    await record(.error, generation: generation, label: "Clock error", detail: lastError)
                }
            case .requiresCorrection(let correlation):
                guard clockDiscipline.recordCorrection() else {
                    lastError = "GET_CLOCK correction budget exhausted"
                    await record(.error, generation: generation, label: "Clock error", detail: lastError)
                    return
                }
                let setSequence = await liveSequences.next()
                let getSequence = await liveSequences.next()
                pendingClockGet = (
                    generation: generation,
                    sequence: getSequence,
                    wallDate: pending.wallDate
                )
                _ = correlation
                do {
                    _ = try await clockExchange.send(
                        wallDate: pending.wallDate,
                        generation: generation,
                        setSequence: setSequence,
                        getSequence: getSequence
                    )
                } catch {
                    pendingClockGet = nil
                    lastError = String(describing: error)
                    await record(.error, generation: generation, label: "Clock error", detail: lastError)
                }
            case .correctionLimitReached:
                lastError = "GET_CLOCK correction budget exhausted"
                await record(.error, generation: generation, label: "Clock error", detail: lastError)
            }
        } catch {
            lastError = String(describing: error)
            await record(.error, generation: generation, label: "Clock error", detail: lastError)
        }
    }

    private struct HistoryMarker {
        enum Kind { case start, end, complete, metadata }
        let kind: Kind
        let token: HistoryToken?
    }

    private func marker(for payload: Data) -> HistoryMarker? {
        guard payload.count > 1 else { return nil }
        switch payload[1] {
        case 1: return HistoryMarker(kind: .start, token: nil)
        case 2:
            let token = payload.count >= 20
                ? try? HistoryToken(bytes: Data(payload[12..<20]))
                : nil
            return HistoryMarker(kind: .end, token: token)
        case 3: return HistoryMarker(kind: .complete, token: nil)
        default: return HistoryMarker(kind: .metadata, token: nil)
        }
    }

    private func routeHistoryMetadata(_ payload: Data, generation: UInt64) async {
        Self.debugLog("history metadata bytes=\(payload.map { String(format: "%02x", $0) }.joined())")
        guard let marker = marker(for: payload) else {
            await record(
                .historyMetadataReceived,
                generation: generation,
                label: "History metadata",
                detail: "Metadata received (\(payload.count) bytes)"
            )
            await receiveMetadata(payload, generation: generation)
            return
        }
        let detail: String
        switch marker.kind {
        case .start: detail = "Chunk start"
        case .end: detail = "Chunk end"
        case .complete: detail = "History complete"
        case .metadata: detail = "Metadata received (\(payload.count) bytes)"
        }
        await record(
            .historyMetadataReceived,
            generation: generation,
            label: "History metadata",
            detail: detail
        )
        switch marker.kind {
        case .start:
            setHistoryOffloadActive(true, reason: "history start marker")
            do {
                _ = try await history.beginBurst(
                    generation: generation,
                    receivedAt: Int64(clock.now().timeIntervalSince1970)
                )
                historyBufferedItems = 0
                await record(
                    .historyDrainStarted,
                    generation: generation,
                    correlationID: "history-\(generation)"
                )
            } catch {
                lastError = String(describing: error)
                await record(.error, generation: generation, label: "History error", detail: lastError)
            }

        case .end:
            guard let token = marker.token else {
                await receiveMetadata(payload, generation: generation)
                return
            }
            let outcome = await history.receiveHistoryEnd(
                token: token,
                generation: generation
            )
            await routeTerminal(
                outcome,
                generation: generation,
                correlationID: token.derivedBatchID,
                token: token
            )

        case .complete:
            let outcome = await history.receiveHistoryComplete(generation: generation)
            await routeTerminal(
                outcome,
                generation: generation,
                correlationID: "history-\(generation)",
                token: nil
            )

        case .metadata:
            await receiveMetadata(payload, generation: generation)
        }
    }

    private func receiveMetadata(_ payload: Data, generation: UInt64) async {
        do {
            let outcome = try await history.receiveMetadata(payload, generation: generation)
            if case .rejected(let error) = outcome {
                lastError = error.localizedDescription
                await record(.error, generation: generation, label: "History error", detail: lastError)
            }
        } catch {
            lastError = String(describing: error)
            await record(.error, generation: generation, label: "History error", detail: lastError)
        }
    }

    private var historicalRecordsStoredThisSession = 0
    private var bandDataRange: (oldest: UInt32, newest: UInt32)?

    /// Reads the banked-data window the band reports for GET_DATA_RANGE.
    ///
    /// The band answers with the oldest and newest seconds it still holds.
    /// Loopr asked for this window from the first release and then threw the
    /// answer away, so it could not tell an empty band from a stalled
    /// transfer. The reference scans the body for plausible epochs rather
    /// than reading fixed offsets, because the response carries junk at
    /// unstable offsets on some firmware. A newest far in the future means a
    /// wandering RTC, and is rejected instead of trusted.
    private func routeDataRangeResponse(_ payload: Data) {
        // Drops the band counter and the opcode. The sequence echo and status
        // bytes stay in the window on purpose: this is a scan, not a fixed
        // read, and it already returns the right range on hardware.
        let body = payload.dropFirst(2)
        guard body.count >= 4 else { return }
        let bytes = [UInt8](body)
        let now = UInt32(clock.now().timeIntervalSince1970)
        let earliestPlausible: UInt32 = 1_600_000_000
        var found: [UInt32] = []
        for offset in 0...(bytes.count - 4) {
            let value = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            if value > earliestPlausible, value < now &+ 86_400 { found.append(value) }
        }
        guard let oldest = found.min(), let newest = found.max() else {
            bandDataRange = nil
            Self.debugLog("band data range: none reported, body=\(bytes.map { String(format: "%02x", $0) }.joined())")
            return
        }
        bandDataRange = (oldest, newest)
        let bankedSeconds = Int(newest) - Int(oldest)
        Self.debugLog("band data range oldest=\(oldest) newest=\(newest) banked=\(bankedSeconds)s")
    }


    private func routeDecodedRecord(
        _ decoded: DecodedHistoricalRecord,
        generation: UInt64
    ) async {
        historicalRecordsStoredThisSession += 1
        guard historyBufferedItems < historyBufferLimit else {
            await failHistoryBuffer(generation: generation)
            return
        }
        // Waveform-only versions share seconds with v24. Writing an empty
        // physiological row would overwrite that second's HR, motion and RR.
        guard decoded.heartRate != nil || decoded.gravity != nil || !decoded.rrIntervalsMilliseconds.isEmpty ||
                decoded.ppgGreen != nil || decoded.ppgRedIR != nil || decoded.skinContact != nil ||
                decoded.spo2RedRaw != nil || decoded.spo2IRRaw != nil || decoded.unidentified68 != nil ||
                decoded.ambientRaw != nil else {
            await routeArchive(raw: decoded.raw, version: decoded.version,
                reason: "Waveform retained without replacing the canonical physiological second", generation: generation)
            return
        }
        let stored = StoredHistoricalRecord(
            decoded: decoded,
            localDay: localDay(for: decoded.timestampSeconds)
        )
        do {
            let outcome = try await history.receive(record: stored, generation: generation)
            if case .buffered = outcome {
                historyBufferedItems += 1
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func routeArchive(
        raw: Data,
        version: UInt8?,
        reason: String,
        generation: UInt64
    ) async {
        guard historyBufferedItems < historyBufferLimit else {
            await failHistoryBuffer(generation: generation)
            return
        }
        let archived = ArchivedHistoricalRecord(
            raw: raw,
            reason: reason,
            capturedAt: Int64(clock.now().timeIntervalSince1970),
            packetType: raw.first,
            version: version
        )
        do {
            let outcome = try await history.receive(archived: archived, generation: generation)
            if case .buffered = outcome {
                historyBufferedItems += 1
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func failHistoryBuffer(generation: UInt64) async {
        lastError = "history buffer limit \(historyBufferLimit) exceeded"
        try? await history.discardBurst(generation: generation)
        await requestReconnect(generation: generation)
    }

    private func routeTerminal(
        _ outcome: HistoryCoordinatorOutcome,
        generation: UInt64,
        correlationID: String,
        token: HistoryToken?
    ) async {
        Self.debugLog("history terminal outcome=\(outcome) id=\(correlationID) storedThisSession=\(historicalRecordsStoredThisSession)")
        switch outcome {
        case .acknowledged:
            let acknowledgedAt = clock.now()
            lastHistoricalCommitAt = acknowledgedAt
            lastHistoricalAcknowledgementAt = acknowledgedAt
            await record(.historyCommitted, generation: generation, correlationID: correlationID)
            await record(
                .acknowledgementEmitted,
                generation: generation,
                correlationID: correlationID
            )
            historyBufferedItems = 0
            // HISTORY_END closes one tokenized chunk, not the historical
            // offload. Edge immediately keeps the same drain open for the
            // next chunk and suppresses maintenance traffic until the band
            // emits HISTORY_COMPLETE. A fresh HISTORY_START is not required
            // between tokenized chunks on real backlogs.
            do {
                _ = try await history.beginBurst(
                    generation: generation,
                    receivedAt: Int64(clock.now().timeIntervalSince1970)
                )
                setHistoryOffloadActive(true, reason: "next tokenized chunk")
            } catch {
                setHistoryOffloadActive(false, reason: "burst open failed")
                lastError = String(describing: error)
                await recoverTransport(generation: generation)
            }

        case .committedWithoutAck:
            lastHistoryCompletedAt = clock.now()
            setHistoryOffloadActive(false, reason: "committed without ack")
            lastHistoricalCommitAt = clock.now()
            await record(.historyCommitted, generation: generation, correlationID: correlationID)
            historyBufferedItems = 0
            await record(.historyDrainCompleted, generation: generation, correlationID: correlationID)

        case .completionTailCommitted:
            lastHistoryCompletedAt = clock.now()
            setHistoryOffloadActive(false, reason: "completion tail committed")
            lastHistoricalCommitAt = clock.now()
            await record(.historyCommitted, generation: generation, correlationID: correlationID)
            historyBufferedItems = 0
            await record(.historyDrainCompleted, generation: generation, correlationID: correlationID)

        case .ackExhausted:
            setHistoryOffloadActive(false, reason: "ack exhausted")
            lastHistoricalCommitAt = clock.now()
            await record(.historyCommitted, generation: generation, correlationID: correlationID)
            historyBufferedItems = 0
            await record(.historyDrainCompleted, generation: generation, correlationID: correlationID)
            await recoverTransport(generation: generation)

        case .rejected(let error):
            setHistoryOffloadActive(false, reason: "history rejected")
            lastError = error.localizedDescription
            if case .ackFailed = error {
                // CommandBuilder/transport ACK failures occur only after the
                // coordinator has received a durable tokenized commit. Keep
                // that progress visible, but never claim that an ACK was
                // emitted; recovery will redeliver safely.
                lastHistoricalCommitAt = clock.now()
                await record(.historyCommitted, generation: generation, correlationID: correlationID)
                historyBufferedItems = 0
                await record(.historyDrainCompleted, generation: generation, correlationID: correlationID)
                await recoverTransport(generation: generation)
            } else if case .commitFailed = error {
                Self.debugLog("history commit failed; \(error.localizedDescription)")
                await recoverTransport(generation: generation)
            }

        case .burstOpened, .buffered:
            _ = token
        }
    }

    private func recoverTransport(generation: UInt64) async {
        guard currentGeneration == generation else {
            await requestReconnect(generation: generation)
            return
        }
        // beginSetup treats any non-cancelled task as in flight, so a task
        // left here blocks setup on every later connection.
        setupTask?.cancel()
        setupTask = nil
        clockRecheckTask?.cancel()
        clockRecheckTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        setupCompleteGeneration = nil
        pendingClockGet = nil
        charging = nil
        onWrist = nil
        failBandExchanges()
        setHistoryOffloadActive(false, reason: "transport recovery")
        await live.reset()
        await writer.disconnect()
        await disconnectConnectionIfNeeded()
        currentGeneration = nil
        await generationBox.set(nil)
        await requestReconnect(generation: generation)
    }

    private func disconnectConnectionIfNeeded() async {
        guard !transportDisconnectIssued else { return }
        // Set the guard before the await. The actor may re-enter while the
        // native adapter tears down, and a second callback must not issue a
        // second physical disconnect.
        transportDisconnectIssued = true
        await connection.disconnect()
    }

    private func localDay(for timestamp: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func updateRadioState(for event: TransportEvent) {
        guard case .managerState(let manager) = event else { return }
        switch manager {
        case .unknown: radioState = .unknown
        case .resetting: radioState = .resetting
        case .unsupported: radioState = .unsupported
        case .unauthorized: radioState = .unauthorized
        case .poweredOff: radioState = .poweredOff
        case .poweredOn: radioState = .poweredOn
        }
    }

    private func healthReport(now: Date) -> ConnectionHealthReport {
        healthEvaluator.evaluate(
            input: ConnectionLivenessInput(
                radioState: radioState,
                lastValidFrameAt: lastValidFrameAt,
                lastHistoricalCommitAt: lastHistoricalCommitAt,
                validFrameCount: validFrameCount,
                corruptFrameCount: corruptFrameCount,
                writeTimeoutCount: writeTimeoutCount,
                expectedCharacteristicsReady: isSetupComplete,
                rollingCorruption: rollingCorruption.snapshot()
            ),
            now: now
        )
    }

    /// Optional equality is not session equality: `nil == nil` describes no
    /// active generation and must never surface as a completed setup.
    private var isSetupComplete: Bool {
        guard let currentGeneration else { return false }
        return setupCompleteGeneration == currentGeneration
    }

    private func record(
        _ kind: ConnectionDiagnosticsKind,
        generation: UInt64,
        correlationID: String? = nil,
        opcode: UInt8? = nil,
        label: String? = nil,
        detail: String? = nil
    ) async {
        await diagnostics.record(ConnectionDiagnosticsEvent(
            kind: kind,
            timestamp: clock.now(),
            generation: generation,
            correlationID: correlationID,
            opcode: opcode,
            label: label,
            detail: detail
        ))
    }

    private func diagnosticName(for characteristic: CharacteristicID) -> String {
        switch characteristic {
        case HarvardBluetoothProfile.response: "Response notifications"
        case HarvardBluetoothProfile.events: "Event notifications"
        case HarvardBluetoothProfile.data: "Data notifications"
        default: "Characteristic notifications"
        }
    }

    private func recordInitializationWrite(
        _ command: ProductionCommand,
        generation: UInt64
    ) async {
        let label: String
        switch command {
        case .hello: label = "HELLO"
        case .advertisingName: label = "GET_ADVERTISING_NAME"
        case .dataRange: label = "GET_DATA_RANGE"
        case .alarmTime: label = "GET_ALARM_TIME"
        case .startHistoricalData: label = "SEND_HISTORICAL_DATA"
        default: return
        }
        await record(
            .initializationWriteResponse,
            generation: generation,
            label: label,
            detail: "Write response received"
        )
    }
}
