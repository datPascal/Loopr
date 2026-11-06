import DomainKit
import Foundation
import RoutineKit

// What the app hands the weekly review. The engine reads these plain values and nothing else: no store, no clock, no
// network. The app maps its protocol checks, night outcomes and found patterns into them.

/// One rule on one day of the week, as the check decided it. Pending and unknown are not decided.
public struct WeeklyRuleDay: Equatable, Sendable {
    public let day: DayIdentity
    public let state: CheckState
    public init(day: DayIdentity, state: CheckState) { self.day = day; self.state = state }
}

public struct WeeklyRuleWeek: Equatable, Sendable, Identifiable {
    public var id: RuleKey { rule.key }
    public let rule: ProtocolRule
    public let days: [WeeklyRuleDay]
    /// The last day the rule was kept before the week, for a rule every few days, weeks or months, so a day it was not
    /// due on is left out of the count (ICP R4 Q3). Nil reads as never done: every day of the week is due.
    public let lastDone: DayIdentity?
    public init(rule: ProtocolRule, days: [WeeklyRuleDay], lastDone: DayIdentity? = nil) {
        self.rule = rule; self.days = days; self.lastDone = lastDone
    }
}

/// One outcome over the week, against the person's usual for it.
public struct WeeklyOutcomeWeek: Equatable, Sendable, Identifiable {
    public var id: NoteOutcomeKind { kind }
    public let kind: NoteOutcomeKind
    public let unit: NoteUnit
    /// The mean over the nights this week that had a value. Nil when none did.
    public let weekMean: Double?
    /// Nights this week with a value.
    public let nights: Int
    public let usual: NoteUsual?

    public init(kind: NoteOutcomeKind, unit: NoteUnit? = nil, weekMean: Double?, nights: Int, usual: NoteUsual?) {
        self.kind = kind; self.unit = unit ?? kind.defaultUnit; self.weekMean = weekMean; self.nights = nights; self.usual = usual
    }
}

/// One night of a rule's history: whether the rule was missed that day and the outcome the night after.
public struct WeeklySlipNight: Equatable, Sendable {
    public let day: DayIdentity?
    public let missed: Bool
    /// Nil when the band had no outcome. The night then counts for neither group.
    public let outcome: Double?
    public init(day: DayIdentity? = nil, missed: Bool, outcome: Double?) {
        self.day = day; self.missed = missed; self.outcome = outcome
    }
}

public enum WeeklyExperimentDesign: String, Codable, CaseIterable, Sendable {
    case alternatingDays, blocks, beforeAndAfter
}

/// A rule the person slipped on this week, with the history that lets the review say whether the slip coincided with a
/// different outcome. The days it slipped this week come from the rule's checks.
public struct WeeklySlip: Equatable, Sendable, Identifiable {
    public var id: String { rule.key.rawValue + "." + outcome.rawValue }
    public let rule: ProtocolRule
    public let outcome: NoteOutcomeKind
    public let unit: NoteUnit
    public let history: [WeeklySlipNight]
    /// The change the proposal names, such as "Kitchen closes at 18:30 on weekends too". Nil keeps the rule every day.
    public let changeTitle: String?
    public let design: WeeklyExperimentDesign

    public init(rule: ProtocolRule, outcome: NoteOutcomeKind, unit: NoteUnit? = nil, history: [WeeklySlipNight],
                changeTitle: String? = nil, design: WeeklyExperimentDesign = .beforeAndAfter) {
        self.rule = rule; self.outcome = outcome; self.unit = unit ?? outcome.defaultUnit; self.history = history
        self.changeTitle = changeTitle; self.design = design
    }
}

public struct WeeklyRunningExperiment: Equatable, Sendable {
    public let title: String
    public let outcome: NoteOutcomeKind
    /// Today's day number, starting at 1.
    public let dayNumber: Int
    public let totalDays: Int
    public init(title: String, outcome: NoteOutcomeKind, dayNumber: Int, totalDays: Int) {
        self.title = title; self.outcome = outcome; self.dayNumber = dayNumber; self.totalDays = totalDays
    }
}

/// What the person declined, kept so the same proposal does not return next week. It holds the evidence the proposal
/// stood on, so the review can tell when the evidence has changed.
public struct WeeklyProposalDecision: Codable, Equatable, Sendable {
    public let weekKey: String
    public let ruleKey: RuleKey
    public let outcome: NoteOutcomeKind
    /// Nights the rule was missed with an outcome, when it was declined.
    public let missedNights: Int
    /// The size of the gap in the outcome's unit, rounded, when it was declined.
    public let gap: Double

    public init(weekKey: String, ruleKey: RuleKey, outcome: NoteOutcomeKind, missedNights: Int, gap: Double) {
        self.weekKey = weekKey; self.ruleKey = ruleKey; self.outcome = outcome; self.missedNights = missedNights; self.gap = gap
    }
}

public struct WeeklyStoryInput: Equatable, Sendable {
    /// The days of the week. At most seven. Days outside this list are ignored.
    public let days: [DayIdentity]
    public let protocolName: String?
    /// The version the person follows. Nil when unknown, which leaves out the proposal.
    public let versionNumber: Int?
    public let rules: [WeeklyRuleWeek]
    public let outcomes: [WeeklyOutcomeWeek]
    public let slips: [WeeklySlip]
    public let runningExperiment: WeeklyRunningExperiment?
    public let declined: [WeeklyProposalDecision]
    /// The protocol's first day. Days of the week before it are not counted, so a protocol that started on Wednesday
    /// reads "5 days". Nil counts every day.
    public let startDay: DayIdentity?

    public init(days: [DayIdentity], protocolName: String? = nil, versionNumber: Int?, rules: [WeeklyRuleWeek],
                outcomes: [WeeklyOutcomeWeek] = [], slips: [WeeklySlip] = [],
                runningExperiment: WeeklyRunningExperiment? = nil, declined: [WeeklyProposalDecision] = [],
                startDay: DayIdentity? = nil) {
        self.days = days; self.protocolName = protocolName; self.versionNumber = versionNumber; self.rules = rules
        self.outcomes = outcomes; self.slips = slips; self.runningExperiment = runningExperiment; self.declined = declined
        self.startDay = startDay
    }
}

public struct WeeklyStoryThresholds: Equatable, Sendable {
    /// Fewer decided rule days than this and the review is absent.
    public let minimumDecidedRuleDays: Int
    /// A week outcome is stated from this many nights.
    public let minimumOutcomeNights: Int
    /// The review states at most this many outcomes.
    public let maximumMovedOutcomes: Int
    /// A proposal runs for this many days.
    public let experimentDays: Int
    /// A declined proposal comes back when the missed group has this many more nights.
    public let renewalNights: Int
    /// A declined proposal comes back when the gap has grown by this share of what it was.
    public let renewalGapGrowth: Double
    /// Nights in each group, and nights for the usual.
    public let notes: NoteThresholds

    public init(minimumDecidedRuleDays: Int = 7, minimumOutcomeNights: Int = 4, maximumMovedOutcomes: Int = 3,
                experimentDays: Int = 14, renewalNights: Int = 7, renewalGapGrowth: Double = 0.5,
                notes: NoteThresholds = .standard) {
        self.minimumDecidedRuleDays = minimumDecidedRuleDays; self.minimumOutcomeNights = minimumOutcomeNights
        self.maximumMovedOutcomes = maximumMovedOutcomes; self.experimentDays = experimentDays
        self.renewalNights = renewalNights; self.renewalGapGrowth = renewalGapGrowth; self.notes = notes
    }

    public static let standard = WeeklyStoryThresholds()
}
