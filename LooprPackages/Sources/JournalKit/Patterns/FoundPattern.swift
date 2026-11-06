import DomainKit
import Foundation

public enum PatternStrength: String, Codable, CaseIterable, Comparable, Sendable {
    case early, clear, strong

    private var rank: Int { switch self { case .early: 0; case .clear: 1; case .strong: 2 } }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Early patterns appear only in detail, never in lists or on Today.
    public var isHeadlineWorthy: Bool { self != .early }

    public var label: String {
        switch self { case .early: "Early"; case .clear: "Clear"; case .strong: "Strong" }
    }

    /// The only place strength is decided.
    /// - strong: `clearAssociation`, adjusted effect at least `strongEffectMultiple` times the
    ///   practical threshold, and an adjusted p-value below `strongPValue`. Recovery has no
    ///   Holm-adjusted p-value (the engine judges it by its interval), so its bootstrap p-value is used.
    /// - clear: `clearAssociation`.
    /// - early: `earlySignal`.
    /// Everything else, including `cannotSeparate`, `stale` and `noClearAssociation`, returns nil.
    public static func classify(_ metric: HabitMetricEstimate, policy: PatternPolicy = .default) -> PatternStrength? {
        guard let sample = metric.sample, sample.overlappingHabitID == nil else { return nil }
        switch sample.status {
        case .clearAssociation:
            guard let adjusted = metric.adjustedDifference, adjusted.isFinite else { return nil }
            let threshold = policy.practicalThreshold(for: metric.metricID)
            let p = metric.adjustedPValue ?? metric.bootstrapPValue
            if abs(adjusted) >= policy.strongEffectMultiple * threshold, let p, p < policy.strongPValue {
                return .strong
            }
            return .clear
        case .earlySignal:
            guard (metric.adjustedDifference ?? metric.rawDifference)?.isFinite == true else { return nil }
            return .early
        default:
            return nil
        }
    }
}

public struct PatternEffect: Codable, Equatable, Sendable {
    public let adjustedDifference: Double?
    public let rawDifference: Double?
    /// Mean on exposed days and on other days. Display only.
    public let withMean: Double?
    public let withoutMean: Double?
    public let intervalLower: Double?
    public let intervalUpper: Double?
    public let pValue: Double?
    public let practicalThreshold: Double
    public let unit: HabitMetricUnitID
    /// The person's usual night-to-night spread of the measure in the window, the same statistic an experiment's noise
    /// band uses (`ExperimentStatistics.nightToNightSpread`), so a gap can be read against it (ICP R2-VET-09). Nil for a
    /// pattern found before it was kept, or with too few back-to-back nights.
    public let spread: Double?

    /// The number to show: the adjusted effect, or the raw one for an early signal.
    public var difference: Double { adjustedDifference ?? rawDifference ?? 0 }

    public init(adjustedDifference: Double?, rawDifference: Double?, withMean: Double?, withoutMean: Double?,
                intervalLower: Double?, intervalUpper: Double?, pValue: Double?,
                practicalThreshold: Double, unit: HabitMetricUnitID, spread: Double? = nil) {
        self.adjustedDifference = adjustedDifference; self.rawDifference = rawDifference
        self.withMean = withMean; self.withoutMean = withoutMean
        self.intervalLower = intervalLower; self.intervalUpper = intervalUpper; self.pValue = pValue
        self.practicalThreshold = practicalThreshold; self.unit = unit; self.spread = spread
    }

    init(_ metric: HabitMetricEstimate, policy: PatternPolicy, spread: Double? = nil) {
        let threshold = policy.practicalThreshold(for: metric.metricID)
        self.init(adjustedDifference: metric.adjustedDifference, rawDifference: metric.rawDifference,
                  withMean: metric.yesMean, withoutMean: metric.noMean,
                  intervalLower: metric.intervalLower, intervalUpper: metric.intervalUpper,
                  pValue: metric.adjustedPValue ?? metric.bootstrapPValue,
                  practicalThreshold: threshold.isFinite ? threshold : 0, unit: metric.metricID.unit, spread: spread)
    }

    private enum CodingKeys: String, CodingKey {
        case adjustedDifference, rawDifference, withMean, withoutMean, intervalLower, intervalUpper, pValue, practicalThreshold, unit, spread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adjustedDifference = try c.decodeIfPresent(Double.self, forKey: .adjustedDifference)
        rawDifference = try c.decodeIfPresent(Double.self, forKey: .rawDifference)
        withMean = try c.decodeIfPresent(Double.self, forKey: .withMean)
        withoutMean = try c.decodeIfPresent(Double.self, forKey: .withoutMean)
        intervalLower = try c.decodeIfPresent(Double.self, forKey: .intervalLower)
        intervalUpper = try c.decodeIfPresent(Double.self, forKey: .intervalUpper)
        pValue = try c.decodeIfPresent(Double.self, forKey: .pValue)
        practicalThreshold = try c.decodeIfPresent(Double.self, forKey: .practicalThreshold) ?? 0
        unit = try c.decodeIfPresent(HabitMetricUnitID.self, forKey: .unit) ?? .scorePoints
        spread = try c.decodeIfPresent(Double.self, forKey: .spread)
    }
}

public struct PatternNights: Codable, Equatable, Sendable {
    /// Nights after exposed days and after other days that had an outcome.
    public let with: Int
    public let without: Int
    public var total: Int { with + without }

    public init(with: Int, without: Int) { self.with = with; self.without = without }

    private enum CodingKeys: String, CodingKey { case with, without }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        with = try c.decodeIfPresent(Int.self, forKey: .with) ?? 0
        without = try c.decodeIfPresent(Int.self, forKey: .without) ?? 0
    }
}

public struct FoundPattern: Codable, Equatable, Identifiable, Sendable {
    /// `<candidate>.<metric>`, the suffix of the store key `found.<candidate>.<metric>`.
    public var key: String { Self.key(candidateID: candidateID, metric: metric) }
    public var id: String { key }
    public let candidateID: String
    public let habitID: HabitID
    public let title: String
    public let predicate: PatternPredicate
    public let metric: HabitOutcomeMetricID
    public let strength: PatternStrength
    public let effect: PatternEffect
    public let nights: PatternNights
    public let windowEnd: String
    public let algorithmVersion: String
    public let foundAt: Date
    public let schemaVersion: Int

    public static func key(candidateID: String, metric: HabitOutcomeMetricID) -> String {
        "\(candidateID).\(metric.rawValue)"
    }

    public init(candidateID: String, habitID: HabitID, title: String, predicate: PatternPredicate,
                metric: HabitOutcomeMetricID, strength: PatternStrength, effect: PatternEffect, nights: PatternNights,
                windowEnd: String, algorithmVersion: String, foundAt: Date, schemaVersion: Int = 1) {
        self.candidateID = candidateID; self.habitID = habitID; self.title = title; self.predicate = predicate
        self.metric = metric; self.strength = strength; self.effect = effect; self.nights = nights
        self.windowEnd = windowEnd; self.algorithmVersion = algorithmVersion; self.foundAt = foundAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case candidateID, habitID, title, predicate, metric, strength, effect, nights, windowEnd, algorithmVersion, foundAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidateID = try c.decode(String.self, forKey: .candidateID)
        habitID = try c.decode(HabitID.self, forKey: .habitID)
        metric = try c.decode(HabitOutcomeMetricID.self, forKey: .metric)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? candidateID
        predicate = try c.decodeIfPresent(PatternPredicate.self, forKey: .predicate) ?? .journalAnswer(name: title)
        strength = try c.decodeIfPresent(PatternStrength.self, forKey: .strength) ?? .early
        effect = try c.decodeIfPresent(PatternEffect.self, forKey: .effect)
            ?? PatternEffect(adjustedDifference: nil, rawDifference: nil, withMean: nil, withoutMean: nil,
                             intervalLower: nil, intervalUpper: nil, pValue: nil, practicalThreshold: 0, unit: metric.unit)
        nights = try c.decodeIfPresent(PatternNights.self, forKey: .nights) ?? .init(with: 0, without: 0)
        windowEnd = try c.decodeIfPresent(String.self, forKey: .windowEnd) ?? ""
        algorithmVersion = try c.decodeIfPresent(String.self, forKey: .algorithmVersion) ?? ""
        foundAt = try c.decodeIfPresent(Date.self, forKey: .foundAt) ?? .distantPast
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

public struct PatternDiscoveryResult: Equatable, Sendable {
    /// Strongest first. Contains early patterns, which callers show only in detail.
    public let patterns: [FoundPattern]
    /// Candidates the engine could not separate from another candidate. They are
    /// never listed; the count lets a caller tell "nothing found" from "nothing separable".
    public let cannotSeparateCount: Int
    public let windowEnd: String
    public let calculatedAt: Date

    /// Strong and clear patterns, the ones Today and the Found list may show.
    public var headline: [FoundPattern] { patterns.filter { $0.strength.isHeadlineWorthy } }

    public init(patterns: [FoundPattern], cannotSeparateCount: Int, windowEnd: String, calculatedAt: Date) {
        self.patterns = patterns; self.cannotSeparateCount = cannotSeparateCount
        self.windowEnd = windowEnd; self.calculatedAt = calculatedAt
    }
}
