import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import SwiftUI

/// "Skip the rest of today": one decision for a sick day instead of a Skip per rule (ICP R2-NEW-06, R2-SEN-02,
/// R2-VET-03, R2-HAB-02, R2-DES-11), limited to the rules the person answers (ICP R3-DES-04, R3-VET-06, R3-NEW-03).
///
/// - It skips the rules the person ticks that are still open today and due today (`ProtocolDeckQueue.isDue`): no
///   answer yet. A rule a source checks is left open for its source, even when the source has not reported yet, so a
///   day Food or the band can still settle never loses its answer. What is kept, not kept or skipped stays, and so does
///   an off night of a running test.
/// - It shows only while two or more such rules are open. With one, the card's own Skip says the same.
/// - A skipped rule is neither kept nor not kept, so the week's share leaves it out (`RoutineWeekCount`).
/// - Undo clears exactly the rules it skipped, which were open before, so they are open again.
public enum ProtocolSkipDay {
    public static let actionTitle = "Skip the rest of today"
    public static let undoTitle = "Undo"
    /// The action shows from this many open rules the person answers (ICP R3-NEW-03).
    public static let minimumOpen = 2

    /// The rules the action would skip, in the day's order. Empty on a day that is not today.
    /// - Parameters:
    ///   - week: this week, Monday first, for the kept count of "N times a week" rules.
    ///   - progress: each longer-period rule's progress, so a rule every few months is skipped only on a day it is due.
    public static func openRules(today: ProtocolDayInput?, week: [ProtocolDayInput] = [],
                                 progress: [RuleKey: RuleProgress] = [:]) -> [RuleKey] {
        guard let today, today.phase == .today else { return [] }
        return today.rules.filter { item in
            item.rule.source == .manual && isOpen(item) && isDue(item.rule, today: today, week: week, progress: progress)
        }.map(\.rule.key)
    }

    /// "Food and the band keep checking their rules.", or "Food keeps checking its rules." for one source: the sources whose
    /// rules are still open today and that the skip leaves alone. Nil when no rule a source checks is still open.
    public static func checkingLine(today: ProtocolDayInput?, week: [ProtocolDayInput] = [],
                                    progress: [RuleKey: RuleProgress] = [:], locale: Locale = .current) -> String? {
        guard let today, today.phase == .today else { return nil }
        let sources = Set(today.rules.filter { item in
            item.rule.source != .manual && isOpen(item) && isDue(item.rule, today: today, week: week, progress: progress)
        }.map(\.rule.source))
        guard !sources.isEmpty else { return nil }
        let names = ProtocolAutoFill.capitalizedFirst(ProtocolAutoFill.names(sources, locale: locale))
        return sources.count == 1 ? "\(names) keeps checking its rules." : "\(names) keep checking their rules."
    }

    /// No answer yet, or a source that could not tell. Kept, not kept and skipped stay as they are.
    static func isOpen(_ item: ProtocolRuleDay) -> Bool {
        guard item.offNightTest == nil else { return false }
        switch item.state {
        case nil, .pending?, .unknown?: return true
        case .kept?, .missed?, .skipped?: return false
        }
    }

    /// The deck's due test, so the skip never touches a rule the deck would not ask today, such as a blood panel months
    /// before its next day.
    static func isDue(_ rule: ProtocolRule, today: ProtocolDayInput, week: [ProtocolDayInput],
                      progress: [RuleKey: RuleProgress]) -> Bool {
        ProtocolDeckQueue.isDue(rule, on: today.day,
                                keptThisWeek: ProtocolDeckQueue.keptDays(rule.key, in: week, through: today.day),
                                progress: progress[rule.key])
    }

    /// Whether the action shows: two or more open rules the person answers, or a skip Undo can still take back.
    public static func shows(openCount: Int, skipped: ProtocolSkippedDay?) -> Bool {
        skipped != nil || openCount >= minimumOpen
    }

    /// "Skip 5 rules you answer?"
    public static func confirmTitle(count: Int) -> String {
        count == 1 ? "Skip 1 rule you answer?" : "Skip \(count) rules you answer?"
    }

    /// "Food and the band keep checking their rules. Skipped rules don't count against your week." `checking` is
    /// `checkingLine`; without one only the second sentence remains.
    public static func confirmMessage(checking: String?) -> String {
        [checking, "Skipped rules don't count against your week."].compactMap { $0 }.joined(separator: " ")
    }

    /// "Skip 4 rules"
    public static func confirmButton(count: Int) -> String { count == 1 ? "Skip 1 rule" : "Skip \(count) rules" }

    /// "4 rules skipped for today."
    public static func doneText(count: Int) -> String {
        count == 1 ? "1 rule skipped for today." : "\(count) rules skipped for today."
    }

    /// The line under "Feeling sick" when it is answered Yes: "Rest today. Loopr can skip the 3 rules you still have to
    /// answer."
    public static func offerText(count: Int) -> String {
        count == 1 ? "Rest today. Loopr can skip the 1 rule you still have to answer."
            : "Rest today. Loopr can skip the \(count) rules you still have to answer."
    }

    /// Whether a question about the day is about being unwell, such as "Feeling sick", "Ill today" or "Flu", so the
    /// evening sheet offers to skip the rest of today when it is answered Yes.
    public static func isSickQuestion(_ title: String) -> Bool {
        let words = Set(title.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: sickWords)
    }

    static let sickWords: Set<String> = ["sick", "ill", "unwell", "flu", "fever", "poorly", "illness"]
}

/// What "Skip the rest of today" did, kept until Undo or the day changes.
public struct ProtocolSkippedDay: Equatable, Sendable {
    public let day: DayIdentity
    /// The rules it skipped, which were open before.
    public let keys: [RuleKey]

    public init(day: DayIdentity, keys: [RuleKey]) { self.day = day; self.keys = keys }
}

/// The action with plain inputs, for the deck's foot and the top of today's day sheet. Before: a quiet button that asks
/// once with the number of rules it skips. After: "4 rules skipped for today." with Undo. Nothing when no rule is open
/// and nothing was skipped.
public struct ProtocolSkipDayAction: View {
    /// Rules the person answers that are still open today.
    let openCount: Int
    /// "Food and the band keep checking their rules.", from `ProtocolSkipDay.checkingLine`. Nil when no source does.
    var checking: String?
    /// What the action skipped today, while Undo can take it back.
    let skipped: ProtocolSkippedDay?
    let isSaving: Bool
    let skip: () -> Void
    let undo: () -> Void
    /// Where it sits, so each place has its own identifiers: "deck", "day-sheet" or "evening".
    var place: String = "deck"
    @State private var confirming = false

    public init(openCount: Int, checking: String? = nil, skipped: ProtocolSkippedDay?, isSaving: Bool, place: String = "deck",
                skip: @escaping () -> Void, undo: @escaping () -> Void) {
        self.openCount = openCount; self.checking = checking; self.skipped = skipped; self.isSaving = isSaving; self.place = place
        self.skip = skip; self.undo = undo
    }

    public var body: some View {
        if let skipped {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprText(ProtocolSkipDay.doneText(count: skipped.keys.count), style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("protocol-skip-day-\(place)-done")
                Button(ProtocolSkipDay.undoTitle, action: undo)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.protocolChip))
                    .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                    .disabled(isSaving)
                    .accessibilityLabel("Undo skipping the rest of today")
                    .accessibilityIdentifier("protocol-skip-day-\(place)-undo")
            }
        } else if ProtocolSkipDay.shows(openCount: openCount, skipped: nil) {
            Button { confirming = true } label: {
                HStack(spacing: LooprSpacing.xs) {
                    Image(systemName: "moon.zzz")
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(.protocolChip))
                        .accessibilityHidden(true)
                    LooprText(ProtocolSkipDay.actionTitle, style: .label, color: .protocolChip)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .disabled(isSaving)
            .accessibilityHint(ProtocolSkipDay.confirmTitle(count: openCount))
            .accessibilityIdentifier("protocol-skip-day-\(place)")
            .confirmationDialog(ProtocolSkipDay.confirmTitle(count: openCount), isPresented: $confirming,
                                titleVisibility: .visible) {
                Button(ProtocolSkipDay.confirmButton(count: openCount)) { skip() }
                    .accessibilityIdentifier("protocol-skip-day-confirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("protocol-skip-day-cancel")
            } message: {
                Text(ProtocolSkipDay.confirmMessage(checking: checking))
            }
        }
    }
}

/// The offer under a "Feeling sick" question answered Yes, in the evening sheet: one line that says why, and the same
/// action with its one confirm and Undo. It reads the tab's model, so the count stays current while the sheet is open.
struct ProtocolSickDayOffer: View {
    @ObservedObject var model: ProtocolTabModel

    var body: some View {
        let open = model.skipDayOpenCount
        if ProtocolSkipDay.shows(openCount: open, skipped: model.skippedToday) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                if model.skippedToday == nil {
                    LooprText(ProtocolSkipDay.offerText(count: open), style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProtocolSkipDayAction(openCount: open, checking: model.skipDayChecking, skipped: model.skippedToday,
                                      isSaving: model.isSaving, place: "evening",
                                      skip: { Task { await model.skipRestOfToday() } },
                                      undo: { Task { await model.undoSkipRestOfToday() } })
            }
            .padding(.vertical, LooprSpacing.xs)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-sick-day-offer")
        }
    }

    /// The offer for the evening sheet's questions: shown under a question about being unwell once it is answered Yes.
    static func offer(model: ProtocolTabModel) -> JournalYesOffer {
        JournalYesOffer(matches: { ProtocolSkipDay.isSickQuestion($0.checkInTitle) }) {
            AnyView(ProtocolSickDayOffer(model: model))
        }
    }
}
