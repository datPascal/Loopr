import Foundation

public enum BandGeneration: String, Codable, Equatable, Sendable {
    case gen4
    case gen5
}

public enum BandModel: Codable, Equatable, Hashable, Sendable {
    case whoop4
    case whoop5
    case whoopMG
    case unknownGen5
}

/// FD4B is shared by WHOOP 5.0 and MG. The model is unknown until DIS
/// evidence resolves it. Protocol facts: noop@5ac2cc2a,
/// Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Variant.swift:18-27,58-98.
public enum Gen5ModelIdentityResolver {
    public static func resolve(
        modelNumber: String?,
        serialNumber: String?,
        hardwareRevision: String?
    ) -> BandModel {
        let model = modelNumber?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if model == "MG" { return .whoopMG }

        let serial = serialNumber?.uppercased() ?? ""
        let hardware = hardwareRevision?.uppercased() ?? ""
        let mgSerial = serial.hasPrefix("5AM") || serial.hasPrefix("MGB")
        let fiveSerial = serial.hasPrefix("5AG")
        let fiveHardware = hardware.contains("WG50")
        if mgSerial && (fiveSerial || fiveHardware) { return .unknownGen5 }
        if mgSerial { return .whoopMG }
        if fiveSerial || fiveHardware { return .whoop5 }
        return .unknownGen5
    }
}

public enum Gen5Capability: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case provisioning
    case connectSubscribe
    case identity
    case battery
    case clockRead
    case clockSet
    case dataRange
    case history
    case acknowledgement
    case v18Ingestion
    case v20Archive
    case v21Archive
    case v26Archive
    case liveHeartRateAndRR
    case haptic
    case alarm
    case deepBuffers
    case restoration
    case sleepAnalytics
    case heartAnalytics
    case stressAnalytics
    case bodyAnalytics
    case workoutAnalytics
    case healthKitEligibility
}

public enum CapabilityState: Equatable, Sendable {
    case unknown
    case observed
    case fixtureVerified
    case hardwareVerified(model: BandModel, firmware: String)
    case betaEnabled
    case suspended

    public func transitioning(to next: Self) throws -> Self {
        let allowed: Bool
        switch (self, next) {
        case (.unknown, .observed),
             (.observed, .fixtureVerified),
             (.fixtureVerified, .hardwareVerified),
             (.hardwareVerified, .betaEnabled),
             (.betaEnabled, .suspended):
            allowed = true
        default:
            allowed = false
        }
        guard allowed else { throw CapabilityTransitionError.nonSequential(from: self, to: next) }
        if case .hardwareVerified(let model, let firmware) = next {
            guard (model == .whoop5 || model == .whoopMG),
                  !firmware.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CapabilityTransitionError.invalidHardwareEvidence
            }
        }
        return next
    }
}

public enum CapabilityTransitionError: Error, Equatable, Sendable {
    case nonSequential(from: CapabilityState, to: CapabilityState)
    case invalidHardwareEvidence
    case unsupportedModel(BandModel)
    case hardwareEvidenceModelMismatch(expected: BandModel, actual: BandModel)
}

public struct Gen5CapabilityMatrix: Equatable, Sendable {
    private var states: [BandModel: [Gen5Capability: CapabilityState]]

    public init() {
        let unknown = Dictionary(uniqueKeysWithValues: Gen5Capability.allCases.map { ($0, CapabilityState.unknown) })
        states = [.whoop5: unknown, .whoopMG: unknown]
    }

    public func state(for capability: Gen5Capability, model: BandModel) -> CapabilityState {
        states[model]?[capability] ?? .unknown
    }

    public mutating func transition(
        _ capability: Gen5Capability,
        model: BandModel,
        to next: CapabilityState
    ) throws {
        guard model == .whoop5 || model == .whoopMG else {
            throw CapabilityTransitionError.unsupportedModel(model)
        }
        if case .hardwareVerified(let evidenceModel, _) = next,
           evidenceModel != model {
            throw CapabilityTransitionError.hardwareEvidenceModelMismatch(
                expected: model,
                actual: evidenceModel
            )
        }
        let current = state(for: capability, model: model)
        states[model, default: [:]][capability] = try current.transitioning(to: next)
    }
}

public struct GATTProfile: Equatable, Sendable {
    public let service: UUID
    public let command: UUID
    public let response: UUID
    public let events: UUID
    public let data: UUID
    public let memfault: UUID?

    public init(
        service: UUID,
        command: UUID,
        response: UUID,
        events: UUID,
        data: UUID,
        memfault: UUID?
    ) {
        self.service = service
        self.command = command
        self.response = response
        self.events = events
        self.data = data
        self.memfault = memfault
    }

    public static let gen4 = Self(
        service: UUID(uuidString: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6")!,
        command: UUID(uuidString: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6")!,
        response: UUID(uuidString: "61080003-8D6D-82B8-614A-1C8CB0F8DCC6")!,
        events: UUID(uuidString: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6")!,
        data: UUID(uuidString: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6")!,
        memfault: nil
    )

    public static let gen5 = Self(
        service: UUID(uuidString: "FD4B0001-CCE1-4033-93CE-002D5875F58A")!,
        command: UUID(uuidString: "FD4B0002-CCE1-4033-93CE-002D5875F58A")!,
        response: UUID(uuidString: "FD4B0003-CCE1-4033-93CE-002D5875F58A")!,
        events: UUID(uuidString: "FD4B0004-CCE1-4033-93CE-002D5875F58A")!,
        data: UUID(uuidString: "FD4B0005-CCE1-4033-93CE-002D5875F58A")!,
        memfault: UUID(uuidString: "FD4B0007-CCE1-4033-93CE-002D5875F58A")!
    )

    public var inboundCharacteristics: Set<UUID> { [response, events, data] }
    public var productionCharacteristics: Set<UUID> { [command, response, events, data] }
}

public enum FrameProfile: String, Codable, Equatable, Sendable {
    case gen4
    case gen5

    public var headerLength: Int { self == .gen4 ? 4 : 8 }
    public var declaredLengthOffset: Int { self == .gen4 ? 1 : 2 }
}

public struct RecordCapabilities: Equatable, Sendable {
    public let supportedVersions: Set<UInt8>

    public init(supportedVersions: Set<UInt8> = []) {
        self.supportedVersions = supportedVersions
    }

    public static let gen4 = Self(supportedVersions: [7, 9, 12, 18, 24, 25])
    public static let gen5ArchiveOnly = Self(supportedVersions: [18, 20, 21, 26])
}

public struct FirmwarePolicy: Equatable, Sendable {
    public let allowedModelFirmwarePairs: Set<String>

    public init(allowedModelFirmwarePairs: Set<String> = []) {
        self.allowedModelFirmwarePairs = allowedModelFirmwarePairs
    }

    public static let stableGen4 = Self()
    public static let denyUnknownGen5 = Self()
}

public struct BandProfile: Equatable, Sendable {
    public let generation: BandGeneration
    public let model: BandModel
    public let gatt: GATTProfile
    public let framing: FrameProfile
    public let commands: CommandCapabilities
    public let records: RecordCapabilities
    public let firmwarePolicy: FirmwarePolicy

    public init(
        generation: BandGeneration,
        model: BandModel,
        gatt: GATTProfile,
        framing: FrameProfile,
        commands: CommandCapabilities,
        records: RecordCapabilities,
        firmwarePolicy: FirmwarePolicy
    ) {
        self.generation = generation
        self.model = model
        self.gatt = gatt
        self.framing = framing
        self.commands = commands
        self.records = records
        self.firmwarePolicy = firmwarePolicy
    }

    /// The Gen 4 command families Loopr has source-pinned byte layouts for.
    /// Gesture stays denied because the reference has no outgoing gesture
    /// opcode at all; the band emits event 14 unconditionally instead.
    public static let gen4Commands = CommandCapabilities(confirmed: [
        .battery,
        .heartRateSharing,
        .identity,
        .rename,
        .haptic,
        .alarm
    ])

    public static let gen4 = Self(
        generation: .gen4,
        model: .whoop4,
        gatt: .gen4,
        framing: .gen4,
        commands: gen4Commands,
        records: .gen4,
        firmwarePolicy: .stableGen4
    )
}
