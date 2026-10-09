import Foundation
import ProtocolKit

/// The composition boundary for the native connection path.
///
/// `BluetoothConnectionCoordinator` owns retrieval/scan/connect generations;
/// `GATTSession` owns exact UUID/property validation and the three-way notify
/// barrier.  Keeping them behind this actor prevents a caller from marking a
/// connection ready after a merely-connected callback or a partial discovery
/// table.  Native callbacks carry `TransportSessionIdentity`; a callback from
/// any replaced session is rejected before it reaches a reassembler.
public actor BluetoothConnectionSession {
    private let coordinator: BluetoothConnectionCoordinator
    private let gatt: GATTSession
    private let transport: any BLETransport
    private let clock: any BluetoothClock
    private var activeIdentity: TransportSessionIdentity?
    private var frames: [Frame] = []

    public init(
        transport: any BLETransport,
        store: any AccessoryProvisioningStore,
        clock: any BluetoothClock = SystemBluetoothClock(),
        gatt: GATTSession? = nil
    ) {
        self.transport = transport
        self.clock = clock
        self.coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: store,
            clock: clock
        )
        // Construct the parser owner inside this initializer so every
        // connection session has an unmistakably private GATT lifetime.
        self.gatt = gatt ?? GATTSession()
    }

    public func setTimeoutHandler(_ handler: @escaping @Sendable (UInt64) async -> Void) async {
        await coordinator.setTimeoutHandler(handler)
    }

    /// Forwards the host lifecycle so a connect issued in the background stays
    /// outstanding instead of being cancelled by a timer that cannot fire.
    public func setApplicationBackgrounded(_ value: Bool) async {
        await coordinator.setApplicationBackgrounded(value)
    }

    public func isApplicationBackgrounded() async -> Bool {
        await coordinator.isApplicationBackgrounded()
    }

    public func start() async -> ConnectionPlan {
        await coordinator.start()
    }

    public func state() async -> BluetoothConnectionState {
        await coordinator.state()
    }

    public func generation() async -> UInt64 {
        await coordinator.currentGeneration()
    }

    /// Deterministic/test hook for the same autonomous watchdog path used by
    /// production clocks. Native transports emit a scoped disconnect here;
    /// `handle(_:generation:)` must then consume it before this session clears
    /// its identity and parsers.
    @discardableResult
    public func expireWatchdogIfNeeded() async -> Bool {
        await coordinator.expireWatchdogIfNeeded()
    }

    public func setupReady() async -> Bool {
        await gatt.isReadyWithCompleteResources()
    }

    public func activeSessionIdentity() -> TransportSessionIdentity? {
        activeIdentity
    }

    /// Processes one event from the generation that created it.  The return
    /// value stays compatible with the coordinator while GATT validation
    /// failures are represented as typed transition errors.
    @discardableResult
    public func handle(
        _ event: TransportEvent,
        generation: UInt64,
        atNanoseconds timestamp: UInt64? = nil
    ) async -> ConnectionTransitionResult {
        // A native watchdog can expire while the central is still in the
        // connecting phase.  CoreBluetooth already stamped that teardown with
        // the immutable operation identity, but the session has not received a
        // didConnect callback yet and therefore has no `activeIdentity` to
        // compare against.  In this one narrow phase, translate the scoped
        // link-down to the coordinator's legacy peripheral form after checking
        // that it belongs to the currently selected connect attempt.  Once a
        // connection callback has been accepted, every scoped event must match
        // `activeIdentity` exactly; no old callback is ever relabeled.
        let coordinatorEvent: TransportEvent
        let isPreConnectDisconnect: Bool
        if case .disconnectedInSession(let identity, let error) = event,
           activeIdentity == nil {
            let current = await coordinator.state()
            guard case .connecting(_, let selected) = current,
                  selected == identity.peripheral else {
                return .rejected(.staleSession(expected: activeIdentity, received: identity))
            }
            isPreConnectDisconnect = true
            coordinatorEvent = .disconnected(identity.peripheral, error: error)
        } else {
            isPreConnectDisconnect = false
            coordinatorEvent = event
        }

        if let identity = event.sessionIdentity {
            if case .connectedInSession = event {
                guard activeIdentity == nil || activeIdentity == identity else {
                    return .rejected(.staleSession(expected: activeIdentity, received: identity))
                }
            } else if !isPreConnectDisconnect && activeIdentity != identity {
                return .rejected(.staleSession(expected: activeIdentity, received: identity))
            }
        } else if activeIdentity != nil && eventRequiresSessionIdentity(event) {
            // Once the native adapter has established a scoped session, an
            // unscoped inbound callback is unsafe by definition.  Do not let
            // legacy/fake event syntax weaken the native stale-callback fence.
            let received = TransportSessionIdentity(
                peripheral: activeIdentity?.peripheral ?? UUID(),
                token: UUID()
            )
            return .rejected(.staleSession(expected: activeIdentity, received: received))
        }

        let transition = await coordinator.handle(coordinatorEvent, generation: generation)
        guard case .accepted = transition else { return transition }
        if case .connectedInSession(let identity) = event {
            activeIdentity = identity
        }

        do {
            switch event {
            case .connected, .connectedInSession:
                await gatt.discover(using: transport)

            case .servicesDiscovered(let services):
                try await gatt.acceptServices(services)
                await discoverCharacteristicsIfAvailable()

            case .servicesDiscoveredInSession(_, let services):
                try await gatt.acceptServices(services)
                await discoverCharacteristicsIfAvailable()

            case .characteristicsDiscovered(let descriptors):
                try await gatt.acceptCharacteristics(descriptors)
                try await gatt.subscribe(using: transport)

            case .characteristicsDiscoveredInSession(_, let descriptors):
                try await gatt.acceptCharacteristics(descriptors)
                try await gatt.subscribe(using: transport)

            case .notificationStateChanged(let characteristic, let enabled):
                try await acceptNotification(
                    characteristic,
                    enabled: enabled,
                    generation: generation
                )

            case .notificationStateChangedInSession(_, let characteristic, let enabled):
                try await acceptNotification(
                    characteristic,
                    enabled: enabled,
                    generation: generation
                )

            case .value(let characteristic, let bytes):
                try await ingest(bytes, characteristic: characteristic, timestamp: timestamp)

            case .valueInSession(_, let characteristic, let bytes):
                try await ingest(bytes, characteristic: characteristic, timestamp: timestamp)

            case .disconnected, .disconnectedInSession:
                await gatt.disconnect()
                activeIdentity = nil

            default:
                break
            }
        } catch let error as GATTDiscoveryError {
            await abortSetup()
            return .rejected(.gattValidationFailed(error))
        } catch {
            await abortSetup()
            return .rejected(.gattValidationFailed(.unknownCharacteristic(UUID())))
        }

        return transition
    }

    /// Releases radio and parser resources and fences every callback from the
    /// previous generation.
    public func disconnect() async {
        activeIdentity = nil
        frames.removeAll(keepingCapacity: false)
        await gatt.disconnect()
        await coordinator.disconnect()
    }

    /// Returns and clears frames accepted from the current, identity-fenced
    /// session.  No frame is ever produced by a stale callback.
    public func drainFrames() -> [Frame] {
        let result = frames
        frames.removeAll(keepingCapacity: false)
        return result
    }

    /// The connected band's signal strength in dBm, or nil when there is no
    /// link or the transport cannot report one. Nothing is scanned and nothing
    /// is written; this is a read of the existing connection.
    public func readSignalStrength() async -> Int? {
        guard activeIdentity != nil,
              let reporter = transport as? any BLESignalStrengthReporting else { return nil }
        return await reporter.readSignalStrength()
    }

    private func discoverCharacteristicsIfAvailable() async {
        guard let discoverer = transport as? any BLEGATTDiscoverer else { return }
        await discoverer.discoverCharacteristics(Array(HarvardBluetoothProfile.requiredCharacteristics))
    }

    private func acceptNotification(
        _ characteristic: CharacteristicID,
        enabled: Bool,
        generation: UInt64
    ) async throws {
        let ready = try await gatt.handleNotificationStateChanged(characteristic, enabled: enabled)
        guard ready else { return }
        let result = await coordinator.markSetupComplete(generation: generation)
        guard case .accepted(.listening) = result else {
            throw GATTDiscoveryError.notificationsNotConfirmed([])
        }
    }

    private func ingest(
        _ bytes: Data,
        characteristic: CharacteristicID,
        timestamp: UInt64?
    ) async throws {
        let timestamp = timestamp ?? clock.nowNanoseconds()
        frames.append(contentsOf: try await gatt.ingest(
            bytes,
            from: characteristic,
            atNanoseconds: timestamp
        ))
    }

    private func abortSetup() async {
        activeIdentity = nil
        frames.removeAll(keepingCapacity: false)
        await gatt.disconnect()
        await coordinator.disconnect()
    }

    private func eventRequiresSessionIdentity(_ event: TransportEvent) -> Bool {
        switch event {
        case .servicesDiscovered, .characteristicsDiscovered,
                .notificationStateChanged, .value, .writeCompleted,
                .disconnected:
            true
        default:
            false
        }
    }
}
