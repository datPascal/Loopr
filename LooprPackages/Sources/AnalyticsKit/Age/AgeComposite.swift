import Foundation

public struct CompositeRiskFeatures: Codable, Equatable, Sendable {
    public let values: [String: Double]

    public init(values: [String: Double]) {
        self.values = values
    }

    public init(contributors: [AgeContributor]) {
        var values: [String: Double] = [:]
        for contributor in contributors {
            if let raw = contributor.rawAggregate {
                values[contributor.kind.rawValue] = raw
            }
        }
        self.values = values
    }
}

public struct ModelCardReviewSignOff: Codable, Equatable, Sendable {
    public let reviewer: String
    public let signedAt: Date?
    public let signature: String
    public let approved: Bool

    public init(
        reviewer: String,
        signedAt: Date?,
        signature: String,
        approved: Bool
    ) {
        self.reviewer = reviewer
        self.signedAt = signedAt
        self.signature = signature
        self.approved = approved
    }

    public var isSigned: Bool {
        approved && !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            signedAt != nil && !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct ModelCardEvidence: Codable, Equatable, Sendable {
    public let summary: String
    public let metrics: [String: Double]

    public init(summary: String, metrics: [String: Double] = [:]) {
        self.summary = summary
        self.metrics = metrics
    }
}

public struct ReferenceRiskAnchor: Codable, Equatable, Sendable {
    public let age: Double
    public let risk: Double

    public init(age: Double, risk: Double) {
        self.age = age
        self.risk = risk
    }
}

/// The reviewable, versioned contract required before a composite age can be
/// exposed.  `reviewSignOff` is intentionally non-optional: an unsigned card
/// is represented explicitly with `approved == false`, never by omission.
public struct ModelCard: Codable, Equatable, Sendable {
    public let modelVersion: Int
    public let referenceVersion: Int
    public let outcome: String
    public let horizon: String
    public let targetPopulation: String
    public let referenceProfile: [String: Double]
    public let coefficients: [String: Double]
    public let transforms: [String: String]
    public let referencePopulation: String
    public let subgroupPerformance: [String: Double]
    public let calibrationEvidence: ModelCardEvidence
    public let discriminationEvidence: ModelCardEvidence
    public let uncertaintyEvidence: ModelCardEvidence
    public let stabilityEvidence: ModelCardEvidence
    public let referenceRiskAnchors: [ReferenceRiskAnchor]
    public let minimumValidatedAge: Double
    public let maximumValidatedAge: Double
    public let reviewSignOff: ModelCardReviewSignOff

    public init(
        modelVersion: Int,
        referenceVersion: Int,
        outcome: String,
        horizon: String,
        targetPopulation: String,
        referenceProfile: [String: Double],
        coefficients: [String: Double],
        transforms: [String: String],
        referencePopulation: String,
        subgroupPerformance: [String: Double],
        calibrationEvidence: ModelCardEvidence,
        discriminationEvidence: ModelCardEvidence,
        uncertaintyEvidence: ModelCardEvidence,
        stabilityEvidence: ModelCardEvidence,
        referenceRiskAnchors: [ReferenceRiskAnchor],
        validatedAgeRange: ClosedRange<Double>,
        reviewSignOff: ModelCardReviewSignOff
    ) {
        self.modelVersion = modelVersion
        self.referenceVersion = referenceVersion
        self.outcome = outcome
        self.horizon = horizon
        self.targetPopulation = targetPopulation
        self.referenceProfile = referenceProfile
        self.coefficients = coefficients
        self.transforms = transforms
        self.referencePopulation = referencePopulation
        self.subgroupPerformance = subgroupPerformance
        self.calibrationEvidence = calibrationEvidence
        self.discriminationEvidence = discriminationEvidence
        self.uncertaintyEvidence = uncertaintyEvidence
        self.stabilityEvidence = stabilityEvidence
        self.referenceRiskAnchors = referenceRiskAnchors
        self.minimumValidatedAge = validatedAgeRange.lowerBound
        self.maximumValidatedAge = validatedAgeRange.upperBound
        self.reviewSignOff = reviewSignOff
    }

    public var validatedAgeRange: ClosedRange<Double> { minimumValidatedAge...maximumValidatedAge }
    public var isSigned: Bool { reviewSignOff.isSigned }

}

/// There is deliberately no populated card in the application bundle at this
/// stage. A future validated release can replace this provider as part of the
/// external scientific/legal gate, while the hard runtime gate remains here.
public enum BundledModelCard {
    public static var current: ModelCard? { nil }
}

public enum CompositeAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(reason: LooprAgeAbsenceReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case state, reason }
    private enum State: String, Codable { case available, unavailable }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available:
            self = .available
        case .unavailable:
            self = .unavailable(reason: try container.decode(LooprAgeAbsenceReason.self, forKey: .reason))
        }
    }
}

public enum AgeConversionBoundary: String, Codable, Sendable {
    case lower
    case upper
}

public struct AgeConversionResult: Codable, Equatable, Sendable {
    public let ageYears: Double?
    public let availability: CompositeAvailability
    public let boundary: AgeConversionBoundary?

    public init(ageYears: Double?, availability: CompositeAvailability, boundary: AgeConversionBoundary?) {
        self.ageYears = ageYears
        self.availability = availability
        self.boundary = boundary
    }
}

public struct AgeConversionSolver: Sendable {
    public init() {}

    /// Converts a modeled risk to the age whose fixed reference profile has the
    /// same risk. The interpolation is monotone and never extrapolates beyond
    /// the validated model-card range.
    public func solve(modeledRisk: Double, modelCard: ModelCard) -> AgeConversionResult {
        guard modelCard.isSigned,
              modeledRisk.isFinite,
              modeledRisk > 0,
              modelCard.referenceRiskAnchors.count >= 2,
              let first = modelCard.referenceRiskAnchors.first,
              let last = modelCard.referenceRiskAnchors.last,
              first.age < last.age,
              modelCard.referenceRiskAnchors.allSatisfy({ $0.risk.isFinite && $0.risk > 0 }),
              monotone(modelCard.referenceRiskAnchors) else {
            return AgeConversionResult(
                ageYears: nil,
                availability: .unavailable(reason: .compositeValidationIncomplete),
                boundary: nil
            )
        }

        if modeledRisk <= first.risk {
            return AgeConversionResult(
                ageYears: modelCard.minimumValidatedAge,
                availability: .available,
                boundary: .lower
            )
        }
        if modeledRisk >= last.risk {
            return AgeConversionResult(
                ageYears: modelCard.maximumValidatedAge,
                availability: .available,
                boundary: .upper
            )
        }

        for pair in zip(modelCard.referenceRiskAnchors, modelCard.referenceRiskAnchors.dropFirst()) {
            let lower = pair.0
            let upper = pair.1
            if modeledRisk >= lower.risk && modeledRisk <= upper.risk {
                let fraction = (modeledRisk - lower.risk) / (upper.risk - lower.risk)
                let age = lower.age + fraction * (upper.age - lower.age)
                return AgeConversionResult(ageYears: age, availability: .available, boundary: nil)
            }
        }

        return AgeConversionResult(
            ageYears: nil,
            availability: .unavailable(reason: .compositeValidationIncomplete),
            boundary: nil
        )
    }

    private func monotone(_ anchors: [ReferenceRiskAnchor]) -> Bool {
        zip(anchors, anchors.dropFirst()).allSatisfy { $0.age < $1.age && $0.risk <= $1.risk }
    }
}

public struct CompositeEvaluation: Codable, Equatable, Sendable {
    public let modeledRisk: Double?
    public let looprAgeYears: Double?
    public let availability: CompositeAvailability
    public let absenceReason: LooprAgeAbsenceReason?
    public let modelVersion: Int?

    public init(
        modeledRisk: Double?,
        looprAgeYears: Double?,
        availability: CompositeAvailability,
        absenceReason: LooprAgeAbsenceReason?,
        modelVersion: Int?
    ) {
        self.modeledRisk = modeledRisk
        self.looprAgeYears = looprAgeYears
        self.availability = availability
        self.absenceReason = absenceReason
        self.modelVersion = modelVersion
    }

    public static func unavailable(_ reason: LooprAgeAbsenceReason) -> CompositeEvaluation {
        CompositeEvaluation(
            modeledRisk: nil,
            looprAgeYears: nil,
            availability: .unavailable(reason: reason),
            absenceReason: reason,
            modelVersion: nil
        )
    }
}

public struct CompositeRiskModel: Sendable {
    public let conversionSolver: AgeConversionSolver

    public init(conversionSolver: AgeConversionSolver = AgeConversionSolver()) {
        self.conversionSolver = conversionSolver
    }

    /// Evaluate only with an explicitly supplied, signed model card. The
    /// default provider is nil, making the shipped composite honestly
    /// unavailable for every input combination.
    public func evaluate(
        features: CompositeRiskFeatures,
        realAgeYears: Int,
        modelCard: ModelCard? = nil
    ) -> CompositeEvaluation {
        guard let modelCard = modelCard ?? BundledModelCard.current else {
            return .unavailable(.compositeValidationIncomplete)
        }
        guard modelCard.isSigned,
              modelCard.validatedAgeRange.contains(Double(realAgeYears)),
              let baseline = risk(at: Double(realAgeYears), anchors: modelCard.referenceRiskAnchors),
              baseline > 0,
              let modeledRisk = modeledRisk(features: features, baseline: baseline, card: modelCard),
              modeledRisk.isFinite,
              modeledRisk > 0 else {
            return .unavailable(.compositeValidationIncomplete)
        }
        let conversion = conversionSolver.solve(modeledRisk: modeledRisk, modelCard: modelCard)
        guard let age = conversion.ageYears, conversion.availability.isAvailable else {
            return .unavailable(.compositeValidationIncomplete)
        }
        return CompositeEvaluation(
            modeledRisk: modeledRisk,
            looprAgeYears: age,
            availability: .available,
            absenceReason: nil,
            modelVersion: modelCard.modelVersion
        )
    }

    private func modeledRisk(features: CompositeRiskFeatures, baseline: Double, card: ModelCard) -> Double? {
        var linear = 0.0
        for (name, coefficient) in card.coefficients {
            guard let value = features.values[name], value.isFinite else { return nil }
            let transform = card.transforms[name] ?? "identity"
            guard let transformed = Self.transform(value, named: transform), transformed.isFinite else { return nil }
            linear += coefficient * transformed
        }
        return baseline * exp(linear)
    }

    private func risk(at age: Double, anchors: [ReferenceRiskAnchor]) -> Double? {
        guard let first = anchors.first, let last = anchors.last, age >= first.age, age <= last.age else {
            return nil
        }
        if age == first.age { return first.risk }
        if age == last.age { return last.risk }
        for pair in zip(anchors, anchors.dropFirst()) {
            if age >= pair.0.age && age <= pair.1.age {
                let fraction = (age - pair.0.age) / (pair.1.age - pair.0.age)
                return pair.0.risk + fraction * (pair.1.risk - pair.0.risk)
            }
        }
        return nil
    }

    private static func transform(_ value: Double, named: String) -> Double? {
        switch named {
        case "identity": return value
        case "log": return value > 0 ? log(value) : nil
        case "square": return value * value
        case "abs": return abs(value)
        default: return nil
        }
    }
}

public enum CompositeUIState: Equatable, Sendable {
    case calibrating
    case unavailableNoModel
    case unavailableMissingDomain
    case established(ageYears: Int)
    case provisional(ageYears: Int)

    public var numericAge: Int? {
        switch self {
        case .established(let age), .provisional(let age): age
        default: nil
        }
    }

    public var visibleCopy: String {
        switch self {
        case .calibrating: "Loopr Age is still being calibrated."
        case .unavailableNoModel: "Loopr Age is unavailable until the validated model is ready."
        case .unavailableMissingDomain: "Loopr Age is unavailable until the required data is available."
        case .established(let age): "Loopr Age: \(age) years."
        case .provisional(let age): "Loopr Age: \(age) years (provisional)."
        }
    }

    public static func forResult(_ result: LooprAgeResult) -> CompositeUIState {
        guard let age = result.looprAgeYears else {
            if result.absenceReason == .missingRequiredDomain || result.absenceReason == .missingDomain {
                return .unavailableMissingDomain
            }
            return .unavailableNoModel
        }
        switch result.confidenceTier {
        case .established: return .established(ageYears: age)
        case .provisional, .lowConfidence, .unavailable: return .provisional(ageYears: age)
        }
    }
}
