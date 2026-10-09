import Foundation

public enum FriendReferenceGroup: String, Codable, CaseIterable, Sendable {
    case female
    case male
}

public struct FriendReferencePoint: Codable, Equatable, Sendable {
    public let calculationAge: Double
    public let femaleMedian: Double
    public let maleMedian: Double

    public init(calculationAge: Double, femaleMedian: Double, maleMedian: Double) {
        self.calculationAge = calculationAge
        self.femaleMedian = femaleMedian
        self.maleMedian = maleMedian
    }

    public func median(for group: FriendReferenceGroup) -> Double {
        switch group {
        case .female: femaleMedian
        case .male: maleMedian
        }
    }
}

/// Versioned FRIEND reference data.  The curve is data, not a constant in the
/// interpolation algorithm.  The JSON companion in Fixtures/Analytics is the
/// reviewable fixture used by parity tests and release evidence.
public struct FriendReferenceCurve: Codable, Equatable, Sendable {
    public let referenceVersion: Int
    public let unit: String
    public let points: [FriendReferencePoint]

    public init(referenceVersion: Int, unit: String = "mL/kg/min", points: [FriendReferencePoint]) {
        self.referenceVersion = referenceVersion
        self.unit = unit
        self.points = points
    }

    public var supportedAgeRange: ClosedRange<Double>? {
        guard let first = points.first, let last = points.last, first.calculationAge <= last.calculationAge else {
            return nil
        }
        return first.calculationAge...last.calculationAge
    }

    /// The only bundled reference curve in Stage A.  It is intentionally
    /// immutable and versioned; derivation code receives a curve value rather
    /// than embedding these values in its math.
    public static let version1 = FriendReferenceCurve(
        referenceVersion: 1,
        points: [
            FriendReferencePoint(calculationAge: 25, femaleMedian: 37.6, maleMedian: 48.0),
            FriendReferencePoint(calculationAge: 35, femaleMedian: 30.2, maleMedian: 42.4),
            FriendReferencePoint(calculationAge: 45, femaleMedian: 26.7, maleMedian: 37.8),
            FriendReferencePoint(calculationAge: 55, femaleMedian: 23.4, maleMedian: 32.6),
            FriendReferencePoint(calculationAge: 65, femaleMedian: 20.0, maleMedian: 28.2),
            FriendReferencePoint(calculationAge: 75, femaleMedian: 18.3, maleMedian: 24.4)
        ]
    )

    public func values(for group: FriendReferenceGroup) -> [(age: Double, median: Double)] {
        points.map { ($0.calculationAge, $0.median(for: group)) }
    }
}

public enum VO2MaxSourceKind: String, Codable, CaseIterable, Sendable {
    case measuredCPET
    case healthKit
    case looprExerciseEstimate
}

public struct MeasuredCPETSample: Codable, Equatable, Sendable {
    public let vo2max: Double
    public let measuredAt: Date
    public let explicitlyMeasured: Bool
    public let supervised: Bool
    public let isValid: Bool

    public init(
        vo2max: Double,
        measuredAt: Date,
        explicitlyMeasured: Bool = true,
        supervised: Bool = true,
        isValid: Bool = true
    ) {
        self.vo2max = vo2max
        self.measuredAt = measuredAt
        self.explicitlyMeasured = explicitlyMeasured
        self.supervised = supervised
        self.isValid = isValid
    }
}

public enum HealthKitVO2MaxTestType: String, Codable, Sendable {
    case maxExercise
    case predictionSubMaxExercise
    case predictionNonExercise
    case predictionStepTest
}

public struct HealthKitVO2MaxSample: Codable, Equatable, Sendable {
    public let vo2max: Double
    public let sampledAt: Date
    public let sourceIdentifier: String
    public let authorized: Bool
    public let compatibleSource: Bool
    public let isValid: Bool
    /// The HealthKit VO2 max test method, separate from the app that wrote it.
    public let testType: HealthKitVO2MaxTestType?

    public init(
        vo2max: Double,
        sampledAt: Date,
        sourceIdentifier: String,
        authorized: Bool = true,
        compatibleSource: Bool = true,
        isValid: Bool = true,
        testType: HealthKitVO2MaxTestType? = nil
    ) {
        self.vo2max = vo2max
        self.sampledAt = sampledAt
        self.sourceIdentifier = sourceIdentifier
        self.authorized = authorized
        self.compatibleSource = compatibleSource
        self.isValid = isValid
        self.testType = testType
    }
}

public struct LooprExerciseVO2MaxEstimate: Codable, Equatable, Sendable {
    public let vo2max: Double
    public let estimatedAt: Date
    public let protocolIdentifier: String

    public init(vo2max: Double, estimatedAt: Date, protocolIdentifier: String) {
        self.vo2max = vo2max
        self.estimatedAt = estimatedAt
        self.protocolIdentifier = protocolIdentifier
    }
}

public enum VO2MaxSelection: Codable, Equatable, Sendable {
    case measuredCPET(value: Double, measuredAt: Date)
    case healthKit(value: Double, sampleDates: [Date])
    case unavailable(reason: LooprAgeAbsenceReason)

    public var source: VO2MaxSourceKind? {
        switch self {
        case .measuredCPET: .measuredCPET
        case .healthKit: .healthKit
        case .unavailable: nil
        }
    }

    public var value: Double? {
        switch self {
        case .measuredCPET(let value, _), .healthKit(let value, _): value
        case .unavailable: nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value, measuredAt, sampleDates, reason }
    private enum Kind: String, Codable { case measuredCPET, healthKit, unavailable }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .measuredCPET(let value, let measuredAt):
            try container.encode(Kind.measuredCPET, forKey: .kind)
            try container.encode(value, forKey: .value)
            try container.encode(measuredAt, forKey: .measuredAt)
        case .healthKit(let value, let sampleDates):
            try container.encode(Kind.healthKit, forKey: .kind)
            try container.encode(value, forKey: .value)
            try container.encode(sampleDates, forKey: .sampleDates)
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .measuredCPET:
            self = .measuredCPET(
                value: try container.decode(Double.self, forKey: .value),
                measuredAt: try container.decode(Date.self, forKey: .measuredAt)
            )
        case .healthKit:
            self = .healthKit(
                value: try container.decode(Double.self, forKey: .value),
                sampleDates: try container.decode([Date].self, forKey: .sampleDates)
            )
        case .unavailable:
            self = .unavailable(reason: try container.decode(LooprAgeAbsenceReason.self, forKey: .reason))
        }
    }
}

public struct VO2MaxSourceSelector: Sendable {
    public let cpetValidity: TimeInterval
    public let healthKitWindow: TimeInterval
    public let minimumHealthKitSamples: Int
    public let minimumHealthKitSpan: TimeInterval

    public init(
        cpetValidity: TimeInterval = 180 * 24 * 60 * 60,
        healthKitWindow: TimeInterval = 42 * 24 * 60 * 60,
        minimumHealthKitSamples: Int = 3,
        minimumHealthKitSpan: TimeInterval = 14 * 24 * 60 * 60
    ) {
        self.cpetValidity = cpetValidity
        self.healthKitWindow = healthKitWindow
        self.minimumHealthKitSamples = minimumHealthKitSamples
        self.minimumHealthKitSpan = minimumHealthKitSpan
    }

    public func select(
        now: Date,
        measuredCPET: [MeasuredCPETSample],
        healthKit: [HealthKitVO2MaxSample],
        looprEstimate: LooprExerciseVO2MaxEstimate? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> VO2MaxSelection {
        let cpet = measuredCPET
            .filter {
                $0.explicitlyMeasured && $0.supervised && $0.isValid &&
                $0.vo2max.isFinite && $0.vo2max > 0 &&
                $0.measuredAt <= now && now.timeIntervalSince($0.measuredAt) <= cpetValidity
            }
            .max { $0.measuredAt < $1.measuredAt }
        if let cpet {
            return .measuredCPET(value: cpet.vo2max, measuredAt: cpet.measuredAt)
        }

        let candidates = healthKit
            .filter {
                $0.authorized && $0.compatibleSource && $0.isValid &&
                ($0.testType == .maxExercise || $0.testType == .predictionSubMaxExercise) &&
                $0.vo2max.isFinite && $0.vo2max > 0 &&
                $0.sampledAt <= now && now.timeIntervalSince($0.sampledAt) <= healthKitWindow
            }
            .sorted { $0.sampledAt < $1.sampledAt }
        let distinctDays = Set(candidates.map { Self.localDayKey(for: $0.sampledAt, timeZone: timeZone) })
        guard candidates.count >= minimumHealthKitSamples,
              distinctDays.count >= minimumHealthKitSamples,
              let first = candidates.first?.sampledAt,
              let last = candidates.last?.sampledAt,
              last.timeIntervalSince(first) >= minimumHealthKitSpan else {
            // The exercise estimator is intentionally not selected.  It remains
            // a typed input for the validation gate but cannot produce a value.
            _ = looprEstimate
            return .unavailable(reason: .noVO2MaxSource)
        }

        let median = Self.median(candidates.map(\.vo2max))
        return .healthKit(value: median, sampleDates: candidates.map(\.sampledAt))
    }

    private static func localDayKey(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(components.era ?? 1)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
