import DesignSystem
import Foundation
import Testing
@testable import SleepKit

/// Data ICP rounds: one Sleep page with a night and its ranges.
struct SleepPageTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ offset: Int, from end: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: end))!
    }

    @Test func aRangeOpensWithOneSentence() {
        let end = Date(timeIntervalSince1970: 1_763_000_000)
        let points = (0..<30).map { LooprChartPoint(date: day(-$0, from: end), value: 460) }
        let text = SleepTrendsContent.summary(points, range: .week, endingOn: end, calendar: calendar)
        #expect(text?.hasPrefix("7 nights with a reading. You averaged 7 h 40 m.") == true)
        #expect(SleepTrendsContent.summary([], range: .week, endingOn: end, calendar: calendar) == nil)
    }

    @Test func longRangesWaitForThatMuchHistory() {
        // Three months of nights: 6M, 1Y and 2Y stay dimmed, so no "2-year average" heads 90 nights (Data ICP R4-SW-01).
        #expect(SleepPageScope.locked(historyDays: 90) == [.range(.halfYear), .range(.year), .range(.twoYears)])
        #expect(SleepPageScope.locked(historyDays: 5) == Set(LooprChartRange.allCases.filter { $0 != .week }.map { .range($0) }))
        #expect(SleepPageScope.locked(historyDays: 800).isEmpty)
        #expect(!SleepPageScope.locked(historyDays: 0).contains(.night))
    }

    @Test func aMorningMainSleepIsADaySleep() {
        var morning = DateComponents(calendar: calendar, year: 2026, month: 11, day: 3, hour: 8, minute: 10)
        let start = calendar.date(from: morning)!
        morning.hour = 15
        let end = calendar.date(from: morning)!
        let day = SleepSessionSummary(id: "d", start: start, end: end, durationMinutes: 410, isMainSleep: true,
                                      isPartial: false, confidence: 1, state: .partial)
        #expect(SleepScreen.sleepSpan(day).hasPrefix("Day sleep, "))
        let night = SleepSessionSummary(id: "n", start: start.addingTimeInterval(-10 * 3600), end: start, durationMinutes: 480,
                                        isMainSleep: true, isPartial: false, confidence: 1, state: .partial)
        #expect(!SleepScreen.sleepSpan(night).hasPrefix("Day sleep"))
    }

    @Test func thePickerOffersTheNightAndEveryRange() {
        #expect(SleepPageScope.options.map(\.title) == ["Night", "7D", "30D", "90D", "6M", "1Y", "2Y"])
    }
}
