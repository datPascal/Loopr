import DomainKit
import Foundation
import RoutineKit

/// What `ExperimentAnalyzer.report` needs besides the stored nights: the outcome on the nights before day 1, and the
/// same for the other measures it checks for "also moved".
nonisolated struct ProtocolExperimentInputs: Sendable, Equatable {
    var baseline: [DayIdentity: Double] = [:]
    var otherBaselines: [String: [DayIdentity: Double]] = [:]
    var alsoMetrics: [ExperimentMetric] = []

    static let none = ProtocolExperimentInputs()

    /// The measures Loopr checks for "also moved", when it has their history.
    static let candidateMetrics: [ExperimentMetric] = [.deepSleep, .sleepHeartRate, .hrv]

    /// Reads the baselines from the app's metric history, the same series the Ask tools read
    /// (`LooprLongevityAgentReader.historyKey(forOutcome:)`). A metric with no series has no baseline, so its report says
    /// it cannot show a result, and it is never listed as also moved.
    static func live(history: any MetricHistoryProviding, timeZone: @escaping @Sendable () -> TimeZone)
        -> @Sendable (Experiment) async -> ProtocolExperimentInputs {
        { experiment in
            let zone = timeZone()
            let outcome = experiment.start.outcome
            var inputs = ProtocolExperimentInputs()
            inputs.baseline = await baseline(of: outcome.key, before: experiment.start.startDay, history: history, zone: zone)
            for metric in candidateMetrics where metric.key != outcome.key {
                guard LooprLongevityAgentReader.historyKey(forOutcome: metric.key) != nil else { continue }
                let values = await baseline(of: metric.key, before: experiment.start.startDay, history: history, zone: zone)
                guard !values.isEmpty else { continue }
                inputs.alsoMetrics.append(metric)
                inputs.otherBaselines[metric.key] = values
            }
            return inputs
        }
    }

    /// The metric on each of the `baselineWindowNights` nights before day 1, keyed by the night's day. A night is
    /// recorded on the day the person wakes, so the reading for night `d` sits on `d + 1`.
    static func baseline(of key: String, before startDay: DayIdentity, history: any MetricHistoryProviding,
                         zone: TimeZone) async -> [DayIdentity: Double] {
        guard let metric = LooprLongevityAgentReader.historyKey(forOutcome: key),
              let startKey = startDay.routineDayKey, let end = AgentDays.noon(of: startKey, in: zone),
              let points = try? await history.series(for: metric, days: ExperimentPolicy.standard.baselineWindowNights,
                                                     endingOn: end) else { return [:] }
        var baseline: [DayIdentity: Double] = [:]
        for point in points where point.value.isFinite {
            guard let woke = DayIdentity(routineDayKey: AgentDays.string(point.day, in: zone)),
                  let night = woke.adding(days: -1), (night.days(until: startDay) ?? 0) > 0 else { continue }
            baseline[night] = point.value
        }
        return baseline
    }
}
