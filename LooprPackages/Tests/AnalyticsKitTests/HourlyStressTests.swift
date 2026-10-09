import Foundation
import XCTest
@testable import AnalyticsKit

final class HourlyStressTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let start = Date(timeIntervalSince1970: 1_790_121_600)

    private func feature(_ day: Date, hour: Int = 10, hr: Double = 70, rmssd: Double = 40,
                         state: StressHourFeature.State = .quiet, calendar: Calendar? = nil) -> StressHourFeature {
        let date = (calendar ?? self.calendar).date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return StressHourFeature(start: date, end: date.addingTimeInterval(3600), state: state, heartRate: hr, rmssd: rmssd)
    }
    private func baseline(_ days: Int, hour: Int = 10) -> [StressHourFeature] {
        (1...days).map { feature(calendar.date(byAdding: .day, value: -$0, to: start)!, hour: hour) }
    }
    private func samples(hour: Int = 10, count: Int = 1800, amplitude: Double = 20) -> [HourlyStressSample] {
        (0..<count).map { second in
            HourlyStressSample(time: start.addingTimeInterval(Double(hour * 3600 + second)), heartRate: 70,
                rrMilliseconds: [800 + (second.isMultiple(of: 2) ? amplitude : -amplitude)])
        }
    }

    func testBaselineNeedsFourteenDistinctPrecedingDays() {
        let current = feature(start)
        let learning = HourlyStress.resolve([current], baseline: baseline(13), calendar: calendar)
        XCTAssertNil(learning.hours[0].score)
        XCTAssertEqual(learning.daysRemaining, 1)
        let ready = HourlyStress.resolve([current], baseline: baseline(14), calendar: calendar)
        XCTAssertEqual(ready.hours[0].score, 50)
        XCTAssertEqual(ready.daysRemaining, 0)
    }
    func testDuplicateHoursAndSameDayDoNotAdvanceLearning() {
        let prior = baseline(13)
        let result = HourlyStress.resolve([feature(start)], baseline: prior + prior + [feature(start)], calendar: calendar)
        XCTAssertEqual(result.hours[0].baselineDays, 13)
        XCTAssertNil(result.hours[0].score)
    }
    func testBaselineExcludesOldActiveMissingAndDifferentClockHours() {
        let references = baseline(13) + [feature(calendar.date(byAdding: .day, value: -29, to: start)!)]
            + [feature(calendar.date(byAdding: .day, value: -14, to: start)!, state: .active)] + baseline(14, hour: 11)
        let result = HourlyStress.resolve([feature(start)], baseline: references, calendar: calendar)
        XCTAssertEqual(result.hours[0].baselineDays, 13)
    }
    func testDirectionAndDispersionFloors() {
        let high = HourlyStress.resolve([feature(start, hr: 85, rmssd: 20)], baseline: baseline(14), calendar: calendar)
        XCTAssertTrue(high.hours[0].isHigh)
        let low = HourlyStress.resolve([feature(start, hr: 60, rmssd: 65)], baseline: baseline(14), calendar: calendar)
        XCTAssertLessThan(try! XCTUnwrap(low.hours[0].score), 35)
        let small = HourlyStress.resolve([feature(start, hr: 71, rmssd: 39)], baseline: baseline(14), calendar: calendar)
        XCTAssertFalse(small.hours[0].isHigh)
    }
    func testSustainedHighNeedsAdjacentScoredHours() {
        let current = [feature(start, hr: 85, rmssd: 20), feature(start, hour: 11, hr: 85, rmssd: 20)]
        let reference = baseline(14) + baseline(14, hour: 11)
        XCTAssertTrue(HourlyStress.resolve(current, baseline: reference, calendar: calendar).hasSustainedHigh)
        let gap = [current[0], feature(start, hour: 11, state: .missing), feature(start, hour: 12, hr: 85, rmssd: 20)]
        XCTAssertFalse(HourlyStress.resolve(gap, baseline: reference + baseline(14, hour: 12), calendar: calendar).hasSustainedHigh)
    }
    func testQualityWindowsPreserveMissingHours() {
        let hours = HourlyStress.features(samples: samples(), dayStart: start, calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[10].state, .quiet)
        XCTAssertEqual(hours[10].heartRate, 70)
        XCTAssertEqual(try! XCTUnwrap(hours[10].rmssd), 40, accuracy: 0.001)
        XCTAssertEqual(hours[11].state, .missing)
        XCTAssertNil(hours[11].heartRate)
        XCTAssertNil(hours[11].rmssd)
    }
    func testTooFewWindowsNoRRFlatRRAndBadQualityStayMissing() {
        for readings in [samples(count: 300), samples(amplitude: 0), samples(amplitude: 700),
                         samples().map { HourlyStressSample(time: $0.time, heartRate: $0.heartRate, rrMilliseconds: []) }] {
            let hours = HourlyStress.features(samples: readings, dayStart: start, calendar: calendar)
            XCTAssertEqual(hours[10].state, .missing)
            XCTAssertNil(hours[10].rmssd)
        }
    }
    func testWorkoutsSleepMotionAndActivityHeartRateMaskDominatedHours() {
        let span = DateInterval(start: start.addingTimeInterval(36000), duration: 1800)
        let readings = samples(count: 3600)
        let workout = HourlyStress.features(samples: readings, dayStart: start, calendar: calendar, workouts: [span])
        XCTAssertEqual(workout[10].state, .active)
        XCTAssertNil(workout[10].heartRate)
        let overlap = HourlyStress.features(samples: readings, dayStart: start, calendar: calendar,
            sleep: [DateInterval(start: span.start, duration: 3600)], workouts: [span])
        XCTAssertEqual(overlap[10].state, .active)
        let sleep = HourlyStress.features(samples: readings, dayStart: start, calendar: calendar, sleep: [span])
        XCTAssertEqual(sleep[10].state, .asleep)
        let motion = (0..<30).map { MotionMinute(start: span.start.timeIntervalSince1970 + Double($0 * 60), sampleCount: 60,
            enmo: 0.1, mad: 0.1, meanMagnitude: 1.1, dynamicAmplitude: 0.1) }
        XCTAssertEqual(HourlyStress.features(samples: readings, dayStart: start, calendar: calendar, motion: motion)[10].state, .active)
        let highHR = readings.map { HourlyStressSample(time: $0.time, heartRate: 150, rrMilliseconds: $0.rrMilliseconds) }
        XCTAssertEqual(HourlyStress.features(samples: highHR, dayStart: start, calendar: calendar, restingHR: 60, maximumHR: 190)[10].state, .active)
    }
    func testShortActivityDoesNotMaskRemainingQuietHour() {
        let span = DateInterval(start: start.addingTimeInterval(36000), duration: 300)
        let hours = HourlyStress.features(samples: samples(count: 3600), dayStart: start, calendar: calendar, workouts: [span])
        XCTAssertEqual(hours[10].state, .quiet)
    }
    func testHRDisagreeingWithCleanBeatsAndDuplicatedSecondsStayMissing() {
        let wrongHR = samples().map { HourlyStressSample(time: $0.time, heartRate: 120, rrMilliseconds: $0.rrMilliseconds) }
        XCTAssertEqual(HourlyStress.features(samples: wrongHR, dayStart: start, calendar: calendar)[10].state, .missing)
        let duplicated = Array(repeating: samples(count: 30), count: 20).flatMap { $0 }
        XCTAssertEqual(HourlyStress.features(samples: duplicated, dayStart: start, calendar: calendar)[10].state, .missing)
    }

    func testMissingInputsNeverBecomeZeroScores() {
        let current = StressHourFeature(start: feature(start).start, end: feature(start).end, state: .quiet)
        XCTAssertNil(HourlyStress.resolve([current], baseline: baseline(14), calendar: calendar).hours[0].score)
        let missing = feature(start, state: .missing)
        XCTAssertNil(HourlyStress.resolve([missing], baseline: baseline(14), calendar: calendar).hours[0].score)
    }

    func testHalfOpenDayBoundaries() {
        let readings = samples() + [HourlyStressSample(time: start.addingTimeInterval(-1), heartRate: 70, rrMilliseconds: [800]),
            HourlyStressSample(time: start.addingTimeInterval(86400), heartRate: 70, rrMilliseconds: [800])]
        let hours = HourlyStress.features(samples: readings, dayStart: start, calendar: calendar)
        XCTAssertEqual(hours.first?.state, .missing)
        XCTAssertEqual(hours.last?.state, .missing)
    }
    func testMotionOutsideTheDayCannotMaskTheFirstHour() {
        let previous = (-30..<0).map { MotionMinute(start: start.timeIntervalSince1970 + Double($0 * 60), sampleCount: 60,
            enmo: 0.1, mad: 0.1, meanMagnitude: 1.1, dynamicAmplitude: 0.1) }
        let result = HourlyStress.features(samples: samples(hour: 0, count: 3600), dayStart: start, calendar: calendar, motion: previous)
        XCTAssertEqual(result[0].state, .quiet)
    }

    func testDSTAndNonUTCClockHour() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = local.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let fall = local.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertEqual(HourlyStress.features(samples: [], dayStart: spring, calendar: local).count, 23)
        let repeated = HourlyStress.features(samples: [], dayStart: fall, calendar: local)
        XCTAssertEqual(repeated.count, 25)
        XCTAssertEqual(Set(repeated.map(\.start)).count, 25)
        local.timeZone = TimeZone(identifier: "Australia/Perth")!
        let today = local.startOfDay(for: start)
        let references = (1...14).map { feature(local.date(byAdding: .day, value: -$0, to: today)!, calendar: local) }
        let result = HourlyStress.resolve([feature(today, calendar: local)], baseline: references, calendar: local)
        XCTAssertEqual(result.hours[0].baselineDays, 14)
        XCTAssertEqual(result.timeZoneIdentifier, "Australia/Perth")
    }
}
