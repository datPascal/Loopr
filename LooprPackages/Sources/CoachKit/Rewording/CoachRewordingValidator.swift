import Foundation

/// Why a rewording was discarded and the rule text shown instead.
public enum CoachRewordRejection: Error, Equatable, Sendable {
    /// Pattern lines are labels in a list, not sentences, so they are never reworded.
    case notRewordable
    case modelUnavailable
    case modelFailed
    case timedOut
    case empty
    case tooLong
    case tooShort
    case forbiddenWord(String)
    case exclamationMark
    case dash
    /// The text states a digit group the note does not.
    case newNumber(String)
    /// The note states a digit group the text left out, or states it fewer times.
    case droppedNumber(String)
    /// The text states a digit group more often than the note does.
    case repeatedNumber(String)
    /// A number written out in words that the note did not use, which the digit check cannot see.
    case spelledNumber(String)
    /// A number is there, but not written as the note wrote it, such as "4 hours" for "4 h".
    case numberFormatChanged(String)
    /// The text says higher where the note says lower, or leaves out the comparison.
    case directionChanged
    /// A rule title, label or weekday the note names is not in the text as written.
    case nameChanged(String)
    /// The numbers could not be found again in the text to draw them highlighted.
    case runMappingFailed
}

/// The limits on a rewording.
public struct CoachRewordLimits: Equatable, Sendable {
    /// The text may be this share of the rule text, in characters, at the shortest and the longest.
    public let lengthRatio: ClosedRange<Double>
    /// How long the model has to answer.
    public let timeout: Duration

    public init(lengthRatio: ClosedRange<Double> = 0.5...1.5, timeout: Duration = .seconds(5)) {
        self.lengthRatio = lengthRatio; self.timeout = timeout
    }

    public static let standard = CoachRewordLimits()
}

/// Decides whether a rewording may replace a note's text, and draws its numbers highlighted again. It is pure: the same
/// note and the same candidate always give the same answer.
public enum CoachRewordValidator {
    /// Words for a comparison. A rewording keeps the same ones the note uses, so a "lower" never becomes a "higher".
    static let directionWords: Set<String> = ["lower", "higher", "below", "above", "longer", "shorter", "faster", "slower"]

    /// Numbers written out. A rewording may use one only if the note's own text does.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "half", "twice", "double", "triple",
        "dozen", "couple",
    ]

    /// The reworded note, or the reason to keep the rule text.
    public static func validate(_ candidate: String, for note: CoachNote,
                                limits: CoachRewordLimits = .standard) -> Result<CoachNote, CoachRewordRejection> {
        let text = normalized(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        // Words and marks that never ship.
        if text.contains("!") { return .failure(.exclamationMark) }
        if text.contains("\u{2014}") || text.contains("\u{2013}") || text.contains(" - ") { return .failure(.dash) }
        let lowered = text.lowercased()
        let words = lowered.split { !$0.isLetter }.map(String.init)
        for banned in ["cause", "causes", "caused", "causing", "because"] where words.contains(banned) {
            return .failure(.forbiddenWord(banned))
        }
        if lowered.contains("due to") { return .failure(.forbiddenWord("due to")) }

        // Length.
        let original = normalized(note.text)
        let ratio = Double(text.count) / Double(max(original.count, 1))
        if ratio > limits.lengthRatio.upperBound { return .failure(.tooLong) }
        if ratio < limits.lengthRatio.lowerBound { return .failure(.tooShort) }

        // Numbers: the same digit groups, none new, none missing, none more often than the note says them.
        let noteTokens = NoteDigits.tokens(in: original)
        let candidateTokens = NoteDigits.tokens(in: text)
        let known = Set(noteTokens)
        if let extra = candidateTokens.first(where: { !known.contains($0) }) { return .failure(.newNumber(extra)) }
        // Each digit group as many times as the note says it, in any order.
        var seen = Set<String>()
        for token in noteTokens where seen.insert(token).inserted {
            let expected = noteTokens.filter { $0 == token }.count
            let found = candidateTokens.filter { $0 == token }.count
            if found < expected { return .failure(.droppedNumber(token)) }
            if found > expected { return .failure(.repeatedNumber(token)) }
        }
        let originalWords = Set(original.lowercased().split { !$0.isLetter }.map(String.init))
        if let spelled = words.first(where: { numberWords.contains($0) && !originalWords.contains($0) }) {
            return .failure(.spelledNumber(spelled))
        }

        // Each number as the note writes it, units and all.
        let numbers = note.numbers.map { (number: $0, displayed: normalized($0.displayed)) }
        for entry in numbers where !text.contains(entry.displayed) { return .failure(.numberFormatChanged(entry.number.displayed)) }

        // The comparison keeps its direction.
        let originalDirections = Set(originalWords).intersection(directionWords)
        let candidateDirections = Set(words).intersection(directionWords)
        let originalInLine = original.lowercased().contains("in line with")
        if originalDirections != candidateDirections || originalInLine != lowered.contains("in line with") {
            return .failure(.directionChanged)
        }

        // Names, as written.
        for phrase in note.protectedPhrases where !lowered.contains(normalized(phrase).lowercased()) {
            return .failure(.nameChanged(phrase))
        }

        guard let runs = runs(for: text, note: note) else { return .failure(.runMappingFailed) }
        let reworded = CoachNote(kind: note.kind, runs: runs, receipt: note.receipt, daysCovered: note.daysCovered,
                                 comparisonGroup: note.comparisonGroup, chips: note.chips,
                                 supportingNumbers: note.supportingNumbers)
        return .success(reworded)
    }

    /// The text as runs again. Each of the note's numbers is found where the text states it and drawn as the note drew
    /// it, highlighted or not. Nil when a digit is left outside every number, so the rule text shows instead.
    static func runs(for text: String, note: CoachNote) -> [NoteRun]? {
        var byDisplayed: [String: (number: NoteNumber, highlighted: Bool)] = [:]
        for run in note.runs {
            guard let number = run.number else { continue }
            let key = normalized(number.displayed)
            if let existing = byDisplayed[key] {
                byDisplayed[key] = (existing.number, existing.highlighted || run.isHighlighted)
            } else {
                byDisplayed[key] = (number, run.isHighlighted)
            }
        }
        // Longest first, so "4 h 04 m" is found before "4".
        let keys = byDisplayed.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        let characters = Array(text)
        var runs: [NoteRun] = []
        var plain = ""
        var index = 0
        func flush() {
            if !plain.isEmpty { runs.append(NoteRun(text: plain)); plain = "" }
        }
        while index < characters.count {
            var matched: (key: String, length: Int)?
            for key in keys {
                let length = key.count
                guard index + length <= characters.count, String(characters[index..<(index + length)]) == key else { continue }
                let before = index > 0 ? characters[index - 1] : nil
                let after = index + length < characters.count ? characters[index + length] : nil
                if let before, NoteDigits.isDigit(before) { continue }
                if let after, NoteDigits.isDigit(after) { continue }
                matched = (key, length)
                break
            }
            if let matched, let entry = byDisplayed[matched.key] {
                flush()
                runs.append(NoteRun(text: entry.number.displayed, number: entry.number, isHighlighted: entry.highlighted))
                index += matched.length
            } else {
                plain.append(characters[index])
                index += 1
            }
        }
        flush()
        // A digit left in a plain run is a number the note does not carry.
        guard runs.allSatisfy({ $0.number != nil || NoteDigits.tokens(in: $0.text).isEmpty }) else { return nil }
        return runs
    }

    /// Non-breaking and narrow spaces read as one space, so a model that swaps them does not fail the check.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
