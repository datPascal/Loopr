#if DEBUG
import AnalyticsKit
import BodyKit
import DomainKit
import Foundation
import DesignSystem
import WorkoutKit

nonisolated extension DebugCaptureFixtures {
    static var siBodyHistoryProvider: (any BodyHistoryProviding)? {
        siBodyMode.map { SIBodyHistoryFixture(mode: $0) }
    }
    static func siBodyHistory(mode: String, anchor: DayIdentity) async -> BodyHistory {
        await SIBodyHistoryFixture(mode: mode).bodyHistory(anchor: anchor)
    }
    static var siBodyWorkoutProvider: (any WorkoutHeartRateRecoveryProviding)? {
        siBodyMode.map { SIBodyWorkoutFixture(mode: $0) }
    }
    static func siBodyMetricPoints(key: MetricKey, days: Int, endingOn: Date, calendar: Calendar, mode: String? = nil) -> [MetricHistoryPoint]? {
        guard let mode = mode ?? siBodyMode, key == .strain || key == .recovery else { return nil }
        let anchor = DayIdentity(bodyDate: endingOn, calendar: calendar)
        if mode == "empty" { return [] }
        let count = min(days, mode == "learning" ? 11 : 91)
        return BodyHistory.window(endingOn: anchor, length: count).enumerated().compactMap { index, day in
            guard let date = day.bodyDate(calendar: calendar) else { return nil }
            let strain = day == anchor ? (LooprFixtureMetrics.today(LooprMetricLinkID.strain) ?? 8.6) : mode == "flagged" && index >= count - 8 ? 18 + LooprFixtureMetrics.variation(seed: "si-heavy", offset: count - index) * 3 : 9 + LooprFixtureMetrics.variation(seed: "si-load", offset: count - index) * 4
            return MetricHistoryPoint(day: date, value: key == .strain ? strain : (day == anchor ? SIPolishFixtureWorld.recovery! : 65 + LooprFixtureMetrics.variation(seed: "si-recovery", offset: count - index) * 24), source: .band)
        }
    }

}
nonisolated private struct SIBodyHistoryFixture: BodyHistoryProviding {
    let mode: String
    func bodyHistory(anchor: DayIdentity) async -> BodyHistory {
        if mode == "empty" { return .empty(anchor: anchor) }
        let count = mode == "learning" ? 10 : 90
        let days = BodyHistory.window(endingOn: anchor.bodyAdding(days: -1), length: count).enumerated().map { index, day in
            BodyHistoryDay(day: day, strain: mode == "flagged" && index >= count - 7 ? 18 + LooprFixtureMetrics.variation(seed: "si-heavy", offset: count - index) * 3 : 9 + LooprFixtureMetrics.variation(seed: "si-load", offset: count - index) * 4,
                           recovery: 65 + LooprFixtureMetrics.variation(seed: "si-recovery", offset: count - index) * 24, steps: 7_200, activeEnergy: 800)
        }
        return BodyHistory(anchor: anchor, days: days + [BodyHistoryDay(day: anchor, recovery: SIPolishFixtureWorld.recovery)])
    }
}
nonisolated private struct SIBodyWorkoutFixture: WorkoutHeartRateRecoveryProviding {
    let mode: String
    func recovery(for workout: WorkoutRecord) async -> WorkoutRecoveryPresentation {
        let end = 600.0
        let points = (-300...123).filter { mode != "empty" || $0 <= 0 }.map { offset in
            WorkoutHRPoint(timestamp: end + Double(offset), bpm: offset <= 0 ? 165 : 165 - min(Double(offset), 120) * 31 / 60)
        }
        let result = WorkoutAnalytics.timedHeartRateRecovery(samples: points, start: 0, end: end, maximumHR: 190)
        return WorkoutRecoveryPresentation(assessment: result, usualDrop: mode == "learning" ? nil : 27,
                                           eligibleWorkouts: mode == "learning" ? 2 : 8)
    }
}
#endif
