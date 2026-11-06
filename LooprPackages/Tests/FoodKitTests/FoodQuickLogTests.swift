import FoodKit
import Foundation
import Testing

struct FoodQuickLogTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute))!
    }

    @Test func mealSlotFollowsTheTimeOfDay() {
        #expect(FoodMealSlot.suggested(at: at(7, 0), calendar: calendar) == .breakfast)
        #expect(FoodMealSlot.suggested(at: at(10, 29), calendar: calendar) == .breakfast)
        #expect(FoodMealSlot.suggested(at: at(10, 30), calendar: calendar) == .lunch)
        #expect(FoodMealSlot.suggested(at: at(13, 30), calendar: calendar) == .lunch)
        #expect(FoodMealSlot.suggested(at: at(16, 0), calendar: calendar) == .snack)
        #expect(FoodMealSlot.suggested(at: at(19, 0), calendar: calendar) == .dinner)
        #expect(FoodMealSlot.suggested(at: at(0, 30), calendar: calendar) == .breakfast)
    }

    @Test func theLogTileMovesOnOnceTheClockSlotHasAMeal() {
        func next(_ hour: Int, _ minute: Int, _ logged: Set<FoodMealSlot>) -> String {
            let result = FoodMealSlot.toLog(at: at(hour, minute), calendar: calendar, logged: logged)
            return "\(result.slot.rawValue) \(result.isClockSlot)"
        }
        // 13:30 is lunch's time.
        #expect(next(13, 30, []) == "lunch true")
        #expect(next(13, 30, [.breakfast]) == "lunch true")
        // With lunch in, the next later slot that is empty is offered, and the title no longer names the clock's slot.
        #expect(next(13, 30, [.breakfast, .lunch]) == "snack false")
        #expect(next(13, 30, [.lunch, .snack]) == "dinner false")
        // Nothing later is free: the clock's slot stays.
        #expect(next(19, 0, [.dinner]) == "dinner false")
        #expect(next(13, 30, [.lunch, .snack, .dinner]) == "lunch false")
    }

    /// Every preset must save as a drink of its own kind, so a tile never fails at Add.
    @Test func everyPresetMakesAValidDrink() throws {
        for kind in FoodDrinkKind.allCases {
            let presets = FoodDrinkPreset.presets(for: kind)
            #expect(!presets.isEmpty)
            #expect(Set(presets.map(\.id)).count == presets.count, "Tile identifiers must be unique")
            for preset in presets {
                #expect(preset.kind == kind)
                var nutrients = FoodNutrients()
                nutrients[.protein] = preset.protein; nutrients[.carbs] = preset.carbs; nutrients[.fat] = preset.fat
                _ = try FoodDrink(kind: kind, name: preset.name, occurredAt: at(12, 0), timeZoneIdentifier: "Australia/Perth",
                                  waterMillilitres: kind == .water ? preset.amount : nil,
                                  caffeineMilligrams: kind == .caffeine ? preset.amount : 0,
                                  alcoholUnits: kind == .alcohol ? preset.amount : 0,
                                  energy: kind == .water ? 0 : preset.energy,
                                  additionalNutrients: kind == .water ? nil : nutrients, confirmedAt: at(12, 0))
            }
        }
    }

    /// Units are 10 g of alcohol: millilitres × strength × 0.789 g/ml ÷ 10, to one decimal.
    @Test func alcoholPresetsMatchTheirServing() {
        let units = Dictionary(uniqueKeysWithValues: FoodDrinkPreset.presets(for: .alcohol).map { ($0.name, $0.amount) })
        func unitsFor(_ millilitres: Double, _ strength: Double) -> Double { (millilitres * strength * 0.789).rounded() / 10 }
        #expect(units["Beer"] == unitsFor(375, 0.048))
        #expect(units["Wine"] == unitsFor(150, 0.13))
        #expect(units["Sparkling"] == unitsFor(150, 0.12))
        #expect(units["Spirit"] == unitsFor(30, 0.40))
    }

    /// A drink row's plus adds the newest drink's preset of that kind, and the first preset when nothing matches.
    @Test func theRowPlusAddsTheLastUsedPreset() throws {
        func drink(_ kind: FoodDrinkKind, _ name: String, _ hour: Int, amount: Double) throws -> FoodDrink {
            try FoodDrink(kind: kind, name: name, occurredAt: at(hour, 0), timeZoneIdentifier: "Australia/Perth",
                          waterMillilitres: kind == .water ? amount : nil, caffeineMilligrams: kind == .caffeine ? amount : 0,
                          alcoholUnits: kind == .alcohol ? amount : 0, confirmedAt: at(hour, 0))
        }
        #expect(FoodDrinkPreset.lastUsed(.caffeine, in: []).name == "Espresso")
        #expect(FoodDrinkPreset.lastUsed(.water, in: []) == .glassOfWater)
        let drinks = [try drink(.caffeine, "Flat white", 8, amount: 130), try drink(.caffeine, "tea", 15, amount: 45),
                      try drink(.alcohol, "Wine", 19, amount: 1.5), try drink(.water, "Water", 9, amount: 500),
                      try drink(.water, "Water", 7, amount: 250)]
        // Matched by name, any case, newest first.
        #expect(FoodDrinkPreset.lastUsed(.caffeine, in: drinks).name == "Tea")
        #expect(FoodDrinkPreset.lastUsed(.alcohol, in: drinks).name == "Wine")
        // Water is matched by amount.
        #expect(FoodDrinkPreset.lastUsed(.water, in: drinks).name == "Bottle")
        // A drink typed by hand matches no preset.
        #expect(FoodDrinkPreset.lastUsed(.alcohol, in: [try drink(.alcohol, "Negroni", 20, amount: 2)]).name == "Beer")
        #expect(FoodDrinkPreset.lastUsed(.water, in: [try drink(.water, "Water", 20, amount: 330)]) == .glassOfWater)
    }

    /// A preset's calories should roughly match its macros, so the day's totals agree with each other.
    @Test func presetCaloriesCoverTheirMacros() {
        for preset in FoodDrinkKind.allCases.flatMap(FoodDrinkPreset.presets(for:)) where preset.kind != .alcohol {
            let fromMacros = preset.protein * 4 + preset.carbs * 4 + preset.fat * 9
            #expect(abs(fromMacros - preset.energy) <= max(15, preset.energy * 0.15), "\(preset.name)")
        }
    }
}
