#if DEBUG
import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import HeartKit
import TodayKit

nonisolated extension DebugCaptureFixtures {
    static var siVitalsMode: String? {
        let prefix = "--loopr-si-vitals-fixture="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static func siVitalsNights(endingOn: Date, calendar: Calendar = .current) -> [OvernightVitalsNight] {
        let count = siVitalsMode == "calibrating" ? 2 : 20
        return (0..<count).map { index in
            let day = calendar.date(byAdding: .day, value: index - count + 1, to: calendar.startOfDay(for: endingOn))!
            let flagged = siVitalsMode == "outside" && index >= count - 2
            let variation = LooprFixtureMetrics.variation(seed: "si-vitals", offset: count - index - 1)
            return .init(night: HeartAlertsDay.key(day, calendar: calendar), values: [
                .restingHeartRate: flagged ? 63 : 54 + (variation * 2).rounded(),
                .heartRateVariability: flagged ? 30 : 56 + variation * (siVitalsMode == "outside" ? 24 : 5),
                .respiratoryRate: 14.1 + variation * 0.25,
                .skinTemperatureDeviation: flagged ? 35.6 : 35 + variation * 0.2
            ])
        }
    }

    static func siVitalsVital(endingOn: Date, calendar: Calendar = .current) -> HeartSkinTemperatureVital? {
        guard siVitalsMode != nil else { return nil }
        guard siVitalsMode != "empty" else {
            return .init(nightlyCelsius: nil, keptSamples: 0, deviation: .noReading,
                missingReason: "No settled temperature for this night. A snug fit overnight helps; sync in the morning.")
        }
        let nights = siVitalsNights(endingOn: endingOn, calendar: calendar)
        let current = nights.last?.values[.skinTemperatureDeviation]
        let deviation = SkinTemperatureAnalytics.deviation(tonightCelsius: current,
            priorNightsOldestFirst: nights.dropLast().map { $0.values[.skinTemperatureDeviation] })
        return .init(nightlyCelsius: current, keptSamples: 21_000, deviation: deviation,
            settledFraction: 0.95, sleepCoverage: 0.9)
    }

    static func siVitalsAssessment(day: DayIdentity) -> OvernightVitalsAssessment? {
        guard siVitalsMode != nil else { return nil }
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)) else { return nil }
        return OvernightVitalsCheck.assessment(nights: siVitalsNights(endingOn: date), calendar: calendar)
    }

    static func siVitalsAlertRecord(now: Date = Date()) -> HeartAlertRecord? {
        guard siVitalsMode == "outside", let assessment = OvernightVitalsCheck.assessment(nights: siVitalsNights(endingOn: now), calendar: .current) else { return nil }
        return .init(id: "si-vitals-episode", kind: .overnightCheck, date: now, overnightNight: assessment.night,
            overnightMetrics: assessment.outliers.map { .init(metric: $0.metric, value: $0.value, low: $0.range.low, high: $0.range.high, direction: $0.direction) }, delivery: .sent)
    }

    static func siVitalsSeries(days: Int, endingOn: Date, calendar: Calendar) -> [MetricHistoryPoint] {
        guard siVitalsMode != "empty" else { return [] }
        let nights = siVitalsNights(endingOn: endingOn, calendar: calendar)
        return nights.indices.suffix(days).compactMap { index in
            let current = nights[index].values[.skinTemperatureDeviation]
            let deviation = SkinTemperatureAnalytics.deviation(tonightCelsius: current,
                priorNightsOldestFirst: nights.prefix(index).map { $0.values[.skinTemperatureDeviation] })
            guard let value = deviation.value, !value.likelyFitChange,
                  let day = MetricHistoryDays.date(nights[index].night, calendar: calendar) else { return nil }
            return .init(day: day, value: value.deltaCelsius, source: .band)
        }
    }

    private static func siVitalsRecovery(_ nights: [OvernightVitalsNight]) -> Double? {
        let inputs: [(RecoverySignal, OvernightVitalMetric)] = [
            (.restingHeartRate, .restingHeartRate), (.hrv, .heartRateVariability),
            (.respiratoryRate, .respiratoryRate)
        ]
        return WellnessAnalytics.recoveryDecomposition(inputs.map { signal, metric in
            .init(signal: signal, value: nights.last?.values[metric],
                baseline: nights.dropLast().compactMap { $0.values[metric] })
        }).score
    }

    static func siVitalsRecoverySeries(for key: MetricKey, days: Int, endingOn: Date,
                                        calendar: Calendar) -> [MetricHistoryPoint]? {
        guard siVitalsMode == "outside" else { return nil }
        let metric: OvernightVitalMetric?
        switch key {
        case .restingHeartRate: metric = .restingHeartRate
        case .rmssd: metric = .heartRateVariability
        case .respiratoryRate: metric = .respiratoryRate
        case .recovery: metric = nil
        default: return nil
        }
        let nights = siVitalsNights(endingOn: endingOn, calendar: calendar)
        return nights.indices.suffix(days).compactMap { index in
            let value = if let metric { nights[index].values[metric] }
                else { siVitalsRecovery(Array(nights.prefix(index + 1))) }
            guard let value, let day = MetricHistoryDays.date(nights[index].night, calendar: calendar) else { return nil }
            return .init(day: day, value: value, source: .band)
        }
    }

    static func siVitalsTodaySummary(composition: AppEnvironment.Composition) -> TodaySummary? {
        guard siVitalsMode == "outside",
              composition == .populated || composition == .activeWorkout || composition == .connectedMixedCapabilities else { return nil }
        let base = TodayFixtures.populated
        let nights = siVitalsNights(endingOn: Date())
        let metrics = base.metrics.map { metric -> TodayMetricValue in
            let value: Double?
            switch metric.id {
            case .heart, .restingHeartRate: value = nights.last?.values[.restingHeartRate]
            case .hrv: value = nights.last?.values[.heartRateVariability]
            case .readiness, .recovery: value = siVitalsRecovery(nights)
            default: return metric
            }
            return .init(id: metric.id, title: metric.title, value: value.map { String(Int($0.rounded())) },
                unit: metric.unit, state: value == nil ? .absent : .partial, source: metric.source,
                algorithmVersion: metric.algorithmVersion, numericValue: value, numericUnit: metric.numericUnit)
        }
        return .init(day: base.day, overallState: base.overallState, freshness: base.freshness,
            device: base.device, metrics: metrics, goals: base.goals, coachPlan: base.coachPlan,
            sleepNeedMinutes: base.sleepNeedMinutes)
    }
}
#endif
