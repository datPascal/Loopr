#if DEBUG
import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import TodayKit

nonisolated extension DebugCaptureFixtures {
    static var siMorningMode: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--loopr-si-morning-fixture=") }
            .map { String($0.dropFirst("--loopr-si-morning-fixture=".count)) } ?? siPolishState
    }

    static func siMorningNights(day: DayIdentity, calendar: Calendar, mode: String? = nil) -> [OvernightVitalsNight] {
        guard let mode = mode ?? siMorningMode,
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return [] }
        if mode == "empty" { return [] }
        let prior = mode == "first-night" ? 0 : mode == "early" ? 6 : 28
        let stale = mode == "stale" ? 16 : 0
        return (0...prior).reversed().map { offset in
            let when = calendar.date(byAdding: .day, value: -offset - stale, to: date)!
            let c = calendar.dateComponents([.year, .month, .day], from: when)
            let label = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            // Irregular invented variation. No owner history is used.
            let wave = LooprFixtureMetrics.variation(seed: "si-morning", offset: offset) * 2
            let current = offset == 0 && stale == 0
            let low = mode == "low" || mode == "flagged"
            return .init(night: label, values: [
                .heartRateVariability: current ? (low ? 38 : LooprFixtureMetrics.today(LooprMetricLinkID.rmssd)!)
                    : LooprFixtureMetrics.recoverySignalBaseline(LooprMetricLinkID.rmssd, offset: offset)!,
                .restingHeartRate: current ? (low ? 61 : LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate)!)
                    : LooprFixtureMetrics.recoverySignalBaseline(LooprMetricLinkID.restingHeartRate, offset: offset)!,
                .respiratoryRate: current ? (low ? 15.7 : LooprFixtureMetrics.today(LooprMetricLinkID.respiratoryRate)!)
                    : LooprFixtureMetrics.recoverySignalBaseline(LooprMetricLinkID.respiratoryRate, offset: offset)!,
                .skinTemperatureDeviation: current ? (mode == "flagged" ? 35.6 : 35.0) : 34.8 + 0.12 * wave
            ])
        }
    }

    static func siMorningContext(day: DayIdentity, summary: TodaySummary?, mode: String? = nil) -> TodayDayContext? {
        guard let mode = mode ?? siMorningMode else { return nil }
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        let nights = siMorningNights(day: day, calendar: calendar, mode: mode)
        let map: [(TodayTrackedMetric, OvernightVitalMetric)] = [(.hrv, .heartRateVariability), (.restingHeartRate, .restingHeartRate), (.respiratoryRate, .respiratoryRate)]
        var history: [TodayTrackedMetric: [LooprChartPoint]] = [:]
        for (metric, vital) in map {
            history[metric] = nights.compactMap { night in
                guard let value = night.values[vital], let when = OvernightDate.parse(night.night, calendar: calendar) else { return nil }
                return .init(date: when, value: value)
            }
        }
        history[.sleep] = nights.compactMap { night in
            guard let when = OvernightDate.parse(night.night, calendar: calendar) else { return nil }
            return .init(date: when, value: calendar.isDate(when, inSameDayAs: date) && (mode == "low" || mode == "flagged") ? 310 : (LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration) ?? 462) + 36 * LooprFixtureMetrics.variation(seed: "si-sleep", offset: calendar.dateComponents([.day], from: when, to: date).day ?? 0))
        }
        let daily: [(TodayTrackedMetric, TodayMetricID, Double, Double)] = [
            (.strain, .strain, 9.0, 1.4), (.stress, .stress, 26.0, 4.0),
            (.steps, .steps, 8_200.0, 850.0), (.activeEnergy, .calories, 610.0, 65.0)
        ]
        for (metric, summaryID, usual, spread) in daily {
            history[metric] = nights.compactMap { night in
                guard let when = OvernightDate.parse(night.night, calendar: calendar) else { return nil }
                if calendar.isDate(when, inSameDayAs: date) {
                    guard let value = summary?.metric(summaryID)?.numericValue else { return nil }
                    return .init(date: when, value: value)
                }
                let offset = calendar.dateComponents([.day], from: when, to: date).day ?? 0
                let wave = LooprFixtureMetrics.variation(seed: "si-" + metric.rawValue, offset: offset) * 2
                return .init(date: when, value: usual + spread * wave)
            }
        }
        let split = LooprTodayContextSource.recoveryBreakdown(summary: summary, history: history, dayStart: date, calendar: calendar)
        let score = mode == "stale" ? nil : split?.score
        let load: TrainingLoad? = mode == "load-heavy" ? .init(fitness: 10, fatigue: 14, days: 42) : nil
        let target = StrainTarget(recovery: score, trainingLoad: load)
        return .init(day: day, dayStart: date, history: history, recovery: split, suggestedStrainRange: target?.range,
            strainTarget: target, tonight: .init(needMinutes: LooprFixtureMetrics.sleepNeedMinutes, alarmMinute: 420, suggestedWakeMinute: nil),
            overnightAssessment: mode == "stale" ? nil : OvernightVitalsCheck.assessment(nights: nights, calendar: calendar))
    }

    static func siMorningSummary(mode: String? = nil) -> TodaySummary? {
        guard let mode = mode ?? siMorningMode else { return nil }
        let base = TodayFixtures.populated
        let nights = siMorningNights(day: base.day, calendar: .current, mode: mode)
        let latest = mode == "stale" ? nil : nights.last
        let readings = RecoverySignal.allCases.map { signal -> RecoverySignalReading in
            let vital: OvernightVitalMetric = switch signal { case .hrv: .heartRateVariability; case .restingHeartRate: .restingHeartRate; case .respiratoryRate: .respiratoryRate }
            return .init(signal: signal, value: latest?.values[vital], baseline: nights.dropLast().compactMap { $0.values[vital] })
        }
        let split = WellnessAnalytics.recoveryDecomposition(readings)
        let metrics = base.metrics.map { metric -> TodayMetricValue in
            let value: Double? = switch metric.id {
            case .readiness, .recovery: mode == "stale" ? nil
                : mode == "good" ? LooprFixtureMetrics.today(LooprMetricLinkID.recovery) : split.score
            case .hrv: latest?.values[.heartRateVariability]
            case .heart, .restingHeartRate: latest?.values[.restingHeartRate]
            case .sleep: mode == "stale" || mode == "empty" ? nil : mode == "low" || mode == "flagged" ? 310 : LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration)
            case .stress: mode == "missing-stress" || mode == "first-night" || mode == "stale" || mode == "empty" ? nil : 24
            default: mode == "stale" || mode == "empty" ? nil : metric.numericValue
            }
            return .init(id: metric.id, title: metric.title, value: value.map { String(Int($0.rounded())) }, unit: metric.unit,
                confidence: metric.id == .stress && value == nil ? "No clean heart data today" : nil,
                state: value == nil ? .absent : .partial, source: "Synthetic capture", numericValue: value, numericUnit: metric.numericUnit)
        }
        return .init(day: base.day, overallState: .partial, freshness: base.freshness, device: base.device, metrics: metrics,
            goals: base.goals + [TodayGoalProgress(id: "sleep", title: "Sleep", value: nil,
                target: String(Int(LooprFixtureMetrics.sleepNeedMinutes)), unit: "minutes", state: .partial)],
            coachPlan: .placeholder, sleepNeedMinutes: LooprFixtureMetrics.sleepNeedMinutes)
    }
}

nonisolated private enum OvernightDate {
    static func parse(_ text: String, calendar: Calendar) -> Date? {
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

nonisolated struct SIMorningContextRepository: TodayContextRepository {
    var mode: String? = nil
    func context(for day: DayIdentity, summary: TodaySummary?) async throws -> TodayDayContext? {
        DebugCaptureFixtures.siMorningContext(day: day, summary: summary, mode: mode)
    }
}
#endif
