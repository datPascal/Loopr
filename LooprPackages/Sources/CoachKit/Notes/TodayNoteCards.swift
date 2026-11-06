import DesignSystem
import Foundation
import TodayKit

/// Where the numbers of a note on Today came from, for their `ProvenanceChip`s.
public struct TodayNoteProvenance: Equatable, Sendable {
    /// Last night's outcome, such as the band's sleeping heart rate.
    public var outcome: LooprProvenance
    /// Last night's factor, such as the time from the last meal to bed.
    public var factor: LooprProvenance
    /// The time an evening rule was kept.
    public var kept: LooprProvenance

    public init(outcome: LooprProvenance = .band(device: ""), factor: LooprProvenance = .food(.logged),
                kept: LooprProvenance = .onThisPhone) {
        self.outcome = outcome
        self.factor = factor
        self.kept = kept
    }
}

/// Turns the rule engine's notes into the cards Today draws (DEC-12.12). The rules write every sentence; this only
/// maps runs, the receipt and the chips, and decides the learning state when the rules have no note to write.
public enum TodayNoteCards {
    /// The qualifier of the chip for the numbers worked out on the phone: the usual, the averages and the counts.
    public static let workedOutQualifier = "worked out from your nights"

    /// The morning slot. Fewer nights than the usual needs is the learning state with the nights still to go; enough
    /// nights and no reading last night is the absent state. Neither invents a sentence.
    public static func morning(_ input: MorningNoteInput, writer: CoachNoteWriter,
                               provenance: TodayNoteProvenance = TodayNoteProvenance()) -> (state: TodayNoteState, note: CoachNote?) {
        let need = writer.context.thresholds.minimumUsualNights
        let have = input.usual?.nights ?? 0
        if have < need { return (.learning(have: have, need: need), nil) }
        guard let note = writer.morning(input) else { return (.absent, nil) }
        return (.note(card(note, provenance: provenance)), note)
    }

    /// The evening note, or nil when the rules have nothing to say tonight.
    public static func evening(_ input: EveningNoteInput, writer: CoachNoteWriter,
                               provenance: TodayNoteProvenance = TodayNoteProvenance()) -> (card: TodayNoteCard, note: CoachNote)? {
        guard let note = writer.evening(input) else { return nil }
        return (card(note, provenance: provenance), note)
    }

    /// The card for a note. Highlighted numbers get their own source; the numbers worked out on the phone share one.
    public static func card(_ note: CoachNote, provenance: TodayNoteProvenance = TodayNoteProvenance(),
                            isReworded: Bool = false) -> TodayNoteCard {
        let kind: TodayNoteKind = note.kind == .evening ? .evening : .morning
        let runs = note.runs.map { run in
            TodayNoteRun(text: run.text, isNumber: isStatedNumber(run), isHighlighted: run.isHighlighted && isStatedNumber(run))
        }
        return TodayNoteCard(kind: kind, runs: runs, receipt: note.receipt.map(receipt), chips: note.chips.map(chip),
                             sources: sources(note, kind: kind, provenance: provenance), isReworded: isReworded,
                             coverage: [note.daysCovered, note.comparisonGroup.map { "Compared: \($0)." }]
                                .compactMap { $0 }.joined(separator: " "))
    }

    /// The card with the on-device model's wording when every number in it matched the rule note, and the rule text
    /// otherwise. `CoachRewriter` makes that call; nothing here trusts the model.
    public static func reworded(_ note: CoachNote, rewriter: CoachRewriter,
                                provenance: TodayNoteProvenance = TodayNoteProvenance()) async -> TodayNoteCard {
        let outcome = await rewriter.reword(note)
        return card(outcome.note, provenance: provenance, isReworded: outcome.isReworded)
    }

    // MARK: Pieces

    /// A number the note states. Digits inside a name the app supplied, such as "Zone 2", are not emphasised.
    static func isStatedNumber(_ run: NoteRun) -> Bool {
        guard let number = run.number else { return false }
        return number.unit != .literal
    }

    static func sources(_ note: CoachNote, kind: TodayNoteKind, provenance: TodayNoteProvenance) -> [TodayNoteSource] {
        var result: [TodayNoteSource] = []
        var seen = Set<String>()
        var highlightIndex = 0
        var hasWorkedOut = false
        for run in note.runs {
            guard let number = run.number, isStatedNumber(run) else { continue }
            guard run.isHighlighted else { hasWorkedOut = true; continue }
            defer { highlightIndex += 1 }
            guard seen.insert(number.displayed).inserted else { continue }
            let source: LooprProvenance = switch kind {
            case .morning: highlightIndex == 0 ? provenance.outcome : provenance.factor
            case .evening: provenance.kept
            }
            result.append(TodayNoteSource(number: number.displayed, provenance: source))
        }
        if hasWorkedOut || note.receipt != nil {
            result.append(TodayNoteSource(number: workedOutQualifier, provenance: .onThisPhone))
        }
        return result
    }

    static func receipt(_ chart: NoteReceiptChart) -> TodayNoteReceipt {
        TodayNoteReceipt(
            outcome: chart.outcome.title, unit: unitWord(chart.unit),
            groups: chart.groups.map { group in
                TodayNoteReceiptGroup(id: group.id, label: group.label, nightCount: group.nightCount, mean: group.mean,
                                      values: group.nights.map(\.value), isLikeLastNight: group.isLikeLastNight)
            },
            lastNightValue: chart.lastNightValue)
    }

    static func unitWord(_ unit: NoteUnit) -> String {
        switch unit {
        case .bpm: "bpm"
        case .milliseconds: "ms"
        case .minutes: "min"
        case .percent: "%"
        case .nights: "nights"
        case .days: "days"
        case .clock, .count, .literal: ""
        }
    }

    static func chip(_ chip: NoteChip) -> TodayNoteChip {
        let action: TodayNoteAction = switch chip.action {
        case .explainOutcome: .explainOutcome
        case .showNights: .showNights
        case .startWindDown: .startWindDown
        case .ask: .ask
        }
        return TodayNoteChip(action: action, label: chip.label)
    }
}
