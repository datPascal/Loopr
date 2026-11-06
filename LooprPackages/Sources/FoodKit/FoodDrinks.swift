import Foundation

public enum FoodDrinkKind: String, CaseIterable, Codable, Sendable {
    case water, caffeine, alcohol
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self { case .water: "drop.fill"; case .caffeine: "cup.and.saucer.fill"; case .alcohol: "wineglass.fill" }
    }
}

public struct FoodDrink: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: FoodDrinkKind
    public let name: String
    public let occurredAt: Date
    public let timeZoneIdentifier: String
    public let localDay: String
    public let waterMillilitres: Double?
    public let caffeineMilligrams: Double?
    public let alcoholUnits: Double?
    public let energy: Double?
    public let additionalNutrients: FoodNutrients?
    public let confirmedAt: Date

    public init(id: UUID = UUID(), kind: FoodDrinkKind, name: String, occurredAt: Date,
                timeZoneIdentifier: String, waterMillilitres: Double? = nil,
                caffeineMilligrams: Double? = nil, alcoholUnits: Double? = nil,
                energy: Double? = nil, additionalNutrients: FoodNutrients? = nil, confirmedAt: Date) throws {
        self.id = id; self.kind = kind; self.name = name; self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        localDay = try FoodMeal.day(at: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
        self.waterMillilitres = waterMillilitres; self.caffeineMilligrams = caffeineMilligrams
        self.alcoholUnits = alcoholUnits; self.energy = energy; self.additionalNutrients = additionalNutrients; self.confirmedAt = confirmedAt
        try validate()
    }

    /// The drink form asks each kind only for its own quantity, so a coffee never states its alcohol. These read a
    /// missing value of another kind as none; the drink's own kind always carries its amount.
    public var knownCaffeineMilligrams: Double? { caffeineMilligrams ?? (kind == .caffeine ? nil : 0) }
    public var knownAlcoholUnits: Double? { alcoholUnits ?? (kind == .alcohol ? nil : 0) }

    public func validate() throws {
        try additionalNutrients?.validate()
        guard additionalNutrients?.values.keys.contains(where: { [.energy, .caffeine, .alcoholUnits].contains($0) }) != true else { throw FoodError.invalidRecord }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              localDay == (try FoodMeal.day(at: occurredAt, timeZoneIdentifier: timeZoneIdentifier)),
              confirmedAt.timeIntervalSince1970.isFinite,
              [waterMillilitres, caffeineMilligrams, alcoholUnits, energy].compactMap({ $0 })
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw FoodError.invalidRecord }
        let quantity = switch kind {
        case .water: waterMillilitres
        case .caffeine: caffeineMilligrams
        case .alcohol: alcoholUnits
        }
        guard let quantity, quantity > 0 else { throw FoodError.invalidRecord }
        if kind == .water {
            guard [energy, caffeineMilligrams, alcoholUnits].compactMap({ $0 }).allSatisfy({ $0 == 0 }),
                  additionalNutrients?.values.values.allSatisfy({ $0 == 0 }) != false else { throw FoodError.invalidRecord }
        }
    }
}

/// Completing a day is a separate, explicit user action. Every changed intake
/// clears completion in the same transaction, including edits across days.
public struct FoodDayRecord: Codable, Equatable, Sendable {
    public let localDay: String
    public let timeZoneIdentifier: String
    public let dayStart: Date
    public var allowance: FoodTrainingAllowance?
    public var completedAt: Date?
    /// When the person marked "None today" for alcohol. Not logging a drink is not an answer, so only this mark, or
    /// a logged alcohol drink, makes a day count as answered for the alcohol-free tile. Adding an alcohol drink clears it.
    public var noAlcoholAt: Date?
    public init(dayStart: Date, timeZoneIdentifier: String, allowance: FoodTrainingAllowance? = nil,
                completedAt: Date? = nil, noAlcoholAt: Date? = nil) throws {
        localDay = try FoodMeal.day(at: dayStart, timeZoneIdentifier: timeZoneIdentifier)
        self.timeZoneIdentifier = timeZoneIdentifier
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { throw FoodError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        self.dayStart = calendar.startOfDay(for: dayStart)
        self.allowance = allowance; self.completedAt = completedAt; self.noAlcoholAt = noAlcoholAt
        try validate()
    }
    public func validate() throws {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { throw FoodError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard localDay == (try FoodMeal.day(at: dayStart, timeZoneIdentifier: timeZoneIdentifier)),
              calendar.startOfDay(for: dayStart) == dayStart,
              completedAt?.timeIntervalSince1970.isFinite != false,
              noAlcoholAt?.timeIntervalSince1970.isFinite != false,
              completedAt.map({ $0 >= dayStart }) != false else { throw FoodError.invalidRecord }
        try allowance?.validate()
    }
}

/// A common drink with typical values, so logging one is a single tap. The amount is in the kind's own
/// unit: millilitres of water, milligrams of caffeine or 10 g units of alcohol. Values are typical
/// servings; the editor lets the person change them before saving.
public struct FoodDrinkPreset: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let kind: FoodDrinkKind
    public let name: String
    /// What the tile says under the name, such as "250 ml".
    public let serving: String
    public let amount: Double
    public let energy: Double
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    public let symbol: String

    public init(kind: FoodDrinkKind, name: String, serving: String, amount: Double, energy: Double = 0,
                protein: Double = 0, carbs: Double = 0, fat: Double = 0, symbol: String) {
        self.kind = kind; self.name = name; self.serving = serving; self.amount = amount
        self.energy = energy; self.protein = protein; self.carbs = carbs; self.fat = fat; self.symbol = symbol
    }

    /// The glass the water row's plus adds.
    public static let glassOfWater = FoodDrinkPreset(kind: .water, name: "Glass", serving: "250 ml", amount: 250, symbol: "drop.fill")

    /// What a drink row's plus adds: the preset the newest drink of `kind` matches, by name, or for water by amount.
    /// A drink that matches no preset, or no drink at all, gives the kind's first preset.
    public static func lastUsed(_ kind: FoodDrinkKind, in drinks: [FoodDrink]) -> FoodDrinkPreset {
        let presets = presets(for: kind)
        let fallback = presets.first ?? glassOfWater
        guard let latest = drinks.filter({ $0.kind == kind }).max(by: { $0.occurredAt < $1.occurredAt }) else { return fallback }
        let match = kind == .water
            ? presets.first { $0.amount == latest.waterMillilitres }
            : presets.first { $0.name.caseInsensitiveCompare(latest.name) == .orderedSame }
        return match ?? fallback
    }

    public static func presets(for kind: FoodDrinkKind) -> [FoodDrinkPreset] {
        switch kind {
        case .water: [
            glassOfWater,
            .init(kind: .water, name: "Bottle", serving: "500 ml", amount: 500, symbol: "waterbottle.fill"),
            .init(kind: .water, name: "Large bottle", serving: "750 ml", amount: 750, symbol: "waterbottle.fill"),
        ]
        // Caffeine from typical servings; a double-shot flat white with 180 ml whole milk.
        case .caffeine: [
            .init(kind: .caffeine, name: "Espresso", serving: "65 mg", amount: 65, energy: 2, symbol: "cup.and.saucer.fill"),
            .init(kind: .caffeine, name: "Coffee", serving: "95 mg", amount: 95, energy: 2, symbol: "mug.fill"),
            .init(kind: .caffeine, name: "Flat white", serving: "130 mg", amount: 130, energy: 115, protein: 6, carbs: 9, fat: 6, symbol: "cup.and.saucer.fill"),
            .init(kind: .caffeine, name: "Tea", serving: "45 mg", amount: 45, energy: 2, symbol: "cup.and.heat.waves.fill"),
            .init(kind: .caffeine, name: "Energy drink", serving: "80 mg", amount: 80, energy: 110, carbs: 27, symbol: "bolt.fill"),
            .init(kind: .caffeine, name: "Cola", serving: "32 mg", amount: 32, energy: 140, carbs: 35, symbol: "takeoutbag.and.cup.and.straw.fill"),
        ]
        // Units of 10 g pure alcohol: millilitres × strength × 0.789 g/ml ÷ 10.
        case .alcohol: [
            .init(kind: .alcohol, name: "Beer", serving: "375 ml, 4.8%", amount: 1.4, energy: 150, protein: 1, carbs: 12, symbol: "mug.fill"),
            .init(kind: .alcohol, name: "Wine", serving: "150 ml, 13%", amount: 1.5, energy: 125, carbs: 4, symbol: "wineglass.fill"),
            .init(kind: .alcohol, name: "Sparkling", serving: "150 ml, 12%", amount: 1.4, energy: 115, carbs: 2, symbol: "wineglass"),
            .init(kind: .alcohol, name: "Spirit", serving: "30 ml, 40%", amount: 0.9, energy: 65, symbol: "drop.halffull"),
        ]
        }
    }
}
