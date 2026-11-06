import DomainKit
import Foundation

public enum PatternTestVerdictKind: String, Codable, CaseIterable, Comparable, Sendable {
    case tooEarly, early, clear, noClearDifference

    private var rank: Int {
        switch self { case .tooEarly: 0; case .early: 1; case .clear, .noClearDifference: 2 }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What a test says so far. The kind comes from the engine's judgement of the
/// metric chosen at the start and from the night-count gates. Now and Before are
/// plain means for display and never decide the kind.
public struct PatternTestVerdict: Equatable, Sendable {
    public let kind: PatternTestVerdictKind
    public let headline: String
    public let detail: String
    public let metric: HabitOutcomeMetricID
    /// Kept nights that have an outcome.
    public let keptNights: Int
    /// Baseline nights that have an outcome.
    public let baselineNights: Int
    /// Mean on kept nights ("Now"). Display only.
    public let nowMean: Double?
    /// Mean on baseline nights ("Before"). Display only.
    public let beforeMean: Double?
    /// The engine's adjusted difference, present for early, clear and no-clear verdicts.
    public let difference: Double?
    public let unit: HabitMetricUnitID
    public let algorithmVersion: String
    public let calculatedAt: Date

    /// True once the gates are met and the engine has judged the result.
    public var isConclusive: Bool { kind == .clear || kind == .noClearDifference }

    public static let tooEarlyHeadline = "Too early to tell"
    public static let footnote = "These compare your own nights. They do not show cause."

    /// Pure: the engine estimate in, a verdict out. `estimate` may be nil. `baselineMean` is the plain mean of the
    /// baseline nights, shown as Before while the engine has no estimate yet, so a test started today already shows
    /// the nights it is compared against (ICP R3-OPT-4).
    public static func make(
        test: PatternTest, estimate: HabitImpactEstimate?, now: Date, policy: PatternPolicy = .default,
        baselineMean: Double? = nil
    ) -> PatternTestVerdict {
        let metric = estimate?.metric(test.outcomeMetric)
        let sample = metric?.sample
        let kept = sample?.yesCount ?? 0
        let baseline = sample?.noCount ?? 0
        let version = "\(PatternPolicy.patternsVersion)/\(estimate?.algorithmVersion ?? policy.impact.algorithmVersion)"

        // The engine's own judgement of the pre-chosen metric.
        var kind: PatternTestVerdictKind = .tooEarly
        switch sample?.status {
        case .clearAssociation: kind = metric?.adjustedDifference == nil ? .tooEarly : .clear
        case .noClearAssociation: kind = metric?.adjustedDifference == nil ? .tooEarly : .noClearDifference
        case .earlySignal: kind = .early
        default: kind = .tooEarly
        }
        // Gates apply on top, so a verdict never outruns the nights behind it.
        let ceiling: PatternTestVerdictKind
        if kept < policy.earlyGate || baseline < policy.earlyGate { ceiling = .tooEarly }
        else if kept < policy.matureGate || baseline < policy.matureGate || kept + baseline < policy.matureEligibleDays { ceiling = .early }
        else { ceiling = .clear }
        if ceiling < kind { kind = ceiling }

        let showsDifference = kind != .tooEarly
        let difference = showsDifference ? (metric?.adjustedDifference ?? metric?.rawDifference) : nil
        let copy = PatternCopy.verdict(kind: kind, metric: test.outcomeMetric, difference: difference,
                                       kept: kept, baseline: baseline, policy: policy)
        return PatternTestVerdict(
            kind: kind, headline: copy.headline, detail: copy.detail, metric: test.outcomeMetric,
            keptNights: kept, baselineNights: baseline, nowMean: metric?.yesMean, beforeMean: metric?.noMean ?? baselineMean,
            difference: difference, unit: test.outcomeMetric.unit, algorithmVersion: version, calculatedAt: now)
    }
}

public struct PatternTestEvaluator: Sendable {
    public let policy: PatternPolicy
    private let calendarProvider: any CalendarProviding

    public init(policy: PatternPolicy = .default, calendarProvider: any CalendarProviding = SystemCalendarProvider()) {
        self.policy = policy
        self.calendarProvider = calendarProvider
    }

    public func evaluate(_ test: PatternTest, outcomes provider: any PatternOutcomeProviding, now: Date) async throws -> PatternTestVerdict {
        let records = test.records(at: now)
        let outcomes = try await provider.outcomes(forRecords: records)
        try Task.checkCancellation()
        let store = PatternRecordBuilder.store(definitions: [test.definition], records: records, outcomes: outcomes)
        let today = test.today(at: now) ?? test.startDay
        let last = min(max(today, test.startDay), test.endDay)
        let estimates = try await HabitInsightEngine(policy: policy.impact, calendarProvider: calendarProvider)
            .recalculateAll(store: store, calculatedAt: now, endingOn: DayIdentity(habitKey: last))
        return PatternTestVerdict.make(test: test, estimate: estimates.first { $0.habitID == test.habitID }, now: now, policy: policy,
                                       baselineMean: Self.baselineMean(test, outcomes: outcomes))
    }

    /// The plain mean of the outcome on the baseline nights that have one, leaving out excluded nights.
    static func baselineMean(_ test: PatternTest, outcomes: PatternOutcomeSet) -> Double? {
        let baseline = Set(test.baselineDayKeys)
        let excluded = Set(outcomes.exclusions.map(\.behaviorDay.habitKey))
        let values = outcomes.outcomes.compactMap { outcome -> Double? in
            let key = outcome.behaviorDay.habitKey
            guard baseline.contains(key), !excluded.contains(key), let value = outcome.metrics[test.outcomeMetric],
                  value.isFinite else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Same as `evaluate`, on a detached task so the bootstrap stays off the main actor.
    public func evaluateInBackground(_ test: PatternTest, outcomes provider: any PatternOutcomeProviding, now: Date) async throws -> PatternTestVerdict {
        let evaluator = self
        let task = Task.detached(priority: .userInitiated) {
            try await evaluator.evaluate(test, outcomes: provider, now: now)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
