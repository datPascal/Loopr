import Foundation

public enum ConnectionPlan: Equatable, Sendable {
    case retrieve(generation: UInt64, identifier: PeripheralID)
    case scan(generation: UInt64, service: ServiceID)
    case connect(generation: UInt64, peripheral: PeripheralID)
    case none
}

public enum BluetoothWatchdogPhase: Equatable, Sendable {
    case scan
    case connect
    case discovery
    case notifications
}

/// Optional native teardown boundary used by the autonomous watchdog.
///
/// A plain `BLETransport.disconnect()` is intentionally a silent owner
/// teardown: callers such as stop/background expiration have already fenced
/// their session and do not want a second reconnect signal.  A watchdog is
/// different.  It must hand the link-down back through the owning connection
/// session so that the session can clear its identity/parsers and the runtime
/// can observe one accepted, generation-scoped disconnect.  Native transports
/// implement this seam by emitting a scoped disconnect before clearing their
/// native identity.  Deterministic transports that do not have such an event
/// source use the coordinator's local fallback below.
public protocol BLEWatchdogDisconnecting: BLETransport {
    /// Requests a watchdog teardown. Returns `true` when the transport emitted
    /// (or will emit synchronously on its event stream) the scoped disconnect
    /// that owns state-machine teardown. Returns `false` when the coordinator
    /// must perform its deterministic local fallback.
    func disconnectForWatchdog() async -> Bool
}

/// Lets the connect watchdog see a link that CoreBluetooth finished while the
/// app was suspended. The sleeping watchdog and the `didConnect` event wake
/// together; cancelling then would kill the connection that just succeeded.
public protocol BLENativeLinkReporting: BLETransport {
    func isNativeLinkConnected() async -> Bool
}

/// Serializes retrieval, service-filtered scan fallback, connect, disconnect,
/// and foreground timeout decisions around one state machine and one transport.
/// It intentionally has no command/setup behavior; those gates begin only after
/// GATTSession has confirmed all three notifications.
public actor BluetoothConnectionCoordinator {
    private let transport: any BLETransport
    private let store: any AccessoryProvisioningStore
    private let clock: any BluetoothClock
    private var machine = ConnectionStateMachine()
    private var provisionedIdentifier: PeripheralID?
    private var connectDeadlineNanoseconds: UInt64?
    private var watchdogPhase: BluetoothWatchdogPhase?
    private var watchdogTask: Task<Void, Never>?
    private var timeoutHandler: (@Sendable (UInt64) async -> Void)?
    /// Mirrors the host application lifecycle. It changes only how a connect
    /// attempt is bounded, never which peripheral is selected.
    private var applicationIsBackgrounded = false

    public init(
        transport: any BLETransport,
        store: any AccessoryProvisioningStore,
        clock: any BluetoothClock = SystemBluetoothClock()
    ) {
        self.transport = transport
        self.store = store
        self.clock = clock
    }

    public func setTimeoutHandler(_ handler: @escaping @Sendable (UInt64) async -> Void) {
        timeoutHandler = handler
    }

    /// Switches the connect attempt between a bounded foreground deadline and
    /// an unbounded background one.
    ///
    /// iOS keeps a pending `connect` outstanding forever and completes it in
    /// the background when the accessory comes back in range, and that
    /// completion is the only thing that wakes a suspended app. A timer-based
    /// deadline cannot fire while the app is suspended, so letting one cancel
    /// the pending connect leaves the app with nothing outstanding and no way
    /// to ever hear about the band again. In the background the attempt is
    /// therefore left standing.
    public func setApplicationBackgrounded(_ value: Bool) {
        guard applicationIsBackgrounded != value else { return }
        applicationIsBackgrounded = value
        guard watchdogPhase == .connect else { return }
        if value {
            watchdogTask?.cancel()
            watchdogTask = nil
            connectDeadlineNanoseconds = nil
            Self.debugLog("connect watchdog suspended; pending connect left outstanding")
        } else if connectDeadlineNanoseconds == nil {
            armWatchdog(.connect, duration: BluetoothTiming.foregroundConnectNanoseconds)
        }
    }

    public func isApplicationBackgrounded() -> Bool { applicationIsBackgrounded }

    public func state() -> BluetoothConnectionState { machine.state }
    public func currentGeneration() -> UInt64 { machine.nextGeneration }
    public func connectDeadline() -> UInt64? { connectDeadlineNanoseconds }
    public func watchdogDeadline() -> UInt64? { connectDeadlineNanoseconds }
    public func activeWatchdogPhase() -> BluetoothWatchdogPhase? { watchdogPhase }

    /// Explicit deterministic hook used by simulator/test clocks.  Production
    /// SystemBluetoothClock instances also invoke the same path autonomously.
    public func expireWatchdogIfNeeded() async -> Bool {
        await expireConnectIfNeeded()
    }

    /// Reads the dedicated provisioning store before considering a scan.  A
    /// failed retrieval consumes that generation and falls back to a new,
    /// Harvard-service-filtered scan generation.
    @discardableResult
    public func start() async -> ConnectionPlan {
        guard !isAttemptInFlight else { return .none }

        let identifier = await store.loadBluetoothIdentifier()
        provisionedIdentifier = identifier
        if let identifier {
            let retrievalGeneration = machine.beginRetrieval()
            if let retriever = transport as? any BLEPeripheralRetriever {
                let matches = await retriever.retrieve([identifier])
                if let peripheral = matches.first {
                    return await connect(peripheral: peripheral)
                }
            }
            return await beginScan(after: retrievalGeneration)
        }
        return await beginScan(after: nil)
    }

    /// Applies a transport event only to its originating generation.  A newly
    /// discovered peripheral is selected exactly once and immediately handed to
    /// the transport for connection.
    @discardableResult
    public func handle(
        _ event: TransportEvent,
        generation: UInt64
    ) async -> ConnectionTransitionResult {
        if let provisionedIdentifier {
            let discovered: PeripheralID?
            switch event {
            case .discovered(let peripheral, _), .discoveredWithAdvertisement(let peripheral, _, _):
                discovered = peripheral
            default:
                discovered = nil
            }
            if let discovered, discovered != provisionedIdentifier {
                return .rejected(.invalidEvent(state: machine.state, event: event))
            }
        }
        let result = machine.handle(event, generation: generation)
        guard case .accepted = result else { return result }

        switch event {
        case .discovered(let peripheral, _),
                .discoveredWithAdvertisement(let peripheral, _, _):
            await stopScan()
            await transport.connect(peripheral)
            armWatchdog(.connect, duration: BluetoothTiming.foregroundConnectNanoseconds)
        case .connected, .connectedInSession:
            // The discovery watchdog starts at connected and remains active
            // until the complete validated characteristic table arrives.
            armWatchdog(.discovery, duration: BluetoothTiming.gattDiscoveryNanoseconds)
        case .servicesDiscovered, .servicesDiscoveredInSession:
            break
        case .characteristicsDiscovered, .characteristicsDiscoveredInSession:
            armWatchdog(.notifications, duration: BluetoothTiming.notificationNanoseconds)
        case .notificationStateChanged, .notificationStateChangedInSession:
            break
        case .disconnected, .disconnectedInSession, .managerState(.poweredOff), .managerState(.poweredOn):
            clearWatchdog()
        case .managerState, .value, .valueInSession, .writeCompleted, .writeCompletedInSession, .restored:
            break
        }
        return result
    }

    /// Marks GATT setup complete and removes the foreground-connect deadline.
    @discardableResult
    public func markSetupComplete(generation: UInt64) -> ConnectionTransitionResult {
        let result = machine.markSetupComplete(generation: generation)
        if case .accepted(.listening) = result { clearWatchdog() }
        return result
    }

    /// Deterministically tears down an expired connect attempt.  Tests advance
    /// the injected clock; production may call this from its timeout task.
    @discardableResult
    public func expireConnectIfNeeded() async -> Bool {
        guard let deadline = connectDeadlineNanoseconds,
              clock.nowNanoseconds() >= deadline,
              let generation = machine.state.generation else { return false }

        // A timed-out connect to the paired identifier is retried directly
        // by the runtime's backoff, as Edge does. Edge scans only on first
        // pairing; a known identifier needs no advertisement.
        if watchdogPhase == .connect,
           let reporter = transport as? any BLENativeLinkReporting,
           await reporter.isNativeLinkConnected() {
            armWatchdog(.discovery, duration: BluetoothTiming.gattDiscoveryNanoseconds)
            return false
        }
        var needsTimeoutNotification = false
        if watchdogPhase == .scan {
            await stopScan()
            if applicationIsBackgrounded, let identifier = provisionedIdentifier {
                // Giving up on the scan in the background parks the coordinator
                // in `.outOfRange` with nothing outstanding, so iOS has no
                // reason to wake the app when the band returns. Fall back to an
                // unbounded pending connect on the paired identifier instead.
                clearWatchdog()
                _ = machine.beginConnect(to: identifier)
                await transport.connect(identifier)
                armWatchdog(.connect, duration: BluetoothTiming.foregroundConnectNanoseconds)
                Self.debugLog("background scan timed out; pending connect armed for paired band")
                return true
            }
            _ = machine.failCurrentAttempt(generation: generation, outOfRange: true)
            needsTimeoutNotification = true
        } else {
            // Do not fail the state machine before a native disconnect event
            // is consumed. The session identity must remain live long enough
            // for the scoped link-down to pass through BluetoothConnectionSession
            // and reach the integrated runtime. A silent deterministic fake has
            // no event source, so it takes the local fallback.
            if let watchdogTransport = transport as? any BLEWatchdogDisconnecting,
               await watchdogTransport.disconnectForWatchdog() {
                // The accepted scoped disconnect will move the machine to
                // reconnecting and clear the session identity.
            } else {
                await transport.disconnect()
                _ = machine.failCurrentAttempt(generation: generation)
                needsTimeoutNotification = true
            }
        }
        clearWatchdog()
        if needsTimeoutNotification { await timeoutHandler?(generation) }
        return true
    }

    /// Disconnect and failure paths share this method so a stale timeout cannot
    /// leave the transport or selected peripheral retained.
    public func disconnect() async {
        await stopScan()
        await transport.disconnect()
        if let generation = machine.state.generation {
            _ = machine.failCurrentAttempt(generation: generation)
        }
        clearWatchdog()
    }

    private var isAttemptInFlight: Bool {
        switch machine.state {
        case .retrieving, .scanning, .connecting, .discovering, .subscribing, .settingUp, .listening, .reconnecting:
            true
        case .idle, .outOfRange, .bluetoothOff:
            false
        }
    }

    private func beginScan(after _: UInt64?) async -> ConnectionPlan {
        await stopScan()
        let generation = machine.beginScan()
        if let scanner = transport as? any BLEPeripheralScanner {
            await scanner.scan(for: HarvardBluetoothProfile.service)
        }
        armWatchdog(.scan, duration: BluetoothTiming.foregroundScanNanoseconds)
        return .scan(generation: generation, service: HarvardBluetoothProfile.service)
    }

    private func connect(peripheral: PeripheralID) async -> ConnectionPlan {
        let generation = machine.beginConnect(to: peripheral)
        await transport.connect(peripheral)
        armWatchdog(.connect, duration: BluetoothTiming.foregroundConnectNanoseconds)
        return .connect(generation: generation, peripheral: peripheral)
    }

    private func deadline(from now: UInt64) -> UInt64 {
        let (deadline, overflow) = now.addingReportingOverflow(BluetoothTiming.foregroundConnectNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private func armWatchdog(_ phase: BluetoothWatchdogPhase, duration: UInt64) {
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogPhase = phase

        // A background connect is deliberately unbounded; see
        // `setApplicationBackgrounded(_:)`.
        if phase == .connect, applicationIsBackgrounded {
            connectDeadlineNanoseconds = nil
            Self.debugLog("background connect pending; no deadline armed")
            return
        }
        connectDeadlineNanoseconds = deadline(from: clock.nowNanoseconds(), duration: duration)

        // Deterministic clocks intentionally expose expiry through
        // `expireConnectIfNeeded()`.  The system clock opts into this task so
        // production cannot depend on a foreground callback to enforce the
        // Edge-aligned bound.
        guard clock.supportsAutonomousSleep,
              let generation = machine.state.generation else { return }
        let clock = self.clock
        watchdogTask = Task { [weak self] in
            // The sleep and the monotonic deadline are read from different
            // clock calls. Waking short of the deadline must sleep the
            // remainder; returning would park the attempt with no watchdog.
            var remaining: UInt64? = duration
            while let nanoseconds = remaining {
                do { try await clock.sleep(forNanoseconds: nanoseconds) }
                catch { return }
                remaining = await self?.expireWatchdog(generation: generation, phase: phase)
            }
        }
    }

    /// Returns the nanoseconds still owed when the watchdog woke early, or
    /// `nil` once the attempt is stale or has been expired.
    private func expireWatchdog(generation: UInt64, phase: BluetoothWatchdogPhase) async -> UInt64? {
        guard machine.state.generation == generation,
              watchdogPhase == phase,
              let deadline = connectDeadlineNanoseconds else { return nil }
        let now = clock.nowNanoseconds()
        guard now >= deadline else { return deadline - now }
        _ = await expireConnectIfNeeded()
        return nil
    }

    private func clearWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogPhase = nil
        connectDeadlineNanoseconds = nil
    }

    private func deadline(from now: UInt64, duration: UInt64) -> UInt64 {
        let (deadline, overflow) = now.addingReportingOverflow(duration)
        return overflow ? UInt64.max : deadline
    }

    private func stopScan() async {
        guard let scanner = transport as? any BLEPeripheralScanner else { return }
        await scanner.stopScan()
    }

    static func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[Loopr BLE] \(Date().formatted(date: .omitted, time: .standard)) \(message())\n"
        fputs(line, stderr)
        #endif
    }
}
