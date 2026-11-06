import Foundation
import Testing
import DesignSystem
import DomainKit
@testable import TodayKit

/// The Today sections the app fills through slots: the Sleep and Strain rows, the timeline order and dimming,
/// the bedtime row and the three prompt chips.
struct TodayAgentSlotTests {
    private let twentyFour = Locale(identifier: "en_GB")
    private let twelve = Locale(identifier: "en_AU")
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    private func items() -> [TodayTimelineItem] {
        [
            TodayTimelineItem(id: "lunch", minuteOfDay: 12 * 60 + 40, kind: .meal, title: "Lunch", detail: "Chicken rice bowl · 712 kcal", isInteractive: true),
            TodayTimelineItem(id: "wake", minuteOfDay: 6 * 60 + 52, kind: .wake, title: "Woke up", detail: "Smart alarm, 8 min early"),
            TodayTimelineItem(id: "upper-a", minuteOfDay: 18 * 60, kind: .workout, title: "Upper A", detail: "Planned", isInteractive: true),
            TodayTimelineItem(id: "breakfast", minuteOfDay: 7 * 60 + 30, kind: .meal, title: "Breakfast", detail: "520 kcal", isInteractive: true),
        ]
    }

    private func tonight(bed: Int = 22 * 60 + 45, need: Double = 490) -> TodayTonightPlan {
        // The plan works back from the alarm, so pick the alarm that lands on the bedtime.
        TodayTonightRules.plan(TodayTonightInputs(needMinutes: need, alarmMinute: (bed + Int(need)) % 1_440, suggestedWakeMinute: nil))!
    }

    @Test func timelineSortsByClockAndEndsWithBedtime() {
        let rows = TodayTimelineRules.rows(items: items(), tonight: tonight(), nowMinute: 13 * 60 + 30, locale: twentyFour)
        #expect(rows.map(\.id) == ["wake", "breakfast", "lunch", "upper-a", "bedtime"])
        #expect(rows.map(\.time) == [6 * 60 + 52, 7 * 60 + 30, 12 * 60 + 40, 18 * 60, 22 * 60 + 45].map { LooprClockFormat.text(minuteOfDay: $0, locale: twentyFour) })
        #expect(rows.last?.title == "Bedtime")
        #expect(rows.last?.detail == "For 8 h 10 m of sleep")
    }

    /// ICP R2-OPT-1: a logged meal is eaten, so it never reads "upcoming", even when its time is after the clock.
    @Test func aLoggedMealIsNeverDimmed() {
        let lunch = TodayTimelineItem(id: "meal-l", minuteOfDay: 12 * 60 + 30, kind: .meal, title: "Lunch", isRecord: true)
        let planned = TodayTimelineItem(id: "workout-planned", minuteOfDay: 18 * 60, kind: .workout, title: "Upper A")
        let rows = TodayTimelineRules.rows(items: [lunch, planned], tonight: nil, nowMinute: 7 * 60 + 12, locale: twentyFour)
        #expect(rows.map(\.isDimmed) == [false, true])
    }

    @Test func onlyWhatIsStillAheadIsDimmed() {
        let rows = TodayTimelineRules.rows(items: items(), tonight: tonight(), nowMinute: 13 * 60 + 30, locale: twentyFour)
        #expect(rows.map(\.isDimmed) == [false, false, false, true, true])
        // At the exact minute of an item it has started, so it is not dimmed.
        let atWorkout = TodayTimelineRules.rows(items: items(), tonight: tonight(), nowMinute: 18 * 60, locale: twentyFour)
        #expect(atWorkout.first { $0.id == "upper-a" }?.isDimmed == false)
        // A day that is over dims nothing.
        #expect(TodayTimelineRules.rows(items: items(), tonight: nil, nowMinute: nil, locale: twentyFour).allSatisfy { !$0.isDimmed })
    }

    @Test func aBedtimeFromSleepReplacesTodaysOwnRule() {
        // Sleep's plan reaches the timeline as a bedtime item. Today's wake-minus-need time must not add a second row.
        var all = items()
        all.append(TodayTimelineItem(id: "bedtime", minuteOfDay: 22 * 60 + 40, kind: .bedtime, title: "Bedtime",
                                     detail: "For 8 h 50 m of sleep", isInteractive: true))
        let rows = TodayTimelineRules.rows(items: all, tonight: tonight(bed: 23 * 60, need: 480), nowMinute: 13 * 60 + 30, locale: twentyFour)
        #expect(rows.filter { $0.id == "bedtime" }.count == 1)
        #expect(rows.last?.time == "22:40")
        #expect(rows.last?.detail == "For 8 h 50 m of sleep")
        #expect(rows.last?.isDimmed == true)
    }

    @Test func aPastDayHasNoBedtimeRow() {
        let rows = TodayTimelineRules.rows(items: items(), tonight: nil, nowMinute: nil, locale: twentyFour)
        #expect(!rows.contains { $0.id == "bedtime" })
        #expect(rows.count == 4)
    }

    @Test func aBedtimeAfterMidnightStaysLast() {
        let late = TodayTimelineRules.rows(items: items(), tonight: tonight(bed: 30, need: 480), nowMinute: 9 * 60, locale: twentyFour)
        #expect(late.last?.id == "bedtime")
        #expect(late.last?.time == LooprClockFormat.text(minuteOfDay: 30, locale: twentyFour))
        #expect(late.last?.isDimmed == true)
    }

    @Test func aTieInTheSameMinuteKeepsKindOrder() {
        let tie = [
            TodayTimelineItem(id: "reminder", minuteOfDay: 20 * 60, kind: .reminder, title: "Pattern check-in"),
            TodayTimelineItem(id: "dinner", minuteOfDay: 20 * 60, kind: .meal, title: "Dinner"),
        ]
        #expect(TodayTimelineRules.rows(items: tie, tonight: nil, nowMinute: nil, locale: twentyFour).map(\.id) == ["dinner", "reminder"])
    }

    @Test func yourDayRowSpeaksTitleValueChipAndCaption() {
        let food = TodayYourDayRow(id: "food", title: "Food", caption: "Protein 82 of 150 g", value: "1,240", unit: "of 2,450 kcal")
        #expect(food.accessibilityLabel == "Food, 1,240 of 2,450 kcal, Protein 82 of 150 g")
        let train = TodayYourDayRow(id: "train", title: "Upper A at 18:00", caption: "6 exercises · about 55 min", chip: "Planned")
        #expect(train.accessibilityLabel == "Upper A at 18:00, Planned, 6 exercises · about 55 min")
        #expect(train.identifier == "today-your-day-train")
    }

    @Test func promptChipsFollowTheDirectionOfHRV() {
        #expect(TodayAskPrompts.prompts(hrvChange: 7).first == "Why is my HRV up?")
        #expect(TodayAskPrompts.prompts(hrvChange: -7).first == "Why is my HRV down?")
        #expect(TodayAskPrompts.prompts(hrvChange: 0.2).first == "How is my HRV doing?")
        #expect(TodayAskPrompts.prompts(hrvChange: nil).first == "How is my HRV doing?")
        #expect(TodayAskPrompts.prompts(hrvChange: nil).count == 3)
        #expect(TodayAskPrompts.prompts(hrvChange: 3).dropFirst() == ["What should I eat tonight?", "Train hard today?"])
    }

    @Test func aPastDayHasItsOwnThreeChipsWhateverTheHRVDid() {
        let expected = ["How did I sleep the night before?", "How did this day compare with my usual?", "What changed from the day before?"]
        #expect(TodayAskPrompts.pastDay == expected)
        for change in [7.0, -7.0, 0.2, nil] {
            #expect(TodayAskPrompts.prompts(hrvChange: change, isToday: false) == expected)
        }
        let words = expected.joined(separator: " ").lowercased()
        #expect(!words.contains("today") && !words.contains("tonight") && !words.contains("this week"))
        #expect(TodayAskPrompts.prompts(hrvChange: 7, isToday: true) == TodayAskPrompts.prompts(hrvChange: 7))
    }

    @Test func thePlaceholderNamesTheDayThatIsOnScreen() {
        #expect(TodayAskPrompts.placeholder(isToday: true) == "Ask about your data")
        #expect(TodayAskPrompts.placeholder(isToday: false) == "Ask about this day")
    }

    @Test func anAlarmSortsAfterWakingUpAndBeforeAMealInTheSameMinute() {
        let tie = [
            TodayTimelineItem(id: "meal-b", minuteOfDay: 7 * 60, kind: .meal, title: "Breakfast"),
            TodayTimelineItem(id: "alarm", minuteOfDay: 7 * 60, kind: .alarm, title: "Smart alarm", isInteractive: true),
            TodayTimelineItem(id: "wake", minuteOfDay: 7 * 60, kind: .wake, title: "Woke up"),
        ]
        #expect(TodayTimelineRules.rows(items: tie, tonight: nil, nowMinute: nil, locale: twentyFour).map(\.id) == ["wake", "alarm", "meal-b"])
    }

    @Test func yourDaySleepIsAShareOfTheNeedAndStrainShowsTheSuggestedRange() throws {
        let context = TodayTestDays.context(tonight: TodayTonightInputs(needMinutes: 450, alarmMinute: 7 * 60, suggestedWakeMinute: nil))
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(sleep: 462, strain: 6.4, need: 450), context)
        let sleep = try #require(dashboard.yourDay.first { $0.kind == .sleep })
        #expect(sleep.value == "103")
        #expect(sleep.unit == "%")
        #expect(sleep.caption == "7 h 42 m of 7 h 30 m needed")
        let strain = try #require(dashboard.yourDay.first { $0.kind == .strain })
        #expect(strain.value == "6.4")
        if let suggested = context.suggestedStrainRange {
            #expect(strain.caption == "Suggested \(Int(suggested.lowerBound.rounded())) to \(Int(suggested.upperBound.rounded()))")
            #expect(strain.range?.domain == 0...21)
        }
    }

    @Test func yourDayWithNoReadingsHasEmptyRows() {
        // No history either, so nothing stands in for the missing night and the missing strain.
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(sleep: nil, strain: nil), nil)
        #expect(dashboard.yourDay.map(\.id) == ["sleep", "strain"])
        #expect(dashboard.yourDay.allSatisfy { $0.value == nil && $0.range == nil })
    }

    @Test func emptyAgentContentHasNothingToShow() {
        #expect(TodayAgentContent.empty.yourDayRows.isEmpty)
        #expect(TodayAgentContent.empty.timeline.isEmpty)
        #expect(TodayAgentContent.empty.pattern == nil)
    }

    @Test func oneTimelineRowReadsInBothClockStyles() {
        let wake = [TodayTimelineItem(id: "lunch", minuteOfDay: 12 * 60 + 40, kind: .meal, title: "Lunch")]
        let in24 = TodayTimelineRules.rows(items: wake, tonight: nil, nowMinute: nil, locale: twentyFour)
        #expect(in24[0].time == "12:40")
        #expect(!in24[0].time.lowercased().contains("m"))
        let in12 = TodayTimelineRules.rows(items: wake, tonight: nil, nowMinute: nil, locale: twelve)
        #expect(plain(in12[0].time) == "12:40 pm")
        let morning = TodayTimelineRules.rows(items: [TodayTimelineItem(id: "w", minuteOfDay: 6 * 60 + 52, kind: .wake, title: "Woke up")],
                                              tonight: nil, nowMinute: nil, locale: twelve)
        #expect(plain(morning[0].time) == "6:52 am")
    }
}
