import Combine
import FoodKit
import Foundation

/// The Type and Speak entry: one line per food, with matches for the line being typed, then review. Picked matches and
/// everyday foods ("2 eggs", "banana") arrive with values; other lines stay unknown until the person adds them.
/// Quick add saves totals alone, without the review screen. The camera has its own flow, `FoodLensModel`.
@MainActor
final class FoodCaptureModel: ObservableObject {
    @Published var draft: FoodMealDraft
    @Published var text = ""
    @Published var message: String?
    @Published var review: FoodMealDraft?
    /// Foods taken from the matches, in the order they were picked.
    @Published var picked: [FoodItem] = []
    /// Foods the person logged before, newest first, one per name. Filled by `loadRecent`.
    @Published private(set) var recent: [FoodItem] = []
    @Published var quickName = ""
    @Published var quick: [FoodNutrient: String] = [:]
    @Published var quickMessage: String?
    let repository: AppFoodRepository
    let fixture: Bool
    let now: Date
    private let reference: FoodReference?
    init(draft: FoodMealDraft, repository: AppFoodRepository, fixture: Bool, now: Date, reference: FoodReference? = .shared) {
        self.draft = draft; self.repository = repository; self.fixture = fixture; self.now = now; self.reference = reference
        #if DEBUG
        // Screenshot tours start Type with text already in it: `--loopr-food-type-text=150 g chick`, "\n" for a new line.
        let flag = "--loopr-food-type-text="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(flag) }) {
            text = String(argument.dropFirst(flag.count)).replacingOccurrences(of: "\\n", with: "\n")
        }
        #endif
    }

    /// The line the matches are for: the last one, while it is being typed.
    var currentLine: String {
        text.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The person's own foods whose name holds every word of the current line.
    var mine: [FoodItem] {
        let words = FoodReference.words(currentLine)
        guard !words.isEmpty else { return [] }
        return recent.filter { item in
            let name = FoodReference.words(item.name)
            return words.allSatisfy { word in name.contains { $0.hasPrefix(word) } }
        }.prefix(3).map { $0 }
    }

    /// USDA matches for the current line, after the amount is taken off ("150 g chick" searches "chick").
    var matches: [FoodReferenceFood] {
        guard let reference, let line = parsedLine, line.name.count >= 2 else { return [] }
        return reference.search(line.name, limit: 6)
    }

    /// How a match reads for the line typed: "150 g" and its values when the line gives grams or millilitres, "2 x 1
    /// large" for a count, otherwise the food's own portion.
    func preview(_ food: FoodReferenceFood) -> (label: String, nutrients: FoodNutrients) {
        let portion = FoodCaptureView.portion(food)
        guard let line = parsedLine, line.unit != .serving || line.amount != 1 else {
            return (portion.label, (try? food.nutrients(grams: portion.grams)) ?? .init())
        }
        switch line.unit {
        case .grams, .millilitres:
            return ("\(FoodInput.text(line.amount)) \(line.unit.title)", (try? food.nutrients(grams: line.amount)) ?? .init())
        case .piece, .serving:
            return ("\(FoodInput.text(line.amount)) x \(portion.label)", (try? food.nutrients(grams: line.amount * portion.grams)) ?? .init())
        }
    }

    /// The current line read as amount, unit and name.
    private var parsedLine: FoodItem? {
        let line = currentLine
        guard !line.isEmpty else { return nil }
        return try? FoodTextCapture.items(line, source: .typed, at: now).first
    }

    /// Takes a USDA match for the current line, with the line's amount when it has one. The food keeps the match's
    /// name, not a half-typed "chick" (R2-VET-05).
    func pick(_ food: FoodReferenceFood) {
        guard let reference else { return }
        let line = parsedLine
        let name = reference.shortName(food)
        let typed = [FoodProvenance(source: .typed, recordedAt: now)]
        let typedAmount = line.map { $0.unit != .serving || $0.amount != 1 } ?? false
        let item = (typedAmount ? try? reference.item(food, name: name, amount: line?.amount ?? 1, unit: line?.unit ?? .serving, keeping: typed, at: now) : nil)
            ?? (try? reference.item(food, name: name, amount: 1, unit: .serving, keeping: typed, at: now))
            ?? (try? reference.item(food, name: name, amount: 100, unit: .grams, keeping: typed, at: now))
        guard let item else { return }
        picked.append(item); dropCurrentLine()
    }

    /// Takes one of the person's own foods as it was logged last time.
    func pick(_ item: FoodItem) {
        picked.append(item.duplicated()); dropCurrentLine()
    }

    func unpick(_ id: UUID) { picked.removeAll { $0.id == id } }

    private func dropCurrentLine() {
        var lines = text.components(separatedBy: .newlines)
        lines.removeLast()
        text = lines.joined(separator: "\n")
    }

    /// The meal as typed so far: picked foods, then each typed line, split into its foods and matched where Loopr knows
    /// them. Throws when there is nothing to add.
    func meal(source: FoodCaptureSource) throws -> [FoodItem] {
        let lines = Self.expanded(text, reference: reference, now: now)
        let typed = lines.isEmpty ? [] : try FoodTextCapture.items(lines.joined(separator: "\n"), source: source, at: now)
        guard !(typed.isEmpty && picked.isEmpty) else { throw FoodError.invalidRecord }
        return picked + typed.map { reference?.resolved($0, at: now) ?? $0 }
    }

    /// Whether every food in the meal has calories, so it can be added without the review screen (R2-MAC-02).
    var allKnown: Bool {
        guard let items = try? meal(source: .typed) else { return false }
        return items.allSatisfy { $0.nutrients[.energy] != nil }
    }

    /// The draft for saving straight away.
    func directDraft(source: FoodCaptureSource) -> FoodMealDraft? {
        guard let items = try? meal(source: source), items.allSatisfy({ $0.nutrients[.energy] != nil }) else { return nil }
        var meal = draft; meal.items = items
        return meal
    }

    func reviewText(source: FoodCaptureSource) {
        do { draft.items = try meal(source: source); review = draft; message = nil }
        catch { message = "Enter a food to review. Use a new line for each item." }
    }

    /// Lines as foods: "2 eggs and toast" and "toast with butter" become two foods when every part is one Loopr knows;
    /// "fish and chips" stays whole. Typed and spoken text follow the same rule (R2-NEW-01, R2-MAC-03, R2-VET-06).
    nonisolated static func expanded(_ text: String, reference: FoodReference?, now: Date) -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let reference else { return lines }
        func known(_ part: String) -> Bool {
            guard let item = try? FoodTextCapture.items(part, source: .typed, at: now).first else { return false }
            return reference.everyday(item.name) != nil
        }
        return lines.flatMap { line -> [String] in
            if known(line) { return [line] }
            let parts = line.replacingOccurrences(of: #"\s*(,|;|&|\+|\band\b|\bwith\b|\bplus\b)\s*"#, with: "\n",
                                                  options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.count > 1 && parts.allSatisfy(known) ? parts : [line]
        }
    }

    /// Foods from the last 30 days and favourites, newest first, one per name.
    func loadRecent(calendar: Calendar) async {
        guard recent.isEmpty else { return }
        var items: [FoodItem] = []
        if let start = calendar.date(byAdding: .day, value: -30, to: now),
           let first = try? FoodMeal.day(at: start, timeZoneIdentifier: calendar.timeZone.identifier),
           let last = try? FoodMeal.day(at: now, timeZoneIdentifier: calendar.timeZone.identifier),
           let data = try? await repository.overview(from: first, through: last) {
            items += data.meals.sorted { $0.occurredAt > $1.occurredAt }.flatMap(\.items)
        }
        items += ((try? await repository.favorites()) ?? []).flatMap(\.items)
        var seen = Set<String>()
        recent = items.filter { $0.nutrients[.energy] != nil && seen.insert($0.name.lowercased()).inserted }
    }

    /// Whether any quick add value is typed, which is when its Save button shows.
    var hasQuickValues: Bool { quick.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    /// The meal quick add saves, or nil with `quickMessage` set when a value does not read as a number.
    func quickDraft() -> FoodMealDraft? {
        do {
            var nutrients = FoodNutrients()
            for (nutrient, value) in quick { nutrients[nutrient] = try FoodInput.number(value, optional: true) }
            var meal = draft
            meal.items = [try FoodTextCapture.quickItem(name: quickName, nutrients: nutrients, at: now)]
            quickMessage = nil
            return meal
        } catch {
            quickMessage = "Enter numbers only. Leave a field blank if you don't know it."
            return nil
        }
    }
}
