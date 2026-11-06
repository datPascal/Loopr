import Foundation

public enum FoodPlantCategory: String, CaseIterable, Codable, Sendable {
    case vegetable, fruit, legume, nut, seed, herb, spice, mushroom
    case wholeGrain = "whole-grain"
}

/// One entry of the bundled plant list (`FoodPlants.json`).
///
/// What counts as a plant: whole or minimally processed plant foods. Vegetables, fruits, legumes, whole grains,
/// nuts, seeds, herbs and spices count, and so do mushrooms. Herbs and spices are in on purpose, because the
/// common "30 plants a week" counting includes them. Refined products are out: sugar and syrups, oils, white
/// flour, white bread, white rice, plain pasta and starches, and drinks such as coffee, tea and cocoa.
public struct FoodPlant: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    /// English display name in sentence case.
    public let name: String
    public let category: FoodPlantCategory
    /// Other names, German ones included, that a photo estimate or a person might use.
    public let synonyms: [String]
    /// Open Food Facts ingredient taxonomy ids, such as `en:spinach`.
    public let offIds: [String]
    /// Ingredient ids whose presence means a more specific plant is in the product, so this general one is not
    /// counted on top (Open Food Facts lists parent ingredients too: kale also lists cabbage).
    public let offSuppressedBy: [String]
    public var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, name, category, synonyms, offIds, offSuppressedBy }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        name = try values.decode(String.self, forKey: .name)
        category = try values.decode(FoodPlantCategory.self, forKey: .category)
        synonyms = try values.decodeIfPresent([String].self, forKey: .synonyms) ?? []
        offIds = try values.decodeIfPresent([String].self, forKey: .offIds) ?? []
        offSuppressedBy = try values.decodeIfPresent([String].self, forKey: .offSuppressedBy) ?? []
    }
}

/// A plant a person or a provider named. `key` is a list key, or `custom:<normalised name>` for a plant that is
/// not in the list.
public struct FoodPlantRef: Codable, Hashable, Sendable {
    public let key: String
    public let name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
    public var isCustom: Bool { key.hasPrefix(FoodPlantList.customPrefix) }
}

public enum FoodPlantMatch: Equatable, Sendable {
    case listed(FoodPlant)
    /// Not in the list, and not a refined product either. Counts as its own plant.
    case custom(FoodPlantRef)
    /// A refined product or a drink. Never counts.
    case excluded
}

public enum FoodPlantListError: Error, Equatable, Sendable {
    case missingResource, unsupportedVersion(Int), invalidEntry(String), duplicateName(String)
}

public struct FoodPlantList: Sendable {
    public static let customPrefix = "custom:"
    public let plants: [FoodPlant]
    public let notPlants: Set<String>
    private let byKey: [String: FoodPlant]
    private let byName: [String: FoodPlant]
    private let byOFFId: [String: [FoodPlant]]

    private struct Document: Decodable {
        let version: Int
        let notPlants: [String]?
        let plants: [FoodPlant]
    }

    public init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw FoodPlantListError.unsupportedVersion(document.version) }
        var byKey: [String: FoodPlant] = [:], byName: [String: FoodPlant] = [:], byOFFId: [String: [FoodPlant]] = [:]
        for plant in document.plants {
            guard !plant.key.isEmpty, plant.key.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }),
                  byKey[plant.key] == nil, !plant.name.isEmpty,
                  plant.offIds.allSatisfy({ $0.contains(":") && $0 == $0.lowercased() }) else { throw FoodPlantListError.invalidEntry(plant.key) }
            byKey[plant.key] = plant
            for name in [plant.name] + plant.synonyms {
                let normalized = Self.normalized(name)
                guard !normalized.isEmpty else { throw FoodPlantListError.invalidEntry(plant.key) }
                if let existing = byName[normalized], existing.key != plant.key { throw FoodPlantListError.duplicateName(name) }
                byName[normalized] = plant
            }
            for id in plant.offIds { byOFFId[id, default: []].append(plant) }
        }
        plants = document.plants
        notPlants = Set((document.notPlants ?? []).map(Self.normalized))
        self.byKey = byKey; self.byName = byName; self.byOFFId = byOFFId
    }

    private static let loaded: Result<FoodPlantList, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "FoodPlants", withExtension: "json") else { throw FoodPlantListError.missingResource }
        return try FoodPlantList(data: Data(contentsOf: url))
    }
    /// The list that ships with the app. It is read once.
    public static func bundled() throws -> FoodPlantList { try loaded.get() }

    public func plant(key: String) -> FoodPlant? { byKey[key] }

    /// Lowercase, no diacritics, `ß` as `ss`, apostrophes dropped, anything else that is not a letter or digit
    /// as one space. "Möhren" and "mohren" are the same name.
    public static func normalized(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let folded = lowered.folding(options: .diacriticInsensitive, locale: nil)
        var result = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else { pendingSpace = true }
        }
        return result
    }

    private static func singularForms(of name: String) -> [String] {
        var forms: [String] = []
        if name.hasSuffix("ies"), name.count > 4 { forms.append(String(name.dropLast(3)) + "y") }
        if name.hasSuffix("es"), name.count > 3 { forms.append(String(name.dropLast(2))) }
        if name.hasSuffix("s"), name.count > 3 { forms.append(String(name.dropLast(1))) }
        return forms
    }

    /// Matches a plain plant name, as a photo estimate or a person writes it. A list name or synonym wins, with
    /// simple plurals folded. A refined product never counts. Anything else is a plant of its own.
    public func match(name: String) -> FoodPlantMatch? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalized(trimmed)
        guard !normalized.isEmpty, trimmed.count <= FoodItem.maximumPlantNameLength else { return nil }
        for candidate in [normalized] + Self.singularForms(of: normalized) {
            if let plant = byName[candidate] { return .listed(plant) }
        }
        if notPlants.contains(normalized) || Self.singularForms(of: normalized).contains(where: notPlants.contains) { return .excluded }
        return .custom(FoodPlantRef(key: Self.customPrefix + normalized, name: trimmed))
    }

    /// The reference for a name a person adds: the list plant when there is one, otherwise a custom plant.
    /// Refined products return nil, because they are not plants.
    public func reference(forName name: String) -> FoodPlantRef? {
        switch match(name: name) {
        case .listed(let plant): FoodPlantRef(key: plant.key, name: plant.name)
        case .custom(let reference): reference
        case .excluded, nil: nil
        }
    }

    /// Plants in an Open Food Facts `ingredients_tags` list, each once.
    ///
    /// Only tags the list names count (`offIds`), so generic parents such as `en:wheat-flour`, `en:sugar` or
    /// `en:vegetable-oil` never add a plant. A tag in another language that the taxonomy did not recognise, such as
    /// `de:dinkelvollkornmehl`, counts when its words are a list name or synonym. A general plant is dropped when a
    /// more specific one in its `offSuppressedBy` is present.
    public func plants(fromOFFTags tags: [String]) -> [FoodPlant] {
        let normalizedTags = tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let present = Set(normalizedTags)
        var found: [String: FoodPlant] = [:]
        func consider(_ plant: FoodPlant) {
            guard found[plant.key] == nil, !plant.offSuppressedBy.contains(where: present.contains) else { return }
            found[plant.key] = plant
        }
        for tag in normalizedTags {
            for plant in byOFFId[tag] ?? [] { consider(plant) }
            guard let colon = tag.firstIndex(of: ":") else { continue }
            let language = tag[..<colon]
            guard language != "en", (2...3).contains(language.count) else { continue }
            let words = Self.normalized(String(tag[tag.index(after: colon)...]))
            for candidate in [words] + Self.singularForms(of: words) {
                if let plant = byName[candidate] { consider(plant); break }
            }
        }
        return plants.filter { found[$0.key] != nil }
    }
}

/// Where a plant on an item came from. An edit wins over both automatic sources.
public enum FoodPlantSource: String, Codable, CaseIterable, Sendable {
    /// `usda` is a typed or spoken single food matched to the USDA table whose name is a listed plant ("banana").
    case edit, openFoodFacts, photoEstimate, usda
}

/// A plant on one item, with its source, so a screen can say where it came from.
public struct FoodItemPlant: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    /// Nil for a plant that is not in the list.
    public let category: FoodPlantCategory?
    public let source: FoodPlantSource
    public var id: String { key }
}

/// What a person changed about an item's plants. An added plant counts even when nothing found it; a removed
/// plant stays out even when a photo or a barcode found it.
public struct FoodPlantEdits: Codable, Equatable, Sendable {
    public var added: [FoodPlantRef]
    public var removed: [String]
    public init(added: [FoodPlantRef] = [], removed: [String] = []) { self.added = added; self.removed = removed }
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    func validate() throws {
        guard added.count <= 60, removed.count <= 60,
              added.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 140 && !$0.name.isEmpty && $0.name.count <= FoodItem.maximumPlantNameLength }),
              removed.allSatisfy({ !$0.isEmpty && $0.count <= 140 }),
              Set(added.map(\.key)).count == added.count, Set(removed).count == removed.count,
              Set(added.map(\.key)).isDisjoint(with: removed) else { throw FoodError.invalidRecord }
    }
}

extension FoodItem {
    public static let maximumPlantNameLength = 100

    /// The plants this item holds: the photo estimate's plants and Open Food Facts ingredients, then the person's
    /// edits on top. A removed plant is gone. An added plant takes the source `.edit`, also when a photo or a
    /// barcode found it too. Sorted by name.
    public func plants(in list: FoodPlantList) -> [FoodItemPlant] {
        var result: [String: FoodItemPlant] = [:]
        for name in estimatedPlants ?? [] {
            switch list.match(name: name) {
            case .listed(let plant):
                result[plant.key] = result[plant.key] ?? .init(key: plant.key, name: plant.name, category: plant.category, source: .photoEstimate)
            case .custom(let reference):
                result[reference.key] = result[reference.key] ?? .init(key: reference.key, name: reference.name, category: nil, source: .photoEstimate)
            case .excluded, nil: break
            }
        }
        for plant in list.plants(fromOFFTags: ingredientTags ?? []) where result[plant.key] == nil {
            result[plant.key] = .init(key: plant.key, name: plant.name, category: plant.category, source: .openFoodFacts)
        }
        // A typed "banana" or "lentils" matched to USDA counts when its name, or the first words of USDA's description
        // ("Bananas, raw"), is a listed plant. Only listed plants: a dish or a custom name adds nothing (R2-VET-04).
        if let reference = provenance.last(where: { $0.source == .reference })?.reference {
            let usdaName = reference.description.components(separatedBy: ",").first ?? ""
            for name in [self.name, usdaName] {
                if case .listed(let plant) = list.match(name: name), result[plant.key] == nil {
                    result[plant.key] = .init(key: plant.key, name: plant.name, category: plant.category, source: .usda); break
                }
            }
        }
        if let plantEdits {
            for key in plantEdits.removed { result[key] = nil }
            for reference in plantEdits.added {
                let plant = list.plant(key: reference.key)
                result[reference.key] = .init(key: reference.key, name: plant?.name ?? reference.name, category: plant?.category, source: .edit)
            }
        }
        return result.values.sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
    }

    /// Adds a plant by name. A refined product is refused with `FoodError.invalidRecord`.
    public mutating func addPlant(named name: String, in list: FoodPlantList, at date: Date) throws {
        guard let reference = list.reference(forName: name) else { throw FoodError.invalidRecord }
        var edits = plantEdits ?? .init()
        edits.removed.removeAll { $0 == reference.key }
        if !edits.added.contains(where: { $0.key == reference.key }) { edits.added.append(reference) }
        try commitPlantEdits(edits, at: date)
    }

    /// Removes a plant, whichever source found it.
    public mutating func removePlant(key: String, at date: Date) throws {
        var edits = plantEdits ?? .init()
        edits.added.removeAll { $0.key == key }
        if !edits.removed.contains(key) { edits.removed.append(key) }
        try commitPlantEdits(edits, at: date)
    }

    private mutating func commitPlantEdits(_ edits: FoodPlantEdits, at date: Date) throws {
        try edits.validate()
        var copy = self
        copy.plantEdits = edits
        try copy.recordEdit(at: date)
        self = copy
    }
}
