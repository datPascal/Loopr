import Foundation
import ProtocolKit

/// Identifiers used at the transport seam.  Keeping these as UUID aliases
/// means the CoreBluetooth adapter and simulator transports share the same
/// values without leaking CoreBluetooth into the session logic.
public typealias PeripheralID = UUID
public typealias ServiceID = UUID
public typealias CharacteristicID = UUID

/// The UUID profile for a WHOOP 4.0 Harvard service session.
public enum HarvardBluetoothProfile {
    public static let service = GATTProfile.gen4.service
    public static let command = GATTProfile.gen4.command
    public static let response = GATTProfile.gen4.response
    public static let events = GATTProfile.gen4.events
    public static let data = GATTProfile.gen4.data

    public static let inboundCharacteristics: Set<CharacteristicID> = [response, events, data]
    public static let requiredCharacteristics: Set<CharacteristicID> = [command, response, events, data]

    public static var requiredServices: [ServiceID] { [service] }
}

/// The experimental fd4b profile. Memfault is retained as identity evidence
/// only and is deliberately absent from both production characteristic sets.
public enum Gen5BluetoothProfile {
    public static let service = GATTProfile.gen5.service
    public static let command = GATTProfile.gen5.command
    public static let response = GATTProfile.gen5.response
    public static let events = GATTProfile.gen5.events
    public static let data = GATTProfile.gen5.data
    public static let memfault = GATTProfile.gen5.memfault!

    public static let inboundCharacteristics = GATTProfile.gen5.inboundCharacteristics
    public static let requiredCharacteristics = GATTProfile.gen5.productionCharacteristics
    public static var requiredServices: [ServiceID] { [service] }
}

/// The state reported by the native radio manager.  Bluetooth-off is kept
/// distinct from a peripheral being out of range all the way to the UI seam.
public enum ManagerState: String, CaseIterable, Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

/// Errors emitted by a transport.  They are intentionally transport-shaped;
/// protocol policy belongs above this seam.
public enum TransportError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case timeout
    case bluetoothOff
    case outOfRange
    case unavailable
    case unsupported
    case disconnected
    case insufficientAuthentication
    case insufficientEncryption
    /// iOS holds a bond the accessory no longer has. Only forgetting the
    /// accessory on the phone clears it; retrying can never succeed.
    case peerRemovedPairing
    case invalidState(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Bluetooth operation cancelled."
        case .timeout: "Bluetooth operation timed out."
        case .bluetoothOff: "Bluetooth is powered off."
        case .outOfRange: "The accessory is out of range."
        case .unavailable: "The Bluetooth accessory is unavailable."
        case .unsupported: "Bluetooth is not supported on this device."
        case .disconnected: "The Bluetooth connection was lost."
        case .insufficientAuthentication: "Bluetooth pairing is required."
        case .insufficientEncryption: "Bluetooth encryption is required."
        case .peerRemovedPairing: "The accessory removed its pairing with this iPhone."
        case .invalidState(let reason): "Bluetooth transport is in an invalid state: \(reason)"
        case .writeFailed(let reason): "Bluetooth write failed: \(reason)"
        }
    }

    public var isBondFailure: Bool {
        switch self {
        case .insufficientAuthentication, .insufficientEncryption, .peerRemovedPairing: true
        default: false
        }
    }
}

public enum BluetoothOwnerError: Error, Equatable, Sendable, LocalizedError {
    case alreadyOwned
    case notOwner

    public var errorDescription: String? {
        switch self {
        case .alreadyOwned: "Another Bluetooth session already owns the process-wide radio."
        case .notOwner: "The Bluetooth owner token is not active."
        }
    }
}

/// Generic process-wide ownership seam shared by normal and restored runtime
/// composition.  The CoreBluetooth factory uses `processWide`; tests and
/// embedding hosts can inject a fresh registry without constructing native
/// CoreBluetooth objects.
public final class BluetoothOwnerRegistry: @unchecked Sendable {
    public static let processWide = BluetoothOwnerRegistry()

    private let lock = NSLock()
    private var activeToken: UUID?

    public init() {}

    public func acquire() throws -> UUID {
        try lock.withLock {
            guard activeToken == nil else { throw BluetoothOwnerError.alreadyOwned }
            let token = UUID()
            activeToken = token
            return token
        }
    }

    public func release(_ token: UUID) {
        lock.withLock {
            guard activeToken == token else { return }
            activeToken = nil
        }
    }

    public func ownerCount() -> Int {
        lock.withLock { activeToken == nil ? 0 : 1 }
    }

    public func currentOwner() -> UUID? {
        lock.withLock { activeToken }
    }
}

/// The subset of GATT properties needed to validate the Harvard profile.
public struct CharacteristicProperties: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let write = Self(rawValue: 1 << 0)
    public static let writeWithoutResponse = Self(rawValue: 1 << 1)
    public static let notify = Self(rawValue: 1 << 2)
    public static let indicate = Self(rawValue: 1 << 3)
}

/// A transport-neutral description of one discovered characteristic.
public struct CharacteristicDescriptor: Equatable, Hashable, Sendable {
    public let id: CharacteristicID
    public let properties: CharacteristicProperties

    public init(id: CharacteristicID, properties: CharacteristicProperties) {
        self.id = id
        self.properties = properties
    }

    public var supportsWriteWithResponse: Bool { properties.contains(.write) }
    public var supportsNotify: Bool { properties.contains(.notify) }
}

/// The subset of restoration state that is safe to hand to the actor.  The
/// adapter converts native objects into immutable IDs before emitting this.
public struct RestorationSnapshot: Equatable, Sendable {
    public let managerState: ManagerState
    public let peripherals: [PeripheralID]

    public init(managerState: ManagerState, peripherals: [PeripheralID] = []) {
        self.managerState = managerState
        self.peripherals = peripherals
    }
}

/// Identity attached to callbacks that originate from a concrete native
/// peripheral/session.  CoreBluetooth can deliver callbacks after a
/// disconnect (and the same peripheral UUID can be reused on reconnect), so
/// a UUID alone is not a sufficient fence.  The token changes for every
/// selected connection session.
public struct TransportSessionIdentity: Equatable, Hashable, Sendable {
    public let peripheral: PeripheralID
    public let token: UUID

    public init(peripheral: PeripheralID, token: UUID = UUID()) {
        self.peripheral = peripheral
        self.token = token
    }
}

/// Events emitted by a CoreBluetooth adapter or one of the deterministic test
/// transports.  There is deliberately no generation on the event itself: the
/// owning session stamps the stream with the generation it is currently
/// consuming and rejects events from replaced streams at that boundary.
public enum TransportEvent: Equatable, Sendable {
    case managerState(ManagerState)
    case discovered(PeripheralID, advertisedServices: [ServiceID])
    case discoveredWithAdvertisement(
        PeripheralID,
        advertisedName: String?,
        advertisedServices: [ServiceID]
    )
    case connected(PeripheralID)
    case disconnected(PeripheralID, error: TransportError?)
    case servicesDiscovered([ServiceID])
    case characteristicsDiscovered([CharacteristicDescriptor])
    case notificationStateChanged(CharacteristicID, enabled: Bool)
    case value(CharacteristicID, Data)
    case writeCompleted(CharacteristicID, error: TransportError?)
    case restored(RestorationSnapshot)

    // The unscoped cases above remain part of the deterministic transport
    // contract.  Native callbacks use these scoped variants so an event from
    // a replaced CBPeripheral/session cannot enter the current parsers.
    case connectedInSession(TransportSessionIdentity)
    case disconnectedInSession(TransportSessionIdentity, error: TransportError?)
    case servicesDiscoveredInSession(TransportSessionIdentity, services: [ServiceID])
    case characteristicsDiscoveredInSession(TransportSessionIdentity, characteristics: [CharacteristicDescriptor])
    case notificationStateChangedInSession(
        TransportSessionIdentity,
        characteristic: CharacteristicID,
        enabled: Bool
    )
    case valueInSession(
        TransportSessionIdentity,
        characteristic: CharacteristicID,
        Data
    )
    case writeCompletedInSession(
        TransportSessionIdentity,
        characteristic: CharacteristicID,
        error: TransportError?
    )

    public var sessionIdentity: TransportSessionIdentity? {
        switch self {
        case .connectedInSession(let identity),
                .disconnectedInSession(let identity, _),
                .servicesDiscoveredInSession(let identity, _),
                .characteristicsDiscoveredInSession(let identity, _),
                .notificationStateChangedInSession(let identity, _, _),
                .valueInSession(let identity, _, _),
                .writeCompletedInSession(let identity, _, _):
            identity
        default:
            nil
        }
    }
}

/// Everything session logic can ask of the radio.  CoreBluetooth implements
/// this protocol; tests use deterministic transports.  No CoreBluetooth type
/// appears in the contract.
public protocol BLETransport: Sendable {
    func events() -> AsyncStream<TransportEvent>
    func connect(_ peripheral: PeripheralID) async
    func discoverServices(_ ids: [ServiceID]) async
    func setNotify(_ char: CharacteristicID, enabled: Bool) async
    func write(_ data: Data, to char: CharacteristicID) async throws
    func disconnect() async
}

/// Optional retrieval capability used by the connection coordinator.  It is
/// separate from `BLETransport` so the required transport seam remains the
/// exact small contract used by scripted/replay tests.
public protocol BLEPeripheralRetriever: BLETransport {
    func retrieve(_ peripherals: [PeripheralID]) async -> [PeripheralID]
}

/// Optional capability implemented by the CoreBluetooth shell for the
/// service-filtered fallback path.  The state machine never scans broadly.
public protocol BLEPeripheralScanner: BLETransport {
    func scan(for service: ServiceID) async
    func stopScan() async
}

public extension BLEPeripheralScanner {
    /// Simulator transports do not need a radio cancellation primitive.  The
    /// default keeps their existing conformance source-compatible while the
    /// native adapter performs the real `CBCentralManager.stopScan()` call.
    func stopScan() async {}
}

/// Optional capability for the second half of Gate C.  Keeping characteristic
/// discovery out of the base seam preserves the tiny transport contract while
/// allowing the native adapter to expose the exact UUID request.
public protocol BLEGATTDiscoverer: BLETransport {
    func discoverCharacteristics(_ ids: [CharacteristicID]) async
}

/// Optional capability for signal strength.  "Find my strap" needs to know
/// whether the person is walking towards the band or away from it, and that is
/// a link-level reading, not a GATT characteristic.  It stays out of the base
/// seam because most transports have nothing to report.
public protocol BLESignalStrengthReporting: BLETransport {
    /// The connected peripheral's RSSI in dBm, or nil when the link is down or
    /// the radio does not answer in time.  A hunt in progress must not be
    /// interrupted by a thrown error.
    func readSignalStrength() async -> Int?
}
