import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import SwiftUI

/// One rule on one day in the day sheet: its state, who checked it and what that source saw, and whether the person can
/// change it (ICP R1-DES-04, R1-HAB-07, R1-VET-04). Every rosette and the "checked for you" row open the same sheet.
public struct ProtocolDayRuleRow: Equatable, Sendable, Identifiable {
    public var id: RuleKey { ruleKey }
    public let ruleKey: RuleKey
    public let title: String
    public let state: ProtocolDotState
    /// "Kept", "Not kept", "Skipped", "Open", "Not known" or "Ahead". "Not asked tonight" on a running test's off night.
    public let stateText: String
    /// Who checked it and what it saw: "Food saw 82 g of protein.", "Your answer.", "Off night in the magnesium test."
    public let detail: String?
    /// The person's answer replaced what a source decided. Shown as "Changed by you", next to what the source saw.
    public let changedByYou: Bool
    /// The answer the control shows: kept, missed or skipped. Nil while open or not known.
    public let selection: CheckState?
    /// False on a day ahead, which nobody can answer yet.
    public let canChange: Bool
    /// "Use what Food says" or "Clear my answer", when the person's answer can go back. Nil when there is nothing to undo.
    public let resetTitle: String?

    public var accessibilityLabel: String {
        [title, stateText, changedByYou ? ProtocolDayRules.changedText : nil, detail].compactMap { $0 }.joined(separator: ", ")
    }

    /// True on a running test's off night, where the person was not asked (ICP R4 SEN words).
    public var isNotAsked: Bool { stateText.hasPrefix(ProtocolDayRules.notAskedPrefix) }
}

/// What the day sheet shows for one day.
public struct ProtocolDaySheetContent: Equatable, Sendable {
    /// "Today, Tuesday 14 Nov".
    public let title: String
    /// "Tap an answer to change it."
    public let lead: String
    public let rows: [ProtocolDayRuleRow]
    /// R2 (ICP R4 Q3): "Not due today: Blood panel, next in February." under the list. Nil when every rule was due.
    public let notDue: String?
    /// R2 (ICP R4 Q6): "You changed your rules on 2 Nov. This day shows the list you had then." Nil unless a past day
    /// shows a list that differs from today's.
    public let listChange: String?

    public init(title: String, lead: String, rows: [ProtocolDayRuleRow], notDue: String? = nil, listChange: String? = nil) {
        self.title = title; self.lead = lead; self.rows = rows; self.notDue = notDue; self.listChange = listChange
    }
}

public enum ProtocolDayRules {
    public static let changedText = "Changed by you"
    /// The detail of a rule answered with Done or Skip today on its reminder (R1, ICP round 4 SEN and VET).
    public static let reminderAnswerText = "Answered from your reminder."
    /// The start of an off night's state: "Not asked tonight", or "Not asked that night" on a past day (ICP R4 SEN).
    static let notAskedPrefix = "Not asked"

    /// The day's rules in the version's order. A day ahead lists its rules with no state and no control.
    public static func rows(for day: ProtocolDayInput, locale: Locale = .current) -> [ProtocolDayRuleRow] {
        day.rules.map { item in
            let future = day.phase == .future
            let state: ProtocolDotState = future ? .pending : .from(item.state, phase: day.phase)
            let selection: CheckState? = item.hasAnswer ? item.state : nil
            let changed = item.overriddenByPerson && item.rule.source != .manual
            let text = future ? "Ahead" : item.isSkippedByDesign ? notAskedText(day.phase) : stateText(state)
            return ProtocolDayRuleRow(ruleKey: item.rule.key, title: item.rule.displayTitle(locale: locale), state: state,
                                      stateText: text, detail: detail(item, phase: day.phase, locale: locale),
                                      changedByYou: changed, selection: future ? nil : selection, canChange: !future,
                                      resetTitle: future ? nil : resetTitle(item))
        }
    }

    public static func content(for day: ProtocolDayInput, calendar: ProtocolWeekCalendar) -> ProtocolDaySheetContent {
        let date = calendar.dayTitle(day.day)
        let title = day.phase == .today ? "Today, \(date)" : date
        let lead = day.phase == .future ? "The rules for this day. You answer them on the day."
            : "Tap an answer to change it."
        return ProtocolDaySheetContent(title: title, lead: lead, rows: rows(for: day, locale: calendar.locale))
    }

    /// "Not asked tonight" on today's off night, "Not asked that night" on any other day.
    static func notAskedText(_ phase: ProtocolDayPhase) -> String {
        phase == .today ? "\(notAskedPrefix) tonight" : "\(notAskedPrefix) that night"
    }

    static func stateText(_ state: ProtocolDotState) -> String {
        switch state {
        case .kept: "Kept"
        case .missed: "Not kept"
        case .skipped: "Skipped"
        case .pending: "Open"
        case .unknown: "Not known"
        }
    }

    /// Who checked the rule and what it saw, in one sentence.
    static func detail(_ item: ProtocolRuleDay, phase: ProtocolDayPhase, locale: Locale) -> String? {
        guard phase != .future else { return nil }
        if item.isSkippedByDesign, let test = item.offNightTest { return "Off night in the \(test) test." }
        let rule = item.rule
        // R1 reminders (ICP round 4, SEN and VET): an answer given on the rule's reminder says so.
        if item.answeredFromReminder, item.hasAnswer { return reminderAnswerText }
        if rule.source == .manual {
            switch item.state {
            case .kept?, .missed?: return "Your answer."
            case .skipped?: return "You skipped it."
            default: return phase == .today ? "Waiting for your answer." : "No answer that day."
            }
        }
        let who = ProtocolAutoFill.capitalizedFirst(ProtocolAutoFill.name(rule.source))
        let saw = seen(rule, value: item.measuredValue, locale: locale).map { "\(who) saw \($0)." }
        if item.overriddenByPerson { return saw }
        switch item.state {
        case .kept?, .missed?: return saw ?? "Checked by \(ProtocolAutoFill.name(rule.source))."
        case .unknown?: return "\(who) could not tell."
        default: return phase == .today ? "\(who) checks it as the day goes on." : "\(who) could not tell."
        }
    }

    /// What a source measured, in the rule's own terms: "82 g of protein", "the last caffeine at 10:15". Nil when it
    /// measured nothing.
    static func seen(_ rule: ProtocolRule, value: Double?, locale: Locale) -> String? {
        guard let value, value.isFinite, value >= 0, let metric = rule.target.metric.flatMap(RoutineMetric.init(rawValue:)) else {
            return nil
        }
        let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        let clock = LooprClockFormat.text(minuteOfDay: Int(value.rounded()) % 1_440, locale: locale)
        switch metric {
        case .lastCaffeineTime: return "the last caffeine at \(clock)"
        case .lastMealTime: return "the last meal at \(clock)"
        case .inBedTime: return "you in bed at \(clock)"
        case .sleepOnsetTime: return "you asleep at \(clock)"
        case .proteinG: return "\(number) g of protein"
        case .fibreG: return "\(number) g of fibre"
        case .energyKcal: return "\(number) kcal"
        case .alcoholDrinks: return value == 0 ? "no drinks logged" : "\(number) \(value == 1 ? "drink" : "drinks")"
        case .zone2Minutes: return "\(number) min in zone 2"
        case .zone45Minutes: return "\(number) min in zones 4 and 5"
        case .workoutMinutes: return "\(number) min of training"
        case .daylightMinutes: return "\(number) min of daylight"
        case .steps: return "\(number) steps"
        default:
            let unit = rule.target.unit?.trimmingCharacters(in: .whitespaces) ?? ""
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
    }

    /// The way back from the person's answer: to the source's own answer, to the off night, or to no answer.
    static func resetTitle(_ item: ProtocolRuleDay) -> String? {
        if item.offNightTest != nil { return item.overriddenByPerson ? "Back to the off night" : nil }
        if item.rule.source == .manual { return item.hasAnswer ? "Clear my answer" : nil }
        return item.overriddenByPerson ? "Use what \(ProtocolAutoFill.name(item.rule.source)) says" : nil
    }
}

/// A day opened from its rosette or from "checked for you".
struct ProtocolOpenedDay: Identifiable, Equatable {
    var id: DayIdentity { day }
    let day: DayIdentity
}

/// The one day sheet: every rule of the day with who checked it and what it saw, and one No, Yes and Skip control that
/// shows its state and changes it. A change is saved at once and marked "Changed by you". Today's sheet starts with
/// "Skip the rest of today" (ICP R2-DES-11, R2-VET-03). It opens large, so ten rules fit in a screen and a half
/// (ICP R2-DES-12).
struct ProtocolDaySheet: View {
    @ObservedObject var model: ProtocolTabModel
    let day: DayIdentity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    if let content {
                        if isToday {
                            ProtocolSkipDayAction(openCount: model.skipDayOpenCount, checking: model.skipDayChecking,
                                                  skipped: model.skippedToday,
                                                  isSaving: model.isSaving, place: "day-sheet",
                                                  skip: { Task { await model.skipRestOfToday() } },
                                                  undo: { Task { await model.undoSkipRestOfToday() } })
                        }
                        LooprText(content.lead, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // R2 (ICP R4 Q6): why a past day's list is not today's.
                        if let change = content.listChange {
                            LooprText(change, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("protocol-day-list-change")
                        }
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { LooprHairline() }
                                    ProtocolDayRuleRowView(row: row, isSaving: model.isSaving) { state in
                                        Task { await model.setAnswer(row.ruleKey, day: day, to: state) }
                                    }
                                }
                            }
                        }
                        // R2 (ICP R4 Q3): the rules this day does not count.
                        if let notDue = content.notDue {
                            LooprText(notDue, style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("protocol-day-not-due")
                        }
                    }
                    if let message = model.errorMessage {
                        LooprInlineMessage(message, tone: .warning)
                    }
                }
                .padding(LooprSpacing.screenGutter)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle(content?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("protocol-day-done")
                }
            }
        }
        .presentationDetents([.large])
        .tint(Color.loopr(.protocol))
        .accessibilityIdentifier("protocol-day-sheet")
    }

    private var isToday: Bool { day == model.routine?.today }

    private var content: ProtocolDaySheetContent? {
        guard let routine = model.routine else { return nil }
        return ProtocolDayRules.content(for: day, routine: routine, calendar: model.week)
    }
}

/// One rule in the day sheet, about 72 pt tall: the state dot, the name and one line on who checked it, with the No,
/// Yes and Skip control beside them. The control is the only place the state is written (ICP R2-DES-12). From the
/// largest standard text size up the control moves under the name, so a long name never squeezes to one word a line.
private struct ProtocolDayRuleRowView: View {
    let row: ProtocolDayRuleRow
    let isSaving: Bool
    /// The person's answer, or nil to go back to the source or to no answer.
    let change: (CheckState?) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// One segment: the 44 pt touch target, so the control sits beside the name.
    static let segment: CGFloat = 44

    struct Choice: Identifiable, Sendable {
        var id: CheckState { state }
        let state: CheckState
        let title: String
        /// What VoiceOver reads.
        let spoken: String
    }

    /// Yes and No, as the deck asks, and Skip. VoiceOver reads them as Not kept, Kept and Skip.
    static let choices = [Choice(state: .missed, title: "No", spoken: "Not kept"), Choice(state: .kept, title: "Yes", spoken: "Kept"),
                          Choice(state: .skipped, title: "Skip", spoken: "Skip")]

    var body: some View {
        let layout = typeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.sm))
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            layout {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    ProtocolStateDot(state: row.state)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                        LooprText(row.title, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = sourceLine {
                            LooprText(line, style: .caption, color: row.changedByYou ? .protocolChip : .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                // "-changed" exists only while the person's answer stands over the source's.
                .accessibilityIdentifier("protocol-day-rule-\(row.ruleKey.rawValue)-\(row.changedByYou ? "changed" : "label")")
                if row.canChange { control }
            }
            if row.canChange, let reset = row.resetTitle {
                LooprInlineAction(reset, identifier: "protocol-day-rule-\(row.ruleKey.rawValue)-reset", color: .protocolChip) {
                    change(nil)
                }
                    .padding(.leading, LooprSpacing.lg)
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .disabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-day-rule-\(row.ruleKey.rawValue)")
    }

    /// "Changed by you. Food saw 82 g of protein.", "Not asked tonight. Off night in the magnesium test.", or who
    /// checked it. One line under the name.
    private var sourceLine: String? {
        if row.isNotAsked { return [row.stateText + ".", row.detail].compactMap { $0 }.joined(separator: " ") }
        guard row.changedByYou else { return row.detail }
        return [ProtocolDayRules.changedText + ".", row.detail].compactMap { $0 }.joined(separator: " ")
    }

    /// Three 44 pt segments in one capsule. The selected one is filled in the Protocol plum.
    private var control: some View {
        let identifier = "protocol-day-rule-\(row.ruleKey.rawValue)-answer"
        return HStack(spacing: LooprSpacing.xxs / 2) {
            ForEach(Self.choices) { choice in
                let selected = row.selection == choice.state
                Button {
                    guard !selected else { return }
                    change(choice.state)
                } label: {
                    LooprText(choice.title, style: .label, color: selected ? LooprColorToken.protocol.spectralChipLabel : .inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, LooprSpacing.xs)
                        .frame(minWidth: Self.segment, minHeight: Self.segment)
                        .background(selected ? Color.loopr(.protocol).opacity(0.16) : Color.clear, in: Capsule())
                        .overlay {
                            if selected {
                                Capsule().stroke(Color.loopr(.protocol), lineWidth: LooprSpacing.hairline)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityLabel("\(row.title), \(choice.spoken)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier)-\(choice.state.rawValue)")
            }
        }
        .padding(LooprSpacing.xxs / 2)
        .background(Color.loopr(.surfaceElevated), in: Capsule())
        .fixedSize()
        .animation(LooprMotion.stateChange, value: row.selection)
        .sensoryFeedback(.selection, trigger: row.selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title)
        .accessibilityIdentifier(identifier)
    }
}
