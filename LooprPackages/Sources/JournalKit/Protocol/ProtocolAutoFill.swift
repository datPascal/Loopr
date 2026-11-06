import DesignSystem
import Foundation
import RoutineKit

/// One rule today that a source answered, or that the person answered over a source.
public struct ProtocolAutoFillItem: Equatable, Sendable, Identifiable {
    public var id: RuleKey { ruleKey }
    public let ruleKey: RuleKey
    public let title: String
    /// The rule's own source: Food, Fitness, the band or Apple Health.
    public let source: CheckSource
    public let state: CheckState
    /// True when the person's answer replaced the source's.
    public let overridden: Bool
}

/// The row under the deck that says how many of today's rules a source checked: "4 checked for you", over "Food,
/// Fitness and the band". A tap opens today's day sheet, where each row says what its source saw and the person can
/// change it (ICP R1-NEW-08, R1-HAB-16, R1-DES-04). It counts the rules a source decided today, kept or not kept, and
/// the ones the person changed after a source decided them, which it names apart.
public struct ProtocolCheckedForYou: Equatable, Sendable {
    public let count: Int
    /// "4 checked for you", or "None checked for you yet".
    public let title: String
    /// "By Food, Fitness and the band. You changed 1."
    public let detail: String

    public var accessibilityLabel: String { "\(title). \(detail)" }
}

public enum ProtocolAutoFill {
    public static func items(today: ProtocolDayInput?, locale: Locale = .current) -> [ProtocolAutoFillItem] {
        (today?.rules ?? []).compactMap { item in
            guard item.rule.source != .manual, let state = item.state, item.isDecided else { return nil }
            return ProtocolAutoFillItem(ruleKey: item.rule.key, title: item.rule.displayTitle(locale: locale),
                                        source: item.rule.source, state: state,
                                        overridden: item.overriddenByPerson)
        }
    }

    /// Nil when the protocol has no rule a source checks.
    public static func checkedForYou(today: ProtocolDayInput?, locale: Locale = .current) -> ProtocolCheckedForYou? {
        let sourceRules = (today?.rules ?? []).filter { $0.rule.source != .manual }
        guard !sourceRules.isEmpty else { return nil }
        let all = items(today: today, locale: locale)
        let changed = all.filter(\.overridden).count
        let kinds = Set((all.isEmpty ? sourceRules.map(\.rule.source) : all.map(\.source)))
        let who = names(kinds, locale: locale)
        guard !all.isEmpty else {
            let verb = kinds.count == 1 ? "checks its rules" : "check their rules"
            return ProtocolCheckedForYou(count: 0, title: "None checked for you yet",
                                         detail: "\(capitalizedFirst(who)) \(verb) as the day goes on.")
        }
        var detail = "By \(who)."
        if changed > 0 { detail += " You changed \(changed)." }
        return ProtocolCheckedForYou(count: all.count, title: "\(all.count) checked for you", detail: detail)
    }

    static let sourceOrder: [CheckSource] = [.food, .fitness, .band, .appleHealth]

    static func names(_ sources: Set<CheckSource>, locale: Locale) -> String {
        ProtocolWeekSummary.list(sourceOrder.filter(sources.contains).map(name), locale: locale)
    }

    public static func name(_ source: CheckSource) -> String {
        switch source {
        case .food: "Food"
        case .fitness: "Fitness"
        case .band: "the band"
        case .appleHealth: "Apple Health"
        case .manual: "you"
        }
    }

    /// Where a check came from, for its chip.
    public static func provenance(_ source: CheckSource) -> LooprProvenance {
        switch source {
        case .food: .food(.logged)
        case .fitness: .onThisPhone
        case .band: .band(device: "")
        case .appleHealth: .appleHealth(source: "")
        case .manual: .typedIn
        }
    }

    /// "No alcohol" becomes "no alcohol". A word in capitals, such as "HRV", stays.
    static func lowercasedFirst(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let second = trimmed.dropFirst().first
        if second?.isUppercase == true { return trimmed }
        return first.lowercased() + trimmed.dropFirst()
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
