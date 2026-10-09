import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import TodayKit

struct TodayHeaderDayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }()
    private let today = LooprDay(year: 2026, month: 9, day: 24)
    /// 23 Sep 22:15 in Perth.
    private let lastSync = Date(timeIntervalSince1970: 1_790_172_900)

    private func navigation(_ day: LooprDay) -> LooprDayNavigation {
        LooprDayNavigation(day: day, today: today, earliest: nil, calendar: calendar, onSelect: { _ in })
    }

    @Test func todayMetaShowsTheDateAndAHumanSyncAge() {
        // 642 minutes after the last sync used to read "SYNCED 642 MIN A…".
        let now = lastSync.addingTimeInterval(642 * 60)
        #expect(TodayHeaderFormatting.meta(navigation: navigation(today), lastSync: lastSync, now: now)
                == "THU 24 SEP · SYNCED 10 H AGO")
    }

    @Test func pastDayMetaNamesTheDayBecauseTheTitleStaysToday() {
        let now = lastSync.addingTimeInterval(25 * 60)
        #expect(TodayHeaderFormatting.meta(navigation: navigation(LooprDay(year: 2026, month: 9, day: 23)), lastSync: lastSync, now: now)
                == "YESTERDAY · WED 23 SEP · SYNCED 25 MIN AGO")
        #expect(TodayHeaderFormatting.meta(navigation: navigation(LooprDay(year: 2026, month: 9, day: 22)), lastSync: lastSync, now: now)
                == "TUE 22 SEP · SYNCED 25 MIN AGO")
    }

    @Test func metaWithoutAnySyncIsJustTheDate() {
        #expect(TodayHeaderFormatting.meta(navigation: navigation(today), lastSync: nil, now: lastSync) == "THU 24 SEP")
    }

    @Test func summaryDayLabelIsShortAndEnglish() {
        #expect(TodayHeaderFormatting.dayLabel(for: DayIdentity(year: 2026, month: 9, day: 24)) == "Thu 24 Sep")
    }
}
