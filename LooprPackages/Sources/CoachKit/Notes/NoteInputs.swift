import DomainKit
import Foundation
import RoutineKit

// Plain values the app fills from stored data. The engine never reads a store, a clock or the network, so the same
// input and the same context always give the same note. The inputs are generic on purpose: the app maps its own
// Journal, Food and pattern types into them.

public enum NoteOutcomeKind: String, Codable, CaseIterable, Sendable {
    case sleepHeartRate, restingHeartRate, hrv, deepSleep, sleepDuration, timeToFallAsleep

    public var defaultUnit: NoteUnit {
        switch self {
        case .sleepHeartRate, .restingHeartRate: .bpm
        case .hrv: .milliseconds
        case .deepSleep, .sleepDuration, .timeToFallAsleep: .minutes
        }
    }

    /// Which way is better for the person. Only the weekly review reads it, to pick a slip that coincided with a worse
    /// outcome. No sentence says better or worse.
    var higherIsBetter: Bool {
        switch self {
        case .hrv, .deepSleep, .sleepDuration: true
        case .sleepHeartRate, .restingHeartRate, .timeToFallAsleep: false
        }
    }

    /// The start of a sentence: "Sleep heart rate was 49 bpm last night."
    var title: String {
        switch self {
        case .sleepHeartRate: "Sleep heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .hrv: "HRV"
        case .deepSleep: "Deep sleep"
        case .sleepDuration: "Sleep"
        case .timeToFallAsleep: "Time to fall asleep"
        }
    }

    /// The middle of a sentence: "On the 21 nights with 4 h or more, sleep heart rate averaged 5 bpm lower."
    var phrase: String {
        self == .hrv ? title : title.prefix(1).lowercased() + title.dropFirst()
    }

    /// The plain word for a direction. Higher is not always better, so the word never judges.
    func direction(higher: Bool) -> String {
        switch self {
        case .sleepHeartRate, .restingHeartRate, .hrv, .deepSleep: higher ? "higher" : "lower"
        case .sleepDuration: higher ? "longer" : "shorter"
        case .timeToFallAsleep: higher ? "slower" : "faster"
        }
    }
}

/// What the band measured for last night. Absent is absent: a missing outcome is a nil `NightOutcome`, never a zero.
public struct NightOutcome: Equatable, Sendable {
    public let kind: NoteOutcomeKind
    public let value: Double
    public let unit: NoteUnit
    /// The day the night ended, used for the weekday in `daysCovered`.
    public let day: DayIdentity?

    public init(kind: NoteOutcomeKind, value: Double, unit: NoteUnit? = nil, day: DayIdentity? = nil) {
        self.kind = kind; self.value = value; self.unit = unit ?? kind.defaultUnit; self.day = day
    }
}

/// The person's usual for the same outcome: the median over a window, with the nights that had data.
public struct NoteUsual: Equatable, Sendable {
    public let median: Double
    /// Nights with data inside the window.
    public let nights: Int
    /// The length of the window in days, for example 30.
    public let windowDays: Int

    public init(median: Double, nights: Int, windowDays: Int) {
        self.median = median; self.nights = nights; self.windowDays = windowDays
    }
}

/// What a factor was last night. The writer sets it into the factor's statement.
public enum NoteFactorValue: Equatable, Sendable {
    case duration(minutes: Double)
    case clock(minuteOfDay: Int)
    case quantity(Double, unit: String)
    /// A yes or no factor with nothing to state.
    case flag
}

/// One of the two groups a factor splits nights into, such as "4 h or more" and "less". The label has to read after
/// "with": "the 21 nights with 4 h or more".
public struct NoteFactorGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// One night of history: the group the night fell in and the outcome that night. A night without an outcome is nil and
/// is left out of every count and mean.
public struct NoteFactorNight: Equatable, Sendable {
    public let day: DayIdentity?
    public let groupID: String
    public let outcome: Double?
    public init(day: DayIdentity? = nil, groupID: String, outcome: Double?) {
        self.day = day; self.groupID = groupID; self.outcome = outcome
    }
}

public struct NightFactor: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// A sentence about last night with `{value}` where the factor's value goes: "You stopped eating {value} before bed."
    public let statement: String
    /// Nil when the factor is unknown for last night. The factor is then never named.
    public let lastNightValue: NoteFactorValue?
    /// The id of the group last night fell in. Nil when unknown.
    public let lastNightGroupID: String?
    /// Exactly two groups. The factor is never named with any other number.
    public let groups: [NoteFactorGroup]
    public let history: [NoteFactorNight]

    public init(id: String, name: String, statement: String, lastNightValue: NoteFactorValue?, lastNightGroupID: String?,
                groups: [NoteFactorGroup], history: [NoteFactorNight]) {
        self.id = id; self.name = name; self.statement = statement; self.lastNightValue = lastNightValue
        self.lastNightGroupID = lastNightGroupID; self.groups = groups; self.history = history
    }
}

public struct MorningNoteInput: Equatable, Sendable {
    /// Nil when the band has no outcome for last night. The note is then absent.
    public let lastNight: NightOutcome?
    public let usual: NoteUsual?
    public let factors: [NightFactor]

    public init(lastNight: NightOutcome?, usual: NoteUsual? = nil, factors: [NightFactor] = []) {
        self.lastNight = lastNight; self.usual = usual; self.factors = factors
    }
}

/// One rule today, from RoutineKit, with what the day's check says.
public struct NoteRuleDay: Equatable, Sendable, Identifiable {
    public var id: RuleKey { rule.key }
    public let rule: ProtocolRule
    public let state: CheckState
    /// When the rule was kept, as minutes after midnight, if the source knows. The kitchen closing at 18:20 is one.
    public let keptAtMinuteOfDay: Int?
    /// A past-tense name for a kept rule: "Kitchen closed". Nil falls back to the title.
    public let keptLabel: String?
    /// Days this week the rule was kept, today included. Nil when the app has no count.
    public let keptDaysThisWeek: Int?
    /// Days of this week that count so far, today included. Never more than 7.
    public let daysThisWeek: Int?

    public init(rule: ProtocolRule, state: CheckState, keptAtMinuteOfDay: Int? = nil, keptLabel: String? = nil,
                keptDaysThisWeek: Int? = nil, daysThisWeek: Int? = nil) {
        self.rule = rule; self.state = state; self.keptAtMinuteOfDay = keptAtMinuteOfDay; self.keptLabel = keptLabel
        self.keptDaysThisWeek = keptDaysThisWeek; self.daysThisWeek = daysThisWeek
    }
}

public struct EveningNoteInput: Equatable, Sendable {
    public let rules: [NoteRuleDay]
    public init(rules: [NoteRuleDay]) { self.rules = rules }
}

public enum NotePatternStrength: String, Codable, CaseIterable, Comparable, Sendable {
    case early, clear, strong

    private var rank: Int { switch self { case .early: 0; case .clear: 1; case .strong: 2 } }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// What a found pattern carries into a line. The app maps its own `FoundPattern` into this.
public struct NotePatternSummary: Equatable, Sendable, Identifiable {
    public let id: String
    /// "Dinner 4 h before bed".
    public let factor: String
    public let outcome: NoteOutcomeKind
    /// With minus the others, in `unit`. Negative reads as lower.
    public let difference: Double
    public let unit: NoteUnit
    public let nights: Int
    public let strength: NotePatternStrength

    public init(id: String, factor: String, outcome: NoteOutcomeKind, difference: Double, unit: NoteUnit? = nil,
                nights: Int, strength: NotePatternStrength) {
        self.id = id; self.factor = factor; self.outcome = outcome; self.difference = difference
        self.unit = unit ?? outcome.defaultUnit; self.nights = nights; self.strength = strength
    }
}
