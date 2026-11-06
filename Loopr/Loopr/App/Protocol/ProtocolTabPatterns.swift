import CoachKit
import DesignSystem
import Foundation
import JournalKit

/// Turns Patterns' found patterns and tests into the Protocol tab's lines and rows. Lines come from CoachKit's
/// `CoachNoteWriter.patternLines` where the outcome is one the writer knows; the rest get the same shape here,
/// "Factor · Outcome 4 points higher · 30 nights". Early patterns never appear (DEC-06.4), and nothing says "caused".
nonisolated enum ProtocolTabPatterns {
    /// How many lines the tab shows. The "All" link opens the rest.
    static let shownLines = 3

    static func state(engine: PatternsEngine?, now: Date, locale: Locale = .current,
                      calendar: Calendar = .current) async -> (ProtocolPatternsState, [ProtocolExperimentRow]?) {
        guard let engine, let snapshot = try? await engine.snapshot() else { return (.unavailable, nil) }
        var patterns = lines(snapshot.found, locale: locale, calendar: calendar)
        patterns.signal = signal(found: snapshot.found, early: snapshot.early, locale: locale)
        var verdicts: [UUID: PatternTestVerdict] = [:]
        for test in snapshot.tests.prefix(3) { verdicts[test.id] = await engine.verdict(for: test) }
        return (patterns, experiments(snapshot.tests, verdicts: verdicts, now: now, locale: locale))
    }

    static func lines(_ found: [FoundPattern], locale: Locale, calendar: Calendar) -> ProtocolPatternsState {
        let writer = CoachNoteWriter(context: NoteContext(locale: locale, calendar: calendar))
        let headline = found.filter { $0.strength.isHeadlineWorthy }
        let lines = headline.compactMap { pattern -> ProtocolPatternLine? in
            let factor = PatternsCopy.display(pattern.title.trimmingCharacters(in: .whitespacesAndNewlines), locale: locale)
            guard !factor.isEmpty else { return nil }
            let text = summary(pattern, factor: factor).flatMap { writer.patternLine($0)?.text } ?? fallback(pattern, factor: factor, locale: locale)
            guard let text else { return nil }
            let prefix = factor + " \u{00B7} "
            let detail = text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
            return ProtocolPatternLine(id: pattern.key, title: factor, detail: detail, bars: pattern.strength == .strong ? 3 : 2,
                                       outcome: pattern.metric.title)
        }
        let nights = Dictionary(headline.map { ($0.key, $0.nights.total) }, uniquingKeysWith: { first, _ in first })
        let ordered = lines.sorted { lhs, rhs in
            if lhs.bars != rhs.bars { return lhs.bars > rhs.bars }
            let left = nights[lhs.id] ?? 0, right = nights[rhs.id] ?? 0
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        return ProtocolPatternsState(isAvailable: true, lines: Array(ordered.prefix(shownLines)), total: ordered.count)
    }

    /// The check-in's pattern line (ICP R2-HAB-01, R3-NEW-02, R3-VET-03): the first clear or strong pattern the Patterns
    /// screen lists, in one plain sentence with its spread, or the fewest more nights the nearest early pattern needs on
    /// both sides to count as clear. The screen's model names the matching rule.
    static func signal(found: [FoundPattern], early: [FoundPattern], locale: Locale,
                       perGroup: Int = PatternPolicy.default.matureGate) -> ProtocolPatternSignal {
        if let finding = found.lazy.compactMap({ ProtocolPatternFinding.make($0, locale: locale) }).first {
            return .found(finding)
        }
        let counts = early.map { (with: $0.nights.with, without: $0.nights.without) }
        return .gathering(nightsToGo: ProtocolPatternSignal.nightsToGo(counts, perGroup: perGroup), perGroup: perGroup)
    }

    /// The writer's input, for an outcome it has words for.
    static func summary(_ pattern: FoundPattern, factor: String) -> NotePatternSummary? {
        let outcome: NoteOutcomeKind
        switch pattern.metric {
        case .restingHeartRate: outcome = .restingHeartRate
        case .hrvRMSSD: outcome = .hrv
        case .deepSleepMinutes: outcome = .deepSleep
        case .sleepDuration: outcome = .sleepDuration
        case .recoveryScore, .sleepScore, .sleepEfficiency, .sleepConsistency, .mood: return nil
        }
        let strength: NotePatternStrength = switch pattern.strength {
        case .strong: .strong
        case .clear: .clear
        case .early: .early
        }
        return NotePatternSummary(id: pattern.key, factor: factor, outcome: outcome, difference: pattern.effect.difference,
                                  nights: pattern.nights.total, strength: strength)
    }

    /// Score outcomes the writer has no words for: "Late dinner · Recovery 4 points lower · 30 nights".
    static func fallback(_ pattern: FoundPattern, factor: String, locale: Locale) -> String? {
        let difference = pattern.effect.difference
        guard pattern.strength.isHeadlineWorthy, pattern.nights.total > 0, difference.isFinite else { return nil }
        let size = abs(difference).rounded()
        guard size > 0 else { return nil }
        let amount = size.formatted(.number.precision(.fractionLength(0)).locale(locale))
        let unit: String = switch pattern.metric.unit {
        case .percentagePoints: size == 1 ? "percentage point" : "percentage points"
        case .scorePoints: size == 1 ? "point" : "points"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .minutes: "min"
        }
        let nights = pattern.nights.total
        return "\(factor) \u{00B7} \(pattern.metric.title) \(amount) \(unit) \(difference > 0 ? "higher" : "lower") \u{00B7} \(nights) \(nights == 1 ? "night" : "nights")"
    }

    /// Experiments started from a pattern, for the Experiments segment's running and finished lists. Each leads with
    /// the verdict in the words the designed experiments use: "Too early to say. Day 6 of 14. Kept on 5 of 6 nights."
    static func experiments(_ tests: [PatternTest], verdicts: [UUID: PatternTestVerdict] = [:], now: Date,
                            locale: Locale) -> [ProtocolExperimentRow] {
        tests.map { test in
            let progress = test.progress(at: now)
            let kept = "Kept on \(progress.keptCount) of \(progress.elapsedDays) \(progress.elapsedDays == 1 ? "night" : "nights")."
            let verdict = verdictLead(verdicts[test.id])
            let detail: String = switch test.state {
            case .running: "\(verdict) Day \(progress.dayNumber) of \(test.testDays). \(kept)"
            case .completed: "\(verdict) \(kept)"
            case .stopped: "Stopped. \(kept)"
            }
            return ProtocolExperimentRow(id: test.id.uuidString.lowercased(), title: PatternsCopy.title(test, locale: locale),
                                         detail: detail, isRunning: test.state == .running)
        }
    }

    /// "Too early to say." for a test without a call yet, so it reads like a designed experiment; otherwise the
    /// verdict's own headline, "Clear difference." or "No clear difference."
    static func verdictLead(_ verdict: PatternTestVerdict?) -> String {
        guard let verdict, verdict.isConclusive else { return "Too early to say." }
        return verdict.headline + "."
    }
}
