import DomainKit
import FoodKit
import Foundation
import Testing
@testable import Loopr

/// The Food tab's longevity loader against the populated Food fixture, whose day is 14 Nov 2023 in Perth.
@MainActor struct FoodLongevityLoaderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }
    private let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
    /// 13:30 in Perth on the fixture clock's day, the day `AppFoodFixtures` seeds as today (14 Nov 2023).
    private var date: Date {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = utc.dateComponents([.year, .month, .day], from: environment.dateProvider.now())
        parts.hour = 13; parts.minute = 30
        return calendar.date(from: parts)!
    }

    private func repository() -> AppFoodRepository {
        ProductRepositoryContainer(environment: environment).fixtureFoodRepository
    }

    @Test func theFixtureHasTheContractStackTheKitchenRuleAndAWeekOfPlants() async throws {
        let repository = repository()
        let snapshot = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: nil)
        #expect(snapshot.targets.kitchenClosesMinute == 1_110 && snapshot.targets.fibreGrams == 35)
        let stack = try #require(snapshot.stack)
        #expect(stack.localDay == "2023-11-14")
        #expect(stack.supplementsHeadline == "6 of 7 taken")
        #expect(stack.evening.map(\.key) == ["supplement-mg-evening"])
        let plants = try #require(snapshot.plants)
        // Fourteen named on the dishes, and hazelnut from the oat bar's ingredients.
        #expect(plants.count == 15 && plants.week.id == "2023-W46")
        #expect(plants.plants.first { $0.key == "hazelnut" }?.sources == [.openFoodFacts])
        #expect(plants.plants.first { $0.key == "oats" }?.sources == [.edit, .openFoodFacts])
        #expect(snapshot.weekMeals.allSatisfy { plants.week.contains(localDay: $0.localDay) } && snapshot.weekMeals.count == 6)
        #expect(snapshot.lens.week == plants.week)
    }

    /// Yesterday is the week's one finished day: 139 g of protein over 78.4 kg, and 110 of 410 classified kcal from the
    /// group 4 oat bar.
    @Test func theFixtureLensHasProteinPerKilogramAndAnUltraProcessedShare() async throws {
        let repository = repository()
        let weights = try await repository.weights(since: date.addingTimeInterval(-60 * 86_400))
        let weight = try #require(FoodWeightTrend(weights)).current
        #expect(weight == 78.4)
        let snapshot = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: weight)
        #expect(try FoodMeal.day(at: date, timeZoneIdentifier: "Australia/Perth") == "2023-11-14")
        #expect(snapshot.lens.completeDays == 1)
        #expect(abs((snapshot.lens.proteinPerKilogram?.value ?? 0) - 139 / 78.4) < 1e-9)
        #expect(snapshot.lens.fibrePerDay?.value == 37)
        let share = try #require(snapshot.lens.ultraProcessed)
        #expect(abs(share.share - 110.0 / 410) < 1e-9 && share.classifiedItems == 2)
        #expect(snapshot.barcodedItems == 2)
        let tiles = FoodLensTiles.tiles(lens: snapshot.lens, bodyWeightKilograms: weight, barcodedItems: snapshot.barcodedItems,
                                        proteinTarget: 150, fibreTarget: snapshot.targets.fibreGrams)
        let protein = try #require(tiles.first { $0.kind == .protein })
        let upf = try #require(tiles.first { $0.kind == .upf })
        // One finished day is too few for a weekly number: the lens has it, the tiles hold it back.
        #expect(protein.isAbsent && upf.isAbsent)
        #expect(protein.note == "1 of 3 finished days so far" && upf.note == "1 of 3 finished days so far")
        // Today's meals and calories are as before.
        let today = try await repository.overview(from: "2023-11-14", through: "2023-11-14")
        #expect(today.meals.count == 2 && FoodNutrientTotal(.energy, items: today.meals.flatMap(\.items)).knownValue == 1_232)
    }

    /// The rolling seven days the Food model loads hold six finished days; the week, Monday to Tuesday, holds one. The
    /// week chart's line and the lens both say one (ICP R2-UPG-8: "0 of 6" beside "1 of 3").
    @Test func theWeekChartAndTheLensCountTheSameFinishedDays() async throws {
        let repository = repository()
        let model = FoodOverviewModel(repository: repository, body: nil)
        await model.load(date: date, calendar: calendar)
        let day = try #require(model.day)
        #expect(model.week.filter(\.isCompleted).count == 6)
        let soFar = try #require(FoodWeekSoFar(day: day, summaries: model.week))
        let snapshot = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: 78.4)
        #expect(soFar.week == snapshot.lens.week)
        #expect(soFar.finishedDays == snapshot.lens.completeDays && soFar.finishedDays == 1)
        #expect(soFar.onTargetLine.hasSuffix("of 1 finished day"))
        let tiles = FoodLensTiles.tiles(lens: snapshot.lens, bodyWeightKilograms: 78.4, barcodedItems: snapshot.barcodedItems,
                                        proteinTarget: 150, fibreTarget: snapshot.targets.fibreGrams)
        #expect(tiles.allSatisfy { $0.note == "\(soFar.finishedDays) of 3 finished days so far" })
    }

    @Test func aTickIsSavedAndASecondTapTakesItBack() async throws {
        let repository = repository()
        let stack = try #require(try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: nil).stack)
        let magnesium = try #require(stack.evening.first)
        try await repository.toggleDose(magnesium, day: stack.localDay, at: date)
        let ticked = try await repository.stackShelf(localDay: stack.localDay)
        #expect(ticked.supplementsHeadline == "7 of 7 taken")
        try await repository.toggleDose(try #require(ticked.evening.first), day: stack.localDay, at: date)
        #expect(try await repository.stackShelf(localDay: stack.localDay).supplementsHeadline == "6 of 7 taken")
    }

    @Test func removingAPlantTakesItOffTheWeekAndAddingPutsItOnOneMeal() async throws {
        let repository = repository()
        let before = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: nil)
        let week = try #require(before.plants).week
        #expect(before.plants?.plants.contains { $0.key == "avocado" } == true)
        try await repository.removePlant(key: "avocado", week: week, at: date)
        let removed = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: nil)
        #expect(removed.plants?.plants.contains { $0.key == "avocado" } == false)
        #expect(removed.plants?.count == 14)

        let lunch = try #require(removed.weekMeals.first { $0.slot == .lunch })
        try await repository.addPlant(named: "Avocados", toMeal: lunch.id, at: date)
        let added = try await repository.longevity(date: date, calendar: calendar, bodyWeightKilograms: nil)
        #expect(added.plants?.plants.first { $0.key == "avocado" }?.itemCount == 1)
        // Meal counts and calories do not change.
        #expect(added.weekMeals.count == before.weekMeals.count)
        await #expect(throws: FoodError.invalidRecord) { try await repository.addPlant(named: "sugar", toMeal: lunch.id, at: date) }
    }

    @Test func theModelCutsAStickerForThePhotographedMealAndSettlesOnRequest() async throws {
        let repository = repository()
        let data = try await repository.overview(from: "2023-11-14", through: "2023-11-14")
        let day = try FoodDaySummary(date: date, calendar: calendar, data: data)
        let model = FoodLongevityModel()
        #expect(!model.state.isLoaded)
        await model.load(repository: repository, date: date, calendar: calendar, day: day, bodyWeightKilograms: 80)
        #expect(model.state.isLoaded && model.state.bodyWeightKilograms == 80)
        let lunch = try #require(day.meals.first { !$0.photos.isEmpty })
        #expect(model.state.stickers.keys.sorted { $0.uuidString < $1.uuidString } == [lunch.id])
        #expect(model.state.stack?.supplementsHeadline == "6 of 7 taken")
        model.settle()
        #expect(model.state.settleToken == 1)

        let magnesium = try #require(model.state.stack?.evening.first)
        #expect(try await model.toggle(magnesium, repository: repository, at: date))
        #expect(model.state.stack?.supplementsHeadline == "7 of 7 taken")
    }
}
