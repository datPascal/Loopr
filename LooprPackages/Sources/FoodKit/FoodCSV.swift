import DomainKit
import Foundation

/// Plain CSV files of the food log for a spreadsheet or another app. Numbers use a dot as the decimal
/// separator and times are local to where each entry was logged. Unknown values are empty cells.
public enum FoodCSV {
    public static func items(_ meals: [FoodMeal]) -> String {
        var rows = [["date", "time", "meal", "item", "amount", "unit", "energy_kcal", "protein_g", "carbs_g", "fat_g",
                     "fibre_g", "sugar_g", "salt_g", "caffeine_mg", "alcohol_units", "meal_id"]]
        for meal in meals.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            for item in meal.items {
                rows.append([meal.localDay, CSV.time(meal.occurredAt, zone: meal.timeZoneIdentifier), meal.slot.rawValue, item.name,
                             CSV.number(item.amount), item.unit.rawValue]
                            + [FoodNutrient.energy, .protein, .carbs, .fat, .fibre, .sugar, .salt, .caffeine, .alcoholUnits].map { CSV.number(item.nutrients[$0]) }
                            + [meal.id.uuidString])
            }
        }
        return CSV.text(rows)
    }

    public static func drinks(_ drinks: [FoodDrink]) -> String {
        var rows = [["date", "time", "kind", "name", "water_ml", "caffeine_mg", "alcohol_units", "energy_kcal"]]
        for drink in drinks.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            rows.append([drink.localDay, CSV.time(drink.occurredAt, zone: drink.timeZoneIdentifier), drink.kind.rawValue, drink.name,
                         CSV.number(drink.waterMillilitres), CSV.number(drink.caffeineMilligrams), CSV.number(drink.alcoholUnits),
                         CSV.number(drink.energy)])
        }
        return CSV.text(rows)
    }

    public static func weights(_ entries: [FoodWeightEntry]) -> String {
        var rows = [["date", "time", "weight_kg"]]
        for entry in entries.sorted(by: { $0.measuredAt < $1.measuredAt }) {
            rows.append([entry.localDay, CSV.time(entry.measuredAt, zone: entry.timeZoneIdentifier), CSV.number(entry.kilograms)])
        }
        return CSV.text(rows)
    }

    /// Each time the targets were saved. A day uses the latest targets saved before it ends.
    public static func targets(_ targets: [FoodTargetSettings]) -> String {
        var rows = [["saved_at", "goal", "base_kcal", "protein_g", "carbs_g", "fat_g", "water_ml", "adjusts_for_active_energy",
                     "goal_weight_kg", "pace_kg_per_week", "activity"]]
        for target in targets.sorted(by: { $0.confirmedAt < $1.confirmedAt }) {
            rows.append([CSV.timestamp(target.confirmedAt), target.goal.rawValue, CSV.number(target.baseEnergy), CSV.number(target.protein),
                         CSV.number(target.carbs), CSV.number(target.fat), CSV.number(target.waterMillilitres),
                         target.adjustsForActiveEnergy ? "yes" : "no", CSV.number(target.plan?.goalWeightKg),
                         CSV.number(target.plan?.paceKgPerWeek), target.plan?.activity.rawValue ?? ""])
        }
        return CSV.text(rows)
    }
}
