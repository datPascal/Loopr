import AnalyticsKit
import DomainKit
import Foundation
import Testing
@testable import HeartKit

struct HeartOvernightPresentationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func presentation(count: Int = 20, flagged: Bool = false, missing: Set<OvernightVitalMetric> = [],
                              lastValues: [OvernightVitalMetric: Double] = [:], temperatureMissingReason: String? = nil) -> HeartOvernightPresentation {
        let nights = (0..<count).map { index -> OvernightVitalsNight in
            let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: index + 1))!
            let key = String(format: "2026-01-%02d", calendar.component(.day, from: date))
            let changed = flagged && index == count - 1
            var values: [OvernightVitalMetric: Double] = [
                .restingHeartRate: changed ? 66 : 54, .heartRateVariability: changed ? 30 : 56,
                .respiratoryRate: 14.2, .skinTemperatureDeviation: 35
            ]
            if index == count - 1 {
                values.merge(lastValues) { _, current in current }
                for metric in missing { values.removeValue(forKey: metric) }
            }
            return .init(night: key, values: values)
        }
        let assessment = OvernightVitalsCheck.assessment(nights: nights, calendar: calendar)
        return .init(snapshot: .init(day: .init(year: 2026, month: 1, day: count), state: .partial, metrics: [], source: "synthetic",
            vitals: .init(skinTemperature: .init(nightlyCelsius: nights.last?.values[.skinTemperatureDeviation], keptSamples: 100,
                deviation: .noReading, missingReason: temperatureMissingReason),
                oxygen: .init(assessment: nil, nightlyRatio: nil, deviation: .noReading), beatToBeat: nil, assessment: assessment)))
    }

    @Test func allFourMustBeWithinBeforeSayingAll() {
        #expect(presentation().summary == "All within your usual range")
        let partial = presentation(missing: [.skinTemperatureDeviation])
        #expect(partial.summary != "All within your usual range")
        #expect(partial.reading(.skinTemperatureDeviation) == nil)
        #expect(partial.detail(.skinTemperatureDeviation) == "No reading")
        #expect(partial.missingHint(.skinTemperatureDeviation) == nil)
        #expect(partial.explanation == nil)
    }

    @Test func flaggedAssessmentNamesCountAndOrdinaryCauses() {
        let shown = presentation(flagged: true)
        #expect(shown.assessment?.isFlagged == true)
        #expect(shown.summary == "Two signals outside your usual range")
        #expect(shown.detail(.restingHeartRate) == "Above your usual range")
        #expect(shown.detail(.heartRateVariability) == "Below your usual range")
        #expect(shown.explanation?.contains("Alcohol, late meals, a hot room, hard training or travel") == true)
    }

    @Test func learningCountsTrackReadingsWhileComparisonsWaitForTheUsualRange() {
        let shown = presentation(count: 2)
        #expect(shown.reading(.restingHeartRate) == 54)
        #expect(shown.detail(.restingHeartRate) == "2 of 14 nights")
        #expect(shown.reading(.skinTemperatureDeviation) == nil)
        #expect(shown.detail(.skinTemperatureDeviation) == "2 of 14 nights")
        #expect(presentation(count: 4).reading(.skinTemperatureDeviation) == 0)
        #expect(presentation(count: 4).detail(.skinTemperatureDeviation) == "4 of 14 nights")
        #expect(shown.explanation == "Each signal needs 14 nights with a reading for its usual range.")
        for metric in OvernightVitalMetric.monitored {
            #expect(shown.comparison(metric) == nil)
            let partial = presentation(count: 13, lastValues: [.restingHeartRate: 55, .skinTemperatureDeviation: 35.2])
            #expect(partial.comparison(metric) == nil)
        }
        let learned = presentation(lastValues: [.restingHeartRate: 55])
        #expect(learned.comparison(.restingHeartRate) == "+1 bpm vs usual")
        #expect(learned.comparison(.heartRateVariability) == "Same as usual")
    }

    @Test func oneOutsideSignalExplainsTheChangeWithoutCallingItLearning() {
        let shown = presentation(flagged: true, missing: [.heartRateVariability])
        #expect(shown.assessment?.isFlagged == false)
        #expect(shown.summary == "One signal outside your usual range")
        #expect(shown.explanation?.hasPrefix("Alcohol, late meals") == true)
    }

    @Test func noReadingsAndOldGenerationsStayMissing() {
        let shown = presentation(missing: Set(OvernightVitalMetric.monitored))
        #expect(shown.summary == "No overnight readings")
        #expect(shown.explanation == "Wear your band overnight and sync in the morning.")
        for metric in OvernightVitalMetric.monitored {
            #expect(shown.reading(metric) == nil)
            #expect(shown.formattedValue(metric) == nil)
            #expect(shown.comparison(metric) == nil)
            #expect(shown.detail(metric) == "No reading")
            #expect(shown.missingHint(metric) == nil)
        }
        let legacy = HeartOvernightPresentation(snapshot: .init(day: .init(year: 2026, month: 1, day: 1), state: .partial, metrics: [], source: "legacy"))
        #expect(legacy.reading(.restingHeartRate) == nil)
        #expect(legacy.detail(.restingHeartRate) == "No reading")
        #expect(legacy.explanation == "Wear your band overnight and sync in the morning.")
    }

    @Test func comparisonsUseTheDisplayedPrecisionForZero() {
        let rounded = presentation(lastValues: [.restingHeartRate: 54.49, .heartRateVariability: 55.51, .respiratoryRate: 14.24])
        for metric in [.restingHeartRate, .heartRateVariability, .respiratoryRate] as [OvernightVitalMetric] {
            #expect(rounded.comparison(metric) == "Same as usual")
            #expect(rounded.detail(metric) == "Within your usual range")
        }
        let changed = presentation(lastValues: [.restingHeartRate: 54.51, .heartRateVariability: 55.49, .respiratoryRate: 14.26])
        #expect(changed.comparison(.restingHeartRate) == "+1 bpm vs usual")
        #expect(changed.comparison(.heartRateVariability) == "−1 ms vs usual")
        #expect(changed.comparison(.respiratoryRate) == "+0.1 br/min vs usual")
    }

    @Test func temperatureValueAlwaysHasASignAndItsReferenceIsSeparate() {
        #expect(presentation(lastValues: [.skinTemperatureDeviation: 35.2]).formattedValue(.skinTemperatureDeviation) == "+0.2")
        #expect(presentation(lastValues: [.skinTemperatureDeviation: 34.7]).formattedValue(.skinTemperatureDeviation) == "−0.3")
        for value in [35.0, 35.04, 34.96] {
            let shown = presentation(lastValues: [.skinTemperatureDeviation: value])
            #expect(shown.formattedValue(.skinTemperatureDeviation) == "0.0")
            #expect(shown.comparison(.skinTemperatureDeviation) == nil)
            #expect(shown.detail(.skinTemperatureDeviation) == "Within your usual range")
        }
    }

    @Test func missingTemperatureKeepsOnlyAnActualModelOrFitReason() {
        let reason = "This band does not report skin temperature."
        let shown = presentation(missing: [.skinTemperatureDeviation], temperatureMissingReason: reason)
        #expect(shown.detail(.skinTemperatureDeviation) == "No reading")
        #expect(shown.missingHint(.skinTemperatureDeviation) == reason)
        #expect(shown.missingHint(.restingHeartRate) == nil)
    }

    @Test func rowOrderAndMissingTemperatureCountsMatchToday() {
        #expect(HeartOvernightPresentation.rowOrder == [.heartRateVariability, .restingHeartRate, .respiratoryRate, .skinTemperatureDeviation])
        let missing = presentation(count: 2, missing: [.skinTemperatureDeviation])
        #expect(missing.detail(.skinTemperatureDeviation) == "1 of 14 nights")
        #expect(missing.formattedValue(.skinTemperatureDeviation) == nil)
    }

    @Test func advancedOmitsTheFourHeadlineMetrics() {
        #expect(!HeartAdvancedSection.metricIDs.contains(.restingHeartRate))
        #expect(!HeartAdvancedSection.metricIDs.contains(.rmssd))
        #expect(!HeartAdvancedSection.metricIDs.contains(.respiration))
        for metric in HeartAdvancedSection.metricIDs { #expect(!HeartAdvancedSection.explanation(metric).isEmpty) }
    }
}
