import DesignSystem
import DomainKit
import Foundation

/// Every sentence the package writes. Wording is observational: it says what
/// differed between a person's own nights and never what caused it.
public enum PatternCopy {
    public static let foundEmpty = "Nothing clear yet. Loopr needs about 5 nights on each side before it says anything."
    public static let testingEmpty = "No test running. Pick a pattern, or use Ask for a suggestion."
    public static let dismissedEmpty = "Patterns you hide with Not now wait here. They stay off Today."
    public static let footnote = PatternTestVerdict.footnote

    /// "14", "7.5". One decimal at most, never localised, so tests and screens agree.
    public static func amount(_ value: Double) -> String {
        let rounded = (abs(value) * 10).rounded() / 10
        let text = String(format: "%.1f", rounded)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func nights(_ count: Int) -> String { count == 1 ? "1 night" : "\(count) nights" }

    /// "Deep sleep was 14 min lower", or "... was the same".
    static func change(metric: HabitOutcomeMetricID, difference: Double) -> String {
        let amount = amount(difference)
        if amount == "0" { return "\(metric.title) was the same" }
        return "\(metric.title) was \(amount) \(metric.unit.label) \(difference > 0 ? "higher" : "lower")"
    }

    static func verdict(kind: PatternTestVerdictKind, metric: HabitOutcomeMetricID, difference: Double?,
                        kept: Int, baseline: Int, policy: PatternPolicy) -> (headline: String, detail: String) {
        switch kind {
        case .tooEarly:
            let count = kept == 1 ? "1 kept night" : "\(kept) kept nights"
            return (PatternTestVerdict.tooEarlyHeadline,
                    "\(count) with \(metric.title.lowercasedKeepingAcronyms) data so far. Loopr needs \(policy.earlyGate) for a first look and \(policy.matureGate) for a clear read.")
        case .early:
            let lead = difference.map { "A first look only. \(change(metric: metric, difference: $0)) on \(nights(kept)) you kept than on the \(nights(baseline)) before. " }
                ?? "A first look only. "
            return (PatternTestVerdict.tooEarlyHeadline,
                    lead + "Loopr needs \(policy.matureGate) kept nights before it calls this clear.")
        case .clear:
            let body = difference.map { "\(change(metric: metric, difference: $0)) on \(nights(kept)) you kept than on the \(nights(baseline)) before. " } ?? ""
            return ("Clear difference", body + footnote)
        case .noClearDifference:
            return ("No clear difference",
                    "\(metric.title) looked about the same on \(nights(kept)) you kept and the \(nights(baseline)) before. \(footnote)")
        }
    }

    /// "Deep sleep was 14 min lower on nights after a late dinner than on other nights."
    public static func summary(for pattern: FoundPattern) -> String {
        let change = change(metric: pattern.metric, difference: pattern.effect.difference)
        let joiner = change.hasSuffix("was the same") ? "as" : "than"
        return "\(change) on nights \(pattern.predicate.pastClause) \(joiner) on other nights."
    }

    /// The counts behind a pattern, for the Today card. With both averages: "On 9 nights when you ate after 21:00,
    /// deep sleep averaged 52 min. On the other 32 nights it was 71 min." Without them it gives the difference.
    /// Times in the sentence are written in the locale's clock style, so "after 21:00" reads "after 9:00 pm" in a 12-hour locale.
    public static func counts(for pattern: FoundPattern, locale: Locale = .current) -> String {
        LooprClockFormat.localizing(rawCounts(for: pattern), locale: locale)
    }

    static func rawCounts(for pattern: FoundPattern) -> String {
        let metric = pattern.metric.title.lowercasedKeepingAcronyms
        let unit = pattern.effect.unit.label.isEmpty ? "" : " " + pattern.effect.unit.label
        let lead = "On \(nights(pattern.nights.with)) \(pattern.predicate.pastClause), \(metric)"
        let others = "the other \(nights(pattern.nights.without))"
        if let with = pattern.effect.withMean, let without = pattern.effect.withoutMean {
            return "\(lead) averaged \(amount(with))\(unit). On \(others) it was \(amount(without))\(unit)."
        }
        let change = amount(pattern.effect.difference)
        if change == "0" { return "\(lead) was the same as on \(others)." }
        return "\(lead) was \(change)\(unit) \(pattern.effect.difference > 0 ? "higher" : "lower") than on \(others)."
    }

    /// "12 nights with, 38 without"
    public static func nightsLabel(_ nights: PatternNights) -> String {
        "\(nights.with) nights with, \(nights.without) without"
    }
}

extension FoundPattern {
    public var summary: String { PatternCopy.summary(for: self) }
    public var nightsLabel: String { PatternCopy.nightsLabel(nights) }
}

private extension String {
    /// "Deep sleep" becomes "deep sleep"; "HRV" stays "HRV".
    var lowercasedKeepingAcronyms: String {
        split(separator: " ", omittingEmptySubsequences: false).map { word in
            word == word.uppercased() && word.count > 1 ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }
}
