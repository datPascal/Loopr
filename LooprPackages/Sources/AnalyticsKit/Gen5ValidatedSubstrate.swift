import Foundation

/// The complete Gen 5 input surface visible to analytics. Candidate optical,
/// oxygen, temperature, step and waveform fields do not exist on this type.
public struct Gen5ValidatedSubstrate: Equatable, Sendable {
    public let timestamp: UInt32
    public let index: UInt32
    public let heartRate: UInt8?
    public let rrMilliseconds: [UInt16]
    public let gravity: SIMD3<Double>

    public init(
        timestamp: UInt32,
        index: UInt32,
        heartRate: UInt8?,
        rrMilliseconds: [UInt16],
        gravity: SIMD3<Double>
    ) {
        self.timestamp = timestamp
        self.index = index
        self.heartRate = heartRate
        self.rrMilliseconds = rrMilliseconds
        self.gravity = gravity
    }
}

public struct BandAgnosticHeartInput: Equatable, Sendable {
    public let timestamp: UInt32
    public let heartRate: UInt8?
    public let rrMilliseconds: [UInt16]
}

public enum Gen5SubstrateMapper {
    public static func heartInput(from substrate: Gen5ValidatedSubstrate) -> BandAgnosticHeartInput {
        .init(
            timestamp: substrate.timestamp,
            heartRate: substrate.heartRate,
            rrMilliseconds: substrate.rrMilliseconds
        )
    }
}

public enum Gen5SurfaceCapability: String, CaseIterable, Equatable, Sendable {
    case connected
    case historyVerified
    case analyticsVerified
    case backgroundVerified
}

public struct Gen5MetricSurfaceProjection: Equatable, Sendable {
    public let modelLabel: String
    public let firmware: String
    public let betaBadge: String
    public let capability: Gen5SurfaceCapability
    public let value: Double?
    public let unavailableReason: String?

    public init(
        modelLabel: String,
        firmware: String,
        capability: Gen5SurfaceCapability,
        value: Double?
    ) {
        self.modelLabel = modelLabel
        self.firmware = firmware
        self.betaBadge = "Experimental Beta"
        self.capability = capability
        self.value = value
        self.unavailableReason = value == nil ? "Not verified for this model and firmware" : nil
    }
}

public enum Gen5CandidateMetric: String, CaseIterable, Sendable {
    case oxygen, temperature, steps, waveform
}

public enum Gen5ExportPolicy {
    public static let allowedFields: Set<String> = ["timestamp", "index", "heartRate", "rrMilliseconds", "gravity"]

    public static func permits(_ candidate: Gen5CandidateMetric) -> Bool { false }
}

public enum Gen5ModelPresentation {
    public static func label(model: String, identityConfirmed: Bool) -> String {
        guard identityConfirmed else { return "Experimental Gen 5 device" }
        switch model {
        case "whoopMG": return "MG band (Experimental Beta)"
        case "whoop5": return "Gen 5 band (Experimental Beta)"
        default: return "Experimental Gen 5 device"
        }
    }

    public static let reachableMedicalClaims: Set<String> = []
    public static let forbiddenMedicalClaims: Set<String> = [
        "ECG", "clinical", "blood pressure", "diagnosis", "medical device"
    ]
}
