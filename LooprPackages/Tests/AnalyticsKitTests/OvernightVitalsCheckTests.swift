import Foundation
import Testing
@testable import AnalyticsKit

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
}

struct OvernightVitalsCheckTests {
    let calendar = utcCalendar()
    private let ordinary: [OvernightVitalMetric: Double] = [.restingHeartRate: 52, .heartRateVariability: 60, .respiratoryRate: 14.5, .skinTemperatureDeviation: 35]
    private let flagged: [OvernightVitalMetric: Double] = [.restingHeartRate: 63, .heartRateVariability: 38, .respiratoryRate: 14.5, .skinTemperatureDeviation: 35.6]
    private func inputs(_ latest: [[OvernightVitalMetric: Double]], baselineCount: Int = 20) -> [OvernightVitalsNight] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        return (Array(repeating: ordinary, count: baselineCount) + latest).enumerated().map { index, values in
            let date = calendar.date(byAdding: .day, value: index, to: start)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return .init(night: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), values: values)
        }
    }

    @Test func eachSignalNeedsItsOwnFourteenScorableNights() throws {
        let below = try #require(OvernightVitalsCheck.assessment(nights: inputs([flagged], baselineCount: 12), calendar: calendar))
        #expect(!below.isFlagged)
        #expect(below.signals.allSatisfy { $0.state == .learning && $0.learningProgress == "13 of 14 nights" })
        let ready = try #require(OvernightVitalsCheck.assessment(nights: inputs([flagged], baselineCount: 13), calendar: calendar))
        #expect(ready.isFlagged)
        #expect(ready.triggeringSignals == [.restingHeartRate, .heartRateVariability, .skinTemperatureDeviation])
        var noTempHistory = inputs([flagged])
        noTempHistory = noTempHistory.enumerated().map { index, night in
            .init(night: night.night, values: index == noTempHistory.count - 1 ? night.values : night.values.filter { $0.key != .skinTemperatureDeviation })
        }
        let partial = try #require(OvernightVitalsCheck.assessment(nights: noTempHistory, calendar: calendar))
        #expect(partial.triggeringSignals == [.restingHeartRate, .heartRateVariability])
        #expect(partial.signals.last?.learningProgress == "1 of 14 nights")
    }

    @Test func firstFlaggedNightShowsAssessmentButNotificationWaitsForSecond() throws {
        let firstInput = inputs([flagged])
        #expect(OvernightVitalsCheck.assessment(nights: firstInput, calendar: calendar)?.isFlagged == true)
        let first = try #require(OvernightVitalsCheck.evaluate(nights: firstInput, state: .initial, calendar: calendar))
        #expect(!first.shouldNotify)
        let second = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: first.nextState, calendar: calendar))
        #expect(second.shouldNotify)
        #expect(second.nextState.episodeNotified == true)
        #expect(second.outliers.map(\.direction) == [.higher, .lower, .higher])
    }

    @Test func episodeIsPersistedAcrossRelaunchAndChangingSignalsDoNotRenotify() throws {
        let second = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: .initial, calendar: calendar))
        #expect(second.shouldNotify)
        let saved = try JSONEncoder().encode(second.nextState)
        let restored = try JSONDecoder().decode(OvernightVitalsCheckState.self, from: saved)
        var different = flagged; different[.respiratoryRate] = 18
        let next = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, different]), state: restored, calendar: calendar))
        #expect(!next.shouldNotify)
        let duplicate = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: restored, calendar: calendar))
        #expect(!duplicate.shouldNotify)
    }

    @Test func legacyNotifiedStateDoesNotRepeatAnOngoingEpisode() throws {
        let json = Data(#"{"lastEvaluatedNight":"2026-09-22","lastNotifiedNight":"2026-09-22","lastNotifiedMetrics":["resting_heart_rate","rmssd"]}"#.utf8)
        let legacy = try JSONDecoder().decode(OvernightVitalsCheckState.self, from: json)
        #expect(legacy.episodeNotified == nil)
        let ongoing = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, flagged]), state: legacy, calendar: calendar))
        #expect(!ongoing.shouldNotify)
        #expect(ongoing.nextState.episodeNotified == true)
        let newEpisode = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, ordinary, flagged, flagged]), state: legacy, calendar: calendar))
        #expect(newEpisode.shouldNotify)
    }

    @Test func missingCachedNightsEndThePersistedEpisode() throws {
        let old = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: .initial, calendar: calendar))
        let latest = inputs([flagged, flagged, flagged, flagged, flagged])
        let recent = latest.indices.suffix(2).compactMap { OvernightVitalsCheck.assessment(nights: Array(latest.prefix($0 + 1)), calendar: calendar) }
        let resumed = try #require(OvernightVitalsCheck.evaluate(assessments: recent, state: old.nextState, calendar: calendar))
        #expect(resumed.shouldNotify)
    }

    @Test func normalNightRearmsOnlyAfterTwoNewFlaggedNights() throws {
        let old = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: .initial, calendar: calendar))
        let normal = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, ordinary]), state: old.nextState, calendar: calendar))
        #expect(normal.nextState.episodeNotified == false)
        let first = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, ordinary, flagged]), state: normal.nextState, calendar: calendar))
        #expect(!first.shouldNotify)
        let second = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged, ordinary, flagged, flagged]), state: first.nextState, calendar: calendar))
        #expect(second.shouldNotify)
    }

    @Test func changedSameNightAssessmentCanNotifyButCannotRepeat() throws {
        let initial = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, ordinary]), state: .initial, calendar: calendar))
        #expect(!initial.shouldNotify)
        let updated = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, flagged]), state: initial.nextState, calendar: calendar))
        #expect(updated.shouldNotify)
        var changed = flagged; changed[.respiratoryRate] = 18
        let again = try #require(OvernightVitalsCheck.evaluate(nights: inputs([flagged, changed]), state: updated.nextState, calendar: calendar))
        #expect(!again.shouldNotify)
    }

    @Test func contactJumpCannotCountAsAnOutlier() throws {
        var values = ordinary; values[.restingHeartRate] = 63; values[.skinTemperatureDeviation] = 40
        let assessment = try #require(OvernightVitalsCheck.assessment(nights: inputs([values]), calendar: calendar))
        #expect(!assessment.isFlagged)
        #expect(assessment.signals.last?.state == .unavailable)
        #expect(assessment.signals.last?.value == nil)
    }

    @Test func backfilledPreviousNightCanCompleteAFlaggedPair() throws {
        let nights = inputs([flagged, flagged, flagged])
        let full = nights.indices.compactMap {
            OvernightVitalsCheck.assessment(nights: Array(nights.prefix($0 + 1)), calendar: calendar)
        }
        let missingPrevious = full.filter { $0.night != "2026-09-22" }
        let waiting = try #require(OvernightVitalsCheck.evaluate(assessments: missingPrevious, state: .initial, calendar: calendar))
        #expect(!waiting.shouldNotify)
        let filled = try #require(OvernightVitalsCheck.evaluate(assessments: full, state: waiting.nextState, calendar: calendar))
        #expect(filled.shouldNotify)
        #expect(OvernightVitalsCheck.evaluate(assessments: full, state: filled.nextState, calendar: calendar)?.shouldNotify == false)
    }

    @Test func oneOutlierOrMissingNewestNightDoesNotFlag() throws {
        var one = ordinary; one[.restingHeartRate] = 63
        #expect(OvernightVitalsCheck.assessment(nights: inputs([one]), calendar: calendar)?.isFlagged == false)
        #expect(OvernightVitalsCheck.assessment(nights: inputs([flagged, [:]]), calendar: calendar)?.isFlagged == false)
        let onlyTemp: [OvernightVitalMetric: Double] = [.skinTemperatureDeviation: 36, .oxygenSaturation: 85]
        #expect(OvernightVitalsCheck.assessment(nights: inputs([onlyTemp]), calendar: calendar)?.isFlagged == false)
    }

    @Test func calendarGapsResetPersistenceAndOldRowsCannotSeedRange() throws {
        let old = inputs([flagged])
        let gapped = old + [.init(night: "2026-09-23", values: flagged)]
        #expect(OvernightVitalsCheck.evaluate(nights: gapped, state: .initial, calendar: calendar)?.shouldNotify == false)
        let stale = old + [.init(night: "2026-12-01", values: flagged)]
        let assessment = try #require(OvernightVitalsCheck.assessment(nights: stale, calendar: calendar))
        #expect(!assessment.isFlagged)
        #expect(assessment.signals.allSatisfy { $0.usualRange == nil && $0.scorableNights == 1 })
    }

    @Test func bothDirectionsCountAndOxygenNeverParticipates() throws {
        var other = ordinary; other[.restingHeartRate] = 42; other[.heartRateVariability] = 80; other[.oxygenSaturation] = 70
        let assessment = try #require(OvernightVitalsCheck.assessment(nights: inputs([other]), calendar: calendar))
        #expect(assessment.isFlagged)
        #expect(assessment.triggeringSignals == [.restingHeartRate, .heartRateVariability])
        #expect(assessment.signals.count == 4)
    }

    @Test func medianRangeHasNoiseFloorAndDuplicateDaysDoNotInflateCount() throws {
        let range = try #require(OvernightVitalsCheck.typicalRange(metric: .restingHeartRate, values: Array(repeating: 50, count: 13)))
        #expect(range.low == 47 && range.high == 53)
        let input = inputs([flagged], baselineCount: 5)
        let assessment = try #require(OvernightVitalsCheck.assessment(nights: input + input + input, calendar: calendar))
        #expect(!assessment.isFlagged)
        #expect(assessment.signals.allSatisfy { $0.scorableNights == 6 })
    }

    @Test func deliveryWaitsForUsualWakeAndQuietHours() {
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        let fiveAM = midnight.addingTimeInterval(5 * 3600)
        let delivered = OvernightVitalsCheck.deliveryDate(now: fiveAM, usualWakeMinute: 7 * 60 + 30,
                                                          earliestMinute: 7 * 60, calendar: calendar)
        #expect(delivered == midnight.addingTimeInterval(7.5 * 3600))
        let earlyRiser = OvernightVitalsCheck.deliveryDate(now: fiveAM, usualWakeMinute: 6 * 60,
                                                           earliestMinute: 7 * 60, calendar: calendar)
        #expect(earlyRiser == midnight.addingTimeInterval(7 * 3600))
        let lateMorning = midnight.addingTimeInterval(10 * 3600)
        #expect(OvernightVitalsCheck.deliveryDate(now: lateMorning, usualWakeMinute: 7 * 60,
                                                  earliestMinute: 7 * 60, calendar: calendar) == lateMorning)
        let wakes = (0..<5).map { midnight.addingTimeInterval(Double($0) * 86_400 + 6.5 * 3600 + Double($0 * 60)) }
        #expect(OvernightVitalsCheck.usualWakeMinute(wakeTimes: wakes, calendar: calendar) == 6 * 60 + 32)
        #expect(OvernightVitalsCheck.usualWakeMinute(wakeTimes: Array(wakes.prefix(2)), calendar: calendar) == nil)
    }

    @Test func cardioFitnessNoticeAtMostOnceEveryFourMonths() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        #expect(CardioFitnessNoticeGate.mayNotify(lastNotifiedAt: nil, now: start, calendar: calendar))
        let threeMonths = calendar.date(byAdding: .month, value: 3, to: start)!
        #expect(!CardioFitnessNoticeGate.mayNotify(lastNotifiedAt: start, now: threeMonths, calendar: calendar))
        let fourMonths = calendar.date(byAdding: .month, value: 4, to: start)!
        #expect(CardioFitnessNoticeGate.mayNotify(lastNotifiedAt: start, now: fourMonths, calendar: calendar))
    }
}
