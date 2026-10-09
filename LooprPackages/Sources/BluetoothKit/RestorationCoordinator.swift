import Foundation
import ProtocolKit

/// The restoration shape delivered by CoreBluetooth.  The adapter maps its
/// `willRestoreState` payload to this value; no CoreBluetooth type crosses the
/// seam.
public enum AdoptionRestorationShape: String, Codable, CaseIterable, Sendable {
    case midConnect
    case midDrain
    case unknownPeripheral
}

public struct AdoptionRestoredCharacteristic: Equatable, Codable, Sendable {
    public let uuid: UUID
    public let supportsWriteWithResponse: Bool
    public let supportsNotify: Bool

    public init(
        uuid: UUID,
        supportsWriteWithResponse: Bool = false,
        supportsNotify: Bool = false
    ) {
        self.uuid = uuid
        self.supportsWriteWithResponse = supportsWriteWithResponse
        self.supportsNotify = supportsNotify
    }
}

public struct AdoptionRestorationSnapshot: Equatable, Codable, Sendable {
    public let generation: BandGeneration
    public let shape: AdoptionRestorationShape
    public let peripheralIdentifier: UUID?
    public let serviceUUIDs: [UUID]
    public let characteristics: [AdoptionRestoredCharacteristic]
    public let hadActiveHistoryBurst: Bool

    public init(
        generation: BandGeneration = .gen4,
        shape: AdoptionRestorationShape,
        peripheralIdentifier: UUID?,
        serviceUUIDs: [UUID] = [],
        characteristics: [AdoptionRestoredCharacteristic] = [],
        hadActiveHistoryBurst: Bool = false
    ) {
        self.generation = generation
        self.shape = shape
        self.peripheralIdentifier = peripheralIdentifier
        self.serviceUUIDs = serviceUUIDs
        self.characteristics = characteristics
        self.hadActiveHistoryBurst = hadActiveHistoryBurst
    }
}

/// Exact Gate C UUIDs used when validating a restored peripheral.  Keeping
/// this table in the restoration seam prevents a restored path from silently
/// accepting a different service or characteristic set.
public enum AdoptionRestorationGATT {
    public static let service = UUID(uuidString: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6")!
    public static let command = UUID(uuidString: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6")!
    public static let response = UUID(uuidString: "61080003-8D6D-82B8-614A-1C8CB0F8DCC6")!
    public static let events = UUID(uuidString: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6")!
    public static let data = UUID(uuidString: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6")!

    public static let allCharacteristics: Set<UUID> = [command, response, events, data]
    public static let inboundCharacteristics: Set<UUID> = [response, events, data]

    /// Validates an already-discovered restoration snapshot without touching
    /// CoreBluetooth.  A caller that does not have a complete table must
    /// rediscover instead of treating partial data as ready.
    public static func validate(
        _ snapshot: AdoptionRestorationSnapshot
    ) -> AdoptionRestorationValidation {
        // Restoration must validate the complete discovery table.  Accepting
        // a required UUID among extras (or accepting duplicate descriptors)
        // would allow a partial/stale CoreBluetooth payload to masquerade as
        // the pinned Gate C profile.
        let profile = snapshot.generation == .gen5 ? GATTProfile.gen5 : GATTProfile.gen4
        let requiredCharacteristics = profile.productionCharacteristics
        let inboundCharacteristics = profile.inboundCharacteristics
        let serviceValid = snapshot.serviceUUIDs.count == 1
            && Set(snapshot.serviceUUIDs) == [profile.service]
        let characteristicIDs = snapshot.characteristics.map(\.uuid)
        let characteristicTableValid = characteristicIDs.count == requiredCharacteristics.count
            && Set(characteristicIDs) == requiredCharacteristics
        let descriptors = snapshot.characteristics.reduce(into: [UUID: AdoptionRestoredCharacteristic]()) {
            $0[$1.uuid] = $1
        }
        let commandValid = characteristicTableValid
            && descriptors[profile.command]?.supportsWriteWithResponse == true
        let inboundValid = inboundCharacteristics.allSatisfy {
            descriptors[$0]?.supportsNotify == true
        }
        return AdoptionRestorationValidation(
            serviceValidated: serviceValid,
            characteristicsValidated: characteristicTableValid && commandValid && inboundValid
        )
    }
}

public struct AdoptionRestorationValidation: Equatable, Sendable {
    public let serviceValidated: Bool
    public let characteristicsValidated: Bool

    public init(serviceValidated: Bool, characteristicsValidated: Bool) {
        self.serviceValidated = serviceValidated
        self.characteristicsValidated = characteristicsValidated
    }

    public var isReady: Bool { serviceValidated && characteristicsValidated }
}

public struct AdoptionRestorationParserSet: Equatable, Sendable {
    public let responseParserID: UUID
    public let eventsParserID: UUID
    public let dataParserID: UUID

    public init(
        responseParserID: UUID,
        eventsParserID: UUID,
        dataParserID: UUID
    ) {
        self.responseParserID = responseParserID
        self.eventsParserID = eventsParserID
        self.dataParserID = dataParserID
    }

    public var allIDs: Set<UUID> { [responseParserID, eventsParserID, dataParserID] }
}

public struct AdoptionRestorationResumeContext: Equatable, Sendable {
    public let generation: UInt64
    public let ownerToken: UUID
    public let parsers: AdoptionRestorationParserSet

    /// A restored session always starts with a new burst.  A pre-restoration
    /// history burst is never resumed because doing so could replay stale data
    /// or emit an ACK from the old generation.
    public let historyBurstDiscarded: Bool
    public let backgroundWorkIsHistoryOnly: Bool

    public init(
        generation: UInt64,
        ownerToken: UUID,
        parsers: AdoptionRestorationParserSet,
        historyBurstDiscarded: Bool = true,
        backgroundWorkIsHistoryOnly: Bool = true
    ) {
        self.generation = generation
        self.ownerToken = ownerToken
        self.parsers = parsers
        self.historyBurstDiscarded = historyBurstDiscarded
        self.backgroundWorkIsHistoryOnly = backgroundWorkIsHistoryOnly
    }
}

public protocol RestorationSessionDriver: Sendable {
    /// Rebuilds delegate ownership and either validates the restored GATT
    /// table or rediscoveries it.  This must complete before `resume`.
    func validateOrRediscover(
        snapshot: AdoptionRestorationSnapshot,
        generation: UInt64,
        ownerToken: UUID
    ) async throws -> AdoptionRestorationValidation

    /// Resumes only after validation and receives fresh parser instances.  The
    /// driver is responsible for routing subsequent work through the single
    /// central owner; it must not create another owner here.
    func resume(
        snapshot: AdoptionRestorationSnapshot,
        context: AdoptionRestorationResumeContext
    ) async throws

    /// Cancels an in-flight or active restored session. The default keeps
    /// existing drivers source-compatible; a CoreBluetooth adapter should
    /// override it to tear down delegates/subscriptions and stop GATT work.
    func cancel(context: AdoptionRestorationResumeContext) async
}

public extension RestorationSessionDriver {
    func cancel(context: AdoptionRestorationResumeContext) async {}
}

public enum RestorationCoordinatorError: Error, Equatable, Sendable, LocalizedError {
    case noPeripheral
    case invalidRestoredGATT
    case staleRestoration
    case ownerAlreadyHeld

    public var errorDescription: String? {
        switch self {
        case .noPeripheral:
            return "The restoration payload did not identify a peripheral."
        case .invalidRestoredGATT:
            return "The restored peripheral did not validate against the required GATT table."
        case .staleRestoration:
            return "The restoration was superseded by a newer session generation."
        case .ownerAlreadyHeld:
            return "Another restored session already owns the central session."
        }
    }
}

public struct AdoptionRestorationOutcome: Equatable, Sendable {
    public let generation: UInt64
    public let parserSet: AdoptionRestorationParserSet?
    public let resumed: Bool
    public let ignoredUnknownPeripheral: Bool
    public let ownerToken: UUID?

    public init(
        generation: UInt64,
        parserSet: AdoptionRestorationParserSet?,
        resumed: Bool,
        ignoredUnknownPeripheral: Bool,
        ownerToken: UUID?
    ) {
        self.generation = generation
        self.parserSet = parserSet
        self.resumed = resumed
        self.ignoredUnknownPeripheral = ignoredUnknownPeripheral
        self.ownerToken = ownerToken
    }
}

/// Process-wide registry used by the adapter seam to prove there is only one
/// active central/session owner.  Normal and restored sessions share this
/// registry instead of creating a second restoration-only owner.
public actor RestorationOwnerRegistry {
    private var activeOwner: UUID?

    public init() {}

    public func acquire() throws -> UUID {
        guard activeOwner == nil else { throw RestorationCoordinatorError.ownerAlreadyHeld }
        let token = UUID()
        activeOwner = token
        return token
    }

    public func release(_ token: UUID) {
        guard activeOwner == token else { return }
        activeOwner = nil
    }

    public func ownerCount() -> Int { activeOwner == nil ? 0 : 1 }
    public func currentOwner() -> UUID? { activeOwner }
}

/// Coordinates CoreBluetooth restoration through the same owner used by the
/// normal connection path.  The actor serializes generation allocation and
/// rejects stale work after an await.
public actor RestorationCoordinator {
    private let driver: any RestorationSessionDriver
    private let ownerRegistry: RestorationOwnerRegistry
    private let makeUUID: @Sendable () -> UUID
    private var generation: UInt64 = 0
    private var activeOwnerToken: UUID?
    private var activeParsers: AdoptionRestorationParserSet?
    private var activeContext: AdoptionRestorationResumeContext?

    public init(
        driver: any RestorationSessionDriver,
        ownerRegistry: RestorationOwnerRegistry = RestorationOwnerRegistry(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.driver = driver
        self.ownerRegistry = ownerRegistry
        self.makeUUID = makeUUID
    }

    public func currentGeneration() -> UInt64 { generation }

    public func currentParsers() -> AdoptionRestorationParserSet? { activeParsers }

    public func currentOwnerToken() -> UUID? { activeOwnerToken }

    public func currentResumeContext() -> AdoptionRestorationResumeContext? {
        activeContext
    }

    /// Exposes the injected process-wide registry for simulator assertions and
    /// for the normal central owner to prove shared ownership.
    public func ownerCount() async -> Int { await ownerRegistry.ownerCount() }

    public func restore(
        _ snapshot: AdoptionRestorationSnapshot
    ) async throws -> AdoptionRestorationOutcome {
        generation &+= 1
        let thisGeneration = generation
        activeParsers = nil

        let oldContext = activeContext
        activeContext = nil
        if let oldContext {
            await driver.cancel(context: oldContext)
        }
        if let oldOwner = activeOwnerToken {
            await ownerRegistry.release(oldOwner)
            activeOwnerToken = nil
        }

        guard snapshot.shape != .unknownPeripheral,
              snapshot.peripheralIdentifier != nil else {
            // Unknown restored peripherals are not connected or resumed.  A
            // fresh generation is still consumed so callbacks from the old
            // session remain stale.
            return AdoptionRestorationOutcome(
                generation: thisGeneration,
                parserSet: nil,
                resumed: false,
                ignoredUnknownPeripheral: true,
                ownerToken: nil
            )
        }

        let ownerToken = try await ownerRegistry.acquire()
        activeOwnerToken = ownerToken
        let parsers = AdoptionRestorationParserSet(
            responseParserID: makeUUID(),
            eventsParserID: makeUUID(),
            dataParserID: makeUUID()
        )
        let context = AdoptionRestorationResumeContext(
            generation: thisGeneration,
            ownerToken: ownerToken,
            parsers: parsers,
            historyBurstDiscarded: true
        )
        // Publish the cancellation context before validation as well as
        // resume: rediscovery can suspend, and invalidation must still be
        // able to ask the driver to tear down that generation.
        activeContext = context

        do {
            let validation = try await driver.validateOrRediscover(
                snapshot: snapshot,
                generation: thisGeneration,
                ownerToken: ownerToken
            )
            guard validation.isReady, generation == thisGeneration else {
                throw generation == thisGeneration
                    ? RestorationCoordinatorError.invalidRestoredGATT
                    : RestorationCoordinatorError.staleRestoration
            }

            try await driver.resume(snapshot: snapshot, context: context)
            guard generation == thisGeneration else {
                throw RestorationCoordinatorError.staleRestoration
            }

            activeParsers = parsers
            return AdoptionRestorationOutcome(
                generation: thisGeneration,
                parserSet: parsers,
                resumed: true,
                ignoredUnknownPeripheral: false,
                ownerToken: ownerToken
            )
        } catch {
            if activeContext?.generation == thisGeneration,
               activeContext?.ownerToken == ownerToken {
                activeContext = nil
                await driver.cancel(context: context)
            }
            await ownerRegistry.release(ownerToken)
            if activeOwnerToken == ownerToken { activeOwnerToken = nil }
            throw error
        }
    }

    /// Invalidates an in-flight restore.  The next callback from the old
    /// generation is ignored by the generation check after suspension.
    public func invalidateCurrentRestoration() async {
        generation &+= 1
        activeParsers = nil
        let context = activeContext
        activeContext = nil
        if let context {
            await driver.cancel(context: context)
        }
        if let owner = activeOwnerToken {
            await ownerRegistry.release(owner)
            activeOwnerToken = nil
        }
    }
}
