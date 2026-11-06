import FoodKit
import Foundation
import Testing

struct FoodGoalPlannerTests {
    private func plan(_ goal: FoodGoal, goalWeight: Double? = nil, activity: FoodActivityLevel = .sitting,
                      pace: Double? = nil) throws -> FoodGoalPlanner {
        try #require(FoodGoalPlanner(goal: goal, age: 30, sex: .male, heightCentimetres: 180, weightKilograms: 80,
                                     goalWeightKilograms: goalWeight, activity: activity, paceKgPerWeek: pace))
    }

    @Test func maintenanceIsRestingEnergyTimesActivity() throws {
        // Mifflin-St Jeor: 10 × 80 + 6.25 × 180 − 5 × 30 + 5 = 1,780 kcal resting.
        let sitting = try plan(.maintain)
        #expect(sitting.restingEnergy == 1_780)
        #expect(sitting.maintenanceEnergy == 2_140, "1,780 × 1.2 = 2,136")
        #expect(sitting.baseEnergy == 2_140)
        #expect(sitting.protein == 130)
        #expect(sitting.fat == 60)
        #expect(sitting.carbs == 270)
        #expect(sitting.waterMillilitres == 2_800)
        #expect(sitting.weeksToGoal == nil)
        #expect(try plan(.maintain, activity: .onFeet).maintenanceEnergy == 2_670, "1,780 × 1.5")
    }

    @Test func losingFollowsThePaceAndGivesAGoalDate() throws {
        let lose = try plan(.lose, goalWeight: 75, pace: 0.5)
        #expect(lose.baseEnergy == 1_590, "2,136 − 0.5 × 7,700 / 7 = 1,586")
        #expect(abs(lose.weeklyChangeKg + 0.4964) < 0.001)
        let weeks = try #require(lose.weeksToGoal)
        #expect(abs(weeks - 10.07) < 0.01)
        #expect(lose.protein == 150, "2 g per kg of the 75 kg goal")
        #expect(lose.fat == 45)
        #expect(lose.carbs == 145)
        #expect(!lose.isAtMinimum && !lose.isFastLoss)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        #expect(lose.goalDate(from: start, calendar: calendar) == calendar.date(byAdding: .day, value: 71, to: start))
    }

    @Test func buildingAddsTheSurplus() throws {
        let build = try plan(.build, goalWeight: 85, pace: 0.25)
        #expect(build.baseEnergy == 2_410, "2,136 + 275")
        #expect(build.protein == 145)
        #expect(try #require(build.weeksToGoal) > 0)
    }

    @Test func aGoalWeightTheWrongWayHasNoDate() throws {
        #expect(try plan(.lose, goalWeight: 85).weeksToGoal == nil)
        #expect(try plan(.build, goalWeight: 70).weeksToGoal == nil)
    }

    @Test func losingStopsAtTheMinimumAndSaysSo() throws {
        let small = try #require(FoodGoalPlanner(goal: .lose, age: 60, sex: .female, heightCentimetres: 155, weightKilograms: 50,
                                                 goalWeightKilograms: 45, paceKgPerWeek: 0.5))
        #expect(small.baseEnergy == 1_200)
        #expect(small.isAtMinimum)
        #expect(small.weeksToGoal == nil, "1,200 kcal is about maintenance here, so there is no honest date")
    }

    @Test func aPaceAboveOnePercentAWeekIsFlagged() throws {
        #expect(try plan(.lose, pace: 1.0).isFastLoss)
        #expect(try !plan(.lose, pace: 0.75).isFastLoss)
    }

    @Test func missingOrImplausibleProfileValuesGiveNoPlan() {
        #expect(FoodGoalPlanner(goal: .maintain, age: nil, sex: .male, heightCentimetres: 180, weightKilograms: 80) == nil)
        #expect(FoodGoalPlanner(goal: .maintain, age: 30, sex: .male, heightCentimetres: nil, weightKilograms: 80) == nil)
        #expect(FoodGoalPlanner(goal: .maintain, age: 30, sex: .male, heightCentimetres: 180, weightKilograms: nil) == nil)
        #expect(FoodGoalPlanner(goal: .maintain, age: 12, sex: .male, heightCentimetres: 150, weightKilograms: 40) == nil)
    }
}

struct FoodWeightTrendTests {
    private func entry(daysAgo: Double, _ kilograms: Double) throws -> FoodWeightEntry {
        try FoodWeightEntry(measuredAt: Date(timeIntervalSince1970: 1_767_268_800 - daysAgo * 86_400), timeZoneIdentifier: "UTC", kilograms: kilograms)
    }

    /// Each weigh-in day moves the trend a tenth of the way to that day's weight; a gap of n days moves it 1 − 0.9ⁿ.
    @Test func smoothsEachDayATenthOfTheWayAndSpansGaps() throws {
        let trend = try #require(FoodWeightTrend([entry(daysAgo: 2, 80), entry(daysAgo: 1, 81), entry(daysAgo: 0, 79)]))
        // 80, then 80 + 0.1 × 1 = 80.1, then 80.1 + 0.1 × (79 − 80.1) = 79.99.
        #expect(abs(trend.smoothed - 79.99) < 0.0001)
        let gap = try #require(FoodWeightTrend([entry(daysAgo: 3, 80), entry(daysAgo: 0, 82)]))
        // Three days: 1 − 0.9³ = 0.271 of the way.
        #expect(abs(gap.smoothed - 80.542) < 0.0001)
        #expect(FoodWeightTrend.smoothing == 0.1)
    }

    @Test func aSteadyLossShowsAsAWeeklyChangeOnceTheTrendCounts() throws {
        // 0.1 kg a day down for 21 days.
        let entries = try (0...20).map { try entry(daysAgo: Double(20 - $0), 82 - Double($0) * 0.1) }
        let trend = try #require(FoodWeightTrend(entries))
        #expect(trend.hasEnoughReadings && trend.recentDays == 14 && trend.daysNeeded == 0)
        #expect(trend.current == trend.smoothed)
        let change = try #require(trend.weeklyChange)
        // The trend lags a falling weight, so it reads a little above the last reading and loses a little under 0.7 kg.
        #expect(trend.smoothed > 80 && trend.smoothed < 81)
        #expect(change < -0.5 && change > -0.7)
        #expect(trend.daily.count == 21)
    }

    @Test func fewReadingsShowTheLatestDayAndSayHowManyTheTrendNeeds() throws {
        let trend = try #require(FoodWeightTrend([entry(daysAgo: 9, 78.4), entry(daysAgo: 0.1, 84), entry(daysAgo: 0, 83.6)]))
        #expect(!trend.hasEnoughReadings && trend.recentDays == 2 && trend.daysNeeded == 5)
        // The latest day's mean, not a trend from two days nine days apart.
        #expect(abs(trend.current - 83.8) < 0.0001)
        #expect(trend.weeklyChange != nil)
    }

    @Test func twoReadingsOnOneDayBecomeOnePoint() throws {
        let trend = try #require(FoodWeightTrend([entry(daysAgo: 0.1, 80), entry(daysAgo: 0, 81)]))
        #expect(trend.daily.map(\.kilograms) == [80.5])
        #expect(trend.smoothed == 80.5)
        #expect(trend.weeklyChange == nil)
    }

    @Test func rejectsImplausibleReadings() {
        #expect(throws: FoodError.self) { try entry(daysAgo: 0, 5) }
        #expect(FoodWeightTrend([]) == nil)
    }
}

struct FoodWeightSuggestionTests {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)
    private func entry(daysAgo: Double, _ kilograms: Double) throws -> FoodWeightEntry {
        try FoodWeightEntry(measuredAt: now.addingTimeInterval(-daysAgo * 86_400), timeZoneIdentifier: "UTC", kilograms: kilograms)
    }
    /// A steady fall of `perDay` kg for 28 days.
    private func falling(_ perDay: Double, days: Int = 28) throws -> FoodWeightTrend {
        try #require(FoodWeightTrend((0..<days).map { try entry(daysAgo: Double(days - 1 - $0), 85 - Double($0) * perDay) }))
    }
    private let plan = FoodGoalPlan(startWeightKg: 85, goalWeightKg: 78, paceKgPerWeek: 0.25, activity: .light)

    @Test func aFasterLossThanPlannedSuggestsEatingMoreAndShowsItsWorking() throws {
        let trend = try falling(0.1)
        let suggestion = try #require(FoodWeightSuggestion(trend: trend, goal: .lose, plan: plan, now: now))
        let change = try #require(trend.weeklyChange)
        #expect(suggestion.trendPerWeek == change && suggestion.planPerWeek == -0.25)
        #expect(suggestion.energyPerDay > 0)
        #expect(abs(suggestion.energyPerDay - (-(change + 0.25) * 7_700 / 7)) <= 5)
        #expect(suggestion.sentence.hasPrefix("Your trend fell "))
        #expect(suggestion.sentence.contains("Your plan aims for a loss of 0.25 kg a week."))
        #expect(suggestion.sentence.contains("kcal more a day would match it."))
        #expect(suggestion.sentence.hasSuffix("kg a week at 7,700 kcal per kg."))
        // The shown rate and the plan's subtract to the shown gap: 0.64 − 0.25 = 0.39.
        let shown = (abs(change) * 100).rounded() / 100
        #expect(suggestion.sentence.contains("fell \(FoodGoalProgress.pace(shown)) kg a week"))
        #expect(suggestion.sentence.contains("a gap of \(FoodGoalProgress.pace(((shown - 0.25) * 100).rounded() / 100)) kg a week"))
    }

    @Test func aTrendCloseToThePlanOrTooFewReadingsSuggestNothing() throws {
        // About 0.25 kg a week once the trend has caught up.
        #expect(FoodWeightSuggestion(trend: try falling(0.25 / 7, days: 60), goal: .lose, plan: plan, now: now) == nil)
        let few = try #require(FoodWeightTrend([entry(daysAgo: 10, 85), entry(daysAgo: 0, 83)]))
        #expect(FoodWeightSuggestion(trend: few, goal: .lose, plan: plan, now: now) == nil)
        #expect(FoodWeightSuggestion(trend: try falling(0.1), goal: .lose, plan: nil, now: now) == nil)
        // A month later the readings are stale.
        #expect(FoodWeightSuggestion(trend: try falling(0.1), goal: .lose, plan: plan, now: now.addingTimeInterval(30 * 86_400)) == nil)
    }

    @Test func holdingWeightWhileBuildingSuggestsEatingMore() throws {
        let flat = try #require(FoodWeightTrend((0..<21).map { try entry(daysAgo: Double(20 - $0), 75) }))
        let build = FoodGoalPlan(startWeightKg: 75, goalWeightKg: 78, paceKgPerWeek: 0.25, activity: .light)
        let suggestion = try #require(FoodWeightSuggestion(trend: flat, goal: .build, plan: build, now: now))
        // 0.25 kg a week × 7,700 ÷ 7 = 275 kcal a day.
        #expect(suggestion.energyPerDay == 280 || suggestion.energyPerDay == 270)
        #expect(suggestion.sentence.hasPrefix("Your trend held steady. Your plan aims for a gain of 0.25 kg a week. Eating about"))
    }
}

struct FoodGoalProgressTests {
    @Test func paceKeepsQuarterKilos() {
        let plan = FoodGoalPlan(startWeightKg: 70, goalWeightKg: 74, paceKgPerWeek: 0.25, activity: .light)
        let settings = FoodTargetSettings(goal: .build, baseEnergy: 2_600, confirmedAt: Date(timeIntervalSince1970: 0), plan: plan)
        // Loopr writes numbers in one locale on every tab (`LooprUnitFormatter.displayLocale`), so "0.25" on any region.
        let point = "."
        #expect(FoodGoalProgress(settings: settings, trend: nil).headline == "Gaining 0\(point)25 kg a week")
        #expect(FoodGoalPlanner.paces(for: .lose).map(FoodGoalProgress.pace) == ["0\(point)25", "0\(point)5", "0\(point)75", "1"])
    }
}
