import Foundation
import ProtocolKit

public enum GATTCharacteristicRole: String, CaseIterable, Equatable, Sendable {
    case command
    case response
    case events
    case data

    public var id: CharacteristicID {
        switch self {
        case .command: HarvardBluetoothProfile.command
        case .response: HarvardBluetoothProfile.response
        case .events: HarvardBluetoothProfile.events
        case .data: HarvardBluetoothProfile.data
        }
    }

    public var expectedProperties: CharacteristicProperties {
        switch self {
        case .command: [.write]
        case .response, .events, .data: [.notify]
        }
    }
}

public enum GATTDiscoveryError: Error, Equatable, Sendable, LocalizedError {
    case unexpectedService(UUID)
    case missingService
    case missingCharacteristic(UUID)
    case unexpectedCharacteristic(UUID)
    case duplicateCharacteristic(UUID)
    case propertyMismatch(UUID, expected: CharacteristicProperties, actual: CharacteristicProperties)
    case notificationsNotConfirmed(Set<CharacteristicID>)
    case unknownCharacteristic(UUID)

    public var errorDescription: String? {
        switch self {
        case .unexpectedService(let id): "Unexpected GATT service \(id.uuidString)."
        case .missingService: "The Harvard GATT service was not discovered."
        case .missingCharacteristic(let id): "Required GATT characteristic \(id.uuidString) is missing."
        case .unexpectedCharacteristic(let id): "Unexpected GATT characteristic \(id.uuidString)."
        case .duplicateCharacteristic(let id): "GATT characteristic \(id.uuidString) was discovered more than once."
        case .propertyMismatch(let id, let expected, let actual):
            "GATT characteristic \(id.uuidString) has properties \(actual.rawValue); expected \(expected.rawValue)."
        case .notificationsNotConfirmed(let ids):
            "Notifications are not confirmed for \(ids.map(\.uuidString).sorted().joined(separator: ", "))."
        case .unknownCharacteristic(let id): "Unknown inbound characteristic \(id.uuidString)."
        }
    }
}

/// One transport-neutral, bounded diagnostic row per inbound characteristic.
/// It deliberately contains no payload or health values.
public struct CharacteristicDiagnostics: Equatable, Sendable {
    public fileprivate(set) var notificationCount: UInt64 = 0
    public fileprivate(set) var lastValidFrameTimeNanoseconds: UInt64?

    public init() {}
}

/// The three inbound stream states are intentionally independent.  A malformed
/// frame on one characteristic can never clear a sibling's parser.
public struct GATTResources: Sendable {
    public private(set) var characteristics: [GATTCharacteristicRole: CharacteristicDescriptor] = [:]
    public private(set) var reassemblers: [GATTCharacteristicRole: FrameReassembler] = [:]
    public private(set) var diagnostics: [GATTCharacteristicRole: CharacteristicDiagnostics] = [:]

    public init() {}

    public var isEmpty: Bool { characteristics.isEmpty && reassemblers.isEmpty && diagnostics.isEmpty }

    fileprivate mutating func install(_ descriptors: [GATTCharacteristicRole: CharacteristicDescriptor]) {
        characteristics = descriptors
        reassemblers = Dictionary(uniqueKeysWithValues: GATTCharacteristicRole.allCases
            .filter { $0 != .command }
            .map { ($0, FrameReassembler()) })
        diagnostics = Dictionary(uniqueKeysWithValues: GATTCharacteristicRole.allCases
            .filter { $0 != .command }
            .map { ($0, CharacteristicDiagnostics()) })
    }

    fileprivate mutating func clear() {
        characteristics.removeAll(keepingCapacity: false)
        reassemblers.removeAll(keepingCapacity: false)
        diagnostics.removeAll(keepingCapacity: false)
    }

    fileprivate mutating func update(
        role: GATTCharacteristicRole,
        reassembler: FrameReassembler,
        diagnostics: CharacteristicDiagnostics
    ) {
        reassemblers[role] = reassembler
        self.diagnostics[role] = diagnostics
    }
}

/// A pure subscription barrier.  Notification confirmation may arrive in any
/// order, but setup is ready only after all three inbound characteristics report
/// enabled.  A disabled confirmation never counts as success.
public actor SubscriptionBarrier {
    public let requiredCharacteristics: Set<CharacteristicID>
    private var confirmed: Set<CharacteristicID> = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    public init(requiredCharacteristics: Set<CharacteristicID> = HarvardBluetoothProfile.inboundCharacteristics) {
        self.requiredCharacteristics = requiredCharacteristics
    }

    public var isReady: Bool { confirmed == requiredCharacteristics }
    public var confirmedCharacteristics: Set<CharacteristicID> { confirmed }

    public func confirm(_ characteristic: CharacteristicID, enabled: Bool) {
        guard requiredCharacteristics.contains(characteristic) else { return }
        if enabled {
            confirmed.insert(characteristic)
        } else {
            confirmed.remove(characteristic)
        }
        guard isReady else { return }
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: true) }
    }

    /// Waits until all required notifications confirm.  Cancellation/reset is
    /// represented by `false`; no command path can mistake it for readiness.
    public func waitUntilReady() async -> Bool {
        if isReady { return true }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func reset() {
        confirmed.removeAll(keepingCapacity: false)
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: false) }
    }
}

/// Owns one discovered GATT session.  It has no command-writing method by
/// design: BLE-03 is a no-write diagnostics mode and later command packages
/// must pass through their own serialized writer boundary.
public actor GATTSession {
    private let barrier: SubscriptionBarrier
    public private(set) var resources = GATTResources()
    public private(set) var discoveredServiceIDs: [ServiceID] = []
    public private(set) var setupReady = false

    public init(barrier: SubscriptionBarrier = SubscriptionBarrier()) {
        self.barrier = barrier
    }

    /// Requests exactly one service from the transport.
    public func discover(using transport: any BLETransport) async {
        await transport.discoverServices(HarvardBluetoothProfile.requiredServices)
    }

    public func acceptServices(_ ids: [ServiceID]) throws {
        guard ids.count == 1, ids.first == HarvardBluetoothProfile.service else {
            if ids.contains(HarvardBluetoothProfile.service), let unexpected = ids.first(where: { $0 != HarvardBluetoothProfile.service }) {
                throw GATTDiscoveryError.unexpectedService(unexpected)
            }
            throw GATTDiscoveryError.missingService
        }
        discoveredServiceIDs = ids
    }

    public func acceptCharacteristics(_ descriptors: [CharacteristicDescriptor]) throws {
        var byRole: [GATTCharacteristicRole: CharacteristicDescriptor] = [:]
        for descriptor in descriptors {
            guard let role = GATTCharacteristicRole.allCases.first(where: { $0.id == descriptor.id }) else {
                // The Harvard service also carries characteristics Loopr
                // does not use, such as the Memfault channel 61080007. A
                // restored link reports all of them. Edge looks up the four
                // it needs and ignores the rest.
                continue
            }
            guard byRole[role] == nil else {
                throw GATTDiscoveryError.duplicateCharacteristic(descriptor.id)
            }
            let expected = role.expectedProperties
            guard descriptor.properties.isSuperset(of: expected) else {
                throw GATTDiscoveryError.propertyMismatch(
                    descriptor.id,
                    expected: expected,
                    actual: descriptor.properties
                )
            }
            byRole[role] = descriptor
        }

        for role in GATTCharacteristicRole.allCases where byRole[role] == nil {
            throw GATTDiscoveryError.missingCharacteristic(role.id)
        }
        resources.install(byRole)
    }

    /// Enables all inbound notifications.  No command characteristic is ever
    /// passed to `setNotify` and no write is attempted here.
    public func subscribe(using transport: any BLETransport) async throws {
        await barrier.reset()
        for role in [GATTCharacteristicRole.response, .events, .data] {
            guard resources.characteristics[role] != nil else {
                throw GATTDiscoveryError.missingCharacteristic(role.id)
            }
            await transport.setNotify(role.id, enabled: true)
        }
        setupReady = false
    }

    @discardableResult
    public func handleNotificationStateChanged(
        _ characteristic: CharacteristicID,
        enabled: Bool
    ) async throws -> Bool {
        guard HarvardBluetoothProfile.inboundCharacteristics.contains(characteristic) else {
            throw GATTDiscoveryError.unknownCharacteristic(characteristic)
        }
        await barrier.confirm(characteristic, enabled: enabled)
        setupReady = await barrier.isReady
        return setupReady
    }

    /// Feeds one notification into only its own bounded reassembler and updates
    /// count/time diagnostics.  Invalid input is safely retained as bounded
    /// reassembler diagnostics and produces no frame.
    @discardableResult
    public func ingest(
        _ bytes: Data,
        from characteristic: CharacteristicID,
        atNanoseconds timestamp: UInt64
    ) throws -> [Frame] {
        guard let role = GATTCharacteristicRole.allCases.first(where: { $0.id == characteristic }),
              role != .command else {
            throw GATTDiscoveryError.unknownCharacteristic(characteristic)
        }
        guard var reassembler = resources.reassemblers[role],
              var diagnostics = resources.diagnostics[role] else {
            throw GATTDiscoveryError.missingCharacteristic(characteristic)
        }

        diagnostics.notificationCount += 1
        let frames = reassembler.ingest(bytes)
        if !frames.isEmpty {
            diagnostics.lastValidFrameTimeNanoseconds = timestamp
        }
        resources.update(role: role, reassembler: reassembler, diagnostics: diagnostics)
        return frames
    }

    public func disconnect() async {
        resources.clear()
        discoveredServiceIDs.removeAll(keepingCapacity: false)
        setupReady = false
        await barrier.reset()
    }

    public func subscriptionBarrier() -> SubscriptionBarrier { barrier }

    public func isReadyWithCompleteResources() -> Bool {
        let roles = Set(GATTCharacteristicRole.allCases)
        let inbound = roles.subtracting([.command])
        return setupReady
            && Set(resources.characteristics.keys) == roles
            && Set(resources.reassemblers.keys) == inbound
            && Set(resources.diagnostics.keys) == inbound
    }
}
