import BodyKit
import DataKit
import DesignSystem
import DomainKit
import FoodKit
import Foundation
import JournalKit
import SleepKit
import StorageKit
import Testing
@testable import Loopr

@MainActor struct FoodOverviewIntegrationTests {
    @Test func populatedFixtureActorAcceptsWaterAfterOverviewRead() async throws {
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let container = ProductRepositoryContainer(environment: environment)
        let repository = container.fixtureFoodRepository
        _ = try await repository.overview(from: "2023-11-08", through: "2023-11-14")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let date = calendar.date(from: .init(year: 2023, month: 11, day: 14, hour: 13, minute: 30))!
        let drink = try FoodDrinkFormInput(kind: .water, name: "Water", amount: "300", energy: "",
            protein: "", carbs: "", fat: "", occurredAt: date).drink(now: date, timeZoneIdentifier: calendar.timeZone.identifier)
        try await repository.confirmDrink(drink)
        let data = try await repository.overview(from: "2023-11-14", through: "2023-11-14")
        #expect(try FoodDaySummary(date: date, calendar: calendar, data: data).water == 1_500)
    }
    @Test func waterFormWithBlankOptionalNutrientsSavesIntoPopulatedDay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodWaterForm-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        try AppFoodFixtures.seed(store, endingOn: anchor)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let date = calendar.date(from: .init(year: 2023, month: 11, day: 14, hour: 13, minute: 30))!
        let input = FoodDrinkFormInput(kind: .water, name: "Water", amount: "300", energy: "",
            protein: "", carbs: "", fat: "", occurredAt: date)
        let drink = try input.drink(now: date, timeZoneIdentifier: calendar.timeZone.identifier)
        try store.confirmDrink(drink)
        let data = try store.overview(from: "2023-11-14", through: "2023-11-14")
        #expect(try FoodDaySummary(date: date, calendar: calendar, data: data).water == 1_500)
    }
    @Test func journalFindsIntakeAcrossDateLineAndDoesNotReuseAnotherZonesCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodTravel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        let repository = AppFoodRepository(store: store, environment: .production())
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let start = calendar.date(from: .init(year: 2026, month: 10, day: 13))!
        let drinkTime = start.addingTimeInterval(3_600)
        let drink = try FoodDrink(kind: .alcohol, name: "Wine", occurredAt: drinkTime,
            timeZoneIdentifier: "Pacific/Honolulu", caffeineMilligrams: 0, alcoholUnits: 1, confirmedAt: drinkTime)
        #expect(drink.localDay == "2026-10-12")
        try store.confirmDrink(drink)
        let provider = AppFoodJournalProvider(repository: repository, sleep: nil)
        let day = DayIdentity(year: 2026, month: 10, day: 13)
        let intake = try await provider.foodDay(for: day, timeZoneID: calendar.timeZone.identifier)
        #expect(try JournalAutoFillProjection.snapshot(day: day, timeZoneID: calendar.timeZone.identifier,
            food: intake).answers[.alcohol]?.answer == .yes)
        try store.deleteDrink(id: drink.id)
        // Tokyo's day starts before Perth's. Completion describes a different
        // interval even though both calendars spell the date identically.
        try store.confirmDayComplete(on: start.addingTimeInterval(12 * 3_600), timeZoneIdentifier: "Asia/Tokyo",
            at: start.addingTimeInterval(23 * 3_600))
        #expect(try await provider.foodDay(for: day, timeZoneID: calendar.timeZone.identifier).completion == nil)
    }
    @Test func realFoodAndDrinkRecordsProvideJournalEvidenceAndWithdrawAfterRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodJournal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        let actor = AppFoodRepository(store: store, environment: .production())
        let day = DayIdentity(year: 2026, month: 10, day: 13), next = DayIdentity(year: 2026, month: 10, day: 14)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let start = calendar.date(from: .init(year: 2026, month: 10, day: 13))!
        let mealTime = start.addingTimeInterval(21.5 * 3_600), bedtime = start.addingTimeInterval(23 * 3_600)
        let item = FoodItem(name: "Dinner", amount: 1, unit: .serving, nutrients: .init([.alcoholUnits: 0, .caffeine: 0]),
            provenance: [.init(source: .typed, recordedAt: mealTime)])
        let meal = try store.confirm(.init(slot: .dinner, occurredAt: mealTime, timeZoneIdentifier: calendar.timeZone.identifier, items: [item]), at: mealTime)
        let sleep = SleepDaySnapshot(day: next, state: .partial,
            mainSleep: .init(id: "food-test-night", start: bedtime, end: bedtime.addingTimeInterval(8 * 3_600),
                durationMinutes: 480, isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial),
            naps: [], metrics: [], hypnogram: [], trend: [], needHours: nil, debtHours: nil, source: "Band", algorithmVersion: "test")
        let provider = AppFoodJournalProvider(repository: actor, sleep: InMemorySleepRepository(values: [next: sleep]))
        func snapshot() async throws -> JournalAutoFillSnapshot {
            try JournalAutoFillProjection.snapshot(day: day, timeZoneID: calendar.timeZone.identifier,
                food: await provider.foodDay(for: day, timeZoneID: calendar.timeZone.identifier))
        }
        let initial = try await snapshot()
        #expect(initial.answers[.lateMeal]?.answer == .yes)
        #expect(initial.answers[.lateMeal]?.provenance.records.contains { $0.domain == .sleep } == true)
        #expect(initial.answers[.alcohol] == nil && initial.answers[.lateCaffeine] == nil)
        try store.confirmDayComplete(on: start, timeZoneIdentifier: calendar.timeZone.identifier, at: bedtime)
        #expect(try await snapshot().answers[.alcohol]?.answer == .no)
        let coffeeTime = start.addingTimeInterval(15 * 3_600)
        let coffee = try FoodDrink(kind: .caffeine, name: "Afternoon coffee", occurredAt: coffeeTime,
            timeZoneIdentifier: calendar.timeZone.identifier, caffeineMilligrams: 95, alcoholUnits: 0, confirmedAt: coffeeTime)
        try store.confirmDrink(coffee)
        let filled = try await snapshot()
        #expect(filled.answers[.lateCaffeine]?.answer == .yes && filled.answers[.alcohol] == nil)
        #expect(filled.answers[.lateCaffeine]?.provenance.records.first?.id == "food-drink:\(coffee.id.uuidString)")
        try store.deleteDrink(id: coffee.id); try store.deleteMeal(id: meal.id, expectedRevision: meal.revision)
        #expect(try await snapshot().answers.isEmpty)
        try database.write { db in try db.execute(sql: "INSERT INTO food_drink VALUES ('corrupt', '2026-10-13', 0, X'01')") }
        await #expect(throws: (any Error).self) { try await snapshot() }
    }

    @Test func foodUsesOnlyTypedQualifiedCanonicalEnergyAndKeepsOldSnapshotsReadable() throws {
        func snapshot(_ metrics: [BodyMetricValue]) -> BodyDaySnapshot {
            .init(day: .init(year: 2026, month: 10, day: 13), state: .partial, metrics: metrics,
                composition: .init(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
                cardioAge: nil, looprAge: nil, source: "Band")
        }
        let legacy = BodyMetricValue(id: .energy, title: "Energy", value: "999,999", unit: "kcal", state: .partial, source: "Band")
        #expect(FoodOverviewModel.context(snapshot([legacy])).0 == nil)
        let qualified = BodyMetricValue(id: .energy, title: "Energy", value: "localised text", unit: "kcal", state: .partial,
            source: "Band", algorithmVersion: "test", numericValue: 300, numericUnit: .kilocalories, qualityQualified: true)
        #expect(FoodOverviewModel.context(snapshot([qualified])).0?.energy == 300)
        let poor = BodyMetricValue(id: .energy, title: "Energy", value: "300", unit: "kcal", state: .lowConfidence,
            source: "Band", algorithmVersion: "test", numericValue: 300, numericUnit: .kilocalories, qualityQualified: false)
        #expect(FoodOverviewModel.context(snapshot([poor])).0 == nil)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(qualified)) as? [String: Any])
        old.removeValue(forKey: "numericValue"); old.removeValue(forKey: "numericUnit"); old.removeValue(forKey: "qualityQualified")
        let decoded = try JSONDecoder().decode(BodyMetricValue.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.numericValue == nil && decoded.qualityQualified == nil)
    }

    @Test func productAndFixtureBackupDayDeletionIncludeDrinksCompletionAndTargetHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodOverviewLifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite")); defer { try? database.databasePool.close() }
        let store = FoodStore(database: database), now = Date(timeIntervalSince1970: 1_700_000_000)
        let drink = try FoodDrink(kind: .water, name: "Water", occurredAt: now, timeZoneIdentifier: "Australia/Perth", waterMillilitres: 250, confirmedAt: now)
        try store.confirmDrink(drink)
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2_000, confirmedAt: now))
        try store.confirmDayComplete(on: now, timeZoneIdentifier: "Australia/Perth", at: now)
        let repository = try SQLiteDataRepository(database: database)
        let backup = try await repository.exportBackupChecked()
        let fixture = DataRepository(); try await fixture.restore(backup)
        await fixture.deleteDay(drink.localDay)
        #expect(await fixture.exportBackup().food?.drinks.isEmpty == true)
        #expect(await fixture.exportBackup().food?.days.isEmpty == true)
        #expect(await fixture.exportBackup().food?.targets.count == 1)
        try await repository.deleteDayChecked(drink.localDay)
        #expect(try store.drinks().isEmpty && store.dayRecord(drink.localDay) == nil)
        try await repository.restoreChecked(backup)
        #expect(try store.exportArchive() == backup.food)
        try await repository.completeDeletionChecked()
        #expect(try store.targetSettings() == nil && store.drinks().isEmpty && store.exportArchive().days.isEmpty)
    }
}
