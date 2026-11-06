import Foundation

/// The drawn shape of one seed in the plants field. Each plant category has its own.
public enum FoodSeedShape: String, CaseIterable, Sendable {
    /// Vegetables, and plants that are not in the list.
    case round
    /// Fruit: a round seed with a short stem.
    case berry
    /// Legumes: a kidney bean.
    case bean
    /// Whole grains: a slim grain with a crease.
    case grain
    /// Nuts and seeds: an almond shape.
    case almond
    /// Herbs and spices: a leaf.
    case leaf
    /// Mushrooms: a cap.
    case cap

    public init(_ category: FoodPlantCategory?) {
        switch category {
        case .vegetable?, nil: self = .round
        case .fruit?: self = .berry
        case .legume?: self = .bean
        case .wholeGrain?: self = .grain
        case .nut?, .seed?: self = .almond
        case .herb?, .spice?: self = .leaf
        case .mushroom?: self = .cap
        }
    }
}

/// One slot of the field: a plant's seed, or an empty slot still to fill.
public struct FoodSeed: Equatable, Sendable, Identifiable {
    public let index: Int
    /// Nil for an empty slot.
    public let plant: FoodWeekPlant?
    public let shape: FoodSeedShape
    /// First counted this week and in none of the weeks before.
    public let isNew: Bool
    /// The seed's colour as `#RRGGBB`, from its category's palette and stable for the plant.
    public let colorHex: String?
    public var id: String { plant?.key ?? "empty-\(index)" }
}

/// Plants per week as a field of 30 seed slots (contract p-food). Plants fill the slots in the order they were first
/// eaten this week, so the field grows through the week. A week past 30 adds rows of ten, so every plant keeps its
/// seed.
public struct FoodSeedField: Equatable, Sendable {
    public static let columns = 10
    public static let slots = FoodPlantWeek.weeklyGoal

    public let seeds: [FoodSeed]
    public let count: Int
    /// The newest of the new plants, newest first, at most three.
    public let newest: [FoodWeekPlant]
    /// Plants still to reach 30, zero once reached.
    public let remaining: Int

    /// - Parameter new: this week's plants that the earlier weeks did not hold (`FoodPlantWeek.newPlants`).
    public init(week: FoodPlantWeek, new: [FoodWeekPlant]) {
        let newKeys = Set(new.map(\.key))
        let ordered = week.plants.sorted { ($0.firstLocalDay, $0.name.lowercased(), $0.key) < ($1.firstLocalDay, $1.name.lowercased(), $1.key) }
        let total = max(Self.slots, (ordered.count + Self.columns - 1) / Self.columns * Self.columns)
        seeds = (0..<total).map { index in
            guard index < ordered.count else { return FoodSeed(index: index, plant: nil, shape: .round, isNew: false, colorHex: nil) }
            let plant = ordered[index]
            return FoodSeed(index: index, plant: plant, shape: FoodSeedShape(plant.category), isNew: newKeys.contains(plant.key),
                            colorHex: Self.color(for: plant))
        }
        count = week.count
        remaining = week.remainingToGoal
        newest = new.sorted { ($0.firstLocalDay, $1.name.lowercased()) > ($1.firstLocalDay, $0.name.lowercased()) }.prefix(3).map { $0 }
    }

    /// The sentence under the field, for the week of `today` (a `yyyy-MM-dd` local day).
    ///
    /// "New this week: shiitake, hemp seeds and fennel. Six more by Sunday." The count to 30 shows only while the week
    /// has days left after today; numbers up to nine are words, as in the rest of Loopr's sentences.
    /// - Parameter comparedWithEarlierWeeks: false when no earlier week had a meal, so nothing can be called new.
    public func sentence(today: String, comparedWithEarlierWeeks: Bool = true) -> String {
        guard count > 0 else { return "No plants counted yet this week. Photos, barcodes and your edits add them." }
        var sentences: [String] = []
        let names = newest.map(Self.inSentence)
        if !names.isEmpty, comparedWithEarlierWeeks { sentences.append("New this week: \(Self.list(names)).") }
        else if !names.isEmpty { sentences.append("Latest: \(Self.list(names)).") }
        let isSunday = FoodLocalDay.daysSinceEpoch(today).map { FoodLocalDay.isoWeekday($0) == 7 } ?? false
        if remaining == 0 { sentences.append("That makes \(count) this week.") }
        else if !isSunday { sentences.append("\(Self.words(remaining).capitalizedFirst) more by Sunday.") }
        return sentences.joined(separator: " ")
    }

    /// One to nine as words, larger numbers as digits.
    static func words(_ number: Int) -> String {
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (0..<names.count).contains(number) ? names[number] : String(number)
    }

    /// "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// List plants are common nouns, so they go lower case mid-sentence. A plant the person named keeps their spelling.
    static func inSentence(_ plant: FoodWeekPlant) -> String {
        plant.key.hasPrefix(FoodPlantList.customPrefix) ? plant.name : plant.name.lowercased()
    }

    /// Earthy tones per category, from the contract's seed colours.
    static let palettes: [FoodPlantCategory?: [String]] = [
        .vegetable: ["#3F7D3A", "#6F8F3A", "#2F6B3A", "#9CC44A", "#335C3A", "#D1783A"],
        .fruit: ["#C9442F", "#C23A5A", "#8A1F3F", "#3B4A8C", "#D9A75A"],
        .legume: ["#7A5233", "#8A5A2B", "#6E4A33", "#C08A5A", "#D9C49A"],
        .wholeGrain: ["#D8B06A", "#D9C49A", "#C08A5A", "#9A8F5C"],
        .nut: ["#8A6A45", "#7A4A2A", "#C08A5A", "#6E4A33"],
        .seed: ["#E8DCC0", "#EFE8D6", "#6B7A3A", "#7A5233"],
        .herb: ["#6B7A3A", "#9CC44A", "#3F7D3A", "#C9D9A0"],
        .spice: ["#D1783A", "#C9442F", "#D9A75A", "#8A5A2B"],
        .mushroom: ["#E8DCC0", "#8A6A45", "#C9B48A", "#6E4A33"],
        nil: ["#9A8F5C", "#6F8F3A", "#C08A5A"],
    ]

    static func color(for plant: FoodWeekPlant) -> String {
        let palette = palettes[plant.category] ?? palettes[nil] ?? ["#6F8F3A"]
        var hash: UInt32 = 2_166_136_261
        for byte in plant.key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
