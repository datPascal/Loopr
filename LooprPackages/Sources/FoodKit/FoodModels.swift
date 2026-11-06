import CryptoKit
import Foundation
import ImageIO

public enum FoodError: Error, Equatable, Sendable, LocalizedError {
    case invalidRecord, unsupportedVersion(Int), staleRevision, missingMeal, invalidPhoto

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "Check the time, amounts and source before saving."
        case .unsupportedVersion: "This food record needs a newer version of Loopr."
        case .staleRevision: "This meal changed. Open it again before saving your edits."
        case .missingMeal: "This meal is no longer available."
        case .invalidPhoto: "This photo could not be read. Choose a JPEG, PNG or HEIC photo under 20 MB."
        }
    }
}

public enum FoodMealSlot: String, CaseIterable, Codable, Sendable {
    case breakfast, lunch, snack, dinner
    public var title: String { rawValue.capitalized }

    /// The meal a log started at this time most likely is: breakfast until 10:30, lunch until 15:00,
    /// a snack until 17:30, dinner after. The review screen can still change it.
    public static func suggested(at date: Date, calendar: Calendar) -> FoodMealSlot {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return suggested(minuteOfDay: (parts.hour ?? 12) * 60 + (parts.minute ?? 0))
    }

    /// `suggested(at:calendar:)` for a minute after midnight.
    public static func suggested(minuteOfDay minutes: Int) -> FoodMealSlot {
        switch minutes {
        case ..<630: .breakfast
        case ..<900: .lunch
        case ..<1050: .snack
        default: .dinner
        }
    }

    /// The slot a new log most likely belongs to, and whether it still reads as the clock's own slot. When the
    /// clock's slot already holds a meal, the next later slot with none is offered instead, so "Log lunch" does not
    /// stay on the screen at 1 pm after lunch is in. With every later slot filled the clock's slot stays.
    /// This is the one slot rule for every way to log: the Log tiles, Speak, Manual and the rail's ghost.
    public static func toLog(at date: Date, calendar: Calendar, logged: Set<FoodMealSlot>) -> (slot: FoodMealSlot, isClockSlot: Bool) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return toLog(minuteOfDay: (parts.hour ?? 12) * 60 + (parts.minute ?? 0), logged: logged)
    }

    /// `toLog(at:calendar:logged:)` for a minute after midnight.
    public static func toLog(minuteOfDay: Int, logged: Set<FoodMealSlot>) -> (slot: FoodMealSlot, isClockSlot: Bool) {
        let clock = suggested(minuteOfDay: minuteOfDay)
        guard logged.contains(clock) else { return (clock, true) }
        let later = allCases.drop(while: { $0 != clock }).dropFirst().first { !logged.contains($0) }
        return (later ?? clock, false)
    }
}

public enum FoodUnit: String, CaseIterable, Codable, Sendable {
    case grams, millilitres, serving, piece
    public var title: String {
        switch self { case .grams: "g"; case .millilitres: "ml"; case .serving: "serving"; case .piece: "piece" }
    }
    /// The unit as it reads after `amount`: "2 pieces", "1 serving", "150 g".
    public func title(for amount: Double) -> String {
        switch self {
        case .serving, .piece: amount == 1 ? title : title + "s"
        default: title
        }
    }
}

public enum FoodNutrient: String, CaseIterable, Codable, Sendable {
    /// Energy is kcal, caffeine is mg, alcohol units are 10 g pure ethanol;
    /// other nutrients use grams. These units also apply to JSON exports.
    case energy, protein, carbs, fat, fibre, sugar, salt, caffeine, alcoholUnits
}

/// Values describe the item's entered amount, not an implicit 100 g serving.
/// Nil means unreported. A labelled zero remains a known zero.
public struct FoodNutrients: Codable, Equatable, Sendable {
    public var values: [FoodNutrient: Double]
    public init(_ values: [FoodNutrient: Double] = [:]) { self.values = values }
    public subscript(_ nutrient: FoodNutrient) -> Double? {
        get { values[nutrient] }
        set { values[nutrient] = newValue }
    }
    public func scaled(by factor: Double) throws -> Self {
        guard factor.isFinite, factor > 0 else { throw FoodError.invalidRecord }
        let result = Self(values.mapValues { $0 * factor })
        try result.validate()
        return result
    }
    public func validate() throws {
        guard values.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw FoodError.invalidRecord }
    }
}

public struct FoodNutrientTotal: Equatable, Sendable {
    public let knownValue: Double?
    public let knownItems: Int
    public let totalItems: Int
    public var isComplete: Bool { knownValue != nil && totalItems > 0 && knownItems == totalItems }

    public init(_ nutrient: FoodNutrient, items: [FoodItem]) {
        self.init(values: items.map { $0.nutrients[nutrient] })
    }
    public init(values readings: [Double?]) {
        let values = readings.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        let sum = values.reduce(0, +)
        knownValue = values.isEmpty || !sum.isFinite ? nil : sum
        knownItems = values.count
        totalItems = readings.count
    }
}

public enum FoodCaptureSource: String, Codable, Sendable {
    /// `agentText` is a meal the Ask agent drafted from the chat text. Its values are estimates.
    /// `reference` is a typed or spoken food matched to the bundled USDA table (`FoodReference`).
    case photoAI, barcode, label, typed, voice, manualEdit, agentText, reference
}

public enum FoodConfidence: String, Codable, Sendable {
    case sure, check, guess
    public var title: String { rawValue.capitalized }
}

/// Edits append provenance; they never replace the original provider or barcode.
public struct FoodProvenance: Codable, Equatable, Sendable {
    public let source: FoodCaptureSource
    public let recordedAt: Date
    public let provider: String?
    public let model: String?
    public let barcode: String?
    public let confidence: FoodConfidence?
    public let product: FoodProductSource?
    public let labelText: String?
    /// The USDA food a `reference` item was matched to. Nil for every other source.
    public let reference: FoodReferenceSource?

    public init(source: FoodCaptureSource, recordedAt: Date, provider: String? = nil,
                model: String? = nil, barcode: String? = nil, confidence: FoodConfidence? = nil,
                product: FoodProductSource? = nil, labelText: String? = nil, reference: FoodReferenceSource? = nil) {
        self.source = source; self.recordedAt = recordedAt; self.provider = provider
        self.model = model; self.barcode = barcode; self.confidence = confidence
        self.product = product; self.labelText = labelText; self.reference = reference
    }

    public func validate() throws {
        guard recordedAt.timeIntervalSince1970.isFinite else { throw FoodError.invalidRecord }
        if source == .photoAI || source == .agentText {
            guard let provider, ["openai", "anthropic"].contains(provider),
                  let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  confidence != nil else { throw FoodError.invalidRecord }
        }
        if source == .barcode {
            guard let barcode, (try? FoodBarcode.normalized(barcode)) != nil else { throw FoodError.invalidRecord }
        }
        if let product {
            guard source == .barcode, product.barcode == (try? FoodBarcode.normalized(barcode ?? "")) else { throw FoodError.invalidRecord }
            try product.validate()
        }
        if let labelText {
            guard source == .label, labelText.count <= 20_000 else { throw FoodError.invalidRecord }
        }
        if source == .reference { guard let reference else { throw FoodError.invalidRecord }; try reference.validate() }
        else if reference != nil { throw FoodError.invalidRecord }
    }
}

public struct FoodItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var amount: Double
    public var unit: FoodUnit
    public var nutrients: FoodNutrients
    public private(set) var provenance: [FoodProvenance]
    /// Open Food Facts `nova_group` (1 to 4) of a barcoded product. Nil when the product has none, and for every
    /// item that was not scanned. Loopr never classifies food itself (DEC-08.3); this one field is the exception
    /// (DEC-12.8).
    public var novaGroup: Int?
    /// Open Food Facts `ingredients_tags` of a barcoded product. Nil when Open Food Facts sent none.
    public var ingredientTags: [String]?
    /// Plain plant names the photo estimate returned for this item. Nil when the response had none.
    public var estimatedPlants: [String]?
    /// The person's changes to this item's plants. They win over the photo estimate and Open Food Facts.
    public var plantEdits: FoodPlantEdits?
    public var isEstimated: Bool { provenance.contains { $0.source == .photoAI || $0.source == .agentText || $0.product?.estimated == true } }
    public var confidence: FoodConfidence? { provenance.last(where: { $0.source == .photoAI || $0.source == .agentText })?.confidence }

    public init(id: UUID = UUID(), name: String, amount: Double, unit: FoodUnit,
                nutrients: FoodNutrients = .init(), provenance: [FoodProvenance],
                novaGroup: Int? = nil, ingredientTags: [String]? = nil,
                estimatedPlants: [String]? = nil, plantEdits: FoodPlantEdits? = nil) {
        self.id = id; self.name = name; self.amount = amount; self.unit = unit
        self.nutrients = nutrients; self.provenance = provenance
        self.novaGroup = novaGroup; self.ingredientTags = ingredientTags
        self.estimatedPlants = estimatedPlants; self.plantEdits = plantEdits
    }

    /// A new item with its own id and the same food: values, provenance, Open Food Facts classification and
    /// plants. Repeating a meal or a favourite copies through this, so the longevity lens still sees them.
    public func duplicated(addingEditAt date: Date? = nil) -> FoodItem {
        var copy = FoodItem(name: name, amount: amount, unit: unit, nutrients: nutrients, provenance: provenance,
            novaGroup: novaGroup, ingredientTags: ingredientTags, estimatedPlants: estimatedPlants, plantEdits: plantEdits)
        if let date { copy.provenance.append(.init(source: .manualEdit, recordedAt: date)) }
        return copy
    }

    public mutating func changeAmount(to amount: Double, at date: Date) throws {
        guard self.amount > 0, amount.isFinite, amount > 0 else { throw FoodError.invalidRecord }
        let scaled = try nutrients.scaled(by: amount / self.amount)
        let source = FoodProvenance(source: .manualEdit, recordedAt: date)
        try source.validate()
        self.amount = amount; nutrients = scaled; provenance.append(source)
    }

    public mutating func recordEdit(at date: Date) throws {
        let source = FoodProvenance(source: .manualEdit, recordedAt: date)
        try source.validate()
        provenance.append(source)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 500,
              amount.isFinite, amount > 0, !provenance.isEmpty else { throw FoodError.invalidRecord }
        try nutrients.validate()
        for source in provenance { try source.validate() }
        let scanned = provenance.contains { $0.source == .barcode }
        if let novaGroup { guard scanned, (1...4).contains(novaGroup) else { throw FoodError.invalidRecord } }
        if let ingredientTags {
            guard scanned, ingredientTags.count <= 500,
                  ingredientTags.allSatisfy({ !$0.isEmpty && $0.count <= 120 }) else { throw FoodError.invalidRecord }
        }
        if let estimatedPlants {
            guard provenance.contains(where: { $0.source == .photoAI || $0.source == .agentText }), estimatedPlants.count <= 60,
                  estimatedPlants.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= Self.maximumPlantNameLength })
            else { throw FoodError.invalidRecord }
        }
        try plantEdits?.validate()
    }
}

public enum FoodPhotoType: String, Codable, Sendable {
    case jpeg = "image/jpeg", png = "image/png", heic = "image/heic"
    public var fileExtension: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .heic: "heic" } }
}

public struct FoodPhotoReference: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let type: FoodPhotoType
    public let capturedAt: Date
    public let sha256: String
    public var fileName: String { "\(id.uuidString).\(type.fileExtension)" }
}

public struct FoodPhoto: Codable, Equatable, Sendable {
    public static let maximumBytes = 20 * 1_024 * 1_024
    public let reference: FoodPhotoReference
    public let bytes: Data

    public init(id: UUID = UUID(), type: FoodPhotoType, capturedAt: Date, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes, capturedAt.timeIntervalSince1970.isFinite else {
            throw FoodError.invalidPhoto
        }
        guard let image = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(image) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let identifier = CGImageSourceGetType(image) as String?,
              identifier == (type == .jpeg ? "public.jpeg" : type == .png ? "public.png" : "public.heic"),
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw FoodError.invalidPhoto }
        self.reference = .init(id: id, type: type, capturedAt: capturedAt,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reference = try container.decode(FoodPhotoReference.self, forKey: .reference)
        try self.init(id: reference.id, type: reference.type, capturedAt: reference.capturedAt,
                      bytes: container.decode(Data.self, forKey: .bytes))
        guard self.reference == reference else { throw FoodError.invalidPhoto }
    }
}

public struct FoodArchive: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let meals: [FoodMeal]
    public let photos: [FoodPhoto]
    public let drinks: [FoodDrink]
    public let days: [FoodDayRecord]
    public let targets: [FoodTargetSettings]
    public let favorites: [FoodFavorite]
    /// Body weight readings. Older backups have none.
    public let weights: [FoodWeightEntry]

    public init(schemaVersion: Int = 3, meals: [FoodMeal], photos: [FoodPhoto],
                drinks: [FoodDrink] = [], days: [FoodDayRecord] = [], targets: [FoodTargetSettings] = [], favorites: [FoodFavorite] = [],
                weights: [FoodWeightEntry] = []) {
        self.schemaVersion = schemaVersion; self.meals = meals; self.photos = photos
        self.drinks = drinks; self.days = days; self.targets = targets; self.favorites = favorites
        self.weights = weights
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            meals: try values.decode([FoodMeal].self, forKey: .meals), photos: try values.decode([FoodPhoto].self, forKey: .photos),
            drinks: try values.decodeIfPresent([FoodDrink].self, forKey: .drinks) ?? [],
            days: try values.decodeIfPresent([FoodDayRecord].self, forKey: .days) ?? [],
            targets: try values.decodeIfPresent([FoodTargetSettings].self, forKey: .targets) ?? [],
            favorites: try values.decodeIfPresent([FoodFavorite].self, forKey: .favorites) ?? [],
            weights: try values.decodeIfPresent([FoodWeightEntry].self, forKey: .weights) ?? [])
        try validate()
    }

    public func validate() throws {
        guard [1, 2, 3].contains(schemaVersion) else { throw FoodError.unsupportedVersion(schemaVersion) }
        guard schemaVersion != 1 || (drinks.isEmpty && days.isEmpty && targets.isEmpty),
              Set(drinks.map(\.id)).count == drinks.count, Set(days.map(\.localDay)).count == days.count,
              Set(targets.map(\.id)).count == targets.count else { throw FoodError.invalidRecord }
        guard schemaVersion >= 3 || favorites.isEmpty, Set(favorites.map(\.id)).count == favorites.count else { throw FoodError.invalidRecord }
        guard schemaVersion >= 3 || weights.isEmpty, Set(weights.map(\.id)).count == weights.count else { throw FoodError.invalidRecord }
        for weight in weights { try weight.validate() }
        for favorite in favorites { try favorite.validate() }
        for drink in drinks { try drink.validate() }
        for day in days { try day.validate() }
        for target in targets { try target.validate() }
        let references = meals.flatMap(\.photos)
        guard Set(meals.map(\.id)).count == meals.count,
              Set(references.map(\.id)).count == references.count,
              Set(photos.map(\.reference.id)).count == photos.count,
              references.count == photos.count else { throw FoodError.invalidRecord }
        for meal in meals { try meal.validate() }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.reference.id, $0.reference) })
        guard references.allSatisfy({ byID[$0.id] == $0 }) else { throw FoodError.invalidPhoto }
    }

    public func selectingDays(includingFavorites: Bool = false, _ include: (String) -> Bool) -> Self {
        let selected = meals.filter { include($0.localDay) }
        let photoIDs = Set(selected.flatMap(\.photos).map(\.id))
        return Self(schemaVersion: schemaVersion, meals: selected, photos: photos.filter { photoIDs.contains($0.reference.id) },
            drinks: drinks.filter { include($0.localDay) }, days: days.filter { include($0.localDay) }, targets: targets,
            favorites: includingFavorites ? favorites : [], weights: weights.filter { include($0.localDay) })
    }
}

/// Capture and edits live in this value until a person confirms them. No draft
/// constructor, parser or provider result writes to the database.
public struct FoodMealDraft: Equatable, Sendable {
    public var id: UUID
    public var slot: FoodMealSlot
    public var occurredAt: Date
    public var timeZoneIdentifier: String
    public var items: [FoodItem]
    public var photos: [FoodPhoto]
    public var note: String
    public var expectedRevision: Int?
    public var photoTime: FoodPhotoTime?

    public init(id: UUID = UUID(), slot: FoodMealSlot, occurredAt: Date, timeZoneIdentifier: String,
                items: [FoodItem] = [], photos: [FoodPhoto] = [], note: String = "", expectedRevision: Int? = nil, photoTime: FoodPhotoTime? = nil) {
        self.id = id; self.slot = slot; self.occurredAt = occurredAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.items = items; self.photos = photos; self.note = note; self.expectedRevision = expectedRevision; self.photoTime = photoTime
    }
}

public struct FoodMeal: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public let revision: Int
    public let slot: FoodMealSlot
    public let occurredAt: Date
    public let timeZoneIdentifier: String
    public let localDay: String
    public let items: [FoodItem]
    public let photos: [FoodPhotoReference]
    public let note: String
    public let confirmedAt: Date
    public let photoTime: FoodPhotoTime?

    init(draft: FoodMealDraft, revision: Int, confirmedAt: Date) throws {
        schemaVersion = Self.currentSchemaVersion; id = draft.id; self.revision = revision; slot = draft.slot
        occurredAt = draft.occurredAt; timeZoneIdentifier = draft.timeZoneIdentifier
        localDay = try Self.day(at: draft.occurredAt, timeZoneIdentifier: draft.timeZoneIdentifier)
        items = draft.items; photos = draft.photos.map(\.reference); note = draft.note; self.confirmedAt = confirmedAt
        photoTime = draft.photoTime
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw FoodError.unsupportedVersion(schemaVersion) }
        guard revision > 0, !items.isEmpty, items.count <= 100, photos.count <= 10, note.count <= 10_000,
              Set(items.map(\.id)).count == items.count, Set(photos.map(\.id)).count == photos.count,
              confirmedAt.timeIntervalSince1970.isFinite,
              try localDay == Self.day(at: occurredAt, timeZoneIdentifier: timeZoneIdentifier) else { throw FoodError.invalidRecord }
        for item in items { try item.validate() }
        for photo in photos {
            guard photo.capturedAt.timeIntervalSince1970.isFinite, photo.sha256.count == 64,
                  photo.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw FoodError.invalidPhoto }
        }
    }

    public static func day(at date: Date, timeZoneIdentifier: String) throws -> String {
        guard date.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timeZoneIdentifier) else { throw FoodError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year), let month = parts.month, let day = parts.day else { throw FoodError.invalidRecord }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
