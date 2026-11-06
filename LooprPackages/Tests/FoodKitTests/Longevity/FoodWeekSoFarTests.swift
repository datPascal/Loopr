import FoodKit
import Foundation
import Testing

/// Food's week chart and its longevity lens count one set of finished days: the shown day's ISO week up to that day
/// (ICP R2-UPG-8, where the lens said 1 and the chart line said 6).
struct FoodWeekSoFarTests {
    private let calendar = Longevity.calendar(Longevity.berlin)

    /// Wednesday 15 Nov 2023 and the six days before it, finished from Friday the 10th to Tuesday the 14th.
    private func fixture() throws -> (data: FoodOverviewData, summaries: [FoodDaySummary]) {
        let finished = ["2023-11-10", "2023-11-11", "2023-11-12", "2023-11-13", "2023-11-14"]
        let data = FoodOverviewData(meals: [], drinks: [], days: try finished.map { try Longevity.completeDay($0) }, targets: [])
        let summaries = try (9...15).map { try FoodDaySummary(date: Longevity.instant(2023, 11, $0), calendar: calendar, data: data) }
        return (data, summaries)
    }

    @Test func theWeekRunsFromMondayToTheShownDayAndCountsTheLensDays() throws {
        let (data, summaries) = try fixture()
        let soFar = try #require(FoodWeekSoFar(day: summaries[6], summaries: summaries))
        #expect(soFar.week.id == "2023-W46" && soFar.dayIndex == 2)
        #expect(soFar.days.map(\.localDay) == ["2023-11-13", "2023-11-14", "2023-11-15"])
        // The rolling seven days hold five finished days; the week holds two, and so does the lens.
        #expect(summaries.filter(\.isCompleted).count == 5)
        #expect(soFar.finishedDays == 2)
        let lens = FoodLongevityLens(week: soFar.week, data: data.through(localDay: "2023-11-15"))
        #expect(lens.completeDays == soFar.finishedDays)
        let tiles = FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: nil, barcodedItems: 0, proteinTarget: nil, fibreTarget: nil)
        #expect(tiles.first { $0.kind == .fibre }?.note == "2 of 3 finished days so far")
        #expect(soFar.onTargetLine == "Within 5% of target on 0 of 2 finished days")
        #expect(soFar.spokenOnTargetLine == "Within five percent of target on 0 of 2 finished days")
    }

    @Test func aPastDayStopsAtThatDayForTheChartAndTheLens() throws {
        let (data, summaries) = try fixture()
        // Monday the 13th, read on its own: Tuesday's finish comes later and counts for neither card.
        let monday = try #require(FoodWeekSoFar(day: summaries[4], summaries: Array(summaries.prefix(5))))
        #expect(monday.days.map(\.localDay) == ["2023-11-13"] && monday.dayIndex == 0)
        #expect(monday.finishedDays == 1 && monday.onTargetLine == "Within 5% of target on 0 of 1 finished day")
        #expect(FoodLongevityLens(week: monday.week, data: data.through(localDay: "2023-11-13")).completeDays == 1)
        #expect(FoodLongevityLens(week: monday.week, data: data).completeDays == 2)
    }

    @Test func theAxisHoldsAllSevenDaysAndNoFinishedDaySaysSo() throws {
        let data = FoodOverviewData(meals: [], drinks: [], days: [], targets: [])
        let wednesday = try FoodDaySummary(date: Longevity.instant(2023, 11, 15), calendar: calendar, data: data)
        let soFar = try #require(FoodWeekSoFar(day: wednesday, summaries: [wednesday]))
        #expect(soFar.onTargetLine == "No finished days yet this week")
        let axis = soFar.axisDates(shownDay: wednesday.date, calendar: calendar)
        #expect(axis.count == 7)
        #expect(axis.first == calendar.startOfDay(for: Longevity.instant(2023, 11, 13)))
        #expect(axis.last == calendar.startOfDay(for: Longevity.instant(2023, 11, 19)))
    }
}
