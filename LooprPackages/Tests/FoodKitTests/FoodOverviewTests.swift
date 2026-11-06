import FoodKit
import Foundation
import StorageKit
import Testing

struct FoodTargetTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    @Test func goalsPreserveConfirmedBaseInsteadOfInventingOffsets() throws {
        for goal in FoodGoal.allCases {
            let result = try FoodTarget.resolve(settings: .init(goal: goal, baseEnergy: 2_000, confirmedAt: now), plan: nil, active: nil, actualStrain: nil)
            #expect(result.energy == 2_000 && result.adjustment == 0 && !result.isEstimated)
            #expect(result.reason.contains(goal.rawValue))
        }
        #expect(try FoodTarget.resolve(settings: nil, plan: nil, active: nil, actualStrain: nil).energy == nil)
    }
    @Test func actualEnergyReplacesAllowanceWithoutDoubleCountingOrLoweringAnUnfinishedPlan() throws {
        let settings = FoodTargetSettings(goal: .build, baseEnergy: 2_270, adjustsForActiveEnergy: true, confirmedAt: now)
        let plan = FoodTrainingAllowance(title: "Upper A", energy: 180, plannedStrain: .init(value: 12, scale: .daily21), confirmedAt: now)
        func actual(_ value: Double, qualified: Bool = true) -> FoodActiveEnergy {
            .init(energy: value, source: "Band", algorithmVersion: "test", hasUsableProfileAndWear: qualified)
        }
        let planned = try FoodTarget.resolve(settings: settings, plan: plan, active: actual(50), actualStrain: .init(value: 4, scale: .daily21))
        #expect(planned.energy == 2_450 && planned.reason.contains("Upper A") && !planned.isEstimated)
        let observed = try FoodTarget.resolve(settings: settings, plan: plan, active: actual(300), actualStrain: .init(value: 15, scale: .daily21))
        #expect(observed.energy == 2_570 && observed.isEstimated && observed.reason.contains("so far"))
        #expect(observed.source == "Band")
        let unavailable = try FoodTarget.resolve(settings: settings, plan: plan, active: actual(300, qualified: false), actualStrain: .init(value: 90, scale: .workout100))
        #expect(unavailable.energy == 2_450 && unavailable.actualStrain?.scale == .workout100)
        let removed = try FoodTarget.resolve(settings: settings, plan: nil, active: nil, actualStrain: nil)
        #expect(removed.energy == 2_270 && removed.reason.contains("More profile and wear data"))
    }
    @Test func manualBaseIgnoresEnergyUntilOptInAndInvalidInputsFail() throws {
        let settings = FoodTargetSettings(goal: .lose, baseEnergy: 2_000, confirmedAt: now)
        let energy = FoodActiveEnergy(energy: 900, source: "Band", algorithmVersion: "test", hasUsableProfileAndWear: true)
        #expect(try FoodTarget.resolve(settings: settings, plan: nil, active: energy, actualStrain: nil).energy == 2_000)
        #expect(throws: FoodError.invalidRecord) {
            try FoodTarget.resolve(settings: settings, plan: nil, active: nil, actualStrain: .init(value: 22, scale: .daily21))
        }
        #expect(throws: FoodError.invalidRecord) {
            try FoodTarget.resolve(settings: .init(goal: .lose, baseEnergy: .nan, confirmedAt: now), plan: nil, active: nil, actualStrain: nil)
        }
        #expect(throws: FoodError.invalidRecord) {
            try FoodTarget.resolve(settings: .init(goal: .lose, baseEnergy: .greatestFiniteMagnitude, confirmedAt: now),
                plan: .init(title: "Plan", energy: .greatestFiniteMagnitude, confirmedAt: now), active: nil, actualStrain: nil)
        }
    }
    @Test func historicalSettingsAndCivilDaysSurviveDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: .init(year: 2026, month: 3, day: 8))!
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        #expect(end.timeIntervalSince(day) == 23 * 3_600)
        let old = FoodTargetSettings(goal: .maintain, baseEnergy: 2_000, confirmedAt: day.addingTimeInterval(-1))
        let new = FoodTargetSettings(goal: .build, baseEnergy: 2_300, confirmedAt: end)
        let data = FoodOverviewData(meals: [], drinks: [], days: [], targets: [new, old])
        let snapshot = try FoodDaySummary(date: day, calendar: calendar, data: data)
        #expect(snapshot.localDay == "2026-03-08" && snapshot.target.energy == 2_000)
        #expect(snapshot.total(.energy).knownValue == nil && snapshot.water == nil)
        #expect(try FoodDaySummary(date: end, calendar: calendar, data: data).target.energy == 2_300)
    }
    @Test func completionCanDeclareAnEmptyDayButCannotMakeUnknownNutrientsZero() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let day = try FoodDayRecord(dayStart: now, timeZoneIdentifier: calendar.timeZone.identifier, completedAt: now)
        let empty = try FoodDaySummary(date: now, calendar: calendar, data: .init(meals: [], drinks: [], days: [day], targets: []))
        #expect(empty.total(.energy).knownValue == 0 && empty.total(.energy).isComplete)
        let drink = try FoodDrink(kind: .caffeine, name: "Coffee", occurredAt: now, timeZoneIdentifier: calendar.timeZone.identifier,
            caffeineMilligrams: 95, confirmedAt: now)
        let partial = try FoodDaySummary(date: now, calendar: calendar, data: .init(meals: [], drinks: [drink], days: [day], targets: []))
        #expect(partial.total(.energy).knownValue == nil && !partial.total(.energy).isComplete)
        #expect(partial.total(.caffeine).knownValue == 95)
        // A coffee is logged as a caffeine drink and alcohol as its own drink, so a coffee carries no alcohol (DEC-08).
        #expect(partial.total(.alcoholUnits).knownValue == 0 && partial.total(.alcoholUnits).isComplete)
    }
}

private final class FoodOverviewDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodOverview-\(UUID())")
    let database: StorageDatabase
    var store: FoodStore { .init(database: database) }
    init() throws { database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite")) }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

struct FoodOverviewStoreTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let zone = "Australia/Perth"
    @Test func drinksTargetsAndCompletionSurviveRestartAndBothArchives() throws {
        let context = try FoodOverviewDatabase(); let store = context.store
        let drink = try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: zone,
            waterMillilitres: 250, caffeineMilligrams: 0, alcoholUnits: 0, energy: 0, confirmedAt: now)
        let target = FoodTargetSettings(goal: .maintain, baseEnergy: 2_000, confirmedAt: now)
        try store.confirmDrink(drink)
        try store.confirmConfiguration(target: target, allowance: .init(title: "Walk", energy: 100, confirmedAt: now), on: now, timeZoneIdentifier: zone)
        try store.confirmDayComplete(on: now, timeZoneIdentifier: zone, at: now)
        let archive = try store.exportArchive()
        let encoded = try JSONEncoder().encode(archive)
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path)
        defer { try? reopened.databasePool.close() }
        let replacement = FoodStore(database: reopened)
        #expect(try replacement.exportArchive() == archive)
        try replacement.deleteAll()
        try replacement.restore(JSONDecoder().decode(FoodArchive.self, from: encoded))
        #expect(try replacement.exportArchive() == archive)
        let snapshot = context.root.appendingPathComponent("export.sqlite")
        try reopened.export(to: snapshot)
        let copied = try StorageDatabase(url: snapshot); defer { try? copied.databasePool.close() }
        #expect(try FoodStore(database: copied).exportArchive() == archive)
    }
    @Test func changingIntakeReopensItsDayAndCrossDayMealEditsReopenBoth() throws {
        let context = try FoodOverviewDatabase(); let store = context.store
        let key = try FoodMeal.day(at: now, timeZoneIdentifier: zone)
        let tomorrow = now.addingTimeInterval(86_400); let nextKey = try FoodMeal.day(at: tomorrow, timeZoneIdentifier: zone)
        let item = FoodItem(name: "Rice", amount: 1, unit: .serving, provenance: [.init(source: .typed, recordedAt: now)])
        let saved = try store.confirm(.init(slot: .lunch, occurredAt: now, timeZoneIdentifier: zone, items: [item]), at: now)
        try store.confirmDayComplete(on: now, timeZoneIdentifier: zone, at: now)
        try store.confirmDayComplete(on: tomorrow, timeZoneIdentifier: zone, at: tomorrow)
        var edit = try store.editDraft(id: saved.id); edit.occurredAt = tomorrow
        try store.confirm(edit, at: tomorrow)
        #expect(try store.dayRecord(key)?.completedAt == nil && store.dayRecord(nextKey)?.completedAt == nil)
        try store.confirmDayComplete(on: tomorrow, timeZoneIdentifier: zone, at: tomorrow)
        let drink = try FoodDrink(kind: .alcohol, name: "Wine", occurredAt: tomorrow, timeZoneIdentifier: zone, alcoholUnits: 1, confirmedAt: tomorrow)
        try store.confirmDrink(drink)
        #expect(try store.dayRecord(nextKey)?.completedAt == nil)
        try store.confirmDayComplete(on: tomorrow, timeZoneIdentifier: zone, at: tomorrow)
        try store.deleteDrink(id: drink.id)
        #expect(try store.dayRecord(nextKey)?.completedAt == nil)
    }
    /// Food and your body's row counts finished days in its window; days left open do not count.
    @Test func finishedDaysAreCountedInTheWindowOnly() throws {
        let context = try FoodOverviewDatabase(); let store = context.store
        let days = (0..<4).map { now.addingTimeInterval(Double($0) * 86_400) }
        for day in days { try store.confirmDayComplete(on: day, timeZoneIdentifier: zone, at: day) }
        try store.reopenDay(FoodMeal.day(at: days[1], timeZoneIdentifier: zone))
        try store.setNoAlcohol(true, on: days[3].addingTimeInterval(86_400), timeZoneIdentifier: zone, at: now)
        let first = try FoodMeal.day(at: days[0], timeZoneIdentifier: zone)
        #expect(try store.finishedDayCount(from: first, through: FoodMeal.day(at: days[3].addingTimeInterval(86_400), timeZoneIdentifier: zone)) == 3)
        #expect(try store.finishedDayCount(from: first, through: FoodMeal.day(at: days[1], timeZoneIdentifier: zone)) == 1)
    }
    @Test func failedIntakeAndConfigurationLeaveCompletionAndTargetsUntouched() throws {
        let context = try FoodOverviewDatabase(); let store = context.store
        try store.confirmDayComplete(on: now, timeZoneIdentifier: zone, at: now)
        let before = try store.exportArchive()
        try context.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_day BEFORE UPDATE ON food_day BEGIN SELECT RAISE(ABORT, 'test'); END") }
        let drink = try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: zone, waterMillilitres: 250, confirmedAt: now)
        #expect(throws: (any Error).self) { try store.confirmDrink(drink) }
        #expect(throws: (any Error).self) {
            try store.confirmConfiguration(target: .init(goal: .build, baseEnergy: 2_500, confirmedAt: now), allowance: nil, on: now, timeZoneIdentifier: zone)
        }
        #expect(try store.exportArchive() == before)
    }
    @Test func dayDeletionPreservesAdjacentDayAndGoalWhileAccountDeletionClearsAll() throws {
        let context = try FoodOverviewDatabase(); let store = context.store
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2_000, confirmedAt: now))
        for date in [now, now.addingTimeInterval(86_400)] {
            try store.confirmDrink(.init(kind: .water, name: "Water", occurredAt: date, timeZoneIdentifier: zone, waterMillilitres: 250, confirmedAt: date))
            try store.confirmDayComplete(on: date, timeZoneIdentifier: zone, at: date)
        }
        let key = try FoodMeal.day(at: now, timeZoneIdentifier: zone)
        #expect(try store.exportArchive(localDay: key).drinks.count == 1)
        try store.deleteDay(key)
        #expect(try store.drinks().count == 1 && store.dayRecord(key) == nil && store.targetSettings() != nil)
        try store.deleteAll()
        #expect(try store.drinks().isEmpty && store.targetSettings() == nil && store.exportArchive().days.isEmpty)
    }
    @Test func legacyArchiveAndInvalidDrinksFailWithoutPartialRestore() throws {
        let old = try JSONDecoder().decode(FoodArchive.self, from: Data(#"{"schemaVersion":1,"meals":[],"photos":[]}"#.utf8))
        #expect(old.drinks.isEmpty && old.targets.isEmpty)
        #expect(throws: FoodError.invalidRecord) {
            try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: zone, waterMillilitres: -.infinity, confirmedAt: now)
        }
        #expect(throws: FoodError.invalidRecord) {
            try FoodDayRecord(dayStart: now, timeZoneIdentifier: zone, completedAt: now.addingTimeInterval(-86_400))
        }
        #expect(throws: FoodError.invalidRecord) {
            try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: zone,
                waterMillilitres: 250, additionalNutrients: .init([.sugar: 5]), confirmedAt: now)
        }
        #expect(throws: FoodError.invalidRecord) {
            try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: zone,
                waterMillilitres: 250, energy: 10, confirmedAt: now)
        }
    }
}


struct FoodNoAlcoholTests {
    private func drink(_ context: LongevityStore, kind: FoodDrinkKind) throws -> FoodDrink {
        try Longevity.drink(kind, on: "2026-10-20")
    }

    @Test func noneTodayIsMarkedKeptAndTakenBack() throws {
        let context = try LongevityStore()
        let noon = Longevity.instant(2026, 10, 20, 12)
        try context.store.setNoAlcohol(true, on: noon, timeZoneIdentifier: Longevity.berlin, at: noon)
        #expect(try context.store.dayRecord("2026-10-20")?.noAlcoholAt == noon)
        // Completing and reopening the day leaves the answer alone.
        try context.store.confirmDayComplete(on: noon, timeZoneIdentifier: Longevity.berlin, at: noon)
        try context.store.reopenDay("2026-10-20")
        #expect(try context.store.dayRecord("2026-10-20")?.noAlcoholAt == noon)
        try context.store.setNoAlcohol(false, on: noon, timeZoneIdentifier: Longevity.berlin, at: noon)
        #expect(try context.store.dayRecord("2026-10-20")?.noAlcoholAt == nil)
    }

    @Test func aLoggedAlcoholDrinkClearsTheMarkButWaterAndCoffeeDoNot() throws {
        let context = try LongevityStore()
        let noon = Longevity.instant(2026, 10, 20, 12)
        try context.store.setNoAlcohol(true, on: noon, timeZoneIdentifier: Longevity.berlin, at: noon)
        try context.store.confirmDrink(drink(context, kind: .water))
        try context.store.confirmDrink(drink(context, kind: .caffeine))
        #expect(try context.store.dayRecord("2026-10-20")?.noAlcoholAt == noon)
        try context.store.confirmDrink(drink(context, kind: .alcohol))
        #expect(try context.store.dayRecord("2026-10-20")?.noAlcoholAt == nil)
    }

    @Test func aRecordSavedBeforeTheMarkExistedStillDecodes() throws {
        let record = try Longevity.completeDay("2026-10-20")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["noAlcoholAt"] = nil
        let old = try JSONDecoder().decode(FoodDayRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == record && old.noAlcoholAt == nil)
    }
}
