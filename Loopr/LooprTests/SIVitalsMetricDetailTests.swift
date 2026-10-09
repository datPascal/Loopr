import AnalyticsKit
import DesignSystem
import Foundation
import HeartKit
import Testing
@testable import Loopr

nonisolated private struct SIVitalsDetailProvider: MetricHistoryProviding {
    let vital: HeartSkinTemperatureVital
    func skinTemperature(endingOn: Date) async throws -> HeartSkinTemperatureVital? { vital }
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        guard let value = vital.deviation.value, !value.likelyFitChange else { return [] }
        return [.init(day: Calendar.current.startOfDay(for: endingOn), value: value.deltaCelsius, source: .band)]
    }
}

struct SIVitalsMetricDetailTests {
    @Test @MainActor
    func calibratingDetailKeepsApproximateValueWithoutInventingDeviation() async {
        let vital = HeartSkinTemperatureVital(nightlyCelsius: 35, keptSamples: 20_000, deviation: .calibrating(nightsRemaining: 2))
        let model = MetricDetailModel(key: .skinTemperatureDeviation)
        await model.load(from: SIVitalsDetailProvider(vital: vital), anchor: MetricDetailAnchor(day: Date(), today: Date()))
        #expect(model.state == .loaded)
        #expect(model.points.isEmpty)
        #expect(model.skinTemperature == vital)
        #expect(HeartVitalsPresenter.skinTemperature(vital).eyebrow == "2 of 4 nights")
    }

    @Test @MainActor
    func trustedDetailLoadsSameDeviationAndRangeAsAnalytics() async throws {
        let deviation = SkinTemperatureAnalytics.deviation(tonightCelsius: 35.6, priorNightsOldestFirst: Array(repeating: 35, count: 15))
        let vital = HeartSkinTemperatureVital(nightlyCelsius: 35.6, keptSamples: 20_000, deviation: deviation)
        let model = MetricDetailModel(key: .skinTemperatureDeviation)
        await model.load(from: SIVitalsDetailProvider(vital: vital), anchor: MetricDetailAnchor(day: Date(), today: Date()))
        let value = try #require(model.skinTemperature?.deviation.value)
        #expect(value.outsideUsualRange)
        #expect(value.usualRange == 34.7...35.3)
        #expect(abs((model.latest?.value ?? .nan) - 0.6) < 1e-9)
        #expect(MetricKey.skinTemperatureDeviation.presentation.availability == .calculated)
        #expect(MetricDetailRules.scale(for: .skinTemperatureDeviation).includeZero)
    }
}
