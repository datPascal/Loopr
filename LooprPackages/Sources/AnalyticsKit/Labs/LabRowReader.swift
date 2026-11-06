import Foundation

struct LabToken: Sendable, Equatable {
    var text: String
    var confidence: Double

    /// Splits recognised text on spaces. A number glued to its unit ("4,9mmol/l") is split into two tokens, but only
    /// when the rest is a unit spelling Loopr knows.
    static func tokenise(_ text: String, confidence: Double) -> [LabToken] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).flatMap { piece -> [LabToken] in
            let word = String(piece)
            if let split = splitGlued(word) {
                return [LabToken(text: split.0, confidence: confidence), LabToken(text: split.1, confidence: confidence)]
            }
            return [LabToken(text: word, confidence: confidence)]
        }
    }

    private static func splitGlued(_ word: String) -> (String, String)? {
        let numberCharacters = Set("0123456789.,-<>≤≥=Oo")
        var end = word.startIndex
        while end < word.endIndex, numberCharacters.contains(word[end]) { end = word.index(after: end) }
        guard end > word.startIndex, end < word.endIndex else { return nil }
        let number = String(word[..<end])
        let rest = String(word[end...])
        guard number.contains(where: { $0.isASCII && $0.isNumber }), LabUnitText.symbol(forPrinted: rest) != nil else { return nil }
        return (number, rest)
    }
}

/// Reads one test out of a row of tokens, starting at a given token. See `LabReportParser`.
struct LabRowReader: Sendable {
    let style: LabDecimalStyle
    let options: LabReportParser.Options

    struct ParsedValue {
        var subject: LabValueSubject
        var assay: String?
        var number: Decimal
        var printedValue: String?
        var comparator: LabValueComparator?
        var unit: String?
        var range: LabReferenceRange
        var flag: String?
        var confidence: Double
        var needsReview: Bool
        /// Why the value needs a look. Empty when it does not.
        var reasons: [LabReviewReason]
        /// The name as printed on the page.
        var printedName: String
    }

    struct Result {
        enum Kind { case value(ParsedValue), skipped(String), ignored }
        var kind: Kind
        var next: Int
    }

    // MARK: Token shapes

    static func isNumberShape(_ token: String) -> Bool {
        guard !token.isEmpty, token.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        for (offset, character) in token.enumerated() {
            if character == "-" { if offset != 0 { return false } } else if !"0123456789.,Oo".contains(character) { return false }
        }
        return true
    }

    private static let flagWords: Set<String> = ["high", "low", "hoch", "niedrig", "erhöht", "erhoht", "erniedrigt"]
    private static let flagTokens: Set<String> = ["H", "L", "HH", "LL", "*", "**", "+", "++", "↑", "↓", "↑↑", "↓↓", "(H)", "(L)", "H*", "L*"]

    static func isFlag(_ token: String) -> Bool {
        flagTokens.contains(token) || flagWords.contains(token.lowercased())
    }

    private static let qualitative: Set<String> = ["negativ", "negative", "positiv", "positive", "neg", "pos", "nichtnachweisbar", "notdetected"]
    private static let rangeLabels: Set<String> = [
        "ref", "referenz", "referenzbereich", "referenzwert", "referenzwerte", "referenzintervall", "normbereich", "normalbereich",
        "bereich", "range", "reference", "referencerange", "refrange", "soll", "sollwert"
    ]
    private static let specimenWords: Set<String> = ["i.s.", "i.p.", "i.b.", "serum", "plasma", "blood", "blut", "vollblut", "s", "p", "im", "in", "edta-blut"]
    private static let rangeWords: Set<String> = ["-", "–", "—", "−", "to", "bis", "<", ">", "≤", "≥", "<=", ">=", "(", ")",
                                                   "negativ", "negative", "neg.", "nicht", "nachweisbar", "not", "detected", "positiv", "positive"]

    // MARK: Reading

    private struct ValueRead {
        var core: String
        var op: String?
        var qualitative: Bool
        var flag: String?
        var length: Int
    }

    func read(_ tokens: [LabToken], from start: Int) -> Result {
        let texts = tokens.map(\.text)
        let n = texts.count
        guard start < n else { return Result(kind: .ignored, next: n) }

        var entry: LabMarkerAliases.Entry?
        var nameEnd = start
        var valueIndex = start
        if let match = LabNameMatcher.match(texts, from: start) {
            entry = match.entry
            nameEnd = start + match.length
            var k = nameEnd
            var skippedQualifiers = 0
            while k < n, readValue(texts, at: k) == nil, skippedQualifiers < 3, isQualifier(texts, at: k) {
                k += 1
                skippedQualifiers += 1
            }
            valueIndex = k
        } else {
            guard texts[start].contains(where: { $0.isLetter }) else { return Result(kind: .ignored, next: start + 1) }
            var j = start
            while j < n, readValue(texts, at: j) == nil { j += 1 }
            guard j < n else { return Result(kind: .ignored, next: n) }
            guard j > start, j - start <= 7 else { return Result(kind: .ignored, next: start + 1) }
            nameEnd = j
            valueIndex = j
        }

        guard valueIndex < n, let value = readValue(texts, at: valueIndex) else {
            // A known name with no readable value counts as a skipped row only when a unit or a range follows it.
            guard entry != nil else { return Result(kind: .ignored, next: start + 1) }
            // A garbled number ("9?2") is a value that cannot be read, not a missing one.
            let garbled = valueIndex < n && texts[valueIndex].contains(where: { $0.isASCII && $0.isNumber })
            let tail = readTail(texts, from: garbled ? valueIndex + 1 : valueIndex, flag: nil)
            if tail.unitSymbol != nil || tail.rangeFound {
                return Result(kind: .skipped(rowText(texts, start, tail.end)), next: tail.end)
            }
            return Result(kind: .ignored, next: max(valueIndex, start + 1))
        }

        let tail = readTail(texts, from: valueIndex + value.length, flag: value.flag)
        let end = max(tail.end, valueIndex + value.length)
        let confidence = tokens[start..<end].map(\.confidence).min() ?? 0
        let printedName = texts[start..<nameEnd].joined(separator: " ")

        // A name that only means this marker with a certain unit, printed with another unit, is another test.
        if let allowed = entry?.onlyWithUnits, !(tail.unitSymbol.map(allowed.contains) ?? false) { entry = nil }

        let unreadable = Result(kind: .skipped(rowText(texts, start, end)), next: end)
        if entry == nil, tail.unitSymbol == nil, !tail.rangeFound { return Result(kind: .ignored, next: end) }
        if value.qualitative {
            return entry == nil ? Result(kind: .ignored, next: end) : unreadable
        }
        // A result printed as a limit ("<0.3", ">200") keeps its sign. Any other sign ("=") cannot be read.
        var comparator: LabValueComparator?
        if let op = value.op {
            guard let sign = LabValueComparator(printed: op) else { return unreadable }
            comparator = sign
        }
        guard let parsed = LabReportNumbers.parse(value.core, style: style),
              let number = LabNumberText.parse(parsed.dotText) else {
            return entry == nil && tail.unitSymbol == nil ? Result(kind: .ignored, next: end) : unreadable
        }

        var reasons: [LabReviewReason] = []
        if parsed.ambiguous { reasons.append(.separatorUnclear) }
        if parsed.repaired { reasons.append(.letterReadAsZero) }
        if confidence < options.lowConfidenceThreshold { reasons.append(.faintRow) }
        if tail.rangeAmbiguous || tail.rangeRepaired { reasons.append(.rangeUnclear) }
        let subject: LabValueSubject
        var assay: String?
        var unit: String?
        if let entry {
            subject = .marker(entry.marker)
            assay = entry.assay
            if let symbol = tail.unitSymbol, entry.marker.marker.units.contains(symbol) {
                unit = tail.unitPrinted
            } else {
                reasons.append(tail.unitSymbol == nil && !tail.unrecognisedUnit ? .unitMissing : .unitUnknown)
            }
        } else {
            subject = .other(name: printedName)
            unit = tail.unitPrinted
            if unit == nil { reasons.append(tail.unrecognisedUnit ? .unitUnknown : .unitMissing) }
        }

        return Result(kind: .value(ParsedValue(
            subject: subject, assay: assay, number: number.value, printedValue: number.printedValue, comparator: comparator,
            unit: unit, range: tail.range, flag: tail.flag, confidence: min(max(confidence, 0), 1),
            needsReview: !reasons.isEmpty, reasons: reasons, printedName: printedName)), next: end)
    }

    private func rowText(_ texts: [String], _ from: Int, _ to: Int) -> String {
        texts[from..<max(from, min(to, texts.count))].joined(separator: " ")
    }

    private func isQualifier(_ texts: [String], at index: Int) -> Bool {
        let token = texts[index]
        if LabUnitText.symbol(forPrinted: token) != nil || LabNameMatcher.match(texts, from: index) != nil { return false }
        if token.hasPrefix("(") || token.hasSuffix(")") { return true }
        if Self.specimenWords.contains(token.lowercased()) { return true }
        return token.allSatisfy { $0.isLetter || $0 == "." || $0 == "-" } && token.contains(where: { $0.isLetter })
    }

    private func readValue(_ texts: [String], at index: Int) -> ValueRead? {
        guard index < texts.count else { return nil }
        var text = texts[index]
        var length = 1
        var op: String?
        if ["<", ">", "≤", "≥", "<=", ">="].contains(text), index + 1 < texts.count {
            op = text
            text = texts[index + 1]
            length = 2
        } else {
            var prefix = ""
            while let first = text.first, "<>≤≥=".contains(first) { prefix.append(first); text.removeFirst() }
            if !prefix.isEmpty { op = prefix }
        }
        if Self.qualitative.contains(LabNameMatcher.normalise(text)) {
            return ValueRead(core: text, op: op, qualitative: true, flag: nil, length: length)
        }
        var flag: String?
        while let last = text.last, "*+↑↓".contains(last) { flag = String(last) + (flag ?? ""); text.removeLast() }
        if let last = text.last, last == "H" || last == "L", text.dropLast().last?.isNumber == true {
            flag = String(last) + (flag ?? "")
            text.removeLast()
        }
        guard Self.isNumberShape(text) else { return nil }
        return ValueRead(core: text, op: op, qualitative: false, flag: flag, length: length)
    }

    // MARK: After the value

    private struct Tail {
        var unitPrinted: String?
        var unitSymbol: String?
        var flag: String?
        var range = LabReferenceRange.none
        var rangeFound = false
        var rangeAmbiguous = false
        var rangeRepaired = false
        var unrecognisedUnit = false
        var end: Int
    }

    private func unitMatch(_ texts: [String], from index: Int) -> (length: Int, printed: String, symbol: String)? {
        guard index < texts.count else { return nil }
        for length in stride(from: min(4, texts.count - index), through: 1, by: -1) {
            let printed = texts[index..<(index + length)].joined()
            if let symbol = LabUnitText.symbol(forPrinted: printed) { return (length, printed, symbol) }
        }
        return nil
    }

    private func readTail(_ texts: [String], from start: Int, flag: String?) -> Tail {
        var tail = Tail(flag: flag, end: start)
        var p = start
        func takeFlags() {
            while p < texts.count, Self.isFlag(texts[p]) {
                tail.flag = tail.flag ?? texts[p]
                p += 1
            }
        }
        takeFlags()
        if let unit = unitMatch(texts, from: p) {
            tail.unitPrinted = unit.printed
            tail.unitSymbol = unit.symbol
            p += unit.length
        } else if p < texts.count, texts[p].first?.isLetter == true, texts[p].contains("/") || texts[p].contains("%"),
                  LabNameMatcher.match(texts, from: p) == nil {
            // A unit Loopr does not know ("pg/ml"): step over it so the range after it still reads. The unit stays nil.
            tail.unrecognisedUnit = true
            p += 1
        }
        takeFlags()
        if let range = readRange(texts, from: p) {
            tail.range = range.range
            tail.rangeFound = true
            tail.rangeAmbiguous = range.ambiguous
            tail.rangeRepaired = range.repaired
            p += range.consumed
            takeFlags()
            if tail.unitSymbol == nil, let unit = unitMatch(texts, from: p) {
                tail.unitPrinted = unit.printed
                tail.unitSymbol = unit.symbol
                p += unit.length
            }
            takeFlags()
        }
        tail.end = p
        return tail
    }

    // MARK: Reference range

    private struct RangeRead {
        var range: LabReferenceRange
        var consumed: Int
        var ambiguous: Bool
        var repaired: Bool
    }

    private func isRangeish(_ token: String) -> Bool {
        token.contains(where: { $0.isASCII && $0.isNumber }) || Self.rangeWords.contains(token.lowercased())
            || token.allSatisfy { "()<>≤≥=-–—−".contains($0) }
    }

    private func readRange(_ texts: [String], from start: Int) -> RangeRead? {
        var p = start
        while p < texts.count, Self.rangeLabels.contains(LabNameMatcher.normalise(texts[p])) { p += 1 }
        let labels = p - start
        var window: [String] = []
        var q = p
        while q < texts.count, window.count < 7, isRangeish(texts[q]) {
            window.append(texts[q])
            q += 1
        }
        for length in stride(from: window.count, through: 1, by: -1) {
            let cleaned = window[0..<length].joined(separator: " ")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let read = interpretRange(cleaned) {
                return RangeRead(range: read.range, consumed: labels + length, ambiguous: read.ambiguous, repaired: read.repaired)
            }
        }
        return nil
    }

    private static let numberPattern = "[0-9Oo.,]*[0-9][0-9Oo.,]*"

    private func interpretRange(_ text: String) -> (range: LabReferenceRange, ambiguous: Bool, repaired: Bool)? {
        let full = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        func number(_ raw: String) -> (value: Decimal, ambiguous: Bool, repaired: Bool)? {
            guard let parsed = LabReportNumbers.parse(raw, style: style), let value = LabNumberText.parse(parsed.dotText) else { return nil }
            return (value.value, parsed.ambiguous, parsed.repaired)
        }

        if let regex = try? NSRegularExpression(pattern: "^(\(Self.numberPattern))\\s*(?:-|to|bis)\\s*(\(Self.numberPattern))$", options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: full), let low = group(match, 1).flatMap(number), let high = group(match, 2).flatMap(number) {
            return (LabReferenceRange(low: low.value, high: high.value), low.ambiguous || high.ambiguous, low.repaired || high.repaired)
        }
        if let regex = try? NSRegularExpression(pattern: "^(<=|>=|<|>|≤|≥)\\s*(\(Self.numberPattern))$"),
           let match = regex.firstMatch(in: text, range: full), let op = group(match, 1), let printed = group(match, 2),
           let parsed = number(printed) {
            return (LabReferenceRange(text: op + printed), parsed.ambiguous, parsed.repaired)
        }
        if Self.qualitative.contains(LabNameMatcher.normalise(text)) || text.lowercased() == "neg." || text.lowercased() == "pos." {
            return (LabReferenceRange(text: text), false, false)
        }
        return nil
    }
}
