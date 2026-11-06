import DomainKit
import Foundation

/// Every number the Patterns feature uses, in one place. The statistical
/// gates are read from `HabitImpactPolicy` so Patterns and Journal insights can
/// not drift apart; the values below that are new to Patterns are marked.
public struct PatternPolicy: Equatable, Sendable {
    public static let patternsVersion = "patterns.v1"

    public let impact: HabitImpactPolicy
    /// New in FT-05.4. A test runs 14 days.
    public let testDays: Int
    /// New in FT-05.4. The 30 days before the start day are the baseline.
    public let baselineDays: Int
    /// New in FT-05.4. Strong needs an adjusted effect of at least this many
    /// practical thresholds.
    public let strongEffectMultiple: Double
    /// New in FT-05.4. Strong needs a p-value below this.
    public let strongPValue: Double
    /// New in FT-05.4. Steps candidate: more than this many steps in a day.
    public let stepsThreshold: Int
    /// New in FT-05.4. A test reminder defaults to 20:15, as in the proposal copy.
    public let defaultReminderMinuteOfDay: Int

    /// Kept nights with an outcome on each side before Loopr shows a first look.
    public var earlyGate: Int { impact.earlyPerGroup }
    /// Kept nights with an outcome on each side before a result counts as clear.
    public var matureGate: Int { impact.maturePerGroup }
    /// Eligible days in all before a result counts as clear.
    public var matureEligibleDays: Int { impact.matureEligibleDays }
    /// Recorded on every found pattern and verdict, so stored results from an
    /// older engine or older thresholds can be told apart.
    public var algorithmVersion: String { "\(Self.patternsVersion)/\(impact.algorithmVersion)" }

    public static let `default` = PatternPolicy()

    public init(
        impact: HabitImpactPolicy = .default,
        testDays: Int = 14,
        baselineDays: Int = 30,
        strongEffectMultiple: Double = 2,
        strongPValue: Double = 0.01,
        stepsThreshold: Int = 10_000,
        defaultReminderMinuteOfDay: Int = 20 * 60 + 15
    ) {
        self.impact = impact
        self.testDays = testDays
        self.baselineDays = baselineDays
        self.strongEffectMultiple = strongEffectMultiple
        self.strongPValue = strongPValue
        self.stepsThreshold = stepsThreshold
        self.defaultReminderMinuteOfDay = defaultReminderMinuteOfDay
    }

    public func practicalThreshold(for metric: HabitOutcomeMetricID) -> Double {
        impact.practicalThresholds[metric] ?? .infinity
    }
}
