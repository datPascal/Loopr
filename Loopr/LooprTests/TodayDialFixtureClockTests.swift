import DomainKit
import Foundation
import Testing
@testable import Loopr

/// Fixture launches pin Today's dial to a morning, a midday or an evening time on the fixture day.
struct TodayDialFixtureClockTests {
    @Test
    func theLaunchArgumentPicksTheMorningOrTheEvening() {
        #expect(TodayDialFixtureClock.minuteOfDay(arguments: []) == 13 * 60 + 30)
        #expect(TodayDialFixtureClock.minuteOfDay(arguments: ["--loopr-today-clock=morning"]) == 7 * 60 + 12)
        #expect(TodayDialFixtureClock.minuteOfDay(arguments: ["--loopr-today-clock=evening"]) == 19 * 60 + 49)
        #expect(TodayDialFixtureClock.minuteOfDay(arguments: ["--loopr-today-clock=noon"]) == 13 * 60 + 30)
        // The last one wins, as with every launch argument.
        #expect(TodayDialFixtureClock.minuteOfDay(arguments: ["--loopr-today-clock=morning", "--loopr-today-clock=evening"]) == 19 * 60 + 49)
    }

    @Test
    func thePinnedInstantIsThatWallClockTimeOnTheFixtureDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Perth"))
        let day = DayIdentity(year: 2023, month: 11, day: 14)
        let evening = try #require(TodayDialFixtureClock.now(day: day, calendar: calendar, arguments: ["--loopr-today-clock=evening"]))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: evening)
        #expect(parts.year == 2023 && parts.month == 11 && parts.day == 14 && parts.hour == 19 && parts.minute == 49)
    }
}
