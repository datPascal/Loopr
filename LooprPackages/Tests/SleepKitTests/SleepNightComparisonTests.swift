import Foundation
import Testing
@testable import SleepKit

/// The on-device "What was different" comparison: which factors it reports, in what order, when it stays
/// quiet and which days count as the trailing 28.
struct SleepNightComparisonTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// `yyyy-MM-dd`, `offset` days before the night on 2026-10-13.
    private func day(_ offset: Int) -> String {
        let end = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
        let date = Self.calendar.date(byAdding: .day, value: -offset, to: end)!
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private var night: String { day(0) }

    /// 24-hour and 12-hour locales. The narrow no-break space some 12-hour formats put before am and pm becomes a plain space.
    private let twentyFour = Locale(identifier: "de_DE")
    private let twelve = Locale(identifier: "en_AU")
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    private func make(_ night: SleepComparisonDay, _ history: [SleepComparisonDay], _ locale: Locale? = nil) -> SleepNightComparison? {
        SleepNightComparison.make(night: night, history: history, locale: locale ?? twentyFour)
    }

    /// 28 days before the night with a late dinner (21:00 to 21:30), alcohol on 20 of them, training on 8 and
    /// bedtimes around 23:30.
    private func usualHistory(days: ClosedRange<Int> = 1...28) -> [SleepComparisonDay] {
        days.map { offset in
            SleepComparisonDay(day: day(offset), dinnerMinute: 21 * 60 + (offset % 3) * 15, alcohol: offset % 7 != 0 && offset % 10 != 0 ? true : false,
                               trained: offset % 3 == 0, bedtimeMinute: 23 * 60 + 30 + (offset % 3) * 5, steps: 8_000 + Double(offset % 4) * 250)
        }
    }

    @Test func reportsTheBiggestDifferencesFirstAndLeavesOutWhatIsUsual() throws {
        // Dinner two hours early, no alcohol and a bedtime 95 minutes early differ. Not training is what most days look like.
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60 + 10, alcohol: false, trained: false,
                                        bedtimeMinute: 22 * 60 + 0, steps: 8_100)
        let result = try #require(make(target, usualHistory()))
        #expect(Set(result.deviations.map(\.factor)) == [.dinner, .bedtime, .alcohol])
        #expect(result.deviations.map(\.strength) == result.deviations.map(\.strength).sorted(by: >))
        #expect(result.text.contains("Dinner was at 19:10, 2 hours earlier than your average."))
        #expect(result.text.contains("You logged no alcohol."))
        #expect(!result.text.contains("unlike") && !result.text.contains("of the last"), "plain sentences, no counts")
        #expect(!result.text.contains("train"))
    }

    @Test func stopsAtThreeDifferencesEvenWhenMoreDiffer() throws {
        // Add a workout the day before, which is rare in this history, to the three above.
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60 + 10, alcohol: false, trained: true,
                                        bedtimeMinute: 22 * 60 + 0, steps: 15_000)
        let result = try #require(make(target, usualHistory()))
        #expect(result.deviations.count == SleepNightComparison.maximumDeviations)
        #expect(result.deviations.map(\.strength) == result.deviations.map(\.strength).sorted(by: >))
    }

    @Test func aNightLikeAnyOtherIsHidden() {
        let usual = SleepComparisonDay(day: night, dinnerMinute: 21 * 60 + 15, alcohol: true, trained: false,
                                       bedtimeMinute: 23 * 60 + 35, steps: 8_200)
        #expect(make(usual, usualHistory()) == nil)
    }

    @Test func noHistoryOrTooLittleOfItIsHidden() {
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60, alcohol: false, trained: true, bedtimeMinute: 22 * 60, steps: 20_000)
        #expect(make(target, []) == nil)
        #expect(make(target, usualHistory(days: 1...6)) == nil)
        #expect(make(SleepComparisonDay(day: night), usualHistory()) == nil)
    }

    @Test func aFactorNeedsSevenDaysOfItsOwnHistory() throws {
        // Dinner has only 6 days of history, alcohol has 28. Only alcohol can be compared.
        let history = usualHistory().enumerated().map { index, entry in
            SleepComparisonDay(day: entry.day, dinnerMinute: index < 6 ? entry.dinnerMinute : nil, alcohol: entry.alcohol)
        }
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60, alcohol: false)
        let result = try #require(make(target, history))
        #expect(result.deviations.map(\.factor) == [.alcohol])
    }

    @Test func onlyTheTrailing28DaysCount() throws {
        // Days 1 to 28 say dinner is at 21:00. Days 29 to 60 say 18:00 and must be ignored.
        let inside = (1...28).map { SleepComparisonDay(day: day($0), dinnerMinute: 21 * 60) }
        let outside = (29...60).map { SleepComparisonDay(day: day($0), dinnerMinute: 18 * 60) }
        let target = SleepComparisonDay(day: night, dinnerMinute: 18 * 60 + 30)
        let result = try #require(make(target, inside + outside))
        #expect(result.text.contains("18:30, 2.5 hours earlier"))
        // Without the window, 32 days at 18:00 would make 18:30 a later dinner.
        #expect(!result.text.contains("later than"))
        // Day 29 alone is outside, and the night itself is not its own history.
        #expect(SleepNightComparison.isInWindow(day(28), before: night))
        #expect(!SleepNightComparison.isInWindow(day(29), before: night))
        #expect(!SleepNightComparison.isInWindow(night, before: night))
        #expect(!SleepNightComparison.isInWindow(day(-1), before: night))
    }

    @Test func aRoutineAnswerIsNotADifference() {
        // Alcohol answered no on 26 of 28 days. A no tonight is what the person always does.
        let history = (1...28).map { SleepComparisonDay(day: day($0), alcohol: $0 <= 2) }
        #expect(make(SleepComparisonDay(day: night, alcohol: false), history) == nil)
        // A yes tonight is the rare answer.
        let result = make(SleepComparisonDay(day: night, alcohol: true), history)
        #expect(result?.deviations.first?.sentence == "You logged alcohol.")
    }

    @Test func aBedtimeAfterMidnightComparesAsLaterNotEarlier() throws {
        let history = (1...14).map { SleepComparisonDay(day: day($0), bedtimeMinute: 23 * 60) }
        let result = try #require(make(SleepComparisonDay(day: night, bedtimeMinute: 30), history))
        #expect(result.text == "Bedtime was 00:30, 1.5 hours later than your average.")
        #expect(SleepComparisonDay(day: night, bedtimeMinute: 30).bedtimeMinute == 1_470)
        #expect(SleepComparisonDay(day: night, bedtimeMinute: 22 * 60).bedtimeMinute == 22 * 60)
    }

    @Test func stepsDifferByAtLeastTwoThousandAndAFifth() throws {
        let history = (1...14).map { SleepComparisonDay(day: day($0), steps: 9_000) }
        #expect(make(SleepComparisonDay(day: night, steps: 10_500), history) == nil)
        let result = try #require(make(SleepComparisonDay(day: night, steps: 12_400), history))
        #expect(result.text == "You took 12,400 steps the day before, about 3,400 more than your average.")
        #expect(result.sources == ["Activity"])
    }

    @Test func sourcesListEachAppOnceInOrder() throws {
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60, alcohol: false, bedtimeMinute: 21 * 60 + 30)
        let result = try #require(make(target, usualHistory()))
        #expect(result.sources.count == Set(result.sources).count)
        #expect(Set(result.sources).isSubset(of: ["Food", "Protocol", "Sleep", "Fitness", "Activity"]))
    }

    @Test func timesFollowTheLocaleLikeTheSleepHero() throws {
        let target = SleepComparisonDay(day: night, dinnerMinute: 19 * 60 + 10, bedtimeMinute: 22 * 60 + 30)
        let history = (1...14).map { SleepComparisonDay(day: day($0), dinnerMinute: 21 * 60 + 10, bedtimeMinute: 23 * 60 + 40) }
        let twelveHour = try #require(make(target, history, twelve))
        #expect(plain(twelveHour.text).contains("Dinner was at 7:10 pm, 2 hours earlier than your average."))
        #expect(plain(twelveHour.text).contains("Bedtime was 10:30 pm, about an hour earlier than your average."))
        let twentyFourHour = try #require(make(target, history, twentyFour))
        #expect(twentyFourHour.text.contains("Dinner was at 19:10"))
    }

    @Test func gapsAreWrittenInPlainWords() {
        #expect(SleepNightComparison.gap(32) == "30 minutes")
        #expect(SleepNightComparison.gap(60) == "an hour")
        #expect(SleepNightComparison.gap(115) == "2 hours")
        #expect(SleepNightComparison.gap(95) == "1.5 hours")
        #expect(SleepNightComparison.gap(100) == "about 1.5 hours")
        #expect(SleepNightComparison.gap(150) == "2.5 hours")
        #expect(SleepNightComparison.gap(5) == "5 minutes")
    }
}
