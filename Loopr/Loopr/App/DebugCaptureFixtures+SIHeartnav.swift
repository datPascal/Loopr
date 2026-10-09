#if DEBUG
import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import HeartKit
import SwiftUI

nonisolated extension DebugCaptureFixtures {
    static var siHeartnavState: String? {
        let prefix = "--loopr-si-heartnav-fixture="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? siPolishState
    }

    static func siHeartnavNights(endingOn: Date, calendar: Calendar = .current) -> [OvernightVitalsNight] {
        if siPolishState != nil {
            let c = calendar.dateComponents([.year, .month, .day], from: endingOn)
            let day = DayIdentity(year: c.year!, month: c.month!, day: c.day!)
            return siMorningNights(day: day, calendar: calendar)
        }
        let count = siHeartnavState == "learning" ? 2 : 20
        return (0..<count).map { index in
            let date = calendar.date(byAdding: .day, value: index - count + 1, to: calendar.startOfDay(for: endingOn))!
            let flagged = siHeartnavState == "flagged" && index == count - 1
            let normalTemperature = siHeartnavState == "normal" && index == count - 1
            let variation = LooprFixtureMetrics.variation(seed: "si-heartnav", offset: count - index - 1)
            let values: [OvernightVitalMetric: Double] = siHeartnavState == "empty" ? [:] : [
                .restingHeartRate: flagged ? 64 : 54 + (variation * 2).rounded(),
                .heartRateVariability: flagged ? 31 : 56 + (variation * 5).rounded(),
                .respiratoryRate: 14.2 + variation * 0.25,
                .skinTemperatureDeviation: normalTemperature ? 35.2 : 35 + variation * 0.2
            ]
            return .init(night: HeartAlertsDay.key(date, calendar: calendar), values: values)
        }
    }

    static func siHeartnavTemperature(endingOn: Date) -> HeartSkinTemperatureVital {
        let nights = siHeartnavNights(endingOn: endingOn)
        let current = nights.last?.values[.skinTemperatureDeviation]
        return .init(nightlyCelsius: current, keptSamples: current == nil ? 0 : 20_000,
            deviation: SkinTemperatureAnalytics.deviation(tonightCelsius: current,
                priorNightsOldestFirst: nights.dropLast().map { $0.values[.skinTemperatureDeviation] }))
    }

    static func siHeartnavSnapshot(_ base: HeartDaySnapshot) -> HeartDaySnapshot {
        guard siHeartnavState != nil, let end = Calendar.current.date(from: DateComponents(
            year: base.day.year, month: base.day.month, day: base.day.day)) else { return base }
        let nights = siHeartnavNights(endingOn: end)
        let assessment = OvernightVitalsCheck.assessment(nights: nights, calendar: .current)
        let metrics = base.metrics.map { metric -> HeartMetricValue in
            let signal: OvernightVitalMetric? = switch metric.id {
            case .restingHeartRate: .restingHeartRate
            case .rmssd: .heartRateVariability
            case .respiration: .respiratoryRate
            default: nil
            }
            let value = signal.flatMap { nights.last?.values[$0] } ?? (signal == nil && siHeartnavState != "empty" ? metric.numericValue : nil)
            return .init(id: metric.id, title: metric.title,
                value: value.map { String(format: "%.*f", metric.id == .respiration ? 1 : 0, $0) }, unit: metric.unit,
                state: value == nil ? .absent : .partial, source: "synthetic-heartnav",
                numericValue: value, numericUnit: metric.numericUnit)
        }
        let beats = siHeartnavState == "empty" ? nil : SIPolishFixtureWorld.beats
        return .init(day: base.day, state: .partial, metrics: metrics, liveState: base.liveState, source: base.source,
            vitals: .init(skinTemperature: siHeartnavTemperature(endingOn: end),
                oxygen: .init(assessment: nil, nightlyRatio: nil, deviation: .noReading), beatToBeat: beats, assessment: assessment))
    }
}

nonisolated struct SIHeartnavMetricHistoryProvider: MetricHistoryProviding {
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        guard DebugCaptureFixtures.siHeartnavState != "empty" else { return [] }
        if let points = DebugCaptureFixtures.siBodyMetricPoints(key: key, days: days, endingOn: endingOn, calendar: .current) { return points }
        let metric: OvernightVitalMetric? = switch key {
        case .restingHeartRate: .restingHeartRate
        case .rmssd: .heartRateVariability
        case .respiratoryRate: .respiratoryRate
        case .skinTemperatureDeviation: .skinTemperatureDeviation
        default: nil
        }
        guard let metric else { return FixtureMetricHistoryProvider.points(for: key, days: days, endingOn: endingOn) }
        let nights = DebugCaptureFixtures.siHeartnavNights(endingOn: endingOn)
        return nights.indices.suffix(days).compactMap { index in
            let value: Double?
            if metric == .skinTemperatureDeviation {
                value = SkinTemperatureAnalytics.deviation(tonightCelsius: nights[index].values[metric],
                    priorNightsOldestFirst: nights.prefix(index).map { $0.values[metric] }).value?.deltaCelsius
            } else { value = nights[index].values[metric] }
            guard let value, let date = MetricHistoryDays.date(nights[index].night, calendar: .current) else { return nil }
            return .init(day: date, value: value, source: .band)
        }
    }

    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital? {
        DebugCaptureFixtures.siHeartnavTemperature(endingOn: endingOn)
    }
}
struct SIHeartnavAccessibilityCapture: ViewModifier {
    func body(content: Content) -> some View {
        if DebugCaptureFixtures.siHeartnavState != nil,
           ProcessInfo.processInfo.arguments.contains("--loopr-si-heartnav-large-text") {
            content.environment(\.dynamicTypeSize, .accessibility5)
                .task {
                    var design = DesignSystemRuntime.state()
                    design.reduceMotion = true
                    DesignSystemRuntime.apply(design)
                }
        } else { content }
    }
}
#endif
