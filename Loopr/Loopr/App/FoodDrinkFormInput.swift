import FoodKit
import Foundation

nonisolated struct FoodDrinkFormInput: Sendable {
    let kind: FoodDrinkKind
    let name: String
    let amount: String
    let energy: String
    let protein: String
    let carbs: String
    let fat: String
    let occurredAt: Date

    func drink(now: Date, timeZoneIdentifier: String) throws -> FoodDrink {
        let quantity = try FoodInput.number(amount)!
        var nutrients = FoodNutrients()
        nutrients[.protein] = try FoodInput.number(protein, optional: true)
        nutrients[.carbs] = try FoodInput.number(carbs, optional: true)
        nutrients[.fat] = try FoodInput.number(fat, optional: true)
        return try FoodDrink(kind: kind, name: name, occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
            waterMillilitres: kind == .water ? quantity : nil,
            // The form asks each kind only for its own amount, so the other two are none.
            caffeineMilligrams: kind == .caffeine ? quantity : 0,
            alcoholUnits: kind == .alcohol ? quantity : 0,
            energy: kind == .water ? 0 : FoodInput.number(energy, optional: true),
            additionalNutrients: nutrients, confirmedAt: now)
    }
}
