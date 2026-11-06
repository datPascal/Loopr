import DesignSystem
import Foundation
import RoutineKit
import SwiftUI

/// The one-time card at the top of the check-in after the move from the Journal (ICP R1-UPG-12): which habit questions
/// became rules and which stayed questions about the day. What a protocol is, `lead`, is said once, on the start screen
/// (ICP R1-NEW-04, R1-SEN-05, R1-DES-02); a protocol from a template gets the "Your list is ready" card instead.
public struct ProtocolIntro: Equatable, Sendable {
    /// What the list is, in the start screen's words: "your list" and "rules", not "protocol", a word a newcomer does
    /// not know (ICP R2-SEN-04). The start screen says it; no other screen repeats it.
    public static let lead = "Your list is a few rules for your day, and each evening Loopr asks about the ones it cannot check for you."
    public static let seenKey = "loopr.protocol.introSeen"
    /// How many rule names the card spells out before it says "and 3 more".
    static let namedLimit = 4

    public let title: String
    public let moved: String?
    public let stayed: String?

    /// - Parameters:
    ///   - rules: the newest version's rules.
    ///   - habitRuleIDs: the habits that became rules.
    ///   - stayed: the names of the Journal questions that did not become rules.
    public static func make(rules: [ProtocolRule], habitRuleIDs: Set<UUID>, stayed: [String],
                            locale: Locale = .current) -> ProtocolIntro {
        let moved = rules.filter { RoutineHabitMigration.habitID(forRuleKey: $0.key).map(habitRuleIDs.contains) == true }
        guard !moved.isEmpty || !habitRuleIDs.isEmpty else {
            return ProtocolIntro(title: "What your protocol is", moved: nil, stayed: nil)
        }
        let count = max(moved.count, habitRuleIDs.count)
        let names = names(moved.map { ProtocolAutoFill.lowercasedFirst($0.displayTitle(locale: locale)) }, locale: locale)
        let movedText = count == 1
            ? "1 of your Journal questions is a rule now\(names.map { ": \($0)" } ?? ""). You answer it in the check-in, and every answer you gave before came with it."
            : "\(count) of your Journal questions are rules now\(names.map { ": \($0)" } ?? ""). You answer them in the check-in, and every answer you gave before came with them."
        var stayedText: String?
        if let list = Self.names(stayed.map(ProtocolAutoFill.lowercasedFirst), locale: locale) {
            stayedText = stayed.count == 1
                ? "1 stayed a question because it is about your day, not a habit: \(list). It is under About the day."
                : "\(stayed.count) stayed questions because they are about your day, not a habit: \(list). They are under About the day."
        }
        return ProtocolIntro(title: "Your habit questions moved here", moved: movedText, stayed: stayedText)
    }

    /// The card shows until it is dismissed, on a protocol moved over from the Journal. A protocol in its first week
    /// without moved questions has nothing to say here: the start screen already said what a protocol is.
    public static func shows(_ routine: ProtocolRoutineData) -> Bool {
        !routine.habitRuleIDs.isEmpty
    }

    /// "no alcohol, screens off by 9:45 pm and 3 more". Nil for an empty list.
    static func names(_ items: [String], locale: Locale) -> String? {
        guard !items.isEmpty else { return nil }
        guard items.count > namedLimit else { return ProtocolWeekSummary.list(items, locale: locale) }
        return ProtocolWeekSummary.list(Array(items.prefix(namedLimit)) + ["\(items.count - namedLimit) more"], locale: locale)
    }
}

/// The card. "Got it" hides it for good.
struct ProtocolIntroCard: View {
    let intro: ProtocolIntro
    let dismiss: () -> Void

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(intro.title, style: .cardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let moved = intro.moved {
                    LooprText(moved, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stayed = intro.stayed {
                    LooprText(stayed, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Got it", action: dismiss)
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                    .accessibilityIdentifier("protocol-intro-dismiss")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-intro")
    }
}
