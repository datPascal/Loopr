import Foundation

public enum BluetoothConnectionState: Equatable, Sendable {
    case idle
    case retrieving(generation: UInt64)
    case scanning(generation: UInt64, service: ServiceID)
    case connecting(generation: UInt64, peripheral: PeripheralID)
    case discovering(generation: UInt64, peripheral: PeripheralID)
    case subscribing(generation: UInt64, peripheral: PeripheralID)
    case settingUp(generation: UInt64, peripheral: PeripheralID)
    case listening(generation: UInt64, peripheral: PeripheralID)
    case reconnecting(generation: UInt64)
    case outOfRange
    case bluetoothOff

    public var generation: UInt64? {
        switch self {
        case .idle, .outOfRange, .bluetoothOff: nil
        case .retrieving(let generation), .scanning(let generation, _),
                .connecting(let generation, _), .discovering(let generation, _),
                .subscribing(let generation, _), .settingUp(let generation, _),
                .listening(let generation, _), .reconnecting(let generation): generation
        }
    }

    public var isConnected: Bool {
        switch self {
        case .discovering, .subscribing, .settingUp, .listening: true
        default: false
        }
    }
}

public enum ConnectionTransitionError: Error, Equatable, Sendable, LocalizedError {
    case invalidEvent(state: BluetoothConnectionState, event: TransportEvent)
    case staleGeneration(expected: UInt64, received: UInt64)
    case staleSession(expected: TransportSessionIdentity?, received: TransportSessionIdentity)
    case gattValidationFailed(GATTDiscoveryError)
    case noPeripheralSelected

    public var errorDescription: String? {
        switch self {
        case .invalidEvent(let state, let event): return "Invalid Bluetooth event \(event) while in \(state)."
        case .staleGeneration(let expected, let received):
            return "Stale Bluetooth generation \(received); current generation is \(expected)."
        case .staleSession(let expected, let received):
            let current = expected.map { "\($0.peripheral.uuidString)/\($0.token.uuidString)" } ?? "none"
            return "Stale Bluetooth session \(received.peripheral.uuidString)/\(received.token.uuidString); current session is \(current)."
        case .gattValidationFailed(let error):
            return "GATT setup failed validation: \(error.localizedDescription)"
        case .noPeripheralSelected: return "No single Bluetooth peripheral is selected."
        }
    }
}

public enum ConnectionTransitionResult: Equatable, Sendable {
    case accepted(BluetoothConnectionState)
    case ignoredStaleGeneration
    case rejected(ConnectionTransitionError)
}

/// A plain value state machine.  Every connect attempt allocates its
/// generation before any transport call, and all event handling is explicitly
/// generation-scoped by the actor/adapter that owns the stream.
public struct ConnectionStateMachine: Sendable {
    public private(set) var state: BluetoothConnectionState = .idle
    public private(set) var nextGeneration: UInt64 = 0
    public private(set) var selectedPeripheral: PeripheralID?
    public private(set) var activeSessionIdentity: TransportSessionIdentity?

    private var subscribed: Set<CharacteristicID> = []

    public init() {}

    @discardableResult
    public mutating func beginRetrieval() -> UInt64 {
        let generation = allocateGeneration()
        state = .retrieving(generation: generation)
        selectedPeripheral = nil
        activeSessionIdentity = nil
        subscribed.removeAll(keepingCapacity: false)
        return generation
    }

    @discardableResult
    public mutating func beginScan() -> UInt64 {
        let generation = allocateGeneration()
        state = .scanning(generation: generation, service: HarvardBluetoothProfile.service)
        selectedPeripheral = nil
        activeSessionIdentity = nil
        subscribed.removeAll(keepingCapacity: false)
        return generation
    }

    @discardableResult
    public mutating func beginConnect(to peripheral: PeripheralID) -> UInt64 {
        let generation = allocateGeneration()
        selectedPeripheral = peripheral
        state = .connecting(generation: generation, peripheral: peripheral)
        activeSessionIdentity = nil
        subscribed.removeAll(keepingCapacity: false)
        return generation
    }

    public mutating func handle(
        _ event: TransportEvent,
        generation: UInt64
    ) -> ConnectionTransitionResult {
        guard let currentGeneration = state.generation else {
            // Manager-state events are global and are still allowed to surface
            // Bluetooth-off even while the state is idle.
            if case .managerState(.poweredOff) = event {
                state = .bluetoothOff
                selectedPeripheral = nil
                activeSessionIdentity = nil
                return .accepted(state)
            }
            if case .managerState(.poweredOn) = event, state == .bluetoothOff {
                state = .idle
                return .accepted(state)
            }
            return .rejected(.invalidEvent(state: state, event: event))
        }

        guard currentGeneration == generation else { return .ignoredStaleGeneration }

        switch event {
        case .managerState(.poweredOff):
            state = .bluetoothOff
            selectedPeripheral = nil
            activeSessionIdentity = nil
            subscribed.removeAll(keepingCapacity: false)
            return .accepted(state)
        case .managerState(.poweredOn):
            guard state == .bluetoothOff else { return reject(event) }
            state = .idle
            return .accepted(state)
        case .managerState:
            return reject(event)
        case .discovered(let peripheral, let advertisedServices):
            guard case .scanning = state,
                  advertisedServices.contains(HarvardBluetoothProfile.service) else {
                return reject(event)
            }
            selectedPeripheral = peripheral
            state = .connecting(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .discoveredWithAdvertisement(let peripheral, let advertisedName, let advertisedServices):
            guard case .scanning = state,
                  BluetoothDiscoveryPolicy(isForeground: true).accepts(
                    name: advertisedName,
                    services: advertisedServices
                  ) else {
                return reject(event)
            }
            selectedPeripheral = peripheral
            state = .connecting(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .connected(let peripheral):
            guard case .connecting(_, let expected) = state,
                  expected == peripheral else { return reject(event) }
            activeSessionIdentity = nil
            state = .discovering(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .connectedInSession(let identity):
            guard case .connecting(_, let expected) = state,
                  expected == identity.peripheral else { return reject(event) }
            activeSessionIdentity = identity
            state = .discovering(generation: generation, peripheral: identity.peripheral)
            return .accepted(state)
        case .servicesDiscovered(let services):
            guard case .discovering(_, let peripheral) = state,
                  services == HarvardBluetoothProfile.requiredServices else {
                return reject(event)
            }
            state = .subscribing(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .servicesDiscoveredInSession(let identity, let services):
            guard sessionMatches(identity),
                  case .discovering(_, let peripheral) = state,
                  peripheral == identity.peripheral,
                  services == HarvardBluetoothProfile.requiredServices else {
                return reject(event)
            }
            state = .subscribing(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .characteristicsDiscovered:
            guard case .subscribing(_, let peripheral) = state else { return reject(event) }
            // Property validation and subscription confirmation are owned by
            // GATTSession; receiving the table is the only state transition.
            state = .subscribing(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .characteristicsDiscoveredInSession(let identity, _):
            guard sessionMatches(identity),
                  case .subscribing(_, let peripheral) = state,
                  peripheral == identity.peripheral else { return reject(event) }
            state = .subscribing(generation: generation, peripheral: peripheral)
            return .accepted(state)
        case .notificationStateChanged(let characteristic, let enabled):
            guard case .subscribing(_, let peripheral) = state,
                  HarvardBluetoothProfile.inboundCharacteristics.contains(characteristic) else {
                return reject(event)
            }
            if enabled { subscribed.insert(characteristic) }
            else { subscribed.remove(characteristic) }
            if subscribed == HarvardBluetoothProfile.inboundCharacteristics {
                state = .settingUp(generation: generation, peripheral: peripheral)
            }
            return .accepted(state)
        case .notificationStateChangedInSession(let identity, let characteristic, let enabled):
            guard sessionMatches(identity),
                  case .subscribing(_, let peripheral) = state,
                  peripheral == identity.peripheral,
                  HarvardBluetoothProfile.inboundCharacteristics.contains(characteristic) else {
                return reject(event)
            }
            if enabled { subscribed.insert(characteristic) }
            else { subscribed.remove(characteristic) }
            if subscribed == HarvardBluetoothProfile.inboundCharacteristics {
                state = .settingUp(generation: generation, peripheral: peripheral)
            }
            return .accepted(state)
        case .value:
            guard case .listening = state else { return reject(event) }
            return .accepted(state)
        case .valueInSession(let identity, _, _):
            guard sessionMatches(identity), case .listening(_, let peripheral) = state,
                  peripheral == identity.peripheral else { return reject(event) }
            return .accepted(state)
        case .writeCompleted:
            return reject(event)
        case .writeCompletedInSession(let identity, _, _):
            guard sessionMatches(identity) else { return reject(event) }
            return reject(event)
        case .disconnected(let peripheral, let error):
            guard selectedPeripheral == peripheral else { return reject(event) }
            subscribed.removeAll(keepingCapacity: false)
            selectedPeripheral = nil
            activeSessionIdentity = nil
            if case .bluetoothOff = state { return .accepted(state) }
            if error == .some(.outOfRange) {
                state = .outOfRange
            } else {
                state = .reconnecting(generation: generation)
            }
            return .accepted(state)
        case .disconnectedInSession(let identity, let error):
            guard sessionMatches(identity), selectedPeripheral == identity.peripheral else {
                return reject(event)
            }
            subscribed.removeAll(keepingCapacity: false)
            selectedPeripheral = nil
            activeSessionIdentity = nil
            if error == .some(.outOfRange) {
                state = .outOfRange
            } else {
                state = .reconnecting(generation: generation)
            }
            return .accepted(state)
        case .restored:
            return reject(event)
        }
    }

    public mutating func markSetupComplete(generation: UInt64) -> ConnectionTransitionResult {
        guard state.generation == generation else { return .ignoredStaleGeneration }
        guard case .settingUp(_, let peripheral) = state else {
            return .rejected(.invalidEvent(
                state: state,
                event: .managerState(.unknown)
            ))
        }
        state = .listening(generation: generation, peripheral: peripheral)
        return .accepted(state)
    }

    public mutating func failCurrentAttempt(generation: UInt64, outOfRange: Bool = false) -> ConnectionTransitionResult {
        guard state.generation == generation else { return .ignoredStaleGeneration }
        selectedPeripheral = nil
        activeSessionIdentity = nil
        subscribed.removeAll(keepingCapacity: false)
        state = outOfRange ? .outOfRange : .idle
        return .accepted(state)
    }

    public mutating func beginReconnect() -> UInt64 {
        let generation = allocateGeneration()
        state = .reconnecting(generation: generation)
        selectedPeripheral = nil
        activeSessionIdentity = nil
        subscribed.removeAll(keepingCapacity: false)
        return generation
    }

    public func isSubscribed(_ characteristic: CharacteristicID) -> Bool {
        subscribed.contains(characteristic)
    }

    private mutating func allocateGeneration() -> UInt64 {
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return nextGeneration
    }

    private func reject(_ event: TransportEvent) -> ConnectionTransitionResult {
        .rejected(.invalidEvent(state: state, event: event))
    }

    private func sessionMatches(_ identity: TransportSessionIdentity) -> Bool {
        activeSessionIdentity == identity
    }
}

/// The production/default bound required by the parity plan.  The coordinator
/// may use this value with any injected deterministic clock.
public enum BluetoothTiming {
    public static let foregroundScanNanoseconds: UInt64 = 12_000_000_000
    public static let foregroundConnectNanoseconds: UInt64 = 20_000_000_000
    public static let gattDiscoveryNanoseconds: UInt64 = 15_000_000_000
    public static let notificationNanoseconds: UInt64 = 15_000_000_000
}

/// A small deterministic clock seam.  `TestSupport` supplies a manual clock;
/// production uses `ContinuousClock` through this adapter.
public protocol BluetoothClock: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(forNanoseconds nanoseconds: UInt64) async throws
    /// Production clocks can enforce deadlines autonomously.  Deterministic
    /// test clocks leave this false and let tests advance/expire explicitly.
    var supportsAutonomousSleep: Bool { get }
}

public extension BluetoothClock {
    var supportsAutonomousSleep: Bool { false }
}

public struct SystemBluetoothClock: BluetoothClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public var supportsAutonomousSleep: Bool { true }

    public func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
