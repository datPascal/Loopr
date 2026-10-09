import Foundation
import ProtocolKit

public protocol Gen5KillSwitchStore: Sendable {
    func loadEnabled() async -> Bool
    func saveEnabled(_ enabled: Bool) async throws
}

public actor InMemoryGen5KillSwitchStore: Gen5KillSwitchStore {
    private var persistedValue: Bool?

    public init(persistedValue: Bool? = nil) {
        self.persistedValue = persistedValue
    }

    public func loadEnabled() -> Bool { persistedValue ?? false }
    public func saveEnabled(_ enabled: Bool) throws { persistedValue = enabled }
}

public final class UserDefaultsGen5KillSwitchStore: Gen5KillSwitchStore, @unchecked Sendable {
    public static let key = "com.loopr.bluetooth.experimentalGen5.enabled"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func loadEnabled() async -> Bool { defaults.bool(forKey: Self.key) }
    public func saveEnabled(_ enabled: Bool) async throws { defaults.set(enabled, forKey: Self.key) }
}

public enum Gen5BetaProduct: String, CaseIterable, Equatable, Sendable {
    case whoop5
    case whoopMG

    public init?(model: BandModel) {
        switch model {
        case .whoop5: self = .whoop5
        case .whoopMG: self = .whoopMG
        default: return nil
        }
    }
}

public final class UserDefaultsGen5ProductKillSwitchStore: Gen5KillSwitchStore, @unchecked Sendable {
    public static func key(for product: Gen5BetaProduct) -> String {
        "com.loopr.bluetooth.experimentalGen5.\(product.rawValue).enabled"
    }

    private let product: Gen5BetaProduct
    private let defaults: UserDefaults

    public init(product: Gen5BetaProduct, defaults: UserDefaults = .standard) {
        self.product = product
        self.defaults = defaults
    }

    public func loadEnabled() async -> Bool { defaults.bool(forKey: Self.key(for: product)) }
    public func saveEnabled(_ enabled: Bool) async throws {
        defaults.set(enabled, forKey: Self.key(for: product))
    }
}

public enum Gen5GateEntryPoint: String, CaseIterable, Equatable, Sendable {
    case provisioning
    case connect
    case commandEncode
    case decode
    case acknowledgement
}

public enum Gen5FeatureGateError: Error, Equatable, Sendable {
    case disabled(Gen5GateEntryPoint)
    case stableProfileRequested
}

/// One durable master switch protects every Gen 5 entry point. Capability
/// graduation adds narrower gates later; none can bypass this boundary.
public actor Gen5FeatureGate {
    private let store: any Gen5KillSwitchStore

    public init(store: any Gen5KillSwitchStore) { self.store = store }

    public func isEnabled() async -> Bool { await store.loadEnabled() }
    public func setEnabled(_ enabled: Bool) async throws { try await store.saveEnabled(enabled) }

    public func authorize(_ entryPoint: Gen5GateEntryPoint) async throws {
        guard await store.loadEnabled() else { throw Gen5FeatureGateError.disabled(entryPoint) }
    }

    public func makeProfile(model: BandModel = .unknownGen5) async throws -> BandProfile {
        try await authorize(.connect)
        guard model != .whoop4 else { throw Gen5FeatureGateError.stableProfileRequested }
        return BandProfile(
            generation: .gen5,
            model: model,
            gatt: .gen5,
            framing: .gen5,
            commands: .none,
            records: .gen5ArchiveOnly,
            firmwarePolicy: .denyUnknownGen5
        )
    }
}

/// Release-time product gates supplement the master Gen 5 switch. A WHOOP
/// 5.0 incident can therefore be contained without enabling or disabling MG,
/// and neither beta switch participates in stable Gen 4 authorization.
public actor Gen5ProductFeatureGates {
    private let master: Gen5FeatureGate
    private let whoop5: Gen5FeatureGate
    private let whoopMG: Gen5FeatureGate

    public init(master: Gen5FeatureGate, whoop5: Gen5FeatureGate, whoopMG: Gen5FeatureGate) {
        self.master = master
        self.whoop5 = whoop5
        self.whoopMG = whoopMG
    }

    public func authorize(_ entryPoint: Gen5GateEntryPoint, model: BandModel) async throws {
        try await master.authorize(entryPoint)
        switch Gen5BetaProduct(model: model) {
        case .whoop5?: try await whoop5.authorize(entryPoint)
        case .whoopMG?: try await whoopMG.authorize(entryPoint)
        case nil: throw Gen5FeatureGateError.stableProfileRequested
        }
    }
}

/// The only production-facing Gate-1 encoder. ProtocolKit's fd4b command
/// vocabulary has package visibility, so clients cannot frame arbitrary or
/// ungraduated opcodes around this durable master gate.
public actor Gen5InitialCommandGateway {
    private let gate: Gen5FeatureGate

    public init(gate: Gen5FeatureGate) { self.gate = gate }

    public func clientHello(sequence: UInt8 = 1) async throws -> Data {
        try await gate.authorize(.commandEncode)
        return try Gen5InitialCommandEncoder().encode(.clientHello(sequence: sequence))
    }
}
