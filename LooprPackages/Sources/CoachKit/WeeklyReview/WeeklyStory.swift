import DomainKit
import Foundation
import RoutineKit

// The weekly review as five pages. Each page is a coach note with its own number set, plus the detail a screen draws
// under the text. Pages without data are left out, so a story has between one and five pages.

public enum WeeklyStoryPageKind: String, Codable, CaseIterable, Sendable {
    case kept, moved, change, proposal, nextWeek
}

public struct WeeklyDayCell: Equatable, Sendable {
    public let day: DayIdentity
    /// The weekday name in the context's locale. Nil when the calendar cannot place the day.
    public let weekday: String?
    public let kept: Int
    public let decided: Int
    /// False for a day before the protocol started. It has no dot and is not in the day count.
    public var counted: Bool = true

    /// Checks the person skipped that day, or a running test kept off.
    public var skipped: Int = 0
    /// "Fri", for the key under the dots. Nil when the calendar cannot place the day.
    public var shortWeekday: String?

    public var missed: Int { decided - kept }
    /// The day has at least one check with an answer, so its dot is filled (ICP R2-VET-02, R2-HAB-10).
    public var isAnswered: Bool { decided > 0 }

    /// The day's mark, drawn as the check-in's rosette draws its dots (ICP R3-DES-05, R3-SEN-07, R3-HAB-07).
    public var mark: WeeklyDayMark {
        guard counted else { return .none }
        if missed > 0 { return .notKept }
        if decided > 0 { return .kept }
        return skipped > 0 ? .skipped : .open
    }
}

/// How one day of the review is drawn: Kept a filled dot, Not kept a filled dot with a small cross cut out, Skipped a
/// slashed ring, Open a hairline ring, the rosette's marks (ICP R3-DES-02, R3-DES-05).
public enum WeeklyDayMark: String, Equatable, Sendable, CaseIterable {
    /// Every check with an answer was kept.
    case kept
    /// A rule was not kept.
    case notKept
    /// Nothing had an answer and something was skipped.
    case skipped
    /// Nothing to answer, or nothing answered.
    case open
    /// Before the protocol started: no mark.
    case none
}

/// One entry of the key under the dots: a mark and what it means this week, "Fri and Sat: a rule not kept".
public struct WeeklyDayKeyEntry: Equatable, Sendable, Identifiable {
    public var id: WeeklyDayMark { mark }
    public let mark: WeeklyDayMark
    public let text: String
}

public struct WeeklyRuleRow: Equatable, Sendable, Identifiable {
    public var id: RuleKey { key }
    public let key: RuleKey
    public let title: String
    public let keptDays: Int
    public let decidedDays: Int
    /// Days kept in a row, counted back from the last decided day of the week.
    public let streak: Int
    public let missedDays: Int
    /// Days the rule was asked and had no answer, for a rule asked every day it is due (ICP R3-VET-02).
    public var notKnownDays: Int = 0
    /// True for a rule with a longer period, such as each week or every 3 months, which is not asked every day.
    public var isLongerPeriod: Bool = false

    /// "6 of 6", "5 of 6 · 1 not known", or for a rule with a longer period "Done this week".
    public var countText: String {
        if isLongerPeriod {
            if keptDays > 0 { return "Done this week" }
            return decidedDays > 0 ? "Not done this week" : "No answer this week"
        }
        let count = decidedDays > 0 ? "\(keptDays) of \(decidedDays)" : "No answer"
        return notKnownDays > 0 ? "\(count) \u{00B7} \(notKnownDays) not known" : count
    }
}

public struct WeeklyKeptDetail: Equatable, Sendable {
    /// The kept share as the hero number, such as "86%".
    public let share: NoteNumber
    public let keptRuleDays: Int
    public let decidedRuleDays: Int
    public let days: [WeeklyDayCell]
    public let rules: [WeeklyRuleRow]
    /// Checks the person skipped, left out of the share.
    public var skippedRuleDays: Int = 0
    /// The week's days from the protocol's start, 7 for a full week.
    public var dayCount: Int = 7
    /// What the dots mean this week, one entry per mark shown: "All kept", "Fri and Sat: a rule not kept".
    public var key: [WeeklyDayKeyEntry] = []
    /// "7 days", over the dots.
    public var dayCountText: String { dayCount == 1 ? "1 day" : "\(dayCount) days" }
}

public enum WeeklyMoveDirection: String, Equatable, Sendable { case above, below, inLine }

public struct WeeklyMovedRow: Equatable, Sendable, Identifiable {
    public var id: NoteOutcomeKind { kind }
    public let kind: NoteOutcomeKind
    public let title: String
    public let weekValue: NoteNumber
    public let nights: NoteNumber
    public let direction: WeeklyMoveDirection
    /// "2 bpm above your usual", or "in line with your usual".
    public let comparison: String
}

public struct WeeklyChangeDetail: Equatable, Sendable {
    public let ruleKey: RuleKey
    public let ruleTitle: String
    /// The weekday names of the days it slipped, when there are three or fewer and the calendar knows them.
    public let missedWeekdays: [String]
    public let missedDays: Int
    /// The nights the rule was missed against the nights it was kept, with every night's outcome.
    public let receipt: NoteReceiptChart
}

public struct WeeklyNextRule: Equatable, Sendable, Identifiable {
    public var id: RuleKey { key }
    public let key: RuleKey
    public let title: String
    /// The rule's time in the locale clock. Nil for a rule with no time.
    public let time: String?
}

public struct WeeklyNextWeekDetail: Equatable, Sendable {
    public let versionNumber: Int?
    public let rules: [WeeklyNextRule]
    public let experiment: WeeklyRunningExperiment?
}

public enum WeeklyStoryDetail: Equatable, Sendable {
    case kept(WeeklyKeptDetail)
    case moved([WeeklyMovedRow])
    case change(WeeklyChangeDetail)
    case proposal(WeeklyReviewProposal)
    case nextWeek(WeeklyNextWeekDetail)
}

/// What the person is asked to start. It names the rule, the outcome and the design, and nothing runs until the person
/// taps Start the experiment. The app starts the experiment from this value.
public struct WeeklyReviewProposal: Equatable, Sendable, Identifiable {
    public var id: String { "\(weekKey)/\(ruleKey.rawValue)/\(outcome.rawValue)" }
    /// The first day of the review week, `YYYY-MM-DD`.
    public let weekKey: String
    public let ruleKey: RuleKey
    public let ruleTitle: String
    /// "Kitchen closes at 18:30 on weekends too", with any time in the locale clock.
    public let changeTitle: String
    public let outcome: NoteOutcomeKind
    public let design: WeeklyExperimentDesign
    public let experimentDays: Int
    /// The version the person follows now. It stays until they decide.
    public let fromVersion: Int
    public let toVersion: Int
    /// "Proposed for version 8".
    public let label: String
    /// Nights the rule was missed, and nights it was kept, that the proposal stands on.
    public let missedNights: Int
    public let keptNights: Int
    /// The size of the gap in the outcome's unit, rounded.
    public let gap: Double

    /// The value Not now hands back: the evidence this proposal stood on.
    public var declineDecision: WeeklyProposalDecision {
        WeeklyProposalDecision(weekKey: weekKey, ruleKey: ruleKey, outcome: outcome, missedNights: missedNights, gap: gap)
    }
}

public struct WeeklyStoryPage: Equatable, Sendable, Identifiable {
    public var id: Int { position }
    public let kind: WeeklyStoryPageKind
    /// One-based place in the story, after pages without data were left out.
    public let position: Int
    public let total: Int
    /// "Your week · 3 of 5".
    public let kicker: String
    /// "One change worth trying."
    public let title: String
    /// The paragraph, its number runs, its number set and its receipt.
    public let note: CoachNote
    public let detail: WeeklyStoryDetail

    /// The identifier a screen gives the page.
    public var identifier: String { "weekly-review-page-\(position)" }

    /// Every string a screen draws on the page, for checks and for VoiceOver.
    public var visibleStrings: [String] {
        var strings = [kicker, title, note.text, note.daysCovered]
        if let comparison = note.comparisonGroup { strings.append(comparison) }
        switch detail {
        case .kept(let kept):
            strings.append(kept.share.displayed)
            strings.append(kept.dayCountText)
            strings.append(contentsOf: kept.days.compactMap(\.weekday))
            strings.append(contentsOf: kept.rules.map(\.title))
            strings.append(contentsOf: kept.key.map(\.text))
        case .moved(let rows):
            for row in rows { strings += [row.title, row.weekValue.displayed, row.nights.displayed, row.comparison] }
        case .change(let change):
            strings.append(change.ruleTitle)
            strings.append(contentsOf: change.missedWeekdays)
            strings.append(contentsOf: change.receipt.groups.map(\.label))
        case .proposal(let proposal):
            strings += [proposal.label, proposal.changeTitle]
        case .nextWeek(let next):
            for rule in next.rules { strings += [rule.title, rule.time ?? ""] }
            if let experiment = next.experiment { strings.append(experiment.title) }
        }
        return strings.filter { !$0.isEmpty }
    }
}

/// Why there is no review this week.
public enum WeeklyStoryAbsence: Equatable, Sendable {
    case noRules
    case tooFewDecidedRuleDays(have: Int, need: Int)

    public var reason: String {
        switch self {
        case .noRules:
            "There are no rules in your protocol yet, so there is nothing to review."
        case .tooFewDecidedRuleDays(let have, let need):
            "A review needs \(need) rule checks with an answer, and this week has \(have)."
        }
    }
}

public struct WeeklyStory: Equatable, Sendable {
    public static let footer = "Written by rules on this iPhone. Nothing was sent."

    /// The first day of the review week, `YYYY-MM-DD`.
    public let weekKey: String
    public let pages: [WeeklyStoryPage]
    /// Set when the story carries a proposal page. Building the story starts nothing.
    public let proposal: WeeklyReviewProposal?
    public var footer: String { Self.footer }
}

public enum WeeklyStoryResult: Equatable, Sendable {
    case story(WeeklyStory)
    case absent(WeeklyStoryAbsence)

    public var story: WeeklyStory? {
        if case .story(let story) = self { return story }
        return nil
    }
}
