import DomainKit
import Foundation

// The output of the rule-written coach (DEC-12.12). A note is a list of runs, so a screen can draw the numbers it
// highlights, and every number the text states is a run of its own. The on-device model step reads `numerals` to
// decide whether a reworded note states anything the rules did not.

public enum NoteUnit: String, Codable, CaseIterable, Sendable {
    case bpm
    case milliseconds
    /// A length of time. Written "48 min" under an hour and "4 h 04 m" from an hour up.
    case minutes
    /// A time of day, written in the locale's clock. The value is minutes after midnight.
    case clock
    case nights
    case days
    case count
    /// A share of a whole, written "86%".
    case percent
    /// A number that came from text the app supplied, such as "Zone 2" in a rule title.
    case literal
}

public struct NoteNumber: Equatable, Hashable, Sendable {
    /// Exactly as it appears in the text, unit included: "49 bpm", "4 h 04 m", "6:20 PM", "21 nights".
    public let displayed: String
    /// The value that was rounded to make `displayed`.
    public let value: Double
    public let unit: NoteUnit

    public init(displayed: String, value: Double, unit: NoteUnit) {
        self.displayed = displayed; self.value = value; self.unit = unit
    }

    /// The digit groups inside `displayed`: "4 h 04 m" gives ["4", "04"], "6:20 PM" gives ["6:20"].
    public var numerals: [String] { NoteDigits.tokens(in: displayed) }
}

public struct NoteRun: Equatable, Sendable {
    public let text: String
    /// Set for a number run. A text run never contains a digit.
    public let number: NoteNumber?
    /// The numbers a screen draws with `.hl`: last night's value, the factor's value, the time a rule closed.
    public let isHighlighted: Bool
    /// A name the app supplied, such as a rule title, a group label or a weekday. A rewording has to keep it.
    public let isProtected: Bool

    public init(text: String, number: NoteNumber? = nil, isHighlighted: Bool = false, isProtected: Bool = false) {
        self.text = text; self.number = number; self.isHighlighted = isHighlighted; self.isProtected = isProtected
    }
}

public enum CoachNoteKind: String, Codable, CaseIterable, Sendable {
    case morning, evening, patternLine
    /// One page of the weekly review story.
    case weeklyPage
}

public enum NoteChipAction: String, Codable, CaseIterable, Sendable {
    /// "Why 49?" opens the nights behind the number.
    case explainOutcome
    /// "All 30 nights" opens every night in the comparison.
    case showNights
    case startWindDown
    case ask
}

public struct NoteChip: Equatable, Sendable, Identifiable {
    public var id: NoteChipAction { action }
    public let action: NoteChipAction
    public let label: String
    public init(action: NoteChipAction, label: String) { self.action = action; self.label = label }
}

public struct NoteReceiptNight: Equatable, Sendable {
    public let day: DayIdentity?
    public let value: Double
    public init(day: DayIdentity?, value: Double) { self.day = day; self.value = value }
}

public struct NoteReceiptGroup: Equatable, Sendable, Identifiable {
    public let id: String
    /// "21 nights, 4 h or more".
    public let label: String
    public let nightCount: Int
    public let mean: Double
    /// Every night in the group with its outcome, in the order the history gave them. Nights without an outcome are not here.
    public let nights: [NoteReceiptNight]
    public let isLikeLastNight: Bool

    public init(id: String, label: String, nightCount: Int, mean: Double, nights: [NoteReceiptNight], isLikeLastNight: Bool) {
        self.id = id; self.label = label; self.nightCount = nightCount; self.mean = mean
        self.nights = nights; self.isLikeLastNight = isLikeLastNight
    }
}

/// The two groups drawn under the morning note. The group like last night comes first.
public struct NoteReceiptChart: Equatable, Sendable {
    public let outcome: NoteOutcomeKind
    public let unit: NoteUnit
    public let groups: [NoteReceiptGroup]
    /// The value to mark on the chart. Nil when the chart has no single night to mark.
    public let lastNightValue: Double?

    public init(outcome: NoteOutcomeKind, unit: NoteUnit, groups: [NoteReceiptGroup], lastNightValue: Double?) {
        self.outcome = outcome; self.unit = unit; self.groups = groups; self.lastNightValue = lastNightValue
    }
}

public struct CoachNote: Equatable, Sendable {
    public let kind: CoachNoteKind
    public let runs: [NoteRun]
    /// Present on a morning note that names a factor. Never on an evening note or a pattern line.
    public let receipt: NoteReceiptChart?
    /// The days the note looked at, in words.
    public let daysCovered: String
    /// What the note compared against, in words, with its nights counted. Nil when nothing was compared.
    public let comparisonGroup: String?
    public let chips: [NoteChip]
    /// Numbers that the chips and descriptions state and the text does not, such as the 30 in "All 30 nights", which is
    /// the 21 and the 9 added. A reworded text is checked against `numerals`, not these.
    public let supportingNumbers: [NoteNumber]

    public init(kind: CoachNoteKind, runs: [NoteRun], receipt: NoteReceiptChart? = nil, daysCovered: String,
                comparisonGroup: String? = nil, chips: [NoteChip] = [], supportingNumbers: [NoteNumber] = []) {
        self.kind = kind; self.runs = runs; self.receipt = receipt; self.daysCovered = daysCovered
        self.comparisonGroup = comparisonGroup; self.chips = chips; self.supportingNumbers = supportingNumbers
    }

    public var text: String { runs.map(\.text).joined() }

    /// Every number the text states, once each, in the order it first appears.
    public var numbers: [NoteNumber] {
        var seen = Set<NoteNumber>()
        return runs.compactMap(\.number).filter { seen.insert($0).inserted }
    }

    /// The names in the text that a rewording has to keep: rule titles, group labels and weekdays, as written.
    public var protectedPhrases: [String] {
        runs.filter { $0.isProtected && $0.number == nil }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The displayed strings the text states.
    public var displayedNumbers: Set<String> { Set(numbers.map(\.displayed)) }

    /// The values behind the displayed strings.
    public var numberValues: Set<Double> { Set(numbers.map(\.value)) }

    /// Every digit group in the text. A reworded note is safe to show when its own digit groups are all in this set.
    public var numerals: Set<String> { Set(numbers.flatMap(\.numerals)) }

    /// The digit groups anywhere in the note: the text, plus the chips, the receipt and the descriptions.
    public var allNumerals: Set<String> { numerals.union(supportingNumbers.flatMap(\.numerals)) }
}

/// Where digit groups start and end. One scanner serves the writers and the checks, so a number the writers do not
/// register cannot get into a note.
public enum NoteDigits {
    /// A digit group is digits with single separators between digits: "49", "04", "6:20", "9,812", "7.5".
    public static func tokens(in text: String) -> [String] {
        ranges(in: text).map { String(text[$0]) }
    }

    static func ranges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isDigit(text[index]) else { index = text.index(after: index); continue }
            let start = index
            var end = text.index(after: index)
            while end < text.endIndex {
                if isDigit(text[end]) { end = text.index(after: end); continue }
                let next = text.index(after: end)
                if ".,:".contains(text[end]), next < text.endIndex, isDigit(text[next]) { end = next; continue }
                break
            }
            result.append(start..<end)
            index = end
        }
        return result
    }

    static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.numericType == .decimal }
    }

    /// The value of a digit group. "6:20" is 380 (minutes after midnight), "9,812" is 9812, "7.5" is 7.5.
    static func value(of token: String) -> Double? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, let hours = integer(parts[0]), let minutes = integer(parts[1]) { return Double(hours * 60 + minutes) }
        var digits = ""
        for character in token {
            if let digit = character.wholeNumberValue { digits.append(String(digit)) } else if character == "." { digits.append(".") }
        }
        return Double(digits) ?? Double(digits.replacingOccurrences(of: ".", with: ""))
    }

    private static func integer(_ text: String) -> Int? {
        var value = 0
        for character in text {
            guard let digit = character.wholeNumberValue else { return nil }
            value = value * 10 + digit
        }
        return value
    }
}
