import Foundation

/// The confidence vocabulary used by all age derivations.  It is deliberately
/// small: a caller must not invent a more optimistic state for missing data.
public enum ConfidenceTier: String, Codable, CaseIterable, Sendable {
    case established
    case provisional
    case lowConfidence
    case unavailable
}

public typealias AgeConfidenceTier = ConfidenceTier

public enum LooprAgeAbsenceReason: String, Codable, CaseIterable, Sendable {
    case noVO2MaxSource
    case unsupportedPopulation
    case declinedReferenceCurve
    case insufficientCoverage
    case illnessOrLowWear
    case staleData
    case failedQuality
    case missingRequiredDomain
    case noMatchingModelVariant
    case compositeNotYetValidated
    case compositeValidationIncomplete
    case modelNotSigned
    case noModel
    case missingDomain
}

public enum CardioAgeStatus: String, Codable, Sendable {
    case available
    case unavailable
}

public struct CardioAgeResult: Codable, Equatable, Sendable {
    public let ageYears: Double?
    public let displayLabel: String?
    public let status: CardioAgeStatus
    public let vo2max: Double?
    public let source: VO2MaxSourceKind?
    public let referenceGroup: FriendReferenceGroup?
    public let referenceVersion: Int
    public let confidence: Double
    public let absenceReason: LooprAgeAbsenceReason?

    public init(
        ageYears: Double?,
        displayLabel: String?,
        status: CardioAgeStatus,
        vo2max: Double?,
        source: VO2MaxSourceKind?,
        referenceGroup: FriendReferenceGroup?,
        referenceVersion: Int,
        confidence: Double,
        absenceReason: LooprAgeAbsenceReason?
    ) {
        self.ageYears = ageYears
        self.displayLabel = displayLabel
        self.status = status
        self.vo2max = vo2max
        self.source = source
        self.referenceGroup = referenceGroup
        self.referenceVersion = referenceVersion
        self.confidence = confidence
        self.absenceReason = absenceReason
    }

    public var isAvailable: Bool { status == .available && ageYears != nil }
    public var isUnavailable: Bool { !isAvailable }
    /// Alias useful to clients that use the shorter name from the product copy.
    public var display: String? { displayLabel }

    public static func unavailable(
        reason: LooprAgeAbsenceReason,
        referenceVersion: Int = 1,
        source: VO2MaxSourceKind? = nil,
        referenceGroup: FriendReferenceGroup? = nil
    ) -> CardioAgeResult {
        CardioAgeResult(
            ageYears: nil,
            displayLabel: nil,
            status: .unavailable,
            vo2max: nil,
            source: source,
            referenceGroup: referenceGroup,
            referenceVersion: referenceVersion,
            confidence: 0,
            absenceReason: reason
        )
    }
}

public enum AgeContributorKind: String, Codable, CaseIterable, Sendable {
    case cardioCapacity
    case restingHeartRate
    case bodyComposition
    case dailyMovement
    case lowModerateAerobicActivity
    case vigorousAerobicActivity
    case strengthActivity
    case sleepDuration
    case sleepConsistency
}

public enum AgeContributorAvailability: Codable, Equatable, Sendable {
    case available
    case absent(reason: LooprAgeAbsenceReason)

    private enum CodingKeys: String, CodingKey { case state, reason }
    private enum State: String, Codable { case available, absent }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case .absent(let reason):
            try container.encode(State.absent, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .available:
            self = .available
        case .absent:
            self = .absent(reason: try container.decode(LooprAgeAbsenceReason.self, forKey: .reason))
        }
    }
}

public enum AgeEffectDirection: String, Codable, CaseIterable, Sendable {
    case improves
    case worsens
    case neutral
    case unknown
}

/// A contributor is an explainable aggregate, not an opaque score.  `source`
/// is provenance from a canonical repository (never a raw sensor stream).
public struct AgeContributor: Codable, Equatable, Sendable {
    public let kind: AgeContributorKind
    public let rawAggregate: Double?
    public let unit: String
    public let source: String
    public let coverage: Double
    public let quality: Double
    public let modelTransform: String
    public let direction: AgeEffectDirection
    public let effect: Double?
    public let availability: AgeContributorAvailability
    public let distribution: [Double]

    public init(
        kind: AgeContributorKind,
        rawAggregate: Double?,
        unit: String,
        source: String,
        coverage: Double,
        quality: Double,
        modelTransform: String,
        direction: AgeEffectDirection = .unknown,
        effect: Double? = nil,
        availability: AgeContributorAvailability,
        distribution: [Double] = []
    ) {
        self.kind = kind
        self.rawAggregate = rawAggregate
        self.unit = unit
        self.source = source
        self.coverage = coverage
        self.quality = quality
        self.modelTransform = modelTransform
        self.direction = direction
        self.effect = effect
        self.availability = availability
        self.distribution = distribution
    }

    /// Compatibility alias for callers using the wording in the result model.
    public var rawValue: Double? { rawAggregate }
}

public struct AgeCoverage: Codable, Equatable, Sendable {
    public let windowDays: Int
    public let eligibleDays: Int
    public let validDays: Int
    public let totalDays: Int
    public let coverageFraction: Double
    public let strongCoverage: Bool

    public init(
        windowDays: Int,
        eligibleDays: Int,
        validDays: Int,
        totalDays: Int,
        coverageFraction: Double,
        strongCoverage: Bool
    ) {
        self.windowDays = windowDays
        self.eligibleDays = eligibleDays
        self.validDays = validDays
        self.totalDays = totalDays
        self.coverageFraction = coverageFraction
        self.strongCoverage = strongCoverage
    }

    public static let empty = AgeCoverage(
        windowDays: 0,
        eligibleDays: 0,
        validDays: 0,
        totalDays: 0,
        coverageFraction: 0,
        strongCoverage: false
    )
}

/// The result shape is intentionally composite-safe. The public initializer
/// does not accept a Loopr Age number, so Stage A cannot accidentally publish a
/// heuristic composite. A future signed-model release can add a separate
/// composer without widening this Stage-A initializer.
public struct LooprAgeResult: Codable, Equatable, Sendable {
    public let realAgeYears: Int
    public let looprAgeYears: Int?
    public let cardioAge: CardioAgeResult?
    public let modelWindow: DateInterval
    public let contributors: [AgeContributor]
    public let coverage: AgeCoverage
    public let confidence: Double
    public let confidenceTier: ConfidenceTier
    public let modelVersion: Int
    public let referenceVersion: Int
    public let generatedAt: Date
    public let absenceReason: LooprAgeAbsenceReason?

    public init(
        realAgeYears: Int,
        cardioAge: CardioAgeResult?,
        modelWindow: DateInterval,
        contributors: [AgeContributor],
        coverage: AgeCoverage,
        confidence: Double,
        confidenceTier: ConfidenceTier,
        modelVersion: Int,
        referenceVersion: Int,
        generatedAt: Date,
        absenceReason: LooprAgeAbsenceReason? = .compositeNotYetValidated
    ) {
        self.realAgeYears = realAgeYears
        self.looprAgeYears = nil
        self.cardioAge = cardioAge
        self.modelWindow = modelWindow
        self.contributors = contributors
        self.coverage = coverage
        self.confidence = confidence
        self.confidenceTier = confidenceTier
        self.modelVersion = modelVersion
        self.referenceVersion = referenceVersion
        self.generatedAt = generatedAt
        self.absenceReason = absenceReason
    }

}

public struct AgeMetricValue: Codable, Equatable, Sendable {
    public let value: Double
    public let unit: String
    public let source: String
    public let quality: Double
    public let coverage: Double
    public let isCanonical: Bool

    public init(
        value: Double,
        unit: String,
        source: String,
        quality: Double = 1,
        coverage: Double = 1,
        isCanonical: Bool = true
    ) {
        self.value = value
        self.unit = unit
        self.source = source
        self.quality = quality
        self.coverage = coverage
        self.isCanonical = isCanonical
    }
}

public struct AgeSnapshotQuality: Codable, Equatable, Sendable {
    public let wearCoverage: Double
    public let qualityScore: Double
    public let acuteIllness: Bool
    public let lowWear: Bool
    public let unsupportedMedication: Bool

    public init(
        wearCoverage: Double = 1,
        qualityScore: Double = 1,
        acuteIllness: Bool = false,
        lowWear: Bool = false,
        unsupportedMedication: Bool = false
    ) {
        self.wearCoverage = wearCoverage
        self.qualityScore = qualityScore
        self.acuteIllness = acuteIllness
        self.lowWear = lowWear
        self.unsupportedMedication = unsupportedMedication
    }

    public var isEligible: Bool {
        !acuteIllness && !lowWear && !unsupportedMedication && wearCoverage > 0 && qualityScore > 0
    }
}

/// Immutable input to the contributor aggregator. All numeric fields are
/// outputs of canonical metric repositories and carry their source/provenance.
public struct DailyAgeContributorSnapshot: Codable, Equatable, Sendable {
    public let day: Date
    public let quality: AgeSnapshotQuality
    public let cardioCapacity: AgeMetricValue?
    public let restingHeartRate: AgeMetricValue?
    public let bodyComposition: AgeMetricValue?
    public let dailyMovement: AgeMetricValue?
    public let lowModerateAerobicMinutes: AgeMetricValue?
    public let vigorousAerobicMinutes: AgeMetricValue?
    public let strengthMinutes: AgeMetricValue?
    public let sleepDurationHours: AgeMetricValue?
    public let sleepOnsetMinuteOfDay: Int?
    public let sleepOffsetMinuteOfDay: Int?

    public init(
        day: Date,
        quality: AgeSnapshotQuality = AgeSnapshotQuality(),
        cardioCapacity: AgeMetricValue? = nil,
        restingHeartRate: AgeMetricValue? = nil,
        bodyComposition: AgeMetricValue? = nil,
        dailyMovement: AgeMetricValue? = nil,
        lowModerateAerobicMinutes: AgeMetricValue? = nil,
        vigorousAerobicMinutes: AgeMetricValue? = nil,
        strengthMinutes: AgeMetricValue? = nil,
        sleepDurationHours: AgeMetricValue? = nil,
        sleepOnsetMinuteOfDay: Int? = nil,
        sleepOffsetMinuteOfDay: Int? = nil
    ) {
        self.day = day
        self.quality = quality
        self.cardioCapacity = cardioCapacity
        self.restingHeartRate = restingHeartRate
        self.bodyComposition = bodyComposition
        self.dailyMovement = dailyMovement
        self.lowModerateAerobicMinutes = lowModerateAerobicMinutes
        self.vigorousAerobicMinutes = vigorousAerobicMinutes
        self.strengthMinutes = strengthMinutes
        self.sleepDurationHours = sleepDurationHours
        self.sleepOnsetMinuteOfDay = sleepOnsetMinuteOfDay
        self.sleepOffsetMinuteOfDay = sleepOffsetMinuteOfDay
    }
}

public struct AgeAggregationResult: Codable, Equatable, Sendable {
    public let contributors: [AgeContributor]
    public let coverage: AgeCoverage
    public let confidenceTier: ConfidenceTier
    public let absenceReason: LooprAgeAbsenceReason?
    public let modelWindow: DateInterval
    public let validDomainCount: Int

    public init(
        contributors: [AgeContributor],
        coverage: AgeCoverage,
        confidenceTier: ConfidenceTier,
        absenceReason: LooprAgeAbsenceReason?,
        modelWindow: DateInterval,
        validDomainCount: Int
    ) {
        self.contributors = contributors
        self.coverage = coverage
        self.confidenceTier = confidenceTier
        self.absenceReason = absenceReason
        self.modelWindow = modelWindow
        self.validDomainCount = validDomainCount
    }
}
