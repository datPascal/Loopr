import Foundation

/// Where a looked-up food's values came from: one entry of the bundled USDA table (`FoodReference.json`, built by
/// `Tools/food-reference/build.py` from FoodData Central SR Legacy, public domain).
public struct FoodReferenceSource: Codable, Equatable, Sendable {
    /// The FoodData Central id, so a value can be traced to fdc.nal.usda.gov/food-details/<id>.
    public let fdcID: Int
    /// USDA's own description, like "Bananas, raw".
    public let description: String
    /// The household portion a count was read as, like "1 medium (7" to 7-7/8" long)". Nil for grams and millilitres.
    public let portion: String?
    public init(fdcID: Int, description: String, portion: String? = nil) {
        self.fdcID = fdcID; self.description = description; self.portion = portion
    }
    public static let dataset = "USDA FoodData Central"
    func validate() throws {
        guard fdcID > 0, !description.isEmpty, description.count <= 300, (portion?.count ?? 0) <= 200 else { throw FoodError.invalidRecord }
    }
}

/// One food of the bundled table. Values are per 100 g.
public struct FoodReferenceFood: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let category: Int
    public let per100g: FoodNutrients
    /// USDA household measures and their weight in grams.
    public let portions: [(label: String, grams: Double)]
    /// The portion a bare count means ("2 eggs"), when the food has one.
    public let defaultPortion: Int?

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The values for `grams` of this food.
    public func nutrients(grams: Double) throws -> FoodNutrients { try per100g.scaled(by: grams / 100) }
}

/// The bundled table and its search. Search runs on the phone; nothing is sent anywhere.
public final class FoodReference: Sendable {
    public let foods: [FoodReferenceFood]
    private let tokens: [[String]]
    /// Everyday names ("eggs", "wine") and the food index they mean, from `Tools/food-reference/common.tsv`.
    private let common: [(alias: String, index: Int)]

    public static let shared: FoodReference? = try? FoodReference()

    public init(data: Data? = nil) throws {
        let raw: Data
        if let data { raw = data } else {
            guard let url = Bundle.module.url(forResource: "FoodReference", withExtension: "json") else { throw FoodError.invalidRecord }
            raw = try Data(contentsOf: url)
        }
        guard let doc = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let order = doc["nutrients"] as? [String], let rows = doc["foods"] as? [[Any]] else { throw FoodError.invalidRecord }
        let keys = order.map { FoodNutrient(rawValue: $0) }
        var foods: [FoodReferenceFood] = []
        foods.reserveCapacity(rows.count)
        for row in rows {
            guard row.count >= 5, let id = row[0] as? Int, let name = row[1] as? String, let category = row[2] as? Int,
                  let values = row[3] as? [Any], let portions = row[4] as? [[Any]] else { continue }
            var nutrients = FoodNutrients()
            for (index, key) in keys.enumerated() where index < values.count {
                if let key, let value = (values[index] as? NSNumber)?.doubleValue { nutrients[key] = value }
            }
            let kept = portions.compactMap { p -> (String, Double)? in
                guard p.count == 2, let label = p[0] as? String, let grams = (p[1] as? NSNumber)?.doubleValue, grams > 0 else { return nil }
                return (label, grams)
            }
            foods.append(.init(id: id, name: name, category: category, per100g: nutrients, portions: kept,
                               defaultPortion: row.count > 5 ? row[5] as? Int : nil))
        }
        self.foods = foods
        tokens = foods.map { Self.words($0.name) }
        let index = Dictionary(foods.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var common: [(alias: String, index: Int)] = []
        for (alias, id) in (doc["common"] as? [String: Int]) ?? [:] {
            let key = Self.words(alias).joined(separator: " ")
            if let at = index[id], !common.contains(where: { $0.alias == key }) { common.append((key, at)) }
        }
        // Shortest first, so typing "ch" offers cheese before chickpeas.
        self.common = common.sorted { $0.alias.count == $1.alias.count ? $0.alias < $1.alias : $0.alias.count < $1.alias.count }
    }

    /// A name a person would recognise: the everyday name that points at the food ("Chicken"), otherwise the start of
    /// USDA's description up to about 32 characters, cut at a comma ("Lentils, sprouted").
    public func shortName(_ food: FoodReferenceFood) -> String {
        if let alias = common.first(where: { foods[$0.index].id == food.id })?.alias {
            // Raw or cooked changes a food by a third, so the name keeps it: "Chicken, roasted" (R3-MAC-05).
            let words = Self.words(food.name)
            let state = Self.preparation.first { words.contains($0) }
            let name = alias.prefix(1).uppercased() + alias.dropFirst()
            return state.map { "\(name), \($0)" } ?? name
        }
        var name = ""
        for part in food.name.components(separatedBy: ", ") {
            let next = name.isEmpty ? part : name + ", " + part
            if !name.isEmpty && next.count > 32 { break }
            name = next
        }
        return name
    }

    /// The everyday food a whole line names, like "eggs" or "greek yoghurt", or nil. Only these fill in a typed or
    /// spoken line by themselves; anything else waits for the person to pick a match.
    public func everyday(_ name: String) -> FoodReferenceFood? {
        let key = Self.words(name).filter { !Self.ignored.contains($0) }.joined(separator: " ")
        return common.first(where: { $0.alias == key }).map { foods[$0.index] }
    }

    /// The best matches for what a person typed, most likely first: the everyday food the words name, everyday foods
    /// that start with them (so "ban" offers bananas), then every food whose description holds each word.
    public func search(_ query: String, limit: Int = 8) -> [FoodReferenceFood] {
        let wanted = Self.words(query).filter { !Self.ignored.contains($0) }
        guard !wanted.isEmpty else { return [] }
        let key = wanted.joined(separator: " ")
        var first: [Int] = common.first(where: { $0.alias == key }).map { [$0.index] } ?? []
        if key.count >= 2 { for entry in common where entry.alias.hasPrefix(key) && !first.contains(entry.index) { first.append(entry.index) } }
        var scored: [(Double, Int)] = []
        for (index, words) in tokens.enumerated() {
            var score = 0.0
            var matchedAll = true
            for (position, word) in wanted.enumerated() {
                // A whole word counts far more than the start of one, so "egg" finds eggs before eggplant.
                var at = words.firstIndex(of: word)
                let whole = at != nil
                if at == nil, word.count >= 3 { at = words.firstIndex(where: { $0.hasPrefix(word) }) }
                guard let at else { matchedAll = false; break }
                score += whole ? 3 : 0.5
                // Words early in USDA's description name the food; later ones describe it.
                score -= Double(at) * 0.35
                if position == 0, at == 0 { score += 3 }
            }
            guard matchedAll else { continue }
            let food = foods[index]
            score -= Double(words.count) * 0.25
            if words.contains("raw") && Self.rawFirst.contains(food.category) { score += 1.5 }
            if words.contains("cooked") || words.contains("roasted") || words.contains("boiled") { score += Self.rawFirst.contains(food.category) ? 0 : 1 }
            if Self.lessLikely.contains(food.category) { score -= 2 }
            scored.append((score, index))
        }
        let ranked = scored.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.1).filter { !first.contains($0) }
        return (first + ranked).prefix(limit).map { foods[$0] }
    }

    /// `item` with values from the everyday food its name is, or `item` unchanged when the name is not one or the
    /// amount cannot be read as grams. Grams are used as typed; millilitres count as grams; a count or serving uses the food's household
    /// portion. Unmatched foods stay unknown, never zero.
    public func resolved(_ item: FoodItem, at date: Date) -> FoodItem {
        guard item.nutrients.values.isEmpty, let food = everyday(item.name),
              let match = try? self.item(food, name: item.name, amount: item.amount, unit: item.unit, keeping: item.provenance, at: date) else { return item }
        return match
    }

    /// A new item for `food`, `amount` of `unit`, with its source recorded after `keeping`.
    public func item(_ food: FoodReferenceFood, name: String? = nil, amount: Double, unit: FoodUnit,
                     keeping: [FoodProvenance] = [], at date: Date) throws -> FoodItem {
        var portion: String?
        let grams: Double
        switch unit {
        case .grams, .millilitres: grams = amount
        case .piece, .serving:
            guard let index = food.defaultPortion, food.portions.indices.contains(index) else { throw FoodError.invalidRecord }
            portion = food.portions[index].label
            grams = amount * food.portions[index].grams
        }
        guard grams.isFinite, grams > 0 else { throw FoodError.invalidRecord }
        let source = FoodProvenance(source: .reference, recordedAt: date,
                                    reference: .init(fdcID: food.id, description: food.name, portion: portion))
        let item = FoodItem(name: name ?? food.name, amount: amount, unit: unit, nutrients: try food.nutrients(grams: grams),
                            provenance: keeping + [source])
        try item.validate()
        return item
    }

    /// Lowercased words, plurals folded ("berries" and "berry", "tomatoes" and "tomato").
    public static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { word -> String in
                var w = String(word)
                if w.count > 4, w.hasSuffix("ies") { w = String(w.dropLast(3)) + "y" }
                else if w.count > 4, w.hasSuffix("oes") { w = String(w.dropLast(2)) }
                else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w = String(w.dropLast()) }
                return w
            }
    }
    /// How a food was prepared, in the order a name mentions it.
    static let preparation = ["raw", "roasted", "boiled", "baked", "fried", "grilled", "broiled", "scrambled", "poached", "cooked", "dry"]
    /// Words that say nothing about which food it is.
    static let ignored: Set<String> = ["a", "an", "the", "of", "with", "and", "some", "my", "fresh", "homemade", "bowl", "plate", "portion"]
    /// Fruit, vegetables, nuts, legumes and spices are usually eaten as listed raw; meat and grains cooked.
    static let rawFirst: Set<Int> = [2, 9, 11, 12, 16]
    /// Fast food, restaurant dishes and sweets win only when the query names them.
    static let lessLikely: Set<Int> = [21, 25, 18, 19]
}

public extension FoodCaptureSource {
    /// How a row names where its values came from.
    var sourceTitle: String {
        switch self {
        case .photoAI: "Photo estimate"
        case .barcode: "Barcode"
        case .label: "Label"
        case .typed: "Typed"
        case .voice: "Spoken"
        case .manualEdit: "Edited"
        case .agentText: "Ask estimate"
        case .reference: "USDA"
        }
    }
}

public extension FoodItem {
    /// Where this item's values came from: the last source that set them. A typed food matched to USDA reads "USDA".
    var valueSource: FoodCaptureSource? { provenance.last(where: { $0.source != .manualEdit })?.source }
    /// The source as a row says it. Typed numbers (quick add, or values typed into a food) are "Your totals"; a typed
    /// name with no numbers is "Typed" (R2-VET-08).
    var valueSourceTitle: String? {
        guard let source = valueSource else { return nil }
        return (source == .typed || source == .voice) && !nutrients.values.isEmpty ? "Your totals" : source.sourceTitle
    }
}

public extension FoodMeal {
    /// One word for where the meal's values came from, like "Barcode", or "Mixed sources". Nil for a meal with no items.
    /// Edits are left out: repeating a meal records one, and the review screen shows each edit on its item.
    var sourceSummary: String? { items.sourceSummary }
}

public extension Array where Element == FoodItem {
    /// See `FoodMeal.sourceSummary`.
    var sourceSummary: String? {
        let sources = Set(compactMap(\.valueSourceTitle))
        guard let first = sources.first else { return nil }
        return sources.count == 1 ? first : "Mixed sources"
    }
}
