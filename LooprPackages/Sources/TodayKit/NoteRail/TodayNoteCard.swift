import DesignSystem
import Foundation

// The coach note under the day dial (DEC-12.12), as TodayKit draws it. CoachKit's rule engine writes the note and maps
// it into these plain values; TodayKit never writes a coach sentence of its own. A missing note is a learning or absent
// state with what is missing, never an invented sentence.

public enum TodayNoteKind: String, Equatable, Sendable {
    case morning, evening

    /// "Loopr · morning note".
    public var header: String { "Loopr · \(rawValue) note" }
}

/// One stretch of the note's text. A number run is drawn emphasised, and a highlighted one in the brand accent.
public struct TodayNoteRun: Equatable, Sendable {
    public let text: String
    public let isNumber: Bool
    public let isHighlighted: Bool

    public init(text: String, isNumber: Bool = false, isHighlighted: Bool = false) {
        self.text = text
        self.isNumber = isNumber
        self.isHighlighted = isHighlighted
    }
}

/// Where one number in the note came from, for its `ProvenanceChip`.
public struct TodayNoteSource: Equatable, Sendable, Identifiable {
    public var id: String { "\(number)|\(provenance.label ?? "")" }
    /// The number as the note states it: "49 bpm".
    public let number: String
    public let provenance: LooprProvenance

    public init(number: String, provenance: LooprProvenance) {
        self.number = number
        self.provenance = provenance
    }
}

public enum TodayNoteAction: String, Equatable, Sendable, CaseIterable {
    /// "Why 49?": the page behind the outcome.
    case explainOutcome
    /// "All 30 nights": the nights in the comparison.
    case showNights
    /// Starts the bedtime Live Activity.
    case startWindDown
    /// Opens Ask, as the header button does.
    case ask

    /// The identifier of the chip that runs it.
    public var identifier: String {
        switch self {
        case .explainOutcome: "today-note-why"
        case .showNights: "today-note-nights"
        case .startWindDown: "today-note-wind-down"
        case .ask: "today-note-ask"
        }
    }
}

extension TodayNoteCard {
    /// The note's quiet toggle for the comparison chart and the sources.
    static let detailToggle = "See the nights"
}

public struct TodayNoteChip: Equatable, Sendable, Identifiable {
    public var id: TodayNoteAction { action }
    public let action: TodayNoteAction
    public let label: String

    public init(action: TodayNoteAction, label: String) {
        self.action = action
        self.label = label
    }
}

/// One group of nights on the receipt chart.
public struct TodayNoteReceiptGroup: Equatable, Sendable, Identifiable {
    public let id: String
    /// "21 nights, 4 h or more".
    public let label: String
    public let nightCount: Int
    public let mean: Double
    /// The outcome of every night in the group, in the order the history gave them.
    public let values: [Double]
    public let isLikeLastNight: Bool

    public init(id: String, label: String, nightCount: Int, mean: Double, values: [Double], isLikeLastNight: Bool) {
        self.id = id
        self.label = label
        self.nightCount = nightCount
        self.mean = mean
        self.values = values
        self.isLikeLastNight = isLikeLastNight
    }

    /// The group like last night is drawn in the brand accent, the other in heart, as the contract draws them.
    public var tint: LooprColorToken { isLikeLastNight ? .brand : .heart }
}

/// The two comparison groups under the morning note, side by side as dots.
public struct TodayNoteReceipt: Equatable, Sendable {
    /// "Sleep heart rate".
    public let outcome: String
    /// "bpm", "ms" or "min".
    public let unit: String
    public let groups: [TodayNoteReceiptGroup]
    public let lastNightValue: Double?

    public init(outcome: String, unit: String, groups: [TodayNoteReceiptGroup], lastNightValue: Double?) {
        self.outcome = outcome
        self.unit = unit
        self.groups = groups
        self.lastNightValue = lastNightValue
    }

    /// Every value the chart draws, for its scale.
    public var allValues: [Double] { groups.flatMap(\.values) + (lastNightValue.map { [$0] } ?? []) }

    /// The low and high edge of the scale, padded so no dot sits on the edge. Nil with nothing to draw.
    public var valueRange: ClosedRange<Double>? {
        let values = allValues.filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return nil }
        let pad = max((high - low) * 0.15, 1)
        return (low - pad)...(high + pad)
    }

    /// What VoiceOver reads for the chart: each group with its nights and its average, then last night.
    public var spokenSummary: String {
        var parts = ["Receipt chart for \(outcome.lowercasedKeepingAcronyms)"]
        for group in groups {
            parts.append("\(group.label), averaged \(Self.format(group.mean)) \(unit)")
        }
        if let lastNightValue { parts.append("Last night \(Self.format(lastNightValue)) \(unit)") }
        return parts.joined(separator: ". ") + "."
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

public struct TodayNoteCard: Equatable, Sendable {
    public let kind: TodayNoteKind
    public let runs: [TodayNoteRun]
    public let receipt: TodayNoteReceipt?
    public let chips: [TodayNoteChip]
    public let sources: [TodayNoteSource]
    /// The on-device model reworded the rule text and every number in it matched.
    public let isReworded: Bool
    /// The days the note looked at and what it compared, for VoiceOver.
    public let coverage: String

    public init(kind: TodayNoteKind, runs: [TodayNoteRun], receipt: TodayNoteReceipt? = nil, chips: [TodayNoteChip] = [],
                sources: [TodayNoteSource] = [], isReworded: Bool = false, coverage: String = "") {
        self.kind = kind
        self.runs = runs
        self.receipt = receipt
        self.chips = chips
        self.sources = sources
        self.isReworded = isReworded
        self.coverage = coverage
    }

    public var text: String { runs.map(\.text).joined() }

    /// The card without one of its chips, such as Start wind-down while the bedtime activity is off.
    public func removingChip(_ action: TodayNoteAction) -> TodayNoteCard {
        TodayNoteCard(kind: kind, runs: runs, receipt: receipt, chips: chips.filter { $0.action != action }, sources: sources,
                      isReworded: isReworded, coverage: coverage)
    }
}

/// What the note slot shows.
public enum TodayNoteState: Equatable, Sendable {
    case note(TodayNoteCard)
    /// Not enough nights for the rules to write a note yet.
    case learning(have: Int, need: Int)
    /// Enough nights, but none last night, so no morning note today.
    case absent

    public var card: TodayNoteCard? {
        if case .note(let card) = self { return card }
        return nil
    }

    /// "The morning note starts after 7 nights of sleep heart rate." No countdown: the wait is not homework (R1-NEW-18).
    public static func learningText(have: Int, need: Int) -> String {
        "The morning note starts after \(need) nights of sleep heart rate."
    }

    public static let absentText = "No sleep heart rate for last night, so there is no morning note for this day."
}

/// The card that offers the bedtime Live Activity on the first evening (DEC-12.17). The activity stays off until the
/// person starts it here or in Settings.
public enum TodayFirstEveningCopy {
    public static let title = "Count down to bed"
    /// The minute the bedtime activity starts counting down (the app's `BedtimeActivityWindow.startMinute`).
    public static let startMinute = 18 * 60

    /// "From 6:00 PM Loopr counts down…" in en_US and "From 18:00…" in en_GB, with the locale's clock (ICP R2-UPG-16).
    public static func body(locale: Locale = .current) -> String {
        "From \(LooprClockFormat.text(minuteOfDay: startMinute, locale: locale)) Loopr counts down to bedtime on your lock "
            + "screen, with tonight's rules as steps. It stays off until you turn it on."
    }
    public static let start = "Start wind-down"
    public static let dismiss = "Not now"
}

extension String {
    /// "Sleep heart rate" to "sleep heart rate", "HRV" stays "HRV".
    var lowercasedKeepingAcronyms: String {
        split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.count > 1 && word == word.uppercased() ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }
}
