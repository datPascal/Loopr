import DesignSystem
import DomainKit
import Foundation
import RoutineKit

/// One card of the check-in: a protocol rule the person can answer now.
public struct ProtocolDeckQuestion: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A protocol rule. A manual rule is ticked; a rule a source checks is overridden by the answer.
        case rule(RuleKey, source: CheckSource)
    }

    public let kind: Kind
    /// Who checks the rule and when: "Checked by you · 21:30".
    public let eyebrow: String
    /// "Screens off by 21:45?", or "Did you keep to no alcohol?" for a rule written as something to avoid. Yes is
    /// always kept.
    public let question: String
    public let minuteOfDay: Int?
    /// Why the rule is on the list, in one short line. Nil when the rule says nothing.
    public var why: String?

    public var key: String {
        switch kind {
        case .rule(let key, _): key.rawValue
        }
    }

    public var id: String { key }
    public var accessibilityIdentifier: String { "protocol-deck-card-\(key)" }

    public var ruleKey: RuleKey? {
        switch kind {
        case .rule(let key, _): key
        }
    }
}

/// The three answers a card takes.
public enum ProtocolDeckChoice: String, Equatable, Sendable {
    case yes, no
    /// "Skip today": neither kept nor missed, left out of the kept share (ICP R1-HAB-01).
    case skip
}

/// An answer the person gave on the deck, kept so Undo can take it back.
public struct ProtocolDeckAnswer: Equatable, Sendable {
    public let question: ProtocolDeckQuestion
    public let choice: ProtocolDeckChoice
    public let day: DayIdentity

    public init(question: ProtocolDeckQuestion, choice: ProtocolDeckChoice, day: DayIdentity) {
        self.question = question; self.choice = choice; self.day = day
    }

    public var yes: Bool { choice == .yes }

    /// "You answered yes." or "You skipped it for today."
    public var summary: String {
        switch choice {
        case .yes: "You answered yes."
        case .no: "You answered no."
        case .skip: "You skipped it for today."
        }
    }
}

/// The rules the person still answers later today, under the deck: "Later tonight" over one row per rule, each of which
/// can be tapped to answer it now (ICP R2-VET-04, R2-HAB-04). Each rule goes by its own name, "In bed by 22:30", never a
/// short form beside a check time that reads as a different rule (R2-SEN-01, R2-NEW-04). Rules a source checks are left
/// out: the source answers them, so they are not questions still to come (R2-DES-17).
public struct ProtocolDeckLater: Equatable, Sendable {
    /// One rule still ahead.
    public struct Item: Equatable, Sendable, Identifiable {
        public let key: RuleKey
        /// The rule's own name: "Magnesium, 300 mg", "Screens off by 21:45".
        public let name: String
        /// "21:30" for a timed rule whose name holds no time, "tonight" for a rule without a time, else nil.
        public let when: String?

        public var id: RuleKey { key }
        public var accessibilityIdentifier: String { "protocol-deck-later-\(key.rawValue)" }
        /// "Magnesium, 300 mg at 21:30", "Stretch tonight".
        public var text: String { when.map { "\(name) \($0 == ProtocolDeckLater.tonight ? $0 : "at \($0)")" } ?? name }
    }

    static let tonight = "tonight"

    /// "Later tonight" when every rule ahead is in the evening and the morning is over, else "Later today".
    public let title: String
    /// Every rule ahead, earliest first. The view shows the first `ProtocolDeckQueue.laterLimit`.
    public let items: [Item]

    public var keys: [RuleKey] { items.map(\.key) }
    /// The rows the view draws, and how many more wait after them.
    public var shown: [Item] { Array(items.prefix(ProtocolDeckQueue.laterLimit)) }
    public var more: Int { max(items.count - ProtocolDeckQueue.laterLimit, 0) }

    /// "Later tonight: Magnesium, 300 mg at 21:30, Screens off by 21:45", for VoiceOver and tests.
    public var text: String {
        var parts = shown.map(\.text)
        if more > 0 { parts.append("and \(more) more") }
        return "\(title): \(parts.joined(separator: ", "))"
    }
}

/// Which rules the check-in deck asks, in which order, and what waits.
///
/// - A rule is asked when `RoutineDayCount.asksPerson` says so: it is still pending today and the person can answer it,
///   a manual rule, or an evening rule whatever its source, since the evening is when the person knows. Kept, missed,
///   skipped and unknown rules are not asked.
/// - A rule is asked only once its time has come (ICP R1-SEN-02, R1-NEW-06, R1-DES-09): its `timeOfDayMinutes` has
///   passed, or it has no time and it is 17:00 or later. A rule the person ticks that is still ahead waits in `later`,
///   and a tap there brings it to the front of the deck (`early`, R2-VET-04). Without a clock (`nowMinute` nil) every
///   open rule is asked.
/// - A rule that is not due today never reaches the deck (`isDue`): an off day of a rule on chosen days, an "N times a
///   week" rule already kept N times this week, a weekly tick already kept, or a rule every few weeks or months before
///   its next day (R2-VET-06).
/// - Rules brought forward come first, in the order they were tapped; then timed rules, earliest first; then untimed
///   rules in the version's order.
/// - The Journal's questions about the day are not cards. A Journal question that became a rule is asked only as that
///   rule (ICP R1-UPG-1).
public enum ProtocolDeckQueue {
    public static let swipeHint = "Swipe right for yes, left for no."
    /// The hint shows only before a person's third answer on this phone (ICP R1-HAB-05, R1-DES-14).
    public static let swipeHintAnswers = 3

    /// The swipe hint shows only to a person who has never answered a card: no answer of their own in the stored
    /// history and fewer than three on this phone (ICP R3-HAB-01, R3-SEN-08, R3-VET-04). A protocol with weeks of the
    /// person's own ticks never shows it, so the card is one line shorter.
    public static func showsSwipeHint(answersOnPhone: Int, history: [ProtocolDayInput]) -> Bool {
        guard answersOnPhone < swipeHintAnswers else { return false }
        return !history.contains { day in day.rules.contains { $0.decidedBy == .manual && $0.hasAnswer } }
    }
    /// Rules without a time join the deck from 17:00.
    public static let eveningMinute = 17 * 60
    /// The later list shows this many rules, then "and 2 more".
    static let laterLimit = 4

    /// - Parameters:
    ///   - week: this week, Monday first, for the kept count of "N times a week" rules. Empty counts nothing.
    ///   - progress: each longer-period rule's progress, for the next day of a rule every few weeks or months.
    ///   - early: rules the person asked to answer now, in the order they asked.
    public static func questions(today: ProtocolDayInput?, week: [ProtocolDayInput] = [],
                                 progress: [RuleKey: RuleProgress] = [:], nowMinute: Int? = nil, early: [RuleKey] = [],
                                 locale: Locale = .current) -> [ProtocolDeckQuestion] {
        let due = open(today: today, week: week, progress: progress)
        let pulled = early.compactMap { key in due.first { $0.element.rule.key == key }?.element }
        let rest = ordered(due.filter { item in
            !early.contains(item.element.rule.key) && hasCome(item.element.rule, nowMinute: nowMinute)
        })
        return (pulled + rest).map { ruleQuestion($0.rule, locale: locale) }
    }

    /// The rules the person can still answer today and that are due, with their place in the version.
    static func open(today: ProtocolDayInput?, week: [ProtocolDayInput],
                     progress: [RuleKey: RuleProgress]) -> [(offset: Int, element: ProtocolRuleDay)] {
        guard let today else { return [] }
        return today.rules.enumerated().filter { _, item in
            RoutineDayCount.asksPerson(source: item.rule.source, isEvening: item.rule.isEvening, state: item.state)
                && isDue(item.rule, on: today.day, keptThisWeek: keptDays(item.rule.key, in: week, through: today.day),
                         progress: progress[item.rule.key])
        }
    }

    static func ordered(_ rules: [(offset: Int, element: ProtocolRuleDay)]) -> [ProtocolRuleDay] {
        rules.sorted { lhs, rhs in
            switch (lhs.element.rule.timeOfDayMinutes, rhs.element.rule.timeOfDayMinutes) {
            case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// True once the rule's time has come: its time has passed, or it has none and it is evening. Nil asks every rule.
    public static func hasCome(_ rule: ProtocolRule, nowMinute: Int?) -> Bool {
        guard let nowMinute else { return true }
        guard let minute = rule.timeOfDayMinutes else { return nowMinute >= eveningMinute }
        return minute <= nowMinute
    }

    /// Whether the deck asks `rule` on `day`: RoutineKit's `RuleDueTest`, the test every count of a day uses too (ICP R4
    /// Q3).
    public static func isDue(_ rule: ProtocolRule, on day: DayIdentity, keptThisWeek: Int,
                             progress: RuleProgress? = nil) -> Bool {
        RuleDueTest.isDue(rule, on: day, keptThisWeek: keptThisWeek, progress: progress)
    }

    /// The days of `week` up to `day` on which the rule was kept.
    static func keptDays(_ key: RuleKey, in week: [ProtocolDayInput], through day: DayIdentity) -> Int {
        week.filter { dayKey($0.day) <= dayKey(day) }
            .filter { input in input.rules.contains { $0.rule.key == key && $0.state == .kept } }.count
    }

    static func dayKey(_ day: DayIdentity) -> Int { day.year * 10_000 + day.month * 100 + day.day }

    /// The rules the person ticks that are still ahead today. Nil when none is.
    public static func later(today: ProtocolDayInput?, week: [ProtocolDayInput] = [], progress: [RuleKey: RuleProgress] = [:],
                             nowMinute: Int, early: [RuleKey] = [], locale: Locale = .current) -> ProtocolDeckLater? {
        let ahead = ordered(open(today: today, week: week, progress: progress).filter { item in
            item.element.rule.source == .manual && !early.contains(item.element.rule.key)
                && !hasCome(item.element.rule, nowMinute: nowMinute)
        })
        guard !ahead.isEmpty else { return nil }
        // In the morning the deck is "This morning", so the list says "Later today" whatever it holds (ICP R3-DES-06).
        let evening = nowMinute >= morningEnd
            && ahead.allSatisfy { ($0.rule.timeOfDayMinutes ?? eveningMinute) >= eveningMinute }
        let items = ahead.map { item in
            ProtocolDeckLater.Item(key: item.rule.key, name: ownName(item.rule, locale: locale), when: when(item.rule, locale: locale))
        }
        return ProtocolDeckLater(title: evening ? "Later tonight" : "Later today", items: items)
    }

    /// The rule's title as the person wrote it, with its time in the locale's clock.
    static func ownName(_ rule: ProtocolRule, locale: Locale) -> String {
        LooprClockFormat.localizing(rule.title.trimmingCharacters(in: .whitespacesAndNewlines), locale: locale)
    }

    /// "21:30", "tonight", or nil when the name already says a time ("In bed by 22:30" is never "In bed by 22:30 at
    /// 21:45").
    static func when(_ rule: ProtocolRule, locale: Locale) -> String? {
        guard let minute = rule.timeOfDayMinutes else { return ProtocolDeckLater.tonight }
        if rule.title.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return nil }
        return LooprClockFormat.text(minuteOfDay: minute, locale: locale)
    }

    /// "Tonight is an off night for the magnesium test.", one line per test that keeps a rule off today (R1-VET-02).
    public static func offNightLines(today: ProtocolDayInput?) -> [String] {
        var names: [String] = []
        for item in today?.rules ?? [] where item.isSkippedByDesign {
            if let name = item.offNightTest?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        return names.map { "Tonight is an off night for the \($0) test." }
    }

    /// Noon, where "This morning" ends.
    static let morningEnd = 12 * 60

    /// The deck's title by the time of day.
    public static func title(nowMinute: Int) -> String {
        if nowMinute < morningEnd { return "This morning" }
        if nowMinute < eveningMinute { return "This afternoon" }
        return "Tonight's check-in"
    }

    /// "Magnesium, 300 mg" reads "Magnesium" and "Screens off by 21:45" reads "Screens off", for lines that put the
    /// rule's time after it or name it in passing.
    static func shortName(_ rule: ProtocolRule, locale: Locale) -> String {
        var title = rule.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = title.firstIndex(of: ","), comma != title.startIndex { title = String(title[..<comma]) }
        title = title.replacingOccurrences(of: #"\s+(by|at|after|before|until)\s+\d{1,2}:\d{2}$"#, with: "",
                                           options: .regularExpression)
        return LooprClockFormat.localizing(title, locale: locale)
    }

    static func ruleQuestion(_ rule: ProtocolRule, locale: Locale) -> ProtocolDeckQuestion {
        let who = "Checked by \(ProtocolAutoFill.name(rule.source))"
        let eyebrow = rule.timeOfDayMinutes.map { "\(who) \u{00B7} \(LooprClockFormat.text(minuteOfDay: $0, locale: locale))" } ?? who
        return ProtocolDeckQuestion(kind: .rule(rule.key, source: rule.source), eyebrow: eyebrow,
                                    question: rule.checkInQuestion(locale: locale), minuteOfDay: rule.timeOfDayMinutes,
                                    why: whyLine(rule))
    }

    /// The rule's why, or the evening reason the person wrote, shortened at a sentence or a word, never mid-word
    /// (ICP R2-SEN-05). Nil when there is none.
    static func whyLine(_ rule: ProtocolRule) -> String? {
        ProtocolRule.shortLine(rule.why ?? rule.rebuttal)
    }

    /// The one quiet line in the deck's place while nothing is due and a rule the person ticks is still ahead
    /// (R2-DES-05): "Nothing yet.", or "Done for now." once the person has answered something today. The later list
    /// right under it names each rule and its time, so the line no longer repeats the next one (ICP R3-SEN-02). Nil
    /// when nothing is ahead, where the closing card takes over.
    /// - Parameter answering: true while an answer from the deck is saving, which counts as answered.
    public static func waitingLine(today: ProtocolDayInput?, later: ProtocolDeckLater?, answering: Bool = false) -> String? {
        guard let next = later?.items.first, today?.rules.contains(where: { $0.rule.key == next.key }) == true else {
            return nil
        }
        let answered = answering || today?.rules.contains { $0.decidedBy == .manual && $0.hasAnswer } == true
        return answered ? "Done for now." : "Nothing yet."
    }
}

/// The card that ends the check-in once nothing is left to answer today (ICP R1-DES-01, R1-SEN-08): it says the day is
/// done, then one line about tomorrow (R2-SEN-06): "Tomorrow: In bed by 22:30." No streak, no score, no word about what
/// was not kept.
public struct ProtocolDeckClosing: Equatable, Sendable {
    public let title: String
    public let detail: String
    /// "Tomorrow: Magnesium, 300 mg at 21:30." Nil when no rule is due tomorrow.
    public let tomorrow: String?

    /// `rules` are the protocol's rules, which tomorrow uses unless they change. The line names tomorrow's earliest
    /// timed rule the person ticks, else the earliest evening rule a source checks ("In bed by 22:30"), else a rule they
    /// tick without a time. A rule only a source checks during the day is named only when nothing else is due.
    public static func make(nowMinute: Int, tomorrow rules: [ProtocolRule], tomorrowDay: DayIdentity? = nil,
                            locale: Locale = .current) -> ProtocolDeckClosing {
        let title = nowMinute >= ProtocolDeckQueue.eveningMinute ? "Tonight is done" : "Today is done"
        let due = rules.filter { rule in tomorrowDay.map { rule.isDue(on: $0) } ?? true }
        let asks = due.filter { $0.source == .manual || $0.isEvening }
        let earliest = { (list: [ProtocolRule]) in
            list.filter { $0.timeOfDayMinutes != nil }.min { ($0.timeOfDayMinutes ?? 0) < ($1.timeOfDayMinutes ?? 0) }
        }
        let ticked = asks.filter { $0.source == .manual }
        let first = earliest(ticked) ?? earliest(asks) ?? ticked.first ?? earliest(due)
        let line = first.map { rule -> String in
            let name = ProtocolDeckQueue.ownName(rule, locale: locale)
            guard let when = ProtocolDeckQueue.when(rule, locale: locale), when != ProtocolDeckLater.tonight else {
                return "Tomorrow: \(name)."
            }
            return "Tomorrow: \(name) at \(when)."
        }
        return ProtocolDeckClosing(title: title, detail: "Nothing is left for you to answer.", tomorrow: line)
    }
}

/// What the deck's counter says: the rules to answer now. Nil hides it while the deck waits for a later rule.
public struct ProtocolDeckProgress: Equatable, Sendable {
    public let remaining: Int
    /// Rules the person answers later today.
    public let later: Int

    public init(remaining: Int, later: Int = 0) { self.remaining = max(remaining, 0); self.later = max(later, 0) }

    /// "3 left", "All answered", or nil while the deck is empty and a rule is still ahead.
    public var text: String? {
        if remaining > 0 { return "\(remaining) left" }
        return later > 0 ? nil : "All answered"
    }

    public var accessibilityLabel: String {
        switch remaining {
        case 0: later > 0 ? "Nothing to answer right now" : "All answered"
        case 1: "1 rule left to answer"
        default: "\(remaining) rules left to answer"
        }
    }
}
