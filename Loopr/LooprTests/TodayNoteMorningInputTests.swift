import CoachKit
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import Loopr

/// LV-04 step 3: the morning note's input from stored nights. Last night against the nights before it, and every night
/// split by how long before bed the last meal was. A night without a meal or a bedtime is left out, never guessed.
struct TodayNoteMorningInputTests {
    private let today = DayIdentity(year: 2023, month: 11, day: 14)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func night(_ offset: Int) -> DayIdentity { today.adding(days: -offset)! }

    /// The bedtime of the night that ended on `day`: 22:30 the evening before.
    private func bed(_ day: DayIdentity) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 22, minute: 30))!
            .addingTimeInterval(-86_400)
    }

    @Test func lastNightTheUsualAndTheMealToBedGroupsComeFromTheStoredNights() throws {
        var outcomes: [DayIdentity: Double] = [:]
        var bedtimes: [DayIdentity: Date] = [:]
        var meals: [Date] = []
        for offset in 0..<20 {
            let day = night(offset)
            let late = offset % 3 == 1
            outcomes[day] = late ? 55 : 50
            bedtimes[day] = bed(day)
            // Early dinners end 4 h 04 m before bed, late ones 2 h before.
            meals.append(bed(day).addingTimeInterval(late ? -7_200 : -14_640))
            // A breakfast the same day does not count as the last meal.
            meals.append(bed(day).addingTimeInterval(-14 * 3_600))
        }
        outcomes[today] = 49
        let input = TodayNoteRailMapping.morningInput(today: today, outcomes: outcomes, bedtimes: bedtimes, meals: meals)
        #expect(input.lastNight == NightOutcome(kind: .sleepHeartRate, value: 49, day: today))
        let usual = try #require(input.usual)
        #expect(usual.nights == 19)
        #expect(usual.windowDays == 30)
        let factor = try #require(input.factors.first)
        #expect(factor.id == TodayNoteRailMapping.mealToBedFactorID)
        #expect(factor.lastNightGroupID == "four-hours")
        #expect(factor.lastNightValue == .duration(minutes: 244))
        #expect(factor.history.count == 20)
        #expect(factor.history.filter { $0.groupID == "less" }.count == 7)
        #expect(factor.history.filter { $0.groupID == "less" }.allSatisfy { $0.outcome == 55 })

        let note = try #require(CoachNoteWriter(context: NoteContext(locale: Locale(identifier: "en_GB"), calendar: calendar)).morning(input))
        #expect(note.text.contains("You stopped eating 4 h 04 m before bed."))
        #expect(note.text.contains("On the 13 nights with 4 h or more"))
    }

    @Test func aNightWithoutAMealOrABedtimeIsLeftOut() throws {
        let outcomes = [today: 49.0, night(1): 50, night(2): 52]
        let bedtimes = [today: bed(today), night(1): bed(night(1))]
        let meals = [bed(today).addingTimeInterval(-3 * 3_600)]
        let input = TodayNoteRailMapping.morningInput(today: today, outcomes: outcomes, bedtimes: bedtimes, meals: meals)
        let factor = try #require(input.factors.first)
        #expect(factor.history.map(\.day) == [today])
        #expect(factor.lastNightGroupID == "less")
    }

    @Test func withoutLastNightsMealTimeNoFactorIsNamedAndWithoutLastNightThereIsNoOutcome() {
        let outcomes = [today: 49.0, night(1): 50]
        let noMeal = TodayNoteRailMapping.morningInput(today: today, outcomes: outcomes, bedtimes: [today: bed(today)], meals: [])
        #expect(noMeal.factors.isEmpty)
        #expect(noMeal.lastNight != nil)
        let noNight = TodayNoteRailMapping.morningInput(today: today, outcomes: [night(1): 50], bedtimes: [:], meals: [])
        #expect(noNight.lastNight == nil)
        #expect(noNight.usual?.nights == 1)
        // A zero is not a reading.
        let zero = TodayNoteRailMapping.morningInput(today: today, outcomes: [today: 0], bedtimes: [:], meals: [])
        #expect(zero.lastNight == nil)
    }
}
