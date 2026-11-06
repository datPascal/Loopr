import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

/// A week from Monday 19 October 2026 to Sunday 25 October 2026, and the checks the review reads.
enum WeeklyFixtures {
    static let enGB = NoteFixtures.enGB
    static let enUS = NoteFixtures.enUS
    static let deDE = NoteFixtures.deDE

    static let weekKey = "2026-10-19"

    static func day(_ offset: Int) -> DayIdentity { DayIdentity(year: 2026, month: 10, day: 19 + offset) }
    static let days: [DayIdentity] = (0..<7).map(day)

    static func writer(_ locale: Locale = enGB, thresholds: WeeklyStoryThresholds = .standard) -> WeeklyStoryWriter {
        WeeklyStoryWriter(context: NoteContext(locale: locale, calendar: NoteFixtures.calendar), thresholds: thresholds)
    }

    /// One state for each day of the week, Monday first.
    static func week(_ states: [CheckState]) -> [WeeklyRuleDay] {
        states.enumerated().map { WeeklyRuleDay(day: day($0.offset), state: $0.element) }
    }

    static let kept = CheckState.kept, missed = CheckState.missed, pending = CheckState.pending, unknown = CheckState.unknown

    static func rule(_ key: String, _ title: String, at minute: Int?) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, timeOfDayMinutes: minute)
    }

    static let kitchenRule = rule("kitchen", "Kitchen closes", at: 18 * 60 + 30)
    static let screensRule = rule("screens", "Screens off", at: 21 * 60 + 45)
    static let lightRule = rule("light", "Morning light", at: 7 * 60)

    /// Kitchen: 5 of 7, missed on Saturday and Sunday. Screens: 7 of 7. Light: 6 of 7, kept on the last two days.
    static var rules: [WeeklyRuleWeek] {
        [
            WeeklyRuleWeek(rule: kitchenRule, days: week([kept, kept, kept, kept, kept, missed, missed])),
            WeeklyRuleWeek(rule: screensRule, days: week([kept, kept, kept, kept, kept, kept, kept])),
            WeeklyRuleWeek(rule: lightRule, days: week([kept, kept, kept, kept, missed, kept, kept])),
        ]
    }

    static var outcomes: [WeeklyOutcomeWeek] {
        [
            WeeklyOutcomeWeek(kind: .sleepHeartRate, weekMean: 51.4, nights: 6, usual: NoteUsual(median: 49, nights: 28, windowDays: 30)),
            WeeklyOutcomeWeek(kind: .hrv, weekMean: 60, nights: 6, usual: NoteUsual(median: 60.2, nights: 28, windowDays: 30)),
            // Too few nights this week, and no usual to compare with.
            WeeklyOutcomeWeek(kind: .deepSleep, weekMean: 70, nights: 3, usual: NoteUsual(median: 60, nights: 28, windowDays: 30)),
            WeeklyOutcomeWeek(kind: .restingHeartRate, weekMean: 52, nights: 6, usual: nil),
        ]
    }

    /// 9 nights missed at 55 and 28 nights kept at 50, so the gap is exactly 5 higher.
    static func slipHistory(missed: Int = 9, kept: Int = 28, missedMean: Double = 55, keptMean: Double = 50) -> [WeeklySlipNight] {
        (0..<missed).map { WeeklySlipNight(day: NoteFixtures.day($0), missed: true, outcome: missedMean) }
            + (0..<kept).map { WeeklySlipNight(day: NoteFixtures.day($0 + 9), missed: false, outcome: keptMean) }
    }

    static func slip(rule: ProtocolRule = kitchenRule, outcome: NoteOutcomeKind = .sleepHeartRate, history: [WeeklySlipNight]? = nil,
                     changeTitle: String? = "Kitchen closes at 18:30 on weekends too") -> WeeklySlip {
        WeeklySlip(rule: rule, outcome: outcome, history: history ?? slipHistory(), changeTitle: changeTitle)
    }

    static func input(rules: [WeeklyRuleWeek]? = nil, outcomes: [WeeklyOutcomeWeek]? = nil, slips: [WeeklySlip]? = nil,
                      version: Int? = 7, experiment: WeeklyRunningExperiment? = nil,
                      declined: [WeeklyProposalDecision] = [], days: [DayIdentity]? = nil) -> WeeklyStoryInput {
        WeeklyStoryInput(days: days ?? self.days, protocolName: "Sleep first", versionNumber: version,
                         rules: rules ?? self.rules, outcomes: outcomes ?? self.outcomes, slips: slips ?? [slip()],
                         runningExperiment: experiment, declined: declined)
    }

    static func story(_ input: WeeklyStoryInput? = nil, _ writer: WeeklyStoryWriter? = nil) -> WeeklyStory? {
        (writer ?? self.writer()).write(input ?? self.input()).story
    }

    // MARK: Checks

    /// The page states only numbers it carries, and every digit on the page is one of them.
    static func expectPageNumbers(_ page: WeeklyStoryPage, sourceLocation: SourceLocation = #_sourceLocation) {
        NoteFixtures.expectNumbersExact(page.note, sourceLocation: sourceLocation)
        for text in page.visibleStrings {
            for token in NoteDigits.tokens(in: text) {
                #expect(page.note.allNumerals.contains(token), "\"\(text)\" shows \(token), which the page does not carry",
                        sourceLocation: sourceLocation)
            }
        }
    }

    static func expectWording(_ page: WeeklyStoryPage, sourceLocation: SourceLocation = #_sourceLocation) {
        for text in page.visibleStrings + [page.kicker] {
            let lowered = text.lowercased()
            for word in NoteFixtures.bannedWords {
                #expect(!lowered.contains(word), "\"\(text)\" says \"\(word)\"", sourceLocation: sourceLocation)
            }
        }
        // Sentence case: a title or paragraph starts with a capital and its other words do not.
        for text in [page.title, page.note.text] {
            #expect(text.first?.isUppercase == true || text.first?.isNumber == true, "\"\(text)\"", sourceLocation: sourceLocation)
        }
        let titleWords = page.title.split(separator: " ").dropFirst()
        #expect(titleWords.allSatisfy { $0.first?.isUppercase != true }, "Title case: \(page.title)", sourceLocation: sourceLocation)
    }
}
