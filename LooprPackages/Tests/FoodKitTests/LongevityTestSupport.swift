import FoodKit
import Foundation
import StorageKit
import Testing

/// A throwaway food database. Meals can only be made through a store, which validates them.
final class LongevityStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongevityTests-\(UUID().uuidString)")
    let database: StorageDatabase
    var store: FoodStore { FoodStore(database: database) }
    init() throws { database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"), applicationVersion: "longevity-tests") }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }

    func meal(at date: Date, zone: String, items: [FoodItem], slot: FoodMealSlot = .lunch) throws -> FoodMeal {
        try store.confirm(FoodMealDraft(slot: slot, occurredAt: date, timeZoneIdentifier: zone, items: items), at: date)
    }
}

enum Longevity {
    static let berlin = "Europe/Berlin"
    static let newYork = "America/New_York"
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func list() throws -> FoodPlantList { try FoodPlantList.bundled() }

    static func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, zone: String = berlin) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A photo estimate item. `plants` nil means the response had no plants field.
    static func photoItem(_ name: String = "Plate", plants: [String]?, nutrients: [FoodNutrient: Double] = [:]) -> FoodItem {
        .init(name: name, amount: 1, unit: .serving, nutrients: .init(nutrients),
            provenance: [.init(source: .photoAI, recordedAt: stamp, provider: "openai", model: "recorded-model", confidence: .check)],
            estimatedPlants: plants)
    }

    /// A scanned item. `nova` and `tags` nil mean Open Food Facts sent none.
    static func scannedItem(_ name: String = "Product", nova: Int? = nil, tags: [String]? = nil, energy: Double? = nil,
                            nutrients: [FoodNutrient: Double] = [:]) -> FoodItem {
        var values = nutrients
        if let energy { values[.energy] = energy }
        return .init(name: name, amount: 100, unit: .grams, nutrients: .init(values),
            provenance: [.init(source: .barcode, recordedAt: stamp, barcode: "1234567890123")],
            novaGroup: nova, ingredientTags: tags)
    }

    static func typedItem(_ name: String = "Lunch", nutrients: [FoodNutrient: Double] = [:]) -> FoodItem {
        .init(name: name, amount: 1, unit: .serving, nutrients: .init(nutrients), provenance: [.init(source: .typed, recordedAt: stamp)])
    }

    static func completeDay(_ localDay: String, noAlcohol: Bool = false, zone: String = berlin) throws -> FoodDayRecord {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        return try FoodDayRecord(dayStart: instant(parts[0], parts[1], parts[2], 0, zone: zone), timeZoneIdentifier: zone,
            completedAt: instant(parts[0], parts[1], parts[2], 23, 0, zone: zone),
            noAlcoholAt: noAlcohol ? instant(parts[0], parts[1], parts[2], 22, 0, zone: zone) : nil)
    }

    static func drink(_ kind: FoodDrinkKind, on localDay: String, units: Double? = nil, energy: Double? = nil,
                      zone: String = berlin) throws -> FoodDrink {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        return try FoodDrink(kind: kind, name: kind.title, occurredAt: instant(parts[0], parts[1], parts[2], 20, zone: zone),
            timeZoneIdentifier: zone, waterMillilitres: kind == .water ? 250 : nil, caffeineMilligrams: kind == .caffeine ? 90 : nil,
            alcoholUnits: kind == .alcohol ? (units ?? 1.5) : nil, energy: energy, confirmedAt: stamp)
    }

    static func close(_ lhs: Double?, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }
}
