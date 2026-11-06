import FoodKit
import Foundation
import Testing

struct FoodLongevityLensTests {
    private let week: FoodISOWeek
    init() throws { week = try FoodISOWeek(containing: "2026-10-21") }

    private func data(_ context: LongevityStore, meals: [(day: Int, hour: Int, items: [FoodItem])], complete: [String],
                      drinks: [FoodDrink] = []) throws -> FoodOverviewData {
        .init(meals: try meals.map { try context.meal(at: Longevity.instant(2026, 10, $0.day, $0.hour), zone: Longevity.berlin, items: $0.items) },
              drinks: drinks, days: try complete.map { try Longevity.completeDay($0) }, targets: [])
    }

    @Test func everyValueIsAbsentRatherThanZeroWithoutInputs() throws {
        let lens = FoodLongevityLens(week: week, data: .init(meals: [], drinks: [], days: [], targets: []))
        #expect(lens.completeDays == 0)
        #expect(lens.proteinPerKilogram == nil && lens.fibrePerDay == nil && lens.ultraProcessed == nil)
        #expect(lens.alcoholFree == nil && lens.lastMealToBedMinutes == nil)
        // Meals on days that were never marked complete count for nothing, except the last meal.
        let context = try LongevityStore()
        let open = try data(context, meals: [(20, 12, [Longevity.scannedItem(nova: 4, energy: 500, nutrients: [.protein: 90, .fibre: 20])])], complete: [])
        let unfinished = FoodLongevityLens(week: week, data: open, bodyWeightKilograms: 75)
        #expect(unfinished.completeDays == 0 && unfinished.proteinPerKilogram == nil && unfinished.fibrePerDay == nil)
        #expect(unfinished.ultraProcessed == nil && unfinished.alcoholFree == nil)
    }

    @Test func proteinPerKilogramAveragesCompleteDaysAndNeedsAValidBodyWeight() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, 12, [Longevity.typedItem(nutrients: [.protein: 140])]),
            (20, 12, [Longevity.typedItem(nutrients: [.protein: 60]), Longevity.typedItem(nutrients: [.protein: 40])]),
            (21, 12, [Longevity.typedItem(nutrients: [.protein: 900])]),
            (26, 12, [Longevity.typedItem(nutrients: [.protein: 900])]),
        ], complete: ["2026-10-19", "2026-10-20", "2026-10-26"])
        let lens = FoodLongevityLens(week: week, data: input, bodyWeightKilograms: 75)
        #expect(lens.completeDays == 2)
        #expect(Longevity.close(lens.proteinPerKilogram?.value, 1.6) && lens.proteinPerKilogram?.days == 2)
        for weight in [nil, 0, -5, .nan, .infinity, 10, 500] as [Double?] {
            #expect(FoodLongevityLens(week: week, data: input, bodyWeightKilograms: weight).proteinPerKilogram == nil, "\(String(describing: weight))")
        }
    }

    @Test func aDayWhereNoItemReportedProteinOrFibreDoesNotCount() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, 12, [Longevity.typedItem(nutrients: [.protein: 100, .fibre: 30])]),
            (20, 12, [Longevity.typedItem(nutrients: [.energy: 500])]),
        ], complete: ["2026-10-19", "2026-10-20"])
        let lens = FoodLongevityLens(week: week, data: input, bodyWeightKilograms: 100)
        #expect(Longevity.close(lens.proteinPerKilogram?.value, 1) && lens.proteinPerKilogram?.days == 1)
        #expect(Longevity.close(lens.fibrePerDay?.value, 30) && lens.fibrePerDay?.days == 1)
        // Nothing reports fibre at all.
        let none = try data(context, meals: [(19, 12, [Longevity.typedItem(nutrients: [.energy: 500])])], complete: ["2026-10-19"])
        #expect(FoodLongevityLens(week: week, data: none, bodyWeightKilograms: 70).fibrePerDay == nil)
        #expect(FoodLongevityLens(week: week, data: none, bodyWeightKilograms: 70).proteinPerKilogram == nil)
        // A complete day with nothing logged is a known zero, as it is everywhere in Food.
        let empty = try data(context, meals: [], complete: ["2026-10-19"])
        #expect(FoodLongevityLens(week: week, data: empty).fibrePerDay?.value == 0)
    }

    @Test func fibreIsAMeanGramsPerDayIncludingDrinksThatReportIt() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, 12, [Longevity.typedItem(nutrients: [.fibre: 12]), Longevity.typedItem(nutrients: [.fibre: 18])]),
            (22, 12, [Longevity.typedItem(nutrients: [.fibre: 40])]),
        ], complete: ["2026-10-19", "2026-10-22"])
        #expect(Longevity.close(FoodLongevityLens(week: week, data: input).fibrePerDay?.value, 35))
    }

    @Test func ultraProcessedShareUsesOnlyNovaGroupFourOnBarcodedItemsAndReportsCoverage() throws {
        let context = try LongevityStore()
        let drink = try Longevity.drink(.caffeine, on: "2026-10-19", energy: 100)
        let input = try data(context, meals: [
            (19, 8, [Longevity.scannedItem("Spread", nova: 4, energy: 300), Longevity.scannedItem("Oats", nova: 1, energy: 100)]),
            (19, 13, [Longevity.scannedItem("No group", nova: nil, energy: 200), Longevity.typedItem("Home cooked", nutrients: [.energy: 400])]),
            // An incomplete day is left out entirely.
            (21, 13, [Longevity.scannedItem("Crisps", nova: 4, energy: 5_000)]),
        ], complete: ["2026-10-19"], drinks: [drink])
        let share = try #require(FoodLongevityLens(week: week, data: input).ultraProcessed)
        #expect(share.ultraProcessedEnergy == 300 && share.classifiedEnergy == 400 && share.totalEnergy == 1_100)
        #expect(Longevity.close(share.share, 0.75) && Longevity.close(share.coverage, 400.0 / 1_100))
        #expect(share.classifiedItems == 2 && share.unclassifiedItems == 2)
    }

    @Test func ultraProcessedShareIsAbsentWhenNothingIsClassified() throws {
        let context = try LongevityStore()
        func lens(_ items: [FoodItem], complete: [String] = ["2026-10-19"]) throws -> FoodLongevityLens {
            FoodLongevityLens(week: week, data: try data(context, meals: [(19, 12, items)], complete: complete))
        }
        // Typed food, a barcode without a group, and a classified item without a known energy all leave it absent.
        #expect(try lens([Longevity.typedItem(nutrients: [.energy: 500])]).ultraProcessed == nil)
        #expect(try lens([Longevity.scannedItem(nova: nil, energy: 500)]).ultraProcessed == nil)
        #expect(try lens([Longevity.scannedItem(nova: 4, energy: nil)]).ultraProcessed == nil)
        #expect(try lens([Longevity.scannedItem(nova: 4, energy: 0)]).ultraProcessed == nil)
        #expect(try lens([Longevity.scannedItem(nova: 4, energy: 500)], complete: []).ultraProcessed == nil)
        // Groups 1 to 3 are classified as not ultra-processed: a share of zero, with its coverage.
        let calmLens = try lens([Longevity.scannedItem(nova: 3, energy: 250), Longevity.typedItem(nutrients: [.energy: 750])])
        let calm = try #require(calmLens.ultraProcessed)
        #expect(calm.share == 0 && Longevity.close(calm.coverage, 0.25))
        let allLens = try lens([Longevity.scannedItem(nova: 4, energy: 250)])
        let all = try #require(allLens.ultraProcessed)
        #expect(all.share == 1 && all.coverage == 1 && all.unclassifiedItems == 0)
    }

    @Test func aDayWithNoDrinkLoggedIsNotAlcoholFreeUntilThePersonSaysNone() throws {
        let context = try LongevityStore()
        let beer = try Longevity.drink(.alcohol, on: "2026-10-20")
        let coffee = try Longevity.drink(.caffeine, on: "2026-10-19")
        let lateBeer = try Longevity.drink(.alcohol, on: "2026-10-22")
        let meals: [(day: Int, hour: Int, items: [FoodItem])] = [
            (19, 12, [Longevity.typedItem()]),
            (21, 12, [Longevity.typedItem(nutrients: [.alcoholUnits: 0])]),
            (23, 12, [Longevity.typedItem(nutrients: [.alcoholUnits: 1])]),
        ]
        var input = try data(context, meals: meals, complete: ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-23"], drinks: [beer, coffee, lateBeer])
        // Nothing was marked: the 19th (coffee only) and the 21st (a reported zero in a meal) are unanswered. The 20th has a
        // beer and the 23rd an item with alcohol, so they are answered as drinking days.
        var result = try #require(FoodLongevityLens(week: week, data: input).alcoholFree)
        #expect(result.alcoholFree == 0 && result.answered == 2 && result.completeDays == 4)
        // "None today" on the 19th and the 21st answers them. The 23rd has alcohol, so its mark does not stand.
        input = FoodOverviewData(meals: input.meals, drinks: input.drinks, days: try [
            Longevity.completeDay("2026-10-19", noAlcohol: true), Longevity.completeDay("2026-10-20"),
            Longevity.completeDay("2026-10-21", noAlcohol: true), Longevity.completeDay("2026-10-23", noAlcohol: true),
        ], targets: [])
        result = try #require(FoodLongevityLens(week: week, data: input).alcoholFree)
        #expect(result.alcoholFree == 2 && result.answered == 4 && result.completeDays == 4)
        // Finished days with no answer at all leave the tile without a number.
        let quiet = try data(context, meals: [(19, 12, [Longevity.typedItem()])], complete: ["2026-10-19", "2026-10-20"])
        #expect(FoodLongevityLens(week: week, data: quiet).alcoholFree == nil)
        let none = try data(context, meals: [], complete: [], drinks: [beer])
        #expect(FoodLongevityLens(week: week, data: none).alcoholFree == nil)
    }

    @Test func lastMealToBedIsWholeMinutesFromTheLastMealBeforeBedtime() throws {
        let context = try LongevityStore()
        let dinner = try context.meal(at: Longevity.instant(2026, 10, 21, 19, 30), zone: Longevity.berlin, items: [Longevity.typedItem()])
        let snack = try context.meal(at: Longevity.instant(2026, 10, 21, 21, 0), zone: Longevity.berlin, items: [Longevity.typedItem()])
        let breakfast = try context.meal(at: Longevity.instant(2026, 10, 22, 7, 0), zone: Longevity.berlin, items: [Longevity.typedItem()])
        let bed = Longevity.instant(2026, 10, 21, 23, 15)
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: bed, meals: [dinner, snack, breakfast]) == 135)
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: bed.addingTimeInterval(59), meals: [dinner, snack]) == 135)
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: bed, meals: [dinner]) == 225)
        // Nothing within 24 hours, nothing before bed, or no meals.
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: Longevity.instant(2026, 10, 22, 21, 0), meals: [dinner]) == nil)
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: Longevity.instant(2026, 10, 21, 6, 0), meals: [dinner, snack]) == nil)
        #expect(FoodLongevityLens.minutesFromLastMeal(toBedAt: bed, meals: []) == nil)
        // Through the lens: no bedtime means no value.
        let input = FoodOverviewData(meals: [dinner, snack], drinks: [], days: [], targets: [])
        #expect(FoodLongevityLens(week: week, data: input, bedtime: bed).lastMealToBedMinutes == 135)
        #expect(FoodLongevityLens(week: week, data: input, bedtime: nil).lastMealToBedMinutes == nil)
        #expect(FoodLongevityLens(week: week, data: .init(meals: [], drinks: [], days: [], targets: []), bedtime: bed).lastMealToBedMinutes == nil)
    }

    @Test func theLensFromDaySummariesMatchesTheLensFromData() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, 8, [Longevity.scannedItem(nova: 4, energy: 300, nutrients: [.protein: 20, .fibre: 4]), Longevity.typedItem(nutrients: [.protein: 100, .fibre: 20])]),
            (20, 19, [Longevity.typedItem(nutrients: [.protein: 120, .fibre: 30, .energy: 600])]),
            (22, 12, [Longevity.typedItem(nutrients: [.protein: 10])]),
        ], complete: ["2026-10-19", "2026-10-20"], drinks: [try Longevity.drink(.alcohol, on: "2026-10-20")])
        let calendar = Longevity.calendar(Longevity.berlin)
        let summaries = try week.days.map { day -> FoodDaySummary in
            let parts = day.split(separator: "-").compactMap { Int($0) }
            return try FoodDaySummary(date: Longevity.instant(parts[0], parts[1], parts[2]), calendar: calendar, data: input)
        }
        let bed = Longevity.instant(2026, 10, 20, 23, 0)
        let fromData = FoodLongevityLens(week: week, data: input, bodyWeightKilograms: 80, bedtime: bed)
        let fromSummaries = FoodLongevityLens(week: week, summaries: summaries, bodyWeightKilograms: 80, bedtime: bed)
        #expect(fromData == fromSummaries)
        #expect(fromData.completeDays == 2 && fromData.lastMealToBedMinutes == 240)
        #expect(Longevity.close(fromData.proteinPerKilogram?.value, 1.5) && Longevity.close(fromData.fibrePerDay?.value, 27))
        // The 20th has a beer; the 19th has no mark, so only one day is answered, as drinking.
        #expect(fromData.alcoholFree == FoodAlcoholFreeDays(alcoholFree: 0, answered: 1, completeDays: 2))
    }
}
