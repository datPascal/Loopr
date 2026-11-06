import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

/// The angle mapping, the hand, the 18:00 switch and the clock edge cases: daylight saving days, a night across
/// midnight and a change of time zone.
struct TodayDialClockTests {
    typealias F = DialFixture

    @Test
    func noonSitsAtTheTopAndTheDayRunsClockwise() {
        #expect(F.close(TodayDialGeometry.angle(minuteOfDay: 720), 0))
        #expect(F.close(TodayDialGeometry.angle(minuteOfDay: 1_080), 90))
        #expect(F.close(TodayDialGeometry.angle(minuteOfDay: 0), 180))
        #expect(F.close(TodayDialGeometry.angle(minuteOfDay: 360), 270))
        #expect(F.close(TodayDialGeometry.angle(minuteOfDay: -90), TodayDialGeometry.angle(minuteOfDay: 1_350)))

        let top = TodayDialGeometry.point(radius: 120, angle: 0)
        #expect(F.close(top.x, 170) && F.close(top.y, 50))
        let right = TodayDialGeometry.point(radius: 120, angle: 90)
        #expect(F.close(right.x, 290) && F.close(right.y, 170))
    }

    @Test
    func theHandFollowsTheClockOnTodayOnly() {
        let model = F.model(F.inputs(now: F.date(F.day, 7, 12)))
        #expect(model.isToday)
        #expect(F.close(model.hand?.angle, 288))
        #expect(F.close(model.handAngle(at: F.date(F.day, 12)), 0))
        #expect(model.handAngle(at: F.date(F.shifted(F.day, by: 1), 1)) == nil)

        let past = F.model(F.inputs(now: F.date(F.shifted(F.day, by: 2), 9)))
        #expect(!past.isToday)
        #expect(past.hand == nil)
        #expect(past.mode == .morning)
    }

    @Test
    func eveningStartsAtSixInTheEvening() {
        #expect(F.model(F.inputs(now: F.date(F.day, 17, 59))).mode == .morning)
        #expect(F.model(F.inputs(now: F.date(F.day, 18, 0))).mode == .evening)
        #expect(F.model(F.inputs(now: F.date(F.day, 23, 59))).mode == .evening)
        #expect(F.model(F.inputs(now: F.date(F.day, 0, 30))).mode == .morning)
        #expect(TodayDialMode.eveningStartMinute == 1_080)
    }

    @Test
    func aNightAcrossMidnightIsOneArcThroughTheBottom() throws {
        let clock = try #require(TodayDialClock(day: F.day, calendar: F.calendar()))
        let night = F.night()
        #expect(F.close(clock.dialMinutes(of: night.start), -90))
        let arc = try #require(clock.arc(from: night.start, to: night.end))
        #expect(F.close(arc.startAngle, 157.5))
        #expect(F.close(arc.sweep, 117))
        #expect(F.close(arc.endAngle, 274.5))
        #expect(clock.arc(from: night.end, to: night.start) == nil)
    }

    @Test
    func theSpringDayHas23HoursAndArcsCrossTheSkippedHour() throws {
        let clock = try #require(TodayDialClock(day: F.springDay, calendar: F.calendar()))
        #expect(clock.hoursInDay == 23)
        // 01:30 to 03:30 is one hour of real time, drawn across the two wall-clock hours it spans.
        let start = F.date(F.springDay, 1, 30), end = F.date(F.springDay, 3, 30)
        #expect(end.timeIntervalSince(start) == 3_600)
        let arc = try #require(clock.arc(from: start, to: end))
        #expect(F.close(arc.sweep, 30))
        #expect(F.close(arc.startAngle, TodayDialGeometry.angle(minuteOfDay: 90)))

        // The night before: 23:00 to 07:00 is seven real hours and eight on the face.
        let night = try #require(clock.arc(from: F.date(F.shifted(F.springDay, by: -1), 23), to: F.date(F.springDay, 7)))
        #expect(F.close(night.sweep, 120))
    }

    @Test
    func theAutumnDayHas25HoursAndTheRepeatedHourSharesItsAngles() throws {
        let clock = try #require(TodayDialClock(day: F.autumnDay, calendar: F.calendar()))
        #expect(clock.hoursInDay == 25)
        // 02:30 summer time is 00:30 UTC, 02:30 winter time is 01:30 UTC.
        let first = F.date(F.autumnDay, 0, 30, zone: F.utc), second = F.date(F.autumnDay, 1, 30, zone: F.utc)
        #expect(F.close(clock.angle(of: first), clock.angle(of: second)))
        #expect(F.close(clock.angle(of: first), TodayDialGeometry.angle(minuteOfDay: 150)))

        // 02:30 summer time to 02:10 winter time: 40 real minutes whose wall clock runs backwards. The elapsed time wins.
        let back = try #require(clock.arc(from: first, to: F.date(F.autumnDay, 1, 10, zone: F.utc)))
        #expect(F.close(back.sweep, 10))

        // The 18:00 switch is wall-clock time on the long day too.
        #expect(F.model(F.inputs(day: F.autumnDay, now: F.date(F.autumnDay, 17, 59))).mode == .morning)
        #expect(F.model(F.inputs(day: F.autumnDay, now: F.date(F.autumnDay, 18, 0))).mode == .evening)
    }

    @Test
    func afterAFlightEverythingSitsAtTheWallClockOfTheDialsZone() throws {
        // Slept in Perth from 22:30 local, viewed in Berlin: 14:30 UTC is 16:30 in Berlin the day before.
        let perthNight = F.night(zone: F.perth)
        var inputs = F.inputs()
        inputs.lastNight = perthNight
        // Breakfast at 07:00 in Perth on the 22nd is 01:00 in Berlin on the 22nd. The next Perth breakfast is the 23rd in Berlin.
        inputs.meals = [F.meal("perth-breakfast", F.date(F.day, 7, zone: F.perth)),
                        F.meal("next-breakfast", F.date(F.shifted(F.day, by: 1), 7, zone: F.perth))]
        let model = F.model(inputs)

        guard case .present(.lastNight(let night)) = model.sleep else {
            Issue.record("Expected last night's hypnogram")
            return
        }
        #expect(F.close(night.night.startAngle, 67.5))
        let eating = try #require(model.eating.value)
        #expect(eating.meals.map(\.id) == ["perth-breakfast"])
        #expect(F.close(eating.meals.first?.angle, 195))

        // The same night drawn in Perth sits at 22:30.
        var local = F.inputs(zone: F.perth)
        local.lastNight = perthNight
        guard case .present(.lastNight(let perth)) = F.model(local).sleep else {
            Issue.record("Expected last night's hypnogram")
            return
        }
        #expect(F.close(perth.night.startAngle, 157.5))
    }

    @Test
    func aTimeAfterMidnightOnTheEveningIsTomorrow() throws {
        let clock = try #require(TodayDialClock(day: F.day, calendar: F.calendar()))
        #expect(TodayDialModel.nightDate(30, clock: clock) == F.date(F.shifted(F.day, by: 1), 0, 30))
        #expect(TodayDialModel.nightDate(1_470, clock: clock) == F.date(F.shifted(F.day, by: 1), 0, 30))
        #expect(TodayDialModel.nightDate(1_350, clock: clock) == F.date(F.day, 22, 30))
    }
}
