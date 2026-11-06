import DomainKit
import Foundation
import RoutineKit

/// Turns exposure series into day records the habit engine understands.
enum PatternRecordBuilder {
    /// One record per day, with one response per candidate that has an answer
    /// for that day. A day with answers in two zones keeps the first zone.
    static func records(series: [PatternExposureSeries], candidates: [PatternCandidate]) -> [HabitDayRecord] {
        let habitByCandidate = Dictionary(candidates.map { ($0.id, $0.habitID) }, uniquingKeysWith: { first, _ in first })
        var byDay: [String: HabitDayRecord] = [:]
        for entry in series {
            guard let habitID = habitByCandidate[entry.candidateID] else { continue }
            for day in entry.days {
                guard let identity = DayIdentity(habitKey: day.dayKey),
                      let answeredAt = day.answeredAt ?? PatternDays.endOfDay(day.dayKey, timeZoneID: day.timeZoneID)
                else { continue }
                var record = byDay[day.dayKey] ?? HabitDayRecord(
                    behaviorDay: identity, behaviorTimeZoneID: day.timeZoneID, createdAt: answeredAt)
                guard record.response(for: habitID) == nil else { continue }
                record.responses.append(HabitResponse(
                    habitID: habitID, behaviorDay: identity, behaviorTimeZoneID: record.behaviorTimeZoneID,
                    answer: day.exposed ? .yes : .no, firstAnsweredAt: answeredAt,
                    firstAnswerSource: day.answeredAt == nil ? .autoFill : .sameDay))
                byDay[day.dayKey] = record
            }
        }
        return byDay.values.sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    /// The engine builds dictionaries keyed by day and habit, so duplicates would trap.
    static func store(definitions: [HabitDefinition], records: [HabitDayRecord], outcomes: PatternOutcomeSet) -> InMemoryHabitStore {
        var latestOutcome: [DayIdentity: HabitOutcomeSnapshot] = [:]
        for outcome in outcomes.outcomes { latestOutcome[outcome.behaviorDay] = outcome }
        var latestExclusion: [DayIdentity: HabitOutcomeExclusionRecord] = [:]
        for exclusion in outcomes.exclusions where latestOutcome[exclusion.behaviorDay] == nil {
            latestExclusion[exclusion.behaviorDay] = exclusion
        }
        return InMemoryHabitStore(
            definitions: definitions, dayRecords: records,
            outcomes: Array(latestOutcome.values), outcomeExclusions: Array(latestExclusion.values))
    }
}

/// Looks for patterns across every candidate with the same engine the Journal
/// uses. It makes no claim about cause; it reports what differed between
/// a person's own nights.
public struct PatternDiscoveryEngine: Sendable {
    public let policy: PatternPolicy
    private let calendarProvider: any CalendarProviding

    public init(policy: PatternPolicy = .default, calendarProvider: any CalendarProviding = SystemCalendarProvider()) {
        self.policy = policy
        self.calendarProvider = calendarProvider
    }

    /// Runs on the caller's executor after the provider calls return, so call it
    /// from `discoverInBackground` or any non-main context.
    public func discover(provider: any PatternExposureProvider, endingOn day: String, calculatedAt: Date) async throws -> PatternDiscoveryResult {
        let candidates = Self.unique(try await provider.candidates())
        try Task.checkCancellation()
        let series = try await provider.exposures(endingOn: day, windowDays: policy.impact.windowDays)
        try Task.checkCancellation()
        let records = PatternRecordBuilder.records(series: series, candidates: candidates)
        let outcomes = try await provider.outcomes(forRecords: records)
        return try await discover(candidates: candidates, records: records, outcomes: outcomes,
                                  endingOn: day, calculatedAt: calculatedAt)
    }

    /// The same run on a detached task, as FoodAssociationRoot does, so the
    /// bootstrap never occupies the main actor. Cancelling the caller cancels the run.
    public func discoverInBackground(provider: any PatternExposureProvider, endingOn day: String, calculatedAt: Date) async throws -> PatternDiscoveryResult {
        let engine = self
        let task = Task.detached(priority: .userInitiated) {
            try await engine.discover(provider: provider, endingOn: day, calculatedAt: calculatedAt)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func discover(
        candidates rawCandidates: [PatternCandidate],
        records: [HabitDayRecord],
        outcomes: PatternOutcomeSet,
        endingOn day: String,
        calculatedAt: Date
    ) async throws -> PatternDiscoveryResult {
        let candidates = Self.unique(rawCandidates)
        guard let endDay = DayIdentity(habitKey: day) else {
            return .init(patterns: [], cannotSeparateCount: 0, windowEnd: day, calculatedAt: calculatedAt)
        }
        let definitions = candidates.enumerated().map { $0.element.definition(sortOrder: $0.offset, at: calculatedAt) }
        let store = PatternRecordBuilder.store(definitions: definitions, records: records, outcomes: outcomes)
        let estimates = try await HabitInsightEngine(policy: policy.impact, calendarProvider: calendarProvider)
            .recalculateAll(store: store, calculatedAt: calculatedAt, endingOn: endDay)
        return result(candidates: candidates, estimates: estimates, windowEnd: day, calculatedAt: calculatedAt,
                      spreads: spreads(outcomes, endingOn: endDay))
    }

    /// Each measure's usual night-to-night spread over the window, from the same outcomes the engine read: the scaled
    /// MAD of back-to-back differences an experiment's noise band uses, so Patterns and Experiments say "usual spread"
    /// about one number (ICP R2-VET-09). A measure with too few nights or pairs has none.
    public func spreads(_ outcomes: PatternOutcomeSet, endingOn endDay: DayIdentity) -> [HabitOutcomeMetricID: Double] {
        guard let start = endDay.adding(days: 1) else { return [:] }
        let window = ExperimentPolicy(baselineWindowNights: policy.impact.windowDays)
        var series: [HabitOutcomeMetricID: [DayIdentity: Double]] = [:]
        for outcome in outcomes.outcomes {
            for (metric, value) in outcome.metrics where value.isFinite { series[metric, default: [:]][outcome.behaviorDay] = value }
        }
        return series.compactMapValues { NoiseBand.make(baseline: $0, startDay: start, policy: window).spread }
    }

    /// Classification only. Public so a caller with stored estimates can reuse it. `spreads` gives each measure's usual
    /// spread, when the caller has the nights.
    public func result(candidates: [PatternCandidate], estimates: [HabitImpactEstimate],
                       windowEnd: String, calculatedAt: Date,
                       spreads: [HabitOutcomeMetricID: Double] = [:]) -> PatternDiscoveryResult {
        let byHabit = Dictionary(estimates.map { ($0.habitID, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [FoundPattern] = []
        var separable = 0
        for candidate in candidates {
            guard let estimate = byHabit[candidate.habitID] else { continue }
            if estimate.metrics.contains(where: { $0.sample?.status == .cannotSeparate }) || estimate.status == .cannotSeparate {
                separable += 1
            }
            for metricID in candidate.targetMetrics {
                guard let metric = estimate.metric(metricID), let sample = metric.sample,
                      let strength = PatternStrength.classify(metric, policy: policy) else { continue }
                found.append(FoundPattern(
                    candidateID: candidate.id, habitID: candidate.habitID, title: candidate.title,
                    predicate: candidate.predicate, metric: metricID, strength: strength,
                    effect: PatternEffect(metric, policy: policy, spread: spreads[metricID]),
                    nights: PatternNights(with: sample.yesCount, without: sample.noCount),
                    windowEnd: estimate.windowEnd.habitKey,
                    algorithmVersion: "\(PatternPolicy.patternsVersion)/\(estimate.algorithmVersion)",
                    foundAt: calculatedAt))
            }
        }
        return PatternDiscoveryResult(patterns: Self.ordered(found), cannotSeparateCount: separable,
                                      windowEnd: windowEnd, calculatedAt: calculatedAt)
    }

    /// Strong before clear before early; then larger effect relative to its
    /// practical threshold; then key, so the order never flickers.
    static func ordered(_ patterns: [FoundPattern]) -> [FoundPattern] {
        patterns.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            let l = lhs.effect.practicalThreshold > 0 ? abs(lhs.effect.difference) / lhs.effect.practicalThreshold : abs(lhs.effect.difference)
            let r = rhs.effect.practicalThreshold > 0 ? abs(rhs.effect.difference) / rhs.effect.practicalThreshold : abs(rhs.effect.difference)
            if l != r { return l > r }
            return lhs.key < rhs.key
        }
    }

    static func unique(_ candidates: [PatternCandidate]) -> [PatternCandidate] {
        var habits = Set<HabitID>(), ids = Set<String>()
        return candidates.filter { habits.insert($0.habitID).inserted && ids.insert($0.id).inserted }
    }
}
