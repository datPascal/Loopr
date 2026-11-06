import Foundation

/// How the decimal separator reads in one report.
enum LabDecimalStyle: Sendable, Equatable {
    case comma
    case dot
    case undetermined

    /// Votes from numbers with one or two decimals ("4,9", "0.82"), then from the language of the labels.
    static func detect(in texts: [String]) -> LabDecimalStyle {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\d.,])\d{1,4}([.,])\d{1,2}(?![\d.,])"#) else { return .undetermined }
        var commas = 0
        var dots = 0
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let separator = Range(match.range(at: 1), in: text) else { continue }
                if text[separator] == "," { commas += 1 } else { dots += 1 }
            }
        }
        if commas != dots { return commas > dots ? .comma : .dot }
        let folded = LabNameMatcher.normalise(texts.joined(separator: " "))
        let german = ["befund", "datum", "referenz", "nuchtern", "einheit", "ergebnis", "probenentnahme", "eingangsdatum", "labor"]
        let english = ["result", "reference", "collected", "units", "fasting", "specimen", "laboratory"]
        let germanVotes = german.filter { folded.contains($0) }.count
        let englishVotes = english.filter { folded.contains($0) }.count
        if germanVotes != englishVotes { return germanVotes > englishVotes ? .comma : .dot }
        return .undetermined
    }
}

enum LabReportNumbers {
    struct Parsed: Sendable, Equatable {
        /// Dot notation with an optional leading minus, ready for `LabNumberText.parse`.
        let dotText: String
        /// A lone separator with exactly three digits after it ("1,234"), read by the report's decimal style.
        let ambiguous: Bool
        /// An "O" or "o" read as a zero.
        let repaired: Bool
    }

    /// Reads one printed number. Returns nil when it cannot be read without guessing, for example "12.09.2026".
    static func parse(_ raw: String, style: LabDecimalStyle) -> Parsed? {
        var text = raw
        var repaired = false
        if text.contains(where: { $0 == "O" || $0 == "o" }) {
            guard text.contains(where: { $0.isASCII && $0.isNumber }),
                  text.allSatisfy({ "0123456789.,-Oo".contains($0) }) else { return nil }
            text = text.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0")
            repaired = true
        }
        var sign = ""
        if text.hasPrefix("-") { sign = "-"; text.removeFirst() }
        guard let first = text.first, let last = text.last, first.isASCII, first.isNumber, last.isASCII, last.isNumber,
              text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }) else { return nil }

        let separators = text.filter { $0 == "." || $0 == "," }
        if separators.isEmpty { return Parsed(dotText: sign + text, ambiguous: false, repaired: repaired) }

        if separators.count == 1, let separator = separators.first {
            let parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let integer = parts[0], fraction = parts[1]
            if fraction.count != 3 || integer.allSatisfy({ $0 == "0" }) || integer.count > 3 {
                return Parsed(dotText: sign + integer + "." + fraction, ambiguous: false, repaired: repaired)
            }
            // "1,234" or "1.234": a decimal or a thousands mark. Only the report's own style can say.
            switch style {
            case .undetermined:
                return nil
            case .comma:
                let thousands = separator == "."
                return Parsed(dotText: sign + integer + (thousands ? "" : ".") + fraction, ambiguous: true, repaired: repaired)
            case .dot:
                let thousands = separator == ","
                return Parsed(dotText: sign + integer + (thousands ? "" : ".") + fraction, ambiguous: true, repaired: repaired)
            }
        }

        // Two or more separators: thousands marks, and at most one different mark for the decimals.
        guard let decimalMark = separators.last else { return nil }
        let thousandsMark: Character = decimalMark == "." ? "," : "."
        let allSame = separators.allSatisfy { $0 == decimalMark }
        let wholePart: String
        var fractionPart = ""
        let groupMark: Character
        if allSame {
            wholePart = text
            groupMark = decimalMark
        } else {
            guard separators.dropLast().allSatisfy({ $0 == thousandsMark }) else { return nil }
            let cut = text.lastIndex(of: decimalMark) ?? text.endIndex
            wholePart = String(text[..<cut])
            fractionPart = String(text[text.index(after: cut)...])
            guard !fractionPart.isEmpty else { return nil }
            groupMark = thousandsMark
        }
        let groups = wholePart.split(separator: groupMark, omittingEmptySubsequences: false).map(String.init)
        guard groups.count >= 2, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        let integer = groups.joined()
        return Parsed(dotText: sign + integer + (fractionPart.isEmpty ? "" : "." + fractionPart), ambiguous: false, repaired: repaired)
    }
}
