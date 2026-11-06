import DesignSystem
import Foundation
import RoutineKit
import SwiftUI

/// One clear or strong pattern as the check-in says it, in two lines (ICP R4 Q7): a headline in the pattern's own words,
/// "Last meal after 21:00, 19 min less deep sleep.", at most about 45 characters so it is read in one glance, then
/// "9 nights against 20. Usual spread 12 min. Not proof of cause." The counts and "Not proof of cause." always stay; the
/// spread shows when the stored pattern has one. The rule on the list it is about is no longer on the line: the Patterns
/// screen names it behind the tap. It is worked out from the stored pattern on every load, so it changes when the
/// pattern does.
public struct ProtocolPatternFinding: Equatable, Sendable {
    /// The longest headline before the pattern's name is shortened.
    public static let headlineLimit = 50

    /// "On the 9 nights you ate after 21:00, you had 19 minutes less deep sleep than on the other 20." The whole
    /// comparison, for the Patterns screen's words and older callers.
    public let sentence: String
    /// "Last meal after 21:00, 19 min less deep sleep."
    public let headline: String
    /// "9 nights against 20."
    public let counts: String
    /// "Usual spread 12 min." Nil for a pattern stored without a spread, where the line leaves it out.
    public let spread: String?
    /// The habit the pattern counts, to find its rule on the list.
    public let habitID: UUID?
    /// The pattern's own name, such as "Alcohol" or "Last meal after 21:00", to match a rule's question.
    public let factor: String
    /// The rule metrics that measure the same habit, such as `last_meal_time` for a late meal.
    public let ruleMetrics: [String]
    /// The rule on the list the pattern is about, "Kitchen closes". Set by `naming(rules:)`.
    public var rule: String?

    public init(sentence: String, headline: String? = nil, counts: String = "", spread: String? = nil, habitID: UUID? = nil,
                factor: String = "", ruleMetrics: [String] = [], rule: String? = nil) {
        self.sentence = sentence; self.headline = headline ?? sentence; self.counts = counts; self.spread = spread
        self.habitID = habitID; self.factor = factor; self.ruleMetrics = ruleMetrics; self.rule = rule
    }

    /// The finding for a stored pattern. Nil for an early pattern, which Patterns never lists either.
    public static func make(_ pattern: FoundPattern, locale: Locale = .current) -> ProtocolPatternFinding? {
        guard pattern.strength.isHeadlineWorthy else { return nil }
        return ProtocolPatternFinding(sentence: sentence(pattern, locale: locale), headline: headline(pattern, locale: locale),
                                      counts: counts(pattern), spread: spread(pattern),
                                      habitID: pattern.habitID.rawValue, factor: pattern.title,
                                      ruleMetrics: ruleMetrics(candidateID: pattern.candidateID))
    }

    /// "Last meal after 21:00, 19 min less deep sleep.": the pattern's name, then what moved and which way. A long name
    /// is cut at a word so the headline stays near `headlineLimit` characters. It never says what caused the gap.
    static func headline(_ pattern: FoundPattern, locale: Locale) -> String {
        let amount = PatternCopy.amount(pattern.effect.difference)
        let higher = pattern.effect.difference > 0
        let metric = lowercased(pattern.metric.title)
        let result: String
        if amount == "0" {
            result = "\(metric) about the same"
        } else {
            switch pattern.metric {
            case .deepSleepMinutes: result = "\(amount) min \(higher ? "more" : "less") deep sleep"
            case .sleepDuration: result = "\(amount) min \(higher ? "more" : "less") sleep"
            default: result = "\(metric) \(amount) \(unit(pattern.effect.unit, amount: amount)) \(higher ? "higher" : "lower")"
            }
        }
        let tail = ", \(result)."
        var name = LooprClockFormat.localizing(pattern.title.trimmingCharacters(in: .whitespacesAndNewlines), locale: locale)
        let room = max(headlineLimit - tail.count, 12)
        if name.count > room {
            var words = name.split(separator: " ").map(String.init)
            while words.count > 1, words.joined(separator: " ").count + 1 > room { words.removeLast() }
            name = words.joined(separator: " ") + "\u{2026}"
        }
        if let first = name.first, first.isLowercase { name = first.uppercased() + name.dropFirst() }
        return name + tail
    }

    /// "9 nights against 20.", "1 night against 12."
    static func counts(_ pattern: FoundPattern) -> String {
        let with = pattern.nights.with
        return "\(with) \(with == 1 ? "night" : "nights") against \(pattern.nights.without)."
    }

    /// "On the 9 nights you ate after 21:00, you had 19 minutes less deep sleep than on the other 20." Times follow the
    /// locale's clock. It compares the person's own nights and never says what caused the gap.
    static func sentence(_ pattern: FoundPattern, locale: Locale) -> String {
        let with = pattern.nights.with, without = pattern.nights.without
        let nights = with == 1 ? "On the one night" : "On the \(with) nights"
        let others = without == 1 ? "the other one" : "the other \(without)"
        let past = pattern.predicate.pastClause
        let clause = past.hasPrefix("when ") ? String(past.dropFirst("when ".count)) : past
        let amount = PatternCopy.amount(pattern.effect.difference)
        let metric = lowercased(pattern.metric.title)
        let text: String
        if amount == "0" {
            text = "\(nights) \(clause), your \(metric) was about the same as on \(others)."
        } else {
            let higher = pattern.effect.difference > 0
            let result: String = switch pattern.metric {
            case .deepSleepMinutes:
                "you had \(amount) \(amount == "1" ? "minute" : "minutes") \(higher ? "more" : "less") deep sleep"
            case .sleepDuration:
                "you slept \(amount) \(amount == "1" ? "minute" : "minutes") \(higher ? "longer" : "less")"
            default:
                "your \(metric) was \(amount) \(unit(pattern.effect.unit, amount: amount)) \(higher ? "higher" : "lower")"
            }
            text = "\(nights) \(clause), \(result) than on \(others)."
        }
        return LooprClockFormat.localizing(text, locale: locale)
    }

    /// "Usual spread 12 min.", the person's night-to-night spread the Patterns screen shows too (ICP R2-VET-09).
    static func spread(_ pattern: FoundPattern) -> String? {
        guard let spread = pattern.effect.spread, spread.isFinite, spread > 0 else { return nil }
        let amount = PatternCopy.amount(spread)
        return "Usual spread \(amount) \(unit(pattern.effect.unit, amount: amount))."
    }

    /// The rule metrics that measure what a pattern's habit is about. Journal habits match by habit or question instead.
    static func ruleMetrics(candidateID: String) -> [String] {
        switch candidateID {
        case "food.lateMeal": [RoutineMetric.lastMealTime.rawValue]
        case "food.alcohol": [RoutineMetric.alcoholDrinks.rawValue]
        case "food.lateCaffeine": [RoutineMetric.lastCaffeineTime.rawValue]
        case "food.proteinTarget": [RoutineMetric.proteinG.rawValue]
        case let id where id.hasPrefix("steps"): [RoutineMetric.steps.rawValue]
        default: []
        }
    }

    /// The finding with the first rule on the list it is about: the same habit, a rule that measures the same thing, or
    /// a rule whose question starts with the same word ("No alcohol" for "Alcohol"). Without one it names no rule.
    public func naming(rules: [ProtocolRule]) -> ProtocolPatternFinding {
        var named = self
        let match = rules.first { rule in
            if let habitID, RoutineHabitMigration.habitID(forRuleKey: rule.key) == habitID { return true }
            if let metric = rule.target.metric, ruleMetrics.contains(metric) { return true }
            return !factor.isEmpty && ProtocolQuestionMatch.matches(factor, rules: [rule])
        }
        named.rule = match.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        return named
    }

    /// The line under the headline: "9 nights against 20. Usual spread 12 min. Not proof of cause.", or "9 nights
    /// against 20. Not proof of cause." without a spread. The rule is not on it (ICP R4 Q7).
    public var detail: String {
        [counts.isEmpty ? nil : counts, spread, "Not proof of cause."].compactMap { $0 }.joined(separator: " ")
    }

    /// "Your rule: Kitchen closes.", for the Patterns screen behind the line's tap. Nil when no rule matches.
    public var ruleLine: String? {
        guard let rule, !rule.isEmpty else { return nil }
        return "Your rule: \(rule.hasSuffix(".") ? String(rule.dropLast()) : rule)."
    }

    private static func unit(_ unit: HabitMetricUnitID, amount: String) -> String {
        switch unit {
        case .scorePoints: amount == "1" ? "point" : "points"
        case .percentagePoints: amount == "1" ? "percentage point" : "percentage points"
        default: unit.label
        }
    }

    /// "Resting heart rate" reads "resting heart rate" mid-sentence; "HRV" stays "HRV".
    private static func lowercased(_ title: String) -> String {
        title.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word == word.uppercased() && word.count > 1 ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }
}

/// What the check-in's pattern line says: the first pattern Patterns shows, or how many more nights the nearest one
/// needs (ICP R2-HAB-01, R2-NEW-08, R2-SEN-06). It never says a habit caused anything.
public enum ProtocolPatternSignal: Equatable, Sendable {
    /// A clear or strong pattern: a headline, then its counts.
    case found(ProtocolPatternFinding)
    /// No pattern to show yet. `nightsToGo` is the fewest more nights the closest habit needs on both sides, nil when no
    /// habit is close enough to count.
    case gathering(nightsToGo: Int?, perGroup: Int)

    /// The line's sentence.
    public var title: String {
        switch self {
        case .found(let finding): finding.headline
        case .gathering(let nights?, _) where nights > 0:
            "At least \(nights) more \(nights == 1 ? "night" : "nights") before Loopr can compare your sleep with and without a habit."
        case .gathering(_?, _): "No clear link between a habit and your sleep yet."
        case .gathering(nil, let perGroup):
            "Loopr compares your sleep once a habit has \(perGroup) nights with it and \(perGroup) without."
        }
    }

    /// The line under it.
    public var detail: String {
        switch self {
        case .found(let finding): finding.detail
        case .gathering(let nights?, let perGroup) where nights > 0:
            "It needs \(perGroup) nights with the habit and \(perGroup) without."
        case .gathering(_?, _): "Loopr looks again as new nights come in."
        case .gathering(nil, _): "Your evening answers count toward it."
        }
    }

    public var accessibilityLabel: String { "\(title) \(detail)" }

    /// The signal with the rule a found pattern is about, from the protocol's rules (ICP R3-NEW-02).
    public func naming(rules: [ProtocolRule]) -> ProtocolPatternSignal {
        guard case .found(let finding) = self else { return self }
        return .found(finding.naming(rules: rules))
    }

    /// The fewest more nights the nearest habit needs before Patterns can compare: what it lacks on each side, added up.
    /// It is a floor, since a night only counts on one side. Nil without any habit to count.
    public static func nightsToGo(_ counts: [(with: Int, without: Int)], perGroup: Int) -> Int? {
        counts.map { max(0, perGroup - $0.with) + max(0, perGroup - $0.without) }.min()
    }
}

/// The pattern line on the check-in: the headline, then the counts, the spread and "Not proof of cause." in one caption
/// line (ICP R4 Q7). A tap opens Patterns, which names the rule. Nil shows nothing. While a card is due the screen puts it under the deck; once nothing is
/// due it sits above (ICP R3-DES-01).
public struct ProtocolCheckInPatternLine: View {
    let signal: ProtocolPatternSignal?
    let open: () -> Void

    public init(signal: ProtocolPatternSignal?, open: @escaping () -> Void) {
        self.signal = signal; self.open = open
    }

    public var body: some View {
        if let signal {
            Button(action: open) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    Image(systemName: "chart.dots.scatter")
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.protocolChip))
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                        LooprText(signal.title, style: .label, color: .ink)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprText(signal.detail, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LooprChevron()
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .looprCardBackground(.standard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(signal.accessibilityLabel)
            .accessibilityHint("Opens Patterns.")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("protocol-pattern-line")
        }
    }
}
