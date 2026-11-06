import DesignSystem
import Foundation

// The protocol rail under the coach note: today's rules in time order with what checks each one. The app maps
// RoutineKit's rules and the day's checks into `TodayRailRuleInput`; every order, label and state decision is here, so
// it is tested without a store.

/// The rule's group in the protocol (RoutineKit's `RuleGroup`).
public enum TodayRailGroup: String, Equatable, Sendable {
    case sleep, food, fitness, supplements, tests, custom
}

/// What a rule's target asks for (RoutineKit's `RuleTargetKind`).
public enum TodayRailTargetKind: String, Equatable, Sendable {
    case done, atLeast, atMost, exactly
}

/// What a rule's metric counts, so the rail writes "38 g" or "18:30" (RoutineKit's `RoutineMetricUnit`).
public enum TodayRailUnit: String, Equatable, Sendable {
    case grams, kilocalories, drinks, minutes, sessions, steps, minutesAfterMidnight, tick, other
}

/// One rule of the active version with today's check.
public struct TodayRailRuleInput: Equatable, Sendable {
    public var key: String
    public var title: String
    public var group: TodayRailGroup
    public var source: TodayDialRuleSource
    /// RoutineKit's metric name. Nil for a plain tick.
    public var metric: String?
    public var targetKind: TodayRailTargetKind
    public var targetValue: Double?
    public var unit: TodayRailUnit?
    /// The reminder time, minutes after midnight. Nil for a rule that holds all day.
    public var timeOfDayMinutes: Int?
    public var isEvening: Bool
    public var state: TodayDialRuleState
    /// What the source measured so far. Nil when it measured nothing, never a stand-in zero.
    public var measuredValue: Double?

    public init(key: String, title: String, group: TodayRailGroup = .custom, source: TodayDialRuleSource = .manual,
                metric: String? = nil, targetKind: TodayRailTargetKind = .done, targetValue: Double? = nil,
                unit: TodayRailUnit? = nil, timeOfDayMinutes: Int? = nil, isEvening: Bool = false,
                state: TodayDialRuleState, measuredValue: Double? = nil) {
        self.key = key
        self.title = title
        self.group = group
        self.source = source
        self.metric = metric
        self.targetKind = targetKind
        self.targetValue = targetValue
        self.unit = unit
        self.timeOfDayMinutes = timeOfDayMinutes
        self.isEvening = isEvening
        self.state = state
        self.measuredValue = measuredValue
    }
}

/// One rule as a row.
public struct TodayRailRow: Equatable, Sendable, Identifiable {
    public let id: String
    /// "07:00", "18:30" in the locale's clock, or "All day".
    public let timeText: String
    public let title: String
    /// "Food checks it", "38 g so far · Food checks it", "48 min in zone 2".
    public let detail: String
    public let state: TodayDialRuleState
    /// Live progress toward the target, 0 to 1, where the source has it.
    public let progress: Double?
    /// A manual rule not kept yet, on today's rail.
    public let canTick: Bool
    public let accent: LooprColorToken
    public let symbol: String
    public let source: TodayDialRuleSource

    /// "Screens off, 21:45, you tick this one."
    public var accessibilityLabel: String {
        var parts = [title, timeText, detail]
        switch state {
        case .kept: parts.append("kept")
        case .missed: parts.append("missed")
        case .pending, .unknown: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A rule shown as a chip at the top: morning light and supplements.
public struct TodayRailChip: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let state: TodayDialRuleState
    public let canTick: Bool

    public var accessibilityLabel: String {
        switch state {
        case .kept: "\(title), kept"
        case .missed: "\(title), missed"
        case .pending, .unknown: canTick ? "\(title), not ticked yet" : "\(title), not kept yet"
        }
    }
}

public struct TodayRailContent: Equatable, Sendable {
    public let chips: [TodayRailChip]
    public let rows: [TodayRailRow]
    public let keptCount: Int
    public let ruleCount: Int

    /// "2 of 8 rules kept".
    public var summary: String { Self.summary(kept: keptCount, total: ruleCount) }

    /// Every row's time text, so each row's time column is as wide as the widest and the squares and titles line up
    /// (ICP R2-UPG-23).
    public var timeTexts: [String] { Array(Set(rows.map(\.timeText))).sorted() }

    public static func summary(kept: Int, total: Int) -> String {
        "\(min(kept, total)) of \(total) \(total == 1 ? "rule" : "rules") kept"
    }

    /// The label beside the header's ring: "4 of 10 kept" (ICP R2-UPG-22).
    public static func ringLabel(kept: Int, total: Int) -> String { "\(min(kept, total)) of \(total) kept" }

    /// Up next's last row: "All 10 rules", or "Your rule" for a protocol of one.
    public static func allRulesLabel(total: Int) -> String { total == 1 ? "Your rule" : "All \(total) rules" }

    /// Up next with nothing open: every rule kept, or the rest already decided for the day.
    public static func nothingLeft(kept: Int, total: Int) -> String {
        kept >= total ? "Every rule kept today." : "Nothing left to do today."
    }
}

public enum TodayRailState: Equatable, Sendable {
    case rules(TodayRailContent)
    /// No protocol yet: one row that says where rules come from.
    case noProtocol

    public static let emptyText = "Today's rules come from your protocol. Start one from a template in Protocol."
    public static let emptyAction = "Open Protocol"
}

/// Order, words and states for the rail.
public enum TodayRailRules {
    /// Rules that show as chips at the top when today has them: morning light and the day's supplements. An evening
    /// supplement, such as magnesium before bed, keeps its time in the rows with the other evening rules.
    public static func isChip(_ rule: TodayRailRuleInput) -> Bool {
        (rule.group == .supplements && !rule.isEvening) || rule.metric == "daylight_minutes"
    }

    /// A bedtime before noon belongs to the evening before, so an evening rule at 00:30 sorts after 23:00, as the bedtime
    /// Live Activity orders its steps. Morning rules keep their clock time.
    static let afterMidnightLimit = 12 * 60

    /// The rail's order. Rules without a time that hold all day come first, then every timed rule by its time (an
    /// evening rule after midnight after the late evening), then evening rules without a time last. Equal times keep the
    /// version's order. Read on its own, the evening rules come out in the same order as the Live Activity's steps.
    public static func ordered(_ rules: [TodayRailRuleInput]) -> [TodayRailRuleInput] {
        rules.enumerated().sorted { lhs, rhs in
            let left = sortKey(lhs.element), right = sortKey(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    static func sortKey(_ rule: TodayRailRuleInput) -> Int {
        guard let minute = rule.timeOfDayMinutes, (0..<1_440).contains(minute) else {
            return rule.isEvening ? Int.max : Int.min
        }
        return rule.isEvening && minute < afterMidnightLimit ? minute + 1_440 : minute
    }

    /// - Parameters:
    ///   - isToday: only today's rail ticks.
    ///   - mode: the dial's mode. A manual rule that can be ticked says "Tap to tick" in both.
    public static func content(_ rules: [TodayRailRuleInput], isToday: Bool, mode: TodayDialMode,
                               locale: Locale = .current) -> TodayRailContent {
        let ordered = ordered(rules)
        let chips = ordered.filter(isChip).map { rule in
            TodayRailChip(id: rule.key, title: LooprClockFormat.localizing(rule.title, locale: locale), state: rule.state,
                          canTick: canTick(rule, isToday: isToday))
        }
        let rows = ordered.filter { !isChip($0) }.map { row($0, isToday: isToday, mode: mode, locale: locale) }
        return TodayRailContent(chips: chips, rows: rows, keptCount: rules.filter { $0.state == .kept }.count,
                                ruleCount: rules.count)
    }

    static func canTick(_ rule: TodayRailRuleInput, isToday: Bool) -> Bool {
        isToday && rule.source == .manual && rule.state != .kept
    }

    static func row(_ rule: TodayRailRuleInput, isToday: Bool, mode: TodayDialMode, locale: Locale) -> TodayRailRow {
        let tick = canTick(rule, isToday: isToday)
        return TodayRailRow(
            id: rule.key, timeText: timeText(rule.timeOfDayMinutes, locale: locale),
            title: LooprClockFormat.localizing(rule.title, locale: locale),
            detail: detail(rule, canTick: tick, mode: mode, locale: locale), state: rule.state,
            progress: rule.state == .pending ? progress(rule) : nil, canTick: tick, accent: accent(rule),
            symbol: rule.state == .kept ? "checkmark" : symbol(rule), source: rule.source)
    }

    public static func timeText(_ minute: Int?, locale: Locale) -> String {
        guard let minute, (0..<1_440).contains(minute) else { return "All day" }
        return LooprClockFormat.text(minuteOfDay: minute, locale: locale)
    }

    // MARK: Words

    /// "The band checks it", "Food checks it", "You tick this one".
    public static func sourcePhrase(_ source: TodayDialRuleSource) -> String {
        switch source {
        case .band: "The band checks it"
        case .food: "Food checks it"
        case .fitness: "Fitness checks it"
        case .appleHealth: "Apple Health checks it"
        case .manual: "You tick this one"
        }
    }

    /// What a manual rule says whenever today's rail can tick it, morning and evening alike.
    public static let tapToTick = "Tap to tick"

    /// The second line of a row. A kept rule says what kept it; a pending rule shows live progress or its target, then
    /// what checks it; a manual rule says how to tick it.
    static func detail(_ rule: TodayRailRuleInput, canTick: Bool, mode: TodayDialMode, locale: Locale) -> String {
        switch rule.state {
        case .kept:
            return keptText(rule, locale: locale)
        case .missed:
            return joined(["Not kept today", rule.source == .manual ? nil : sourcePhrase(rule.source)])
        case .unknown:
            if rule.source == .manual { return canTick ? manualPhrase(mode) : "Not ticked" }
            return joined(["No reading yet", sourcePhrase(rule.source)])
        case .pending:
            if rule.source == .manual { return canTick ? manualPhrase(mode) : sourcePhrase(.manual) }
            let lead = progressText(rule, locale: locale) ?? targetText(rule, locale: locale)
            return joined([lead, sourcePhrase(rule.source)])
        }
    }

    static func manualPhrase(_ mode: TodayDialMode) -> String {
        tapToTick
    }

    /// What kept a rule: "48 min in zone 2", "10 minutes early", "132 g today", "Ticked".
    public static func keptText(_ rule: TodayRailRuleInput, locale: Locale) -> String {
        if rule.source == .manual { return "Ticked" }
        guard let value = rule.measuredValue, value.isFinite, value >= 0 else { return "Kept" }
        switch rule.unit {
        case .minutesAfterMidnight?:
            guard let target = rule.targetValue, target.isFinite else { return "Kept" }
            let gap = Int((target - value).rounded())
            switch rule.targetKind {
            // Up to an hour early reads as minutes. Further ahead the time says more: a kitchen that closed after
            // lunch at 12:30 is "At 12:30", not "360 minutes early" (ICP R2-OPT-8).
            case .atMost where gap > 0 && gap < 60: return "\(gap) \(gap == 1 ? "minute" : "minutes") early"
            case .atMost where gap >= 60:
                return "At \(LooprClockFormat.text(minuteOfDay: ((Int(value.rounded()) % 1_440) + 1_440) % 1_440, locale: locale))"
            case .atMost, .exactly: return "Right on time"
            case .atLeast, .done:
                return "At \(LooprClockFormat.text(minuteOfDay: ((Int(value.rounded()) % 1_440) + 1_440) % 1_440, locale: locale))"
            }
        case .minutes?:
            let amount = integer(value, locale: locale)
            switch rule.metric {
            case "zone2_minutes": return "\(amount) min in zone 2"
            case "zone45_minutes": return "\(amount) min in zones 4 and 5"
            case "daylight_minutes": return "\(amount) min in daylight"
            case "workout_minutes": return "\(amount) min of training"
            default: return "\(amount) min"
            }
        case .tick?:
            return rule.group == .supplements ? "All taken" : "Kept"
        case .grams?, .kilocalories?, .steps?, .drinks?, .sessions?:
            return quantity(value, unit: rule.unit, locale: locale) + " today"
        case .other?, nil:
            return "Kept"
        }
    }

    /// "38 g so far" for a rule that counts up through the day and has a reading. Nil otherwise.
    public static func progressText(_ rule: TodayRailRuleInput, locale: Locale) -> String? {
        guard rule.targetKind == .atLeast, let value = rule.measuredValue, value.isFinite, value >= 0 else { return nil }
        switch rule.unit {
        case .grams?, .kilocalories?, .steps?, .minutes?, .sessions?:
            return quantity(value, unit: rule.unit, locale: locale) + " so far"
        default:
            return nil
        }
    }

    /// Progress toward an "at least" target, 0 to 1.
    static func progress(_ rule: TodayRailRuleInput) -> Double? {
        guard rule.targetKind == .atLeast, let value = rule.measuredValue, let target = rule.targetValue,
              value.isFinite, target.isFinite, target > 0, rule.unit != .minutesAfterMidnight else { return nil }
        return min(max(value / target, 0), 1)
    }

    /// "By 18:30", "130 g". Nil when the title already says it or there is nothing to say.
    static func targetText(_ rule: TodayRailRuleInput, locale: Locale) -> String? {
        guard let target = rule.targetValue, target.isFinite, target >= 0 else { return nil }
        let text: String
        switch rule.unit {
        case .minutesAfterMidnight?:
            let minute = ((Int(target.rounded()) % 1_440) + 1_440) % 1_440
            let clock = LooprClockFormat.text(minuteOfDay: minute, locale: locale)
            let title = LooprClockFormat.localizing(rule.title, locale: locale)
            if title.contains(clock) || rule.title.contains(String(format: "%02d:%02d", minute / 60, minute % 60)) { return nil }
            // "No caffeine after 14:00" stores its limit as 13:59. The title already says the time; "By 1:59 PM" under
            // "after 2:00 PM" read as a bug (UX R2-NEW-08).
            let next = (minute + 1) % 1_440
            if title.contains(LooprClockFormat.text(minuteOfDay: next, locale: locale))
                || rule.title.contains(String(format: "%02d:%02d", next / 60, next % 60)) { return nil }
            switch rule.targetKind {
            case .atMost: text = "By \(clock)"
            case .atLeast: text = "From \(clock)"
            case .exactly, .done: text = "At \(clock)"
            }
        case .grams?, .kilocalories?, .steps?, .minutes?, .sessions?, .drinks?:
            let amount = quantity(target, unit: rule.unit, locale: locale)
            if rule.title.contains(integer(target, locale: locale)) { return nil }
            switch rule.targetKind {
            case .atLeast: text = "At least \(amount)"
            // A limit of zero is "None today", not "At most 0 drinks" (UX R2-VET-10).
            case .atMost: text = target.rounded() == 0 ? "None today" : "At most \(amount)"
            case .exactly: text = amount
            case .done: return nil
            }
        default:
            return nil
        }
        return text
    }

    static func quantity(_ value: Double, unit: TodayRailUnit?, locale: Locale) -> String {
        let amount = integer(value, locale: locale)
        let whole = Int(value.rounded())
        switch unit {
        case .grams?: return "\(amount) g"
        case .kilocalories?: return "\(amount) kcal"
        case .minutes?: return "\(amount) min"
        case .steps?: return "\(amount) steps"
        case .drinks?: return whole == 1 ? "1 drink" : "\(amount) drinks"
        case .sessions?: return whole == 1 ? "1 session" : "\(amount) sessions"
        default: return amount
        }
    }

    /// Through the app's one number formatter, as the dial and Your day write numbers (ICP R2-OPT-9).
    static func integer(_ value: Double, locale: Locale) -> String {
        LooprUnitFormatter.number(value.rounded()) ?? String(Int(value.rounded()))
    }

    static func joined(_ parts: [String?]) -> String {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        guard let first = kept.first else { return "" }
        // Food, Fitness and Apple Health are names and keep their capital after the dot; "The band" does not.
        let rest = kept.dropFirst().map { part in
            part.hasPrefix("The ") || part.hasPrefix("You ") ? part.prefix(1).lowercased() + part.dropFirst() : part
        }
        return ([first] + rest).joined(separator: " · ")
    }

    // MARK: Look

    /// The domain accent of a row's square. Manual rules are the protocol's own plum.
    static func accent(_ rule: TodayRailRuleInput) -> LooprColorToken {
        if rule.source == .manual { return .protocol }
        switch rule.group {
        case .food: return .energy
        case .fitness: return .strain
        case .sleep: return .sleep
        case .supplements: return .protocol
        case .tests, .custom: return .brand
        }
    }

    static func symbol(_ rule: TodayRailRuleInput) -> String {
        switch rule.group {
        case .food: return "fork.knife"
        case .fitness: return "figure.run"
        case .sleep: return rule.source == .manual ? "iphone" : "moon.fill"
        case .supplements: return "pills.fill"
        case .tests: return "testtube.2"
        case .custom: return rule.source == .manual ? "hand.tap" : "circle.dashed"
        }
    }
}
