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

private struct VitalsFixedDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// The canonical wiring of overnight vitals and cardio fitness: tonight's
/// values, the fold over earlier nights, and the gates in between.
@MainActor
final class VitalsDerivationTests: XCTestCase {
    private let zone = TimeZone(identifier: "Australia/Perth")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func profile(birthYear: Int? = 1993, sex: BiologicalSex = .male) -> Profile {
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-0000000057A1")!, displayName: "Vitals",
            birthYear: birthYear, biologicalSex: sex, heightCentimeters: 180, weightKilograms: 78,
            timezoneIdentifier: zone.identifier, unitSystem: .metric,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func projection(day: Int, skinCelsius: Double? = nil, resting: Double? = nil, restingCaption: String? = nil,
                            slept: Bool = true, profile: Profile? = nil) -> CanonicalDailyProjection {
        let identity = DayIdentity(year: 2026, month: 9, day: day)
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 0))!.addingTimeInterval(-3_600)
        let session = SleepSessionSummary(id: "n\(day)", start: start, end: start.addingTimeInterval(7 * 3_600),
            durationMinutes: 420, isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial)
        let vitals = HeartVitalsSnapshot(
            skinTemperature: HeartSkinTemperatureVital(nightlyCelsius: skinCelsius, keptSamples: skinCelsius == nil ? 0 : 20_000,
                deviation: skinCelsius == nil ? .noReading : .calibrating(nightsRemaining: 3)),
            oxygen: HeartOxygenVital(assessment: nil, nightlyRatio: nil, deviation: .noReading), beatToBeat: nil)
        let metrics = resting.map {
            [HeartMetricValue(id: .restingHeartRate, title: "Resting heart rate", value: String(format: "%.0f", $0), unit: "bpm",
                state: .partial, confidence: restingCaption, source: "test", numericValue: $0, numericUnit: .beatsPerMinute)]
        } ?? []
        return CanonicalDailyProjection(revision: 1, movementBaselineRevision: 0, profile: profile,
            timeZoneIdentifier: zone.identifier, algorithmVersion: CanonicalDailyAnalytics.version, latestRecord: nil,
            today: TodaySummary(day: identity, overallState: .partial,
                freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: ""),
                device: TodayDeviceSnapshot(model: "", generation: "", connection: .unknown, status: .partial), metrics: []),
            sleep: SleepDaySnapshot(day: identity, state: .partial, mainSleep: slept ? session : nil, metrics: [], source: "test"),
            heart: HeartDaySnapshot(day: identity, state: .partial, metrics: metrics, source: "test", vitals: vitals),
            body: BodyDaySnapshot(day: identity, state: .partial, metrics: [],
                composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
                cardioAge: nil, looprAge: nil, source: "test"),
            strainConfidence: 0)
    }

    func testTonightsVitalsComeFromWornInSleepSeconds() throws {
        let onset = 1_790_000_000.0
        let records = (0..<21_600).map { second in
            StoredHistoricalRecord(physiologicalTimestamp: Int64(onset) + Int64(second), bandCounter: UInt32(second),
                absoluteTimestamp: Int64(onset) + Int64(second), localDay: "2026-09-22", heartRate: 58,
                spo2RedRaw: 560, spo2IRRaw: 618, unidentified68: 850, skinTemperatureCelsius: 35)
        }
        let vitals = CanonicalDailyAnalytics.overnightVitals(records: records,
            sleepWindow: VitalsWindow(start: onset, end: onset + 21_600), cleanSleepBeats: nil)
        XCTAssertEqual(try XCTUnwrap(vitals.skinTemperature.nightlyCelsius), 35, accuracy: 1e-9)
        XCTAssertEqual(vitals.skinTemperature.deviation, .calibrating(nightsRemaining: 3))
        XCTAssertEqual(vitals.oxygen.assessment?.usable, false, "constant optical channels are not a pulse")
        XCTAssertNil(vitals.oxygen.nightlyRatio)
        XCTAssertNil(vitals.beatToBeat)

        let noNight = CanonicalDailyAnalytics.overnightVitals(records: records, sleepWindow: nil, cleanSleepBeats: nil)
        XCTAssertEqual(noNight.skinTemperature.deviation, .noReading)
        XCTAssertNil(noNight.oxygen.assessment)
    }

    func testSkinTemperatureDeviationWaitsForFourEarlierNights() throws {
        let today = projection(day: 23, skinCelsius: 35.3)
        let two = [projection(day: 22, skinCelsius: 35), projection(day: 21, skinCelsius: 35)]
        XCTAssertEqual(CanonicalDailyAnalytics.heartVitalsWithHistory(today, priorDays: two)?.skinTemperature.deviation,
                       .calibrating(nightsRemaining: 1))

        let five = (17...22).reversed().map { projection(day: $0, skinCelsius: 35) }
        let value = try XCTUnwrap(CanonicalDailyAnalytics.heartVitalsWithHistory(today, priorDays: five)?.skinTemperature.deviation.value)
        XCTAssertEqual(value.deltaCelsius, 0.3, accuracy: 1e-9)
        XCTAssertEqual(value.baselineNights, 6)
        XCTAssertEqual(HeartVitalsPresenter.skinTemperature(
            CanonicalDailyAnalytics.heartVitalsWithHistory(today, priorDays: five)?.skinTemperature).value, "+0.3")
    }

    func testCardioFitnessNeverEstimatesVO2MaxFromRestingHeartRate() {
        let owner = profile()
        let today = projection(day: 23, resting: 56, profile: owner)
        // Two nights inside the window, one with a daytime caption, one too old.
        let prior = [
            projection(day: 22, resting: 54),
            projection(day: 21, resting: 70, restingCaption: "From your quietest stretch today, not from sleep"),
            projection(day: 20, resting: 55),
            projection(day: 10, resting: 55)
        ]
        let short = CanonicalDailyAnalytics.cardioFitness(today, priorDays: prior, calendar: calendar)
        XCTAssertNil(short.estimate)
        XCTAssertNil(short.gap)
        XCTAssertEqual(short.nightsRemaining, 0)

        let enough = CanonicalDailyAnalytics.cardioFitness(today, priorDays: prior + [projection(day: 17, resting: 57)],
                                                           calendar: calendar)
        // The body lane removed the ratio estimator. Even enough nights
        // cannot supply cardio fitness without an Apple Health reading.
        XCTAssertNil(enough.estimate)
        XCTAssertNil(enough.gap)
        XCTAssertEqual(enough.nightsRemaining, 0)
        XCTAssertEqual(enough.age, 33)
        XCTAssertEqual(enough.referenceGroup, .male)
    }

    func testCardioFitnessKeepsOptionalProfileContextWithoutInventingAnEstimate() {
        let noAge = CanonicalDailyAnalytics.cardioFitness(projection(day: 23, resting: 56, profile: profile(birthYear: nil)),
            priorDays: (19...22).map { projection(day: $0, resting: 56) }, calendar: calendar)
        XCTAssertNil(noAge.estimate)
        XCTAssertNil(noAge.gap)
        XCTAssertEqual(noAge.nightsRemaining, 0)
        XCTAssertNil(noAge.age)
        XCTAssertEqual(noAge.referenceGroup, .male)
        let undisclosed = CanonicalDailyAnalytics.cardioFitness(projection(day: 23, resting: 56, profile: profile(sex: .undisclosed)),
            priorDays: (19...22).map { projection(day: $0, resting: 56) }, calendar: calendar)
        XCTAssertNil(undisclosed.estimate)
        XCTAssertNil(undisclosed.gap)
        XCTAssertEqual(undisclosed.nightsRemaining, 0)
        XCTAssertEqual(undisclosed.age, 33)
        XCTAssertNil(undisclosed.referenceGroup)
    }

    func testDaytimeRestingHeartRateIsNotANight() {
        XCTAssertNil(CanonicalDailyAnalytics.nocturnalRestingHeartRate(projection(day: 23, resting: 70, slept: false)))
        XCTAssertNil(CanonicalDailyAnalytics.nocturnalRestingHeartRate(
            projection(day: 23, resting: 70, restingCaption: "From your quietest stretch today, not from sleep")))
        XCTAssertEqual(CanonicalDailyAnalytics.nocturnalRestingHeartRate(projection(day: 23, resting: 52)), 52)
    }
}
