import Foundation

/// Apple's four cardio fitness levels.
public enum CardioFitnessLevel: String, Codable, CaseIterable, Sendable {
    case low
    case belowAverage
    case aboveAverage
    case high

    public var title: String {
        switch self {
        case .low: "Low"
        case .belowAverage: "Below average"
        case .aboveAverage: "Above average"
        case .high: "High"
        }
    }
}

/// The four level boundaries for one age decade and reference group, in
/// ml/kg/min. A value below `low` is Low, below `median` Below average, below
/// `upperQuartile` Above average, and anything higher is High.
public struct CardioFitnessThresholds: Codable, Sendable, Equatable {
    public let low: Double
    public let median: Double
    public let upperQuartile: Double

    public init(low: Double, median: Double, upperQuartile: Double) {
        self.low = low
        self.median = median
        self.upperQuartile = upperQuartile
    }

    public func level(for vo2Max: Double) -> CardioFitnessLevel {
        if vo2Max < low { return .low }
        if vo2Max < median { return .belowAverage }
        if vo2Max < upperQuartile { return .aboveAverage }
        return .high
    }
}

/// Published FRIEND treadmill percentiles for one decade and group.
public struct FriendPercentileRow: Codable, Sendable, Equatable {
    public let ageLower: Int
    public let ageUpper: Int
    public let group: FriendReferenceGroup
    public let p10: Double
    public let p25: Double
    public let p50: Double
    public let p75: Double

    public init(ageLower: Int, ageUpper: Int, group: FriendReferenceGroup, p10: Double, p25: Double, p50: Double, p75: Double) {
        self.ageLower = ageLower
        self.ageUpper = ageUpper
        self.group = group
        self.p10 = p10
        self.p25 = p25
        self.p50 = p50
        self.p75 = p75
    }

    /// FRIEND does not publish a 20th percentile. It is interpolated linearly
    /// between the published 10th and 25th.
    public var interpolatedP20: Double { p10 + (p25 - p10) * (20 - 10) / (25 - 10) }
}

/// Loopr's level table.
///
/// Low follows Apple's published rule (Apple, "Using Apple Watch to Estimate
/// Cardio Fitness with VO2 max", May 2021): the lowest FRIEND quintile for the
/// age decade from 20 to 59, and an absolute 18 ml/kg/min for men and 15 for
/// women from 60. Apple does not publish its other three boundaries, so Loopr
/// splits the rest at the published FRIEND median and 75th percentile.
/// Percentiles: Kaminsky, Arena, Myers 2015, Mayo Clin Proc 90(11), table 3
/// (treadmill, PMC4919021).
public struct CardioFitnessLevelTable: Sendable {
    public let rows: [FriendPercentileRow]
    public let olderAdultLowMale: Double
    public let olderAdultLowFemale: Double
    public let olderAdultAge: Int

    public init(rows: [FriendPercentileRow], olderAdultLowMale: Double = 18, olderAdultLowFemale: Double = 15,
                olderAdultAge: Int = 60) {
        self.rows = rows
        self.olderAdultLowMale = olderAdultLowMale
        self.olderAdultLowFemale = olderAdultLowFemale
        self.olderAdultAge = olderAdultAge
    }

    public static let friend2015 = CardioFitnessLevelTable(rows: [
        FriendPercentileRow(ageLower: 20, ageUpper: 29, group: .male, p10: 32.1, p25: 40.1, p50: 48.0, p75: 55.2),
        FriendPercentileRow(ageLower: 30, ageUpper: 39, group: .male, p10: 30.2, p25: 35.9, p50: 42.4, p75: 49.2),
        FriendPercentileRow(ageLower: 40, ageUpper: 49, group: .male, p10: 26.8, p25: 31.9, p50: 37.8, p75: 45.0),
        FriendPercentileRow(ageLower: 50, ageUpper: 59, group: .male, p10: 22.8, p25: 27.1, p50: 32.6, p75: 39.7),
        FriendPercentileRow(ageLower: 60, ageUpper: 69, group: .male, p10: 19.8, p25: 23.7, p50: 28.2, p75: 34.5),
        FriendPercentileRow(ageLower: 70, ageUpper: 79, group: .male, p10: 17.1, p25: 20.4, p50: 24.4, p75: 30.4),
        FriendPercentileRow(ageLower: 20, ageUpper: 29, group: .female, p10: 23.9, p25: 30.5, p50: 37.6, p75: 44.7),
        FriendPercentileRow(ageLower: 30, ageUpper: 39, group: .female, p10: 20.9, p25: 25.3, p50: 30.2, p75: 36.1),
        FriendPercentileRow(ageLower: 40, ageUpper: 49, group: .female, p10: 18.8, p25: 22.1, p50: 26.7, p75: 32.4),
        FriendPercentileRow(ageLower: 50, ageUpper: 59, group: .female, p10: 17.3, p25: 19.9, p50: 23.4, p75: 27.6),
        FriendPercentileRow(ageLower: 60, ageUpper: 69, group: .female, p10: 14.6, p25: 17.2, p50: 20.0, p75: 23.8),
        FriendPercentileRow(ageLower: 70, ageUpper: 79, group: .female, p10: 13.6, p25: 15.6, p50: 18.3, p75: 20.8)
    ])

    /// Nil outside 20 to 79, where FRIEND has no reference.
    public func thresholds(age: Int, group: FriendReferenceGroup) -> CardioFitnessThresholds? {
        guard let row = rows.first(where: { $0.group == group && (($0.ageLower)...($0.ageUpper)).contains(age) }) else {
            return nil
        }
        let low: Double
        if age >= olderAdultAge {
            low = group == .male ? olderAdultLowMale : olderAdultLowFemale
        } else {
            low = row.interpolatedP20
        }
        return CardioFitnessThresholds(low: low, median: row.p50, upperQuartile: row.p75)
    }

    public func level(vo2Max: Double, age: Int, group: FriendReferenceGroup) -> CardioFitnessLevel? {
        guard vo2Max.isFinite, vo2Max > 0 else { return nil }
        return thresholds(age: age, group: group)?.level(for: vo2Max)
    }
}

public enum CardioFitnessSource: String, Codable, Sendable, Equatable {
    /// Apple Health VO2 max samples, selected by `VO2MaxSourceSelector`.
    case appleHealth
    /// Loopr's resting heart-rate ratio estimate.
    case heartRateRatio
}

public enum MaximumHeartRateSource: String, Codable, Sendable, Equatable {
    case agePredicted
}

/// A VO2 max estimate from the heart-rate ratio.
public struct HeartRateRatioEstimate: Codable, Sendable, Equatable {
    public let vo2Max: Double
    public let lower: Double
    public let upper: Double
    public let restingHeartRate: Double
    public let maximumHeartRate: Double
    public let maximumHeartRateSource: MaximumHeartRateSource
    public let restingNights: Int
    public let algorithmVersion: String

    public init(vo2Max: Double, lower: Double, upper: Double, restingHeartRate: Double, maximumHeartRate: Double,
                maximumHeartRateSource: MaximumHeartRateSource, restingNights: Int,
                algorithmVersion: String = VitalsAlgorithmVersion.cardioFitness) {
        self.vo2Max = vo2Max
        self.lower = lower
        self.upper = upper
        self.restingHeartRate = restingHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.maximumHeartRateSource = maximumHeartRateSource
        self.restingNights = restingNights
        self.algorithmVersion = algorithmVersion
    }
}

/// Why no estimate exists yet. Each maps to one honest empty state.
public enum CardioFitnessGap: String, Codable, Sendable, Equatable, Error {
    case needsAge
    case unsupportedAge
    case needsNights
}

/// The value a screen shows: Apple Health when it has a usable VO2 max,
/// otherwise Loopr's estimate.
public struct CardioFitnessResolution: Codable, Sendable, Equatable {
    public let vo2Max: Double
    public let lower: Double?
    public let upper: Double?
    public let source: CardioFitnessSource
    public let level: CardioFitnessLevel?
    /// Only ever built from an Apple Health or lab source (DEC-02 item 10,
    /// `LOOPR_AGE.md`); a resting-ratio estimate never produces one.
    public let cardioAge: CardioAgeResult?

    public init(vo2Max: Double, lower: Double?, upper: Double?, source: CardioFitnessSource,
                level: CardioFitnessLevel?, cardioAge: CardioAgeResult?) {
        self.vo2Max = vo2Max
        self.lower = lower
        self.upper = upper
        self.source = source
        self.level = level
        self.cardioAge = cardioAge
    }
}

public enum CardioFitnessResolver {
    public static func resolve(estimate: HeartRateRatioEstimate?,
                               appleHealth: [HealthKitVO2MaxSample] = [],
                               age: Int?,
                               group: FriendReferenceGroup?,
                               now: Date,
                               timeZone: TimeZone = .autoupdatingCurrent,
                               table: CardioFitnessLevelTable = .friend2015,
                               curve: FriendReferenceCurve = .version1) -> CardioFitnessResolution? {
        func level(_ value: Double) -> CardioFitnessLevel? {
            guard let age, let group else { return nil }
            return table.level(vo2Max: value, age: age, group: group)
        }
        let selection = VO2MaxSourceSelector().select(now: now, measuredCPET: [], healthKit: appleHealth, timeZone: timeZone)
        if case .healthKit(let value, _) = selection {
            let cardioAge = CardioAgeCalculator().calculate(vo2max: value, referenceGroup: group, curve: curve,
                source: .healthKit, calculationAge: age)
            return CardioFitnessResolution(vo2Max: value, lower: nil, upper: nil, source: .appleHealth,
                level: level(value), cardioAge: cardioAge)
        }
        return nil // DEC-02.10/11: archived resting-HR estimates are never shown.
    }
}

/// The single call the `monitors` lane uses for a "low cardio fitness"
/// notification. It decides eligibility only; it schedules nothing.
public enum LowCardioFitnessCheck {
    /// At most one notification every four months.
    public static let minimumMonthsBetween = 4

    /// True when the level is Low, the value came from Apple Health (a
    /// resting-ratio estimate is too rough to act on: Molina-Garcia 2022 limits
    /// of agreement run from −13 to +17 ml/kg/min), and four calendar months
    /// have passed since the last one.
    public static func shouldNotify(resolution: CardioFitnessResolution?,
                                    lastNotifiedAt: Date?,
                                    now: Date,
                                    calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let resolution, resolution.level == .low, resolution.source == .appleHealth else { return false }
        guard let lastNotifiedAt else { return true }
        guard let earliest = calendar.date(byAdding: .month, value: minimumMonthsBetween, to: lastNotifiedAt) else { return false }
        return now >= earliest
    }
}
