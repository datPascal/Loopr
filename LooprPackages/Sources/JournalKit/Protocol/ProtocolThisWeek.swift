import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import SwiftUI

/// One rule in "This week": how many of its checks were kept, who checks it, the days that passed with no answer, and
/// how far a rule with a longer period has come (ICP R3-VET-01, R3-VET-02).
public struct ProtocolThisWeekRow: Equatable, Sendable, Identifiable {
    public var id: RuleKey { ruleKey }
    public let ruleKey: RuleKey
    public let title: String
    /// The rule's checks Monday to today, counted as the hero counts them.
    public let count: RoutineWeekCount
    /// "5 of 6 kept", or "No answer yet". Nil for a rule with a longer period that had nothing to answer this week.
    public let countText: String?
    /// "Checked by you", "Checked by Food".
    public let who: String
    /// Days before today that passed with no answer, for a rule asked every day it is due.
    public let notKnown: Int
    /// Checks the person changed over what a source decided.
    public let changed: Int
    /// "Each week · 112 of 150 min · 6 days left", "Every 3 months · last done 2 Nov · due 2 Feb". Nil for a daily rule.
    public let schedule: String?

    /// The line under the name: "Checked by Food · 1 not known · 1 skipped".
    public var detail: String {
        var parts = [who]
        if notKnown > 0 { parts.append("\(notKnown) not known") }
        if count.skipped > 0 { parts.append("\(count.skipped) skipped") }
        if changed > 0 { parts.append("\(changed) changed by you") }
        return parts.joined(separator: " \u{00B7} ")
    }

    public var accessibilityLabel: String {
        [title, countText, detail, schedule].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What "This week" shows: the hero's number opened into its checks, one row per rule.
public struct ProtocolThisWeekContent: Equatable, Sendable {
    /// "This week, 13 to 19 Nov".
    public let title: String
    /// "12 of 13 kept so far.", the hero's count.
    public let lead: String
    /// "Counts checks with an answer. Skipped and not known are left out."
    public let countingRule: String
    public let rows: [ProtocolThisWeekRow]
    /// Every row added up. The same numbers as the hero's.
    public let count: RoutineWeekCount
    /// "2 of the 13 were changed by you." Nil when nothing has an answer or no rule a source checks has one.
    public let foot: String?
}

/// Builds "This week" from plain inputs: the protocol's rules, this week's counted days
/// (`ProtocolRoutineData.countedWeek`, only the rules due each day, ICP R4 Q3) and the longer rules' progress. It counts
/// with `RoutineWeekCount`, so its total is the hero's (ICP R3-VET-01).
///
/// - One row per rule of the newest version, in its order, then any rule that left the protocol this week and still has
///   days in it.
/// - "1 not known" counts the days before today on which a rule asked that day had no answer, kept or not kept or
///   skipped. Today is still open, so it never counts. A rule with a longer period, such as "Zone 2, 150 min a week" or
///   a blood panel every 3 months, is not asked every day; it shows how far it has come instead.
/// - "Changed by you" counts the checks with an answer the person set over what a source decided, as the day sheet
///   marks them.
public enum ProtocolThisWeek {
    public static let title = "This week"

    public static func make(rules: [ProtocolRule], week: [ProtocolDayInput], progress: [RuleKey: RuleProgress] = [:],
                            today: DayIdentity, calendar: ProtocolWeekCalendar) -> ProtocolThisWeekContent {
        let counted = week.filter { $0.phase != .future }
        var order = rules.map(\.key)
        var byKey = Dictionary(rules.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for day in counted {
            for item in day.rules where byKey[item.rule.key] == nil {
                byKey[item.rule.key] = item.rule
                order.append(item.rule.key)
            }
        }
        let locale = calendar.locale
        let rows = order.compactMap { key -> ProtocolThisWeekRow? in
            guard let rule = byKey[key] else { return nil }
            let items = counted.compactMap { day in day.rules.first { $0.rule.key == key }.map { (phase: day.phase, item: $0) } }
            return row(rule, items: items, progress: progress[key], today: today, locale: locale)
        }
        let total = RoutineWeekCount(kept: rows.reduce(0) { $0 + $1.count.kept }, missed: rows.reduce(0) { $0 + $1.count.missed },
                                     skipped: rows.reduce(0) { $0 + $1.count.skipped },
                                     unknown: rows.reduce(0) { $0 + $1.count.unknown })
        let lead = total.decided == 0 ? ProtocolWeekSummary.absentText + "."
            : "\(total.kept) of \(total.decided) kept so far."
        let hasSourceAnswers = counted.contains { day in day.rules.contains { $0.rule.source != .manual && $0.isDecided } }
        let changed = rows.reduce(0) { $0 + $1.changed }
        let foot = total.decided > 0 && hasSourceAnswers ? changesLine(changed, of: total.decided) : nil
        let sunday = calendar.adding(6, to: calendar.week(containing: today).first ?? today)
        let range = (calendar.week(containing: today).first).flatMap { monday in
            sunday.map { ProtocolWeeklyReviewPlacement.range(monday, $0, calendar: calendar) }
        }
        return ProtocolThisWeekContent(title: range.map { "\(title), \($0)" } ?? title, lead: lead,
                                       countingRule: ProtocolWeekSummary.countingRule, rows: rows, count: total, foot: foot)
    }

    static func row(_ rule: ProtocolRule, items: [(phase: ProtocolDayPhase, item: ProtocolRuleDay)], progress: RuleProgress?,
                    today: DayIdentity, locale: Locale) -> ProtocolThisWeekRow {
        let count = RoutineWeekCount(states: items.map(\.item.state))
        let longer = RuleProgressReader.hasProgress(rule)
        let notKnown = longer ? 0 : items.filter { entry in
            entry.phase == .past && !entry.item.hasAnswer
        }.count
        let changed = items.filter { $0.item.isDecided && $0.item.overriddenByPerson && rule.source != .manual }.count
        let countText: String? = count.decided > 0 ? "\(count.kept) of \(count.decided) kept"
            : (longer ? nil : "No answer yet")
        return ProtocolThisWeekRow(ruleKey: rule.key, title: rule.displayTitle(locale: locale), count: count,
                                   countText: countText,
                                   who: "Checked by \(ProtocolAutoFill.name(rule.source))", notKnown: notKnown,
                                   changed: changed,
                                   schedule: ProtocolRulesPresentation.schedule(rule, progress: progress, today: today,
                                                                                locale: locale))
    }

    /// "2 of the 13 were changed by you.", "1 of the 13 was changed by you.", "None of the 13 were changed by you."
    static func changesLine(_ changed: Int, of decided: Int) -> String {
        switch changed {
        case 0: "None of the \(decided) were changed by you."
        case 1: "1 of the \(decided) was changed by you."
        default: "\(changed) of the \(decided) were changed by you."
        }
    }
}

extension ProtocolWeekSummary {
    /// "In bed not kept on Monday": the part of the hero that opens that day. Nil when the hero names no rule.
    var heroSlip: String? {
        let prefix = line + " \u{00B7} "
        guard slippedDay != nil, hero.hasPrefix(prefix) else { return nil }
        return String(hero.dropFirst(prefix.count))
    }

    /// The hero without `heroSlip`: "12 of 13 kept this week".
    var heroLead: String { heroSlip == nil ? hero : line }
}

/// The hero line with "This week" behind it (ICP R3-VET-01): a tap on the number opens every rule's count, while the
/// words that name a rule not kept still open that day. The check-in places this where the hero sits.
struct ProtocolThisWeekHero: View {
    @ObservedObject var model: ProtocolTabModel
    let summary: ProtocolWeekSummary
    /// Opens the day the named rule was last not kept.
    var openSlip: (() -> Void)?
    @State private var showsWeek = false

    var body: some View {
        ProtocolKeptHero(summary: summary, openSlip: openSlip, openWeek: { showsWeek = true })
            .sheet(isPresented: $showsWeek) {
                if let routine = model.routine {
                    ProtocolThisWeekSheet(content: ProtocolThisWeek.make(rules: routine.rules, week: routine.countedWeek,
                                                                         progress: routine.progress, today: routine.today,
                                                                         calendar: model.week))
                }
            }
    }
}

/// "This week": the hero's count, the counting rule, one row per rule and how many answers the person changed. It
/// opens large, so twelve rules fit in a screen and a half, and every row wraps at large text sizes.
public struct ProtocolThisWeekSheet: View {
    let content: ProtocolThisWeekContent
    @Environment(\.dismiss) private var dismiss

    public init(content: ProtocolThisWeekContent) { self.content = content }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(content.lead, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-this-week-lead")
                        LooprText(content.countingRule, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { LooprHairline() }
                                ProtocolThisWeekRowView(row: row)
                            }
                        }
                    }
                    if let foot = content.foot {
                        LooprText(foot, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-this-week-changes")
                    }
                }
                .padding(LooprSpacing.screenGutter)
            }
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle(content.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("protocol-this-week-done")
                }
            }
        }
        .presentationDetents([.large])
        .tint(Color.loopr(.protocol))
        .accessibilityIdentifier("protocol-this-week-sheet")
    }
}

/// One rule: the name over who checks it, the count on the right. From the largest standard text size up the count
/// moves under the name, so a long name keeps its width.
private struct ProtocolThisWeekRowView: View {
    let row: ProtocolThisWeekRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
        layout {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                LooprText(row.title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(row.detail, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let schedule = row.schedule {
                    LooprText(schedule, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let count = row.countText {
                LooprText(count, style: .label, color: row.count.decided > 0 ? .ink : .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .padding(.vertical, LooprSpacing.xs)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("protocol-this-week-rule-\(row.ruleKey.rawValue)")
    }
}
