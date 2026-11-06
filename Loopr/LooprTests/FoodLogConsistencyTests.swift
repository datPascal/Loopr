import BodyKit
import DesignSystem
import DomainKit
import FoodKit
import Foundation
import StorageKit
import Testing
@testable import Loopr

/// Food, Today and Ask read the same day the same way, and Food takes numbers typed on any keypad.
struct FoodLogConsistencyTests {
    @Test func aDecimalCommaReadsLikeADecimalPoint() throws {
        #expect(try FoodInput.number("2,5") == 2.5)
        #expect(try FoodInput.number(" 2.5 ") == 2.5)
        #expect(try FoodInput.number("", optional: true) == nil)
        #expect(throws: FoodError.self) { try FoodInput.number("2,5,1") }
        #expect(throws: FoodError.self) { try FoodInput.number("-1") }
        #expect(FoodInput.parse("0,75") == 0.75)
    }

    @Test func prefilledNumbersUseThePhonesDecimalSeparator() {
        #expect(FoodInput.text(2.5, locale: Locale(identifier: "de_DE")) == "2,5")
        #expect(FoodInput.text(2.5, locale: Locale(identifier: "en_AU")) == "2.5")
        #expect(FoodInput.text(2500, locale: Locale(identifier: "de_DE")) == "2500")
        #expect(FoodInput.text(nil) == "")
    }

    @Test func aDrinkRowNamesItsAmount() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func drink(_ kind: FoodDrinkKind, _ amount: Double) throws -> FoodDrink {
            try FoodDrink(kind: kind, name: "Drink", occurredAt: now, timeZoneIdentifier: "Australia/Perth",
                          waterMillilitres: kind == .water ? amount : nil, caffeineMilligrams: kind == .caffeine ? amount : nil,
                          alcoholUnits: kind == .alcohol ? amount : nil, confirmedAt: now)
        }
        #expect(FoodDrinkEditor.amount(try drink(.water, 500)) == "500 ml")
        #expect(FoodDrinkEditor.amount(try drink(.caffeine, 95)) == "95 mg caffeine")
        #expect(FoodDrinkEditor.amount(try drink(.alcohol, 1)) == "1 unit")
    }

    /// With "Adjust for active energy" on, the target adds what the body data says was burned so far. Today's food row
    /// and Ask used to show the base target while the Food tab showed the adjusted one.
    @Test func theSharedSummaryAddsQualifiedActiveEnergyWhenTheTargetAdjusts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodLogConsistency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite")); defer { try? database.databasePool.close() }
        let store = FoodStore(database: database)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12)))
        try store.confirmTarget(.init(goal: .maintain, baseEnergy: 2_000, adjustsForActiveEnergy: true, confirmedAt: noon.addingTimeInterval(-86_400)))
        let data = try store.overview(from: "2026-10-13", through: "2026-10-13")
        let energy = BodyMetricValue(id: .energy, title: "Energy", value: "350", unit: "kcal", state: .partial,
            source: "Band", algorithmVersion: "test", numericValue: 350, numericUnit: .kilocalories, qualityQualified: true)
        let day = DayIdentity(year: 2026, month: 10, day: 13)
        let body = InMemoryBodyRepository(values: [day: BodyDaySnapshot(day: day, state: .partial, metrics: [energy],
            composition: .init(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"), cardioAge: nil, looprAge: nil, source: "Band")])

        let adjusted = try await FoodOverviewModel.summary(date: noon, calendar: calendar, data: data, body: body)
        #expect(adjusted.summary.target.energy == 2_350 && !adjusted.bodyFailed)
        let withoutBody = try await FoodOverviewModel.summary(date: noon, calendar: calendar, data: data, body: nil)
        #expect(withoutBody.summary.target.energy == 2_000)
        let today = TodayFoodFacts(adjusted.summary)
        #expect(today.energyTarget == 2_350, "Today's row shows the target the Food tab shows")
        #expect(LooprAgentDataSource.row(adjusted.summary).targets?.energy == 2_350, "and so does Ask")
    }
}
