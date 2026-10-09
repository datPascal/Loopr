import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import SleepKit

struct SleepNightLabelTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }()

    private func snapshot(_ day: DayIdentity, main: Bool) -> SleepDaySnapshot {
        let populated = SleepFixtures.populated
        return SleepDaySnapshot(day: day, state: main ? .partial : .absent, mainSleep: main ? populated.mainSleep : nil,
                                metrics: [], source: "test")
    }

    /// Thursday 24 Sep 2026, 09:41 in Perth.
    private let thursdayMorning = Date(timeIntervalSince1970: 1_790_214_060)

    @Test func noSleepYetNamesTheNightBeforeNotTheComingOne() {
        // The header used to say "LAST NIGHT · THU 24 → FRI 25 SEP" here.
        let meta = SleepDateFormatting.nightMeta(for: snapshot(DayIdentity(year: 2026, month: 9, day: 24), main: false),
                                                 today: thursdayMorning, calendar: calendar)
        #expect(meta == "LAST NIGHT · WED 23 → THU 24 SEP")
    }

    @Test func aPastNightIsNotCalledLastNight() {
        let meta = SleepDateFormatting.nightMeta(for: snapshot(DayIdentity(year: 2026, month: 9, day: 23), main: true),
                                                 today: thursdayMorning, calendar: calendar)
        #expect(meta == "TUE 22 → WED 23 SEP")
    }

    @Test func sharedDayHeaderFollowsTheSelectedDay() {
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let onToday = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: calendar, onSelect: { _ in })
        // The shared header grammar: today is "last night", the date follows
        // from the navigator; any other day names its night.
        #expect(LooprHeaderMeta.nightPhrase(onToday) == "LAST NIGHT")
        let earlier = LooprDayNavigation(day: LooprDay(year: 2026, month: 9, day: 21), today: today, earliest: nil,
                                         calendar: calendar, onSelect: { _ in })
        #expect(LooprHeaderMeta.nightPhrase(earlier) == "SUN 20 → MON 21 SEP")
    }
}
