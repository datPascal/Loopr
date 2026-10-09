import XCTest
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import TodayKit
import HeartKit
import SleepKit
import BodyKit
import DesignSystem
@testable import Loopr

private struct VitalsHistoryDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// The vitals lane's day values reach the metric history through the one
/// band mapping: skin temperature change from the display generation, never
/// band oxygen or an unvalidated VO2 max estimate.
@MainActor
final class BandMetricSeriesVitalsTests: XCTestCase {
    private var roots: [URL] = []
    private let zone = TimeZone(identifier: "Australia/Perth")!
    private let identity = DayIdentity(year: 2026, month: 9, day: 23)

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: Mapping

    func testDisplayGenerationWithholdsBandVO2MaxEstimate() {
        let projection = projection(skin: .available(skinValue(delta: -0.3)), estimate: estimate())
        let values = BandMetricSeriesMapping.values(projection: projection, today: projection.today)
        XCTAssertEqual(values[.skinTemperatureDeviation] ?? nil, -0.3)
        XCTAssertTrue(values.keys.contains(.vo2Max))
        XCTAssertNil(values[.vo2Max] ?? nil)

        let ranges = BandMetricSeriesMapping.ranges(projection: projection, today: projection.today)
        XCTAssertNil(ranges[.vo2Max])
        XCTAssertNil(ranges[.skinTemperatureDeviation], "Skin temperature has no range")
    }

    func testANightTheBandSatDifferentlyClearsSkinTemperatureInsteadOfStoringIt() {
        // The Heart card shows no number for a change this large, so the
        // history must not chart one either.
        let projection = projection(skin: .available(skinValue(delta: -5.8, likelyFitChange: true)), estimate: nil)
        let values = BandMetricSeriesMapping.values(projection: projection, today: projection.today)
        XCTAssertTrue(values.keys.contains(.skinTemperatureDeviation))
        XCTAssertNil(values[.skinTemperatureDeviation] ?? nil)
    }

    func testCalibratingNightsAndMissingEstimateAreAbsentNeverZero() {
        let projection = projection(skin: .calibrating(nightsRemaining: 3), estimate: nil)
        let values = BandMetricSeriesMapping.values(projection: projection, today: projection.today)
        for key in [MetricKey.skinTemperatureDeviation, .vo2Max] {
            XCTAssertTrue(values.keys.contains(key), "\(key) is covered so a stale value is cleared")
            XCTAssertNil(values[key] ?? nil, key.rawValue)
        }
        XCTAssertTrue(BandMetricSeriesMapping.ranges(projection: projection, today: projection.today).isEmpty)
    }

    func testBaseGenerationLeavesTheFoldedVitalsAlone() {
        // The day's own generation carries skin temperature as "calibrating"
        // because the fold over earlier nights has not run. Mapping it would
        // clear the value the display generation stored.
        let projection = projection(skin: .available(skinValue(delta: 0.4)), estimate: estimate())
        let values = BandMetricSeriesMapping.values(projection: projection, today: nil)
        XCTAssertFalse(values.keys.contains(.skinTemperatureDeviation))
        XCTAssertFalse(values.keys.contains(.vo2Max))
        XCTAssertTrue(BandMetricSeriesMapping.ranges(projection: projection, today: nil).isEmpty)
    }

    func testBandOxygenRatioNeverBecomesAPercentage() {
        let projection = projection(skin: .noReading, estimate: nil, oxygenRatio: 0.92)
        let values = BandMetricSeriesMapping.values(projection: projection, today: projection.today)
        XCTAssertTrue(values.keys.contains(.oxygenSaturation))
        XCTAssertNil(values[.oxygenSaturation] ?? nil, "Clear stale band oxygen; only imports supply blood oxygen")
    }

    // MARK: Storage and provider

    func testRecorderClearsOldBandVO2MaxRows() throws {
        let history = try database()
        try history.upsertMetricSeries([
            .init(localDay: "2026-09-23", metricKey: "vo2_max", source: .band, value: 44.1, low: 34.9, high: 53.3)
        ], updatedAt: 1)
        let recorder = MetricSeriesRecorder(history: history, dates: VitalsHistoryDate(value: Date(timeIntervalSince1970: 1_790_000_000)))
        let projection = projection(skin: .available(skinValue(delta: 0.2)), estimate: estimate())
        XCTAssertTrue(recorder.recordBand(day: identity, projection: projection, today: projection.today))

        let vo2 = try history.metricSeries(metricKey: MetricKey.vo2Max.rawValue, from: "2026-09-23", through: "2026-09-23")
        XCTAssertTrue(vo2.isEmpty)
        let skin = try history.metricSeries(metricKey: MetricKey.skinTemperatureDeviation.rawValue,
                                            from: "2026-09-23", through: "2026-09-23")
        XCTAssertEqual(skin.map(\.value), [0.2])
        XCTAssertNil(skin.first?.low)

        // A later derivation of the same day that can no longer produce
        // them clears both rows.
        let later = self.projection(skin: .calibrating(nightsRemaining: 1), estimate: nil)
        recorder.recordBand(day: identity, projection: later, today: later.today)
        XCTAssertTrue(try history.metricSeries(metricKey: MetricKey.vo2Max.rawValue, from: "2026-09-23", through: "2026-09-23").isEmpty)
        XCTAssertTrue(try history.metricSeries(metricKey: MetricKey.skinTemperatureDeviation.rawValue,
                                               from: "2026-09-23", through: "2026-09-23").isEmpty)
    }

    func testAppleHealthVO2MaxHidesOldBandEstimates() async throws {
        XCTAssertEqual(MetricKey.vo2Max.historySourcePreference, [.appleHealth])
        XCTAssertEqual(MetricKey.oxygenSaturation.historySourcePreference, [.whoopExport, .appleHealth])
        for key in MetricKey.allCases where key != .vo2Max && key != .oxygenSaturation {
            XCTAssertEqual(key.historySourcePreference, [.band, .whoopExport, .appleHealth], key.rawValue)
        }

        let root = try makeRoot()
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        try history.upsertMetricSeries([
            .init(localDay: "2026-09-21", metricKey: "vo2_max", source: .band, value: 44, low: 35, high: 53),
            .init(localDay: "2026-09-22", metricKey: "vo2_max", source: .band, value: 45, low: 36, high: 54),
            .init(localDay: "2026-09-22", metricKey: "vo2_max", source: .appleHealth, value: 41.5),
            .init(localDay: "2026-09-22", metricKey: "skin_temperature_deviation", source: .band, value: 0.3)
        ], updatedAt: 1)
        let now = Date(timeIntervalSince1970: 1_790_100_000)
        let engine = try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: VitalsHistoryDate(value: now), timeZoneProvider: SystemTimeZoneProvider(timeZone: zone),
            namespace: "daily-analytics", budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)),
            sharedGenerations: LooprSharedGenerationCache())
        let provider = LooprMetricHistory()
        provider.attach(history: history, analytics: engine, timeZoneProvider: SystemTimeZoneProvider(timeZone: zone),
                        dateProvider: VitalsHistoryDate(value: now), healthClient: nil, scheduleWork: false)

        let endingOn = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!
        let vo2 = try await provider.series(for: .vo2Max, days: 7, endingOn: endingOn)
        XCTAssertEqual(vo2.map(\.value), [41.5])
        XCTAssertEqual(vo2.map(\.source), [.appleHealth])
        XCTAssertNil(vo2.first?.low)
        XCTAssertNil(vo2.first?.high)
        let skin = try await provider.series(for: .skinTemperatureDeviation, days: 7, endingOn: endingOn)
        XCTAssertEqual(skin.map(\.value), [0.3])
        try await LooprMetricHistoryDeletion(history: provider).deleteAll()
    }

    func testMetricPagesNoLongerCallTheseMetricsUncalculated() {
        XCTAssertEqual(MetricKey.skinTemperatureDeviation.presentation.availability, .calculated)
        XCTAssertEqual(MetricKey.vo2Max.presentation.availability, .appleHealthOnly)
        XCTAssertTrue(MetricContentCatalog.content(for: .vo2Max).provenance.contains("does not calculate"))
        // DEC-05.2 permits imported oxygen readings only, with their source.
        XCTAssertEqual(MetricKey.oxygenSaturation.presentation.availability, .importedOnly)
        XCTAssertEqual(MetricKey.oxygenSaturation.historySourcePreference, [.whoopExport, .appleHealth])
    }

    // MARK: Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func skinValue(delta: Double, likelyFitChange: Bool = false) -> SkinTemperatureDeviationValue {
        SkinTemperatureDeviationValue(deltaCelsius: delta, baselineCelsius: 35, z: delta / 0.2,
            baselineNights: 5, trusted: false, outsideUsualRange: abs(delta / 0.2) >= 2, likelyFitChange: likelyFitChange)
    }

    private func estimate() -> HeartRateRatioEstimate {
        HeartRateRatioEstimate(vo2Max: 44.1, lower: 34.9, upper: 53.3, restingHeartRate: 55, maximumHeartRate: 185,
            maximumHeartRateSource: .agePredicted, restingNights: 5)
    }

    private func projection(skin: SkinTemperatureDeviation, estimate: HeartRateRatioEstimate?,
                            oxygenRatio: Double? = nil) -> CanonicalDailyProjection {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 23))!
        let session = SleepSessionSummary(id: "n23", start: start, end: start.addingTimeInterval(7 * 3_600),
            durationMinutes: 420, isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial)
        let vitals = HeartVitalsSnapshot(
            skinTemperature: HeartSkinTemperatureVital(nightlyCelsius: 35, keptSamples: 20_000, deviation: skin),
            oxygen: HeartOxygenVital(assessment: nil, nightlyRatio: oxygenRatio, deviation: .noReading), beatToBeat: nil)
        let fitness = BodyCardioFitness(estimate: estimate, gap: estimate == nil ? .needsNights : nil,
            nightsRemaining: estimate == nil ? 2 : 0, age: 33, referenceGroup: .male)
        return CanonicalDailyProjection(revision: 1, movementBaselineRevision: 0, profile: nil,
            timeZoneIdentifier: zone.identifier, algorithmVersion: CanonicalDailyAnalytics.version, latestRecord: nil,
            today: TodaySummary(day: identity, overallState: .partial,
                freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: ""),
                device: TodayDeviceSnapshot(model: "", generation: "", connection: .unknown, status: .partial), metrics: []),
            sleep: SleepDaySnapshot(day: identity, state: .partial, mainSleep: session, metrics: [], source: "test"),
            heart: HeartDaySnapshot(day: identity, state: .partial, metrics: [], source: "test", vitals: vitals),
            body: BodyDaySnapshot(day: identity, state: .partial, metrics: [],
                composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
                cardioAge: nil, looprAge: nil, source: "test", cardioFitness: fitness),
            strainConfidence: 0)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vitals-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func database() throws -> StorageDatabase {
        try StorageDatabase(url: makeRoot().appendingPathComponent("history.sqlite"))
    }
}
