import Foundation

/// Turns the unit text a lab printed into the catalog's unit symbol. It accepts the common printed variants of
/// each unit, where the variant means exactly the same unit, and nothing else. It never guesses: "G/L" is a
/// count unit (10^9/L), "g/L" is grams per litre, and a unit it does not know comes back nil.
public enum LabUnitText {
    /// Spellings that differ only by case or by the prefix letter matter here, so they match as printed.
    private static let exact: [String: String] = [
        "G/L": "10^9/L", "G/l": "10^9/L", "Gpt/L": "10^9/L", "Gpt/l": "10^9/L"
    ]

    /// Spellings after `fold`: lower case, micro sign turned into "u", superscripts turned into "^2", "^3" and "^9", and "×" into "x".
    private static let folded: [String: String] = {
        var table: [String: String] = [:]
        func add(_ symbol: String, _ spellings: [String]) {
            for spelling in spellings { table[spelling] = symbol }
        }
        add("mg/dL", ["mg/dl"])
        add("g/dL", ["g/dl"])
        add("g/L", ["g/l"])
        add("mg/L", ["mg/l"])
        add("mmol/L", ["mmol/l"])
        add("µmol/L", ["umol/l"])
        add("nmol/L", ["nmol/l"])
        add("pmol/L", ["pmol/l"])
        add("%", ["%"])
        add("mmol/mol", ["mmol/mol", "mmol/molhb"])
        add("fL", ["fl"])
        add("µm³", ["um3", "um^3"])
        add("U/L", ["u/l", "iu/l"])
        add("µkat/L", ["ukat/l"])
        add("10^3/µL", ["10^3/ul", "x10^3/ul", "x10e3/ul", "10e3/ul", "10*3/ul", "k/ul", "tsd/ul", "tsd./ul"])
        add("10^9/L", ["10^9/l", "x10^9/l", "x10e9/l", "10e9/l", "10*9/l", "gpt/l", "/nl"])
        add("µIU/mL", ["uiu/ml", "uu/ml"])
        add("mIU/L", ["miu/l", "mu/l"])
        add("ng/mL", ["ng/ml"])
        add("µg/L", ["ug/l"])
        add("mL/min/1.73 m²", ["ml/min/1.73m2", "ml/min/1.73m^2", "ml/min/1,73m2", "ml/min/1,73m^2"])
        return table
    }()

    private static func fold(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            switch character {
            case "\u{00B5}", "\u{03BC}": result.append("u")
            case "\u{00B2}": result.append("^2")
            case "\u{00B3}": result.append("^3")
            case "\u{2079}": result.append("^9")
            case "\u{00D7}": result.append("x")
            default: result.append(character)
            }
        }
        return result
    }

    /// The catalog unit symbol for printed unit text, or nil when the text is not a known spelling.
    public static func symbol(forPrinted printed: String) -> String? {
        let squeezed = printed.filter { !$0.isWhitespace && $0 != "\u{00A0}" }
        guard !squeezed.isEmpty else { return nil }
        if let symbol = exact[squeezed] { return symbol }
        return folded[fold(squeezed)]
    }
}
