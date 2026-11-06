import DomainKit
import Foundation
import RoutineKit
import Testing

@testable import Loopr

/// The start window of the bedtime Live Activity: 18:00 to the bedtime, with a short grace, for the evening that is
/// under way and never for a past day.
struct BedtimeActivityWindowTests {
    static func calendar(_ identifier: String = "Europe/Berlin") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let berlin = BedtimeActivityWindowTests.calendar()
    private let bedtime = 22 * 60 + 30

    @Test
    func beforeEighteenIsNotYetAndNamesTonightsEvening() {
        let now = Self.date(2026, 10, 24, 17, 59, in: berlin)
        guard case .before(let evening) = BedtimeActivityWindow.phase(now: now, bedtimeMinute: bedtime, calendar: berlin) else {
            Issue.record("expected before"); return
        }
        #expect(evening.start == Self.date(2026, 10, 24, 18, in: berlin))
        #expect(evening.bedtime == Self.date(2026, 10, 24, 22, 30, in: berlin))
        #expect(evening.day == DayIdentity(year: 2026, month: 10, day: 24))
    }

    @Test
    func betweenEighteenAndBedtimeRunsAndEighteenSharpStarts() {
        for (hour, minute) in [(18, 0), (19, 49), (22, 29)] {
            let now = Self.date(2026, 10, 24, hour, minute, in: berlin)
            guard case .running = BedtimeActivityWindow.phase(now: now, bedtimeMinute: bedtime, calendar: berlin) else {
                Issue.record("expected running at \(hour):\(minute)"); return
            }
        }
    }

    @Test
    func afterBedtimeIsGraceThenOverAndNothingStartsAfterBedtime() {
        let atBedtime = Self.date(2026, 10, 24, 22, 30, in: berlin)
        guard case .grace = BedtimeActivityWindow.phase(now: atBedtime, bedtimeMinute: bedtime, calendar: berlin) else {
            Issue.record("expected grace at bedtime"); return
        }
        let lateInGrace = Self.date(2026, 10, 24, 22, 44, in: berlin)
        guard case .grace = BedtimeActivityWindow.phase(now: lateInGrace, bedtimeMinute: bedtime, calendar: berlin) else {
            Issue.record("expected grace"); return
        }
        let afterGrace = Self.date(2026, 10, 24, 22, 45, in: berlin)
        #expect(BedtimeActivityWindow.phase(now: afterGrace, bedtimeMinute: bedtime, calendar: berlin) == .over)
    }

    @Test
    func aBedtimeAfterMidnightKeepsTheEveningRunningPastTwelve() {
        let afterMidnight = 60
        let late = Self.date(2026, 10, 24, 23, 30, in: berlin)
        let early = Self.date(2026, 10, 25, 0, 30, in: berlin)
        for now in [late, early] {
            guard case .running(let evening) = BedtimeActivityWindow.phase(now: now, bedtimeMinute: afterMidnight, calendar: berlin) else {
                Issue.record("expected running at \(now)"); return
            }
            #expect(evening.day == DayIdentity(year: 2026, month: 10, day: 24))
            #expect(evening.bedtime == Self.date(2026, 10, 25, 1, in: berlin))
        }
        let grace = Self.date(2026, 10, 25, 1, 10, in: berlin)
        guard case .grace = BedtimeActivityWindow.phase(now: grace, bedtimeMinute: afterMidnight, calendar: berlin) else {
            Issue.record("expected grace"); return
        }
        // At 01:30 last night is over and the next evening has not begun.
        let over = Self.date(2026, 10, 25, 1, 30, in: berlin)
        guard case .before(let next) = BedtimeActivityWindow.phase(now: over, bedtimeMinute: afterMidnight, calendar: berlin) else {
            Issue.record("expected before"); return
        }
        #expect(next.day == DayIdentity(year: 2026, month: 10, day: 25))
    }

    @Test
    func neverOffersAPastDay() {
        // Mid-morning with a 22:30 bedtime: the countdown is today's evening, not last night's.
        let morning = Self.date(2026, 10, 25, 9, in: berlin)
        guard case .before(let evening) = BedtimeActivityWindow.phase(now: morning, bedtimeMinute: bedtime, calendar: berlin) else {
            Issue.record("expected before"); return
        }
        #expect(evening.day == DayIdentity(year: 2026, month: 10, day: 25))
        // 00:30 after a 22:30 bedtime is the small hours of the next day, with no evening running.
        let night = Self.date(2026, 10, 25, 0, 30, in: berlin)
        guard case .before(let tonight) = BedtimeActivityWindow.phase(now: night, bedtimeMinute: bedtime, calendar: berlin) else {
            Issue.record("expected before"); return
        }
        #expect(tonight.day == DayIdentity(year: 2026, month: 10, day: 25))
    }

    @Test
    func noBedtimeOrAnUnusableOneHasNoWindow() {
        let now = Self.date(2026, 10, 24, 19, in: berlin)
        #expect(BedtimeActivityWindow.phase(now: now, bedtimeMinute: nil, calendar: berlin) == .noBedtime)
        // 14:00 is neither an evening nor an after-midnight bedtime.
        #expect(BedtimeActivityWindow.phase(now: now, bedtimeMinute: 14 * 60, calendar: berlin) == .noBedtime)
        #expect(BedtimeActivityWindow.isCountdownMinute(18 * 60))
        #expect(BedtimeActivityWindow.isCountdownMinute(0))
        #expect(!BedtimeActivityWindow.isCountdownMinute(12 * 60))
        #expect(!BedtimeActivityWindow.isCountdownMinute(17 * 60 + 59))
    }

    @Test
    func theSpringForwardNightIsOneHourShorterOnTheClock() throws {
        let newYork = Self.calendar("America/New_York")
        // 2026-03-08 loses 02:00 to 03:00. Evening of the 7th to a 03:00 bedtime is 8 real hours, not 9.
        let evening = try #require(BedtimeActivityWindow.evening(
            startingOn: Self.date(2026, 3, 7, 12, in: newYork), bedtimeMinute: 3 * 60, calendar: newYork))
        #expect(evening.bedtime.timeIntervalSince(evening.start) == 8 * 3_600)
        let beforeJump = Self.date(2026, 3, 8, 1, 30, in: newYork)
        guard case .running = BedtimeActivityWindow.phase(now: beforeJump, bedtimeMinute: 3 * 60, calendar: newYork) else {
            Issue.record("expected running before the jump"); return
        }
        // 03:10 EDT is ten minutes past bedtime, still grace.
        let afterJump = Self.date(2026, 3, 8, 3, 10, in: newYork)
        guard case .grace = BedtimeActivityWindow.phase(now: afterJump, bedtimeMinute: 3 * 60, calendar: newYork) else {
            Issue.record("expected grace after the jump"); return
        }
    }

    @Test
    func theFallBackNightUsesTheFirstOccurrenceOfARepeatedBedtime() throws {
        let newYork = Self.calendar("America/New_York")
        // 2026-11-01 repeats 01:00 to 02:00. A 01:30 bedtime is the first one, 7.5 real hours after 18:00 on the 31st.
        let evening = try #require(BedtimeActivityWindow.evening(
            startingOn: Self.date(2026, 10, 31, 12, in: newYork), bedtimeMinute: 90, calendar: newYork))
        #expect(evening.bedtime.timeIntervalSince(evening.start) == 7.5 * 3_600)
    }

    @Test
    func theInBedRuleWinsOverTonightsPlan() {
        let inBed = ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                                 target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350),
                                 source: .band)
        #expect(BedtimeActivityBedtime.minuteOfDay(rules: [inBed], plannedMinute: 23 * 60 + 10) == 1_350)
        #expect(BedtimeActivityBedtime.minuteOfDay(rules: [], plannedMinute: 23 * 60 + 10) == 23 * 60 + 10)
        #expect(BedtimeActivityBedtime.minuteOfDay(rules: [], plannedMinute: nil) == nil)
        // A rule with no time falls back to the plan.
        let timeless = ProtocolRule(key: "in-bed", title: "In bed early", group: .sleep,
                                    target: RuleTarget(kind: .done, metric: RoutineMetric.inBedTime.rawValue), source: .band)
        #expect(BedtimeActivityBedtime.minuteOfDay(rules: [timeless], plannedMinute: 1_380) == 1_380)
        // 25:00 means 01:00.
        let past = ProtocolRule(key: "in-bed", title: "In bed", group: .sleep,
                                target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_500),
                                source: .band)
        #expect(BedtimeActivityBedtime.inBedRuleMinute(in: [past]) == 60)
    }
}
