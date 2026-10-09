import Foundation
import Testing
import DomainKit
import DesignSystem
import AnalyticsKit
@testable import HeartKit

struct HeartVitalsTests {
    private func skin(_ deviation: SkinTemperatureDeviation) -> HeartSkinTemperatureVital {
        HeartSkinTemperatureVital(nightlyCelsius: 35, keptSamples: 20_000, deviation: deviation)
    }

    private func value(delta: Double, outside: Bool = false, fit: Bool = false) -> SkinTemperatureDeviationValue {
        SkinTemperatureDeviationValue(deltaCelsius: delta, baselineCelsius: 35, z: 0,
            baselineNights: 14, trusted: true, outsideUsualRange: outside, likelyFitChange: fit)
    }

    @Test
    func skinTemperatureShowsSignedChangeAgainstUsual() {
        let shown = HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: 0.31))))
        #expect(shown.value == "+0.3")
        #expect(shown.unit == "°C")
        #expect(shown.eyebrow == "vs your usual")
        #expect(shown.state == .partial)
        #expect(HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: -0.04)))).value == "0.0")
        #expect(HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: -0.26)))).value == "−0.3")
    }

    @Test
    func skinTemperatureEmptyStatesAreHonest() {
        let calibrating = HeartVitalsPresenter.skinTemperature(skin(.calibrating(nightsRemaining: 4)))
        #expect(calibrating.value == nil)
        #expect(calibrating.eyebrow == "0 of 4 nights")
        #expect(calibrating.state == .settling)
        #expect(HeartVitalsPresenter.skinTemperature(skin(.calibrating(nightsRemaining: 1))).eyebrow == "3 of 4 nights")
        let none = HeartVitalsPresenter.skinTemperature(nil)
        #expect(none.value == nil)
        #expect(none.state == .absent)
    }

    @Test
    func largeSkinTemperatureChangeIsLowConfidence() {
        let shown = HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: -5.7, outside: true, fit: true))))
        #expect(shown.state == .lowConfidence)
        #expect(shown.value == nil, "an implausible jump must not show a number")
        #expect(shown.detail?.contains("band sat differently") == true)
    }

    @Test
    func oxygenPrefersAppleHealthAndNeverShowsABandPercentage() {
        let unusable = HeartOxygenVital(
            assessment: OxygenSignalAssessment(analysedSeconds: 25_000, redChangeFraction: 0.04,
                infraredChangeFraction: 0.04, variableWindowFraction: 0, usable: false),
            nightlyRatio: nil, deviation: .noReading)
        let band = HeartVitalsPresenter.oxygen(unusable, appleHealth: nil)
        #expect(band.value == nil)
        #expect(band.state == .unsupportedHardware)
        #expect(band.eyebrow == "Not available from this band")

        let health = HeartVitalsPresenter.oxygen(unusable, appleHealth: HeartExternalOxygenReading(percent: 96.6, date: Date()))
        #expect(health.value == "97")
        #expect(health.unit == "%")
        #expect(health.eyebrow == "From Apple Health")

        let usable = HeartOxygenVital(
            assessment: OxygenSignalAssessment(analysedSeconds: 25_000, redChangeFraction: 0.9,
                infraredChangeFraction: 0.9, variableWindowFraction: 0.9, usable: true),
            nightlyRatio: 0.6, deviation: .available(percentChange: 5, baselineNights: 5))
        let relative = HeartVitalsPresenter.oxygen(usable, appleHealth: nil)
        #expect(relative.value == nil)
        #expect(relative.unit == nil)
        #expect(relative.state == .unsupportedHardware)
        #expect(relative.detail == "This band doesn't report blood oxygen. Imported readings appear when available.")
    }

    @Test
    func vitalsSurviveCodableAndOldSnapshotsDecodeWithoutThem() throws {
        let vitals = HeartVitalsSnapshot(skinTemperature: skin(.calibrating(nightsRemaining: 2)),
            oxygen: HeartOxygenVital(assessment: nil, nightlyRatio: nil, deviation: .noReading),
            beatToBeat: BeatToBeatSummary(sd1Milliseconds: 30, sd2Milliseconds: 80, meanIntervalMilliseconds: 1_000,
                beatCount: 20_000, pairCount: 19_000, points: [PoincarePoint(current: 990, next: 1_010)],
                tachogram: [TachogramPoint(minute: 0, meanIntervalMilliseconds: 1_000)]))
        let day = DayIdentity(era: 1, year: 2026, month: 9, day: 23)
        let snapshot = HeartDaySnapshot(day: day, state: .partial, metrics: [], source: "test", vitals: vitals)
        let decoded = try JSONDecoder().decode(HeartDaySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)

        let old = HeartDaySnapshot(day: day, state: .partial, metrics: [], source: "test")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "vitals")
        let legacy = try JSONDecoder().decode(HeartDaySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.vitals == nil)
    }

    @Test
    func vitalsCopyAvoidsMedicalWording() {
        let banned = ["diagnos", "detect", "afib", "atrial", "arrhythm", "irregular", "tachycard", "bradycard",
                      "apnea", "hypertens", "blood pressure", "abnormal", "dangerous", "medical", "clinical", "—"]
        let presentations = [
            HeartVitalsPresenter.skinTemperature(nil),
            HeartVitalsPresenter.skinTemperature(skin(.calibrating(nightsRemaining: 3))),
            HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: 0.2)))),
            HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: 0.9, outside: true)))),
            HeartVitalsPresenter.skinTemperature(skin(.available(value(delta: 3, outside: true, fit: true)))),
            HeartVitalsPresenter.oxygen(nil, appleHealth: nil),
            HeartVitalsPresenter.oxygen(HeartOxygenVital(assessment: OxygenSignalAssessment(analysedSeconds: 1,
                redChangeFraction: 0, infraredChangeFraction: 0, variableWindowFraction: 0, usable: false),
                nightlyRatio: nil, deviation: .noReading), appleHealth: nil)
        ]
        for presentation in presentations {
            let text = presentation.accessibilitySummary.lowercased()
            for word in banned { #expect(!text.contains(word), "\(word) in \(text)") }
            #expect(!text.contains("!"))
        }
    }
}
