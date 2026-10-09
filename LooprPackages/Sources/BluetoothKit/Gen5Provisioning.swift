import Foundation
import ProtocolKit

public protocol Gen5ConsentStore: Sendable {
    func loadConsent() async -> Bool
    func saveConsent(_ consented: Bool) async throws
}

public actor InMemoryGen5ConsentStore: Gen5ConsentStore {
    private var value: Bool

    public init(consented: Bool = false) { value = consented }
    public func loadConsent() -> Bool { value }
    public func saveConsent(_ consented: Bool) { value = consented }
}

public enum Gen5ConsentError: Error, Equatable, Sendable {
    case consentRequired
}

/// Local consent and the master switch form one provisioning boundary.
/// Withdrawing consent synchronously persists OFF before returning.
public actor Gen5ConsentGate {
    private let consentStore: any Gen5ConsentStore
    private let featureGate: Gen5FeatureGate

    public init(consentStore: any Gen5ConsentStore, featureGate: Gen5FeatureGate) {
        self.consentStore = consentStore
        self.featureGate = featureGate
    }

    public func recordConsent() async throws {
        try await consentStore.saveConsent(true)
    }

    public func withdrawConsent() async throws {
        try await featureGate.setEnabled(false)
        try await consentStore.saveConsent(false)
    }

    public func authorizeProvisioning() async throws {
        guard await consentStore.loadConsent() else { throw Gen5ConsentError.consentRequired }
        try await featureGate.authorize(.provisioning)
    }
}

public enum LooprDistribution: String, Equatable, Sendable {
    case internalDevelopment
    case testFlight
    case appStore
}

public struct AccessoryServiceDescriptor: Equatable, Sendable {
    public let generation: BandGeneration
    public let service: UUID

    public init(generation: BandGeneration, service: UUID) {
        self.generation = generation
        self.service = service
    }
}

public enum AccessoryDescriptorCatalog {
    public static let stableGen4 = [
        AccessoryServiceDescriptor(generation: .gen4, service: GATTProfile.gen4.service)
    ]

    public static func descriptors(
        for distribution: LooprDistribution,
        experimentalSupportEnabled: Bool = false
    ) -> [AccessoryServiceDescriptor] {
        guard experimentalSupportEnabled else { return stableGen4 }
        return stableGen4 + [AccessoryServiceDescriptor(generation: .gen5, service: GATTProfile.gen5.service)]
    }
}

public struct Gen5CandidateIdentity: Equatable, Sendable {
    public let peripheralID: UUID
    public let service: UUID
    public let name: String?
    public let helloIdentity: Data?
    public let firmware: String?
    public let model: BandModel
    public let modelConfidence: Double

    public init(
        peripheralID: UUID,
        service: UUID,
        name: String?,
        helloIdentity: Data?,
        firmware: String?,
        model: BandModel = .unknownGen5,
        modelConfidence: Double = 0
    ) {
        self.peripheralID = peripheralID
        self.service = service
        self.name = name
        self.helloIdentity = helloIdentity
        self.firmware = firmware
        self.model = model
        self.modelConfidence = min(max(modelConfidence, 0), 1)
    }
}

public enum BandProfileResolutionError: Error, Equatable, Sendable {
    case noSupportedService
    case ambiguousServiceFamilies
}

public enum BandProfileResolver {
    public static func generation(for advertisedServices: Set<UUID>) throws -> BandGeneration {
        let hasGen4 = advertisedServices.contains(GATTProfile.gen4.service)
        let hasGen5 = advertisedServices.contains(GATTProfile.gen5.service)
        guard !(hasGen4 && hasGen5) else { throw BandProfileResolutionError.ambiguousServiceFamilies }
        if hasGen5 { return .gen5 }
        if hasGen4 { return .gen4 }
        throw BandProfileResolutionError.noSupportedService
    }
}
