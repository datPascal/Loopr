import Foundation

public struct FoodLabelResult: Equatable, Sendable {
    public let text: String
    public let basis: FoodUnit?
    public let nutrients: FoodNutrients
    public let issues: [String]
    public func item(name: String, at date: Date) throws -> FoodItem {
        guard let basis else { throw FoodError.invalidRecord }
        let item = FoodItem(name: name, amount: 100, unit: basis, nutrients: nutrients,
            provenance: [.init(source: .label, recordedAt: date, labelText: text)])
        try item.validate(); return item
    }
}

public enum FoodLabelParser {
    /// One resolved per-100-unit column. Ambiguous multi-column labels stay editable.
    public static func parse(_ text: String) -> FoodLabelResult {
        let input = String(text.prefix(20_000))
        let lower = input.lowercased().replacingOccurrences(of: "\u{00a0}", with: " ")
        let grams = lower.range(of: #"(?:per|pour|par|pro|/)\s*100\s*g\b"#, options: .regularExpression) != nil
        let ml = lower.range(of: #"(?:per|pour|par|pro|/)\s*100\s*ml\b"#, options: .regularExpression) != nil
        let serving = lower.range(of: #"per\s+(?:serving|portion)|par\s+portion|pro\s+portion"#, options: .regularExpression) != nil
        guard grams != ml, !serving else {
            return .init(text: input, basis: nil, nutrients: .init(), issues: ["Choose one nutrition column and enter its amount. The label's basis is unclear."])
        }
        let definitions: [(FoodNutrient, String, String)] = [
            (.energy, #"(?:energy|énergie|energie|calories)"#, "kcal"),
            (.protein, #"(?:protein|proteins|protéines|eiweiß|eiweiss)"#, "g"),
            (.carbs, #"(?:carbohydrate|carbohydrates|glucides|kohlenhydrate)"#, "g"),
            (.fat, #"(?:fat|total fat|matières grasses|fett)"#, "g"),
            (.fibre, #"(?:fiber|fibre|fibres|dietary fiber|ballaststoffe)"#, "g"),
            (.sugar, #"(?:sugars|sugar|total sugars|dont sucres|davon zucker)"#, "g"),
            (.salt, #"(?:salt|sel|salz)"#, "g"), (.caffeine, #"(?:caffeine|caféine|koffein)"#, "mg")
        ]
        var nutrients = FoodNutrients(); var issues: [String] = []
        for (nutrient, names, unit) in definitions {
            var readings: [Double] = []
            for raw in lower.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.range(of: "^" + names + #"\b"#, options: .regularExpression) != nil else { continue }
                let pattern = #"(?<![\d.,<>~])\b(\d+(?:[.,]\d+)?)\s*"# + unit + #"\b"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: line),
                      !line.contains("<"), !line.contains(">"), !line.contains("~"),
                      let number = Double(line[range].replacingOccurrences(of: ",", with: ".")), number.isFinite else {
                    issues.append("Check \(nutrient.rawValue) on the label."); continue
                }
                readings.append(number)
            }
            if readings.count == 1 { nutrients[nutrient] = readings[0] }
            else if readings.count > 1 { issues.append("More than one \(nutrient.rawValue) value was found.") }
        }
        if nutrients.values.isEmpty { issues.append("No clear nutrient values were found. Enter them from the label.") }
        return .init(text: input, basis: grams ? .grams : .millilitres, nutrients: nutrients, issues: issues)
    }
}

public enum FoodTextCapture {
    /// Local text capture records what was said without inventing nutrient estimates.
    public static func items(_ text: String, source: FoodCaptureSource, at date: Date) throws -> [FoodItem] {
        guard source == .typed || source == .voice, text.count <= 10_000 else { throw FoodError.invalidRecord }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ";\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 100 else { throw FoodError.invalidRecord }
        return try parts.map { text in
            var name = text; var amount = 1.0; var unit = FoodUnit.serving
            // "150 g chicken" keeps its unit. A bare leading number counts pieces: "2 eggs" is 2 pieces of eggs, not
            // one serving called "2 eggs" (ICP R2-UPG-20). "1,5" reads as 1.5.
            let pattern = #"^(\d+(?:[.,]\d+)?)(?:\s*(g|grams?|ml|millilitres?|servings?|pieces?)\s+|\s*x\s+|\s+)(.+)$"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let amountRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 3), in: text),
               let value = Double(text[amountRange].replacingOccurrences(of: ",", with: ".")), value.isFinite {
                amount = value; name = String(text[nameRange])
                if let unitRange = Range(match.range(at: 2), in: text) {
                    let label = text[unitRange].lowercased()
                    unit = label.hasPrefix("g") ? .grams : label.hasPrefix("m") ? .millilitres : label.hasPrefix("p") ? .piece : .serving
                } else { unit = .piece }
            } else if let spoken = spokenAmount(text) {
                // "two scrambled eggs" is 2 eggs, the way people type and say it (ICP R3-NEW-5).
                amount = spoken.amount; name = spoken.name; unit = .piece
            }
            if unit == .piece, let measured = measure(name) { name = measured.name; unit = measured.unit }
            let item = FoodItem(name: name, amount: amount, unit: unit, provenance: [.init(source: source, recordedAt: date)])
            try item.validate(); return item
        }
    }

    /// The name a quick add saves under when the person leaves the name blank.
    public static let quickAddName = "Quick add"

    /// A meal typed as its totals alone, like "600 kcal, 30 g protein", with no foods listed. It is one serving.
    /// Blank values stay unknown; at least one of energy, protein, carbs or fat is needed.
    public static func quickItem(name: String, nutrients: FoodNutrients, at date: Date) throws -> FoodItem {
        guard [FoodNutrient.energy, .protein, .carbs, .fat].contains(where: { nutrients[$0] != nil }) else { throw FoodError.invalidRecord }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = FoodItem(name: trimmed.isEmpty ? quickAddName : trimmed, amount: 1, unit: .serving, nutrients: nutrients,
                            provenance: [.init(source: .typed, recordedAt: date)])
        try item.validate(); return item
    }

    /// The amount words a meal is typed or spoken with.
    static let amountWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "half": 0.5, "half a": 0.5, "a couple of": 2, "a dozen": 12,
    ]

    /// "two scrambled eggs" gives 2 and "scrambled eggs". Nil when the text does not start with an amount word.
    static func spokenAmount(_ text: String) -> (amount: Double, name: String)? {
        let lowered = text.lowercased()
        // Longest first, so "a couple of" wins over "a".
        for word in amountWords.keys.sorted(by: { $0.count > $1.count }) where lowered.hasPrefix(word + " ") {
            let rest = text.dropFirst(word.count + 1).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty, let amount = amountWords[word] else { continue }
            return (amount, rest)
        }
        return nil
    }

    /// "slice of sourdough toast" counts slices of "sourdough toast"; "cups of coffee" counts servings of "coffee".
    static func measure(_ name: String) -> (name: String, unit: FoodUnit)? {
        let pattern = #"^(slices?|pieces?|cups?|glass(?:es)?|bowls?|portions?|servings?)\s+of\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let wordRange = Range(match.range(at: 1), in: name), let restRange = Range(match.range(at: 2), in: name) else { return nil }
        let word = name[wordRange].lowercased()
        return (String(name[restRange]), word.hasPrefix("slice") || word.hasPrefix("piece") ? .piece : .serving)
    }
}
