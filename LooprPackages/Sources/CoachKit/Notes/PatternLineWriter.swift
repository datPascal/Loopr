import Foundation

/// One line per pattern, for the list under a tab: "Dinner 4 h before bed · Sleep heart rate 5 bpm lower · 30 nights".
/// Early patterns have no line (DEC-06.4), and neither has a pattern whose difference rounds to nothing.
enum PatternLineWriter {
    static func write(_ pattern: NotePatternSummary, context: NoteContext) -> CoachNote? {
        guard pattern.strength != .early, pattern.nights > 0, pattern.difference.isFinite else { return nil }
        let factor = pattern.factor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !factor.isEmpty else { return nil }
        let formatter = NoteFormatter(context: context)
        guard let size = formatter.number(abs(pattern.difference), unit: pattern.unit), size.value > 0 else { return nil }
        let nights = formatter.count(pattern.nights, noun: "night", unit: .nights)

        var builder = NoteBuilder(context: context)
        builder.text(factor)
        builder.text(" \u{00B7} \(pattern.outcome.title) ")
        builder.number(size)
        builder.text(" \(pattern.outcome.direction(higher: pattern.difference > 0)) \u{00B7} ")
        builder.number(nights)

        let note = CoachNote(kind: .patternLine, runs: builder.runs, daysCovered: "The \(nights.displayed) in the comparison.",
                             comparisonGroup: "Your own nights, with and without it")
        return NoteGuard.isClean(note.text) ? note : nil
    }

    /// The lines for a list: strongest first, then the most nights, then the id. Early patterns are left out.
    static func lines(_ patterns: [NotePatternSummary], context: NoteContext, limit: Int?) -> [CoachNote] {
        let ordered = patterns.filter { $0.strength != .early }.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            if lhs.nights != rhs.nights { return lhs.nights > rhs.nights }
            return lhs.id < rhs.id
        }
        let lines = ordered.compactMap { write($0, context: context) }
        guard let limit else { return lines }
        return Array(lines.prefix(max(0, limit)))
    }
}

/// The rule-written coach. Free, offline, and it sends nothing. Every method is a pure function of its input and the
/// context, so the same data always gives the same note, and a note is nil when the data to write it is missing.
public struct CoachNoteWriter: Sendable {
    public let context: NoteContext

    public init(context: NoteContext = NoteContext()) { self.context = context }

    public func morning(_ input: MorningNoteInput) -> CoachNote? { MorningNoteWriter.write(input, context: context) }

    public func evening(_ input: EveningNoteInput) -> CoachNote? { EveningNoteWriter.write(input, context: context) }

    public func patternLine(_ pattern: NotePatternSummary) -> CoachNote? { PatternLineWriter.write(pattern, context: context) }

    public func patternLines(_ patterns: [NotePatternSummary], limit: Int? = nil) -> [CoachNote] {
        PatternLineWriter.lines(patterns, context: context, limit: limit)
    }
}
