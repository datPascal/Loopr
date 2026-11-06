import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// ICP round 1 (R1-NEW-05, R1-DES-06, R1-VET-01): the hero line, the percent from day 3, the counting rule and the rule
/// not kept on the most days.
final class ProtocolWeekSummaryTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    private let monday: [RuleKey: CheckState] = ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .kept,
        "zone2": .kept, "training": .kept, "magnesium": .kept, "screens": .kept, "bed": .missed, "stretch": .unknown]

    func testTheLineCountsKeptOverAnsweredThroughToday() {
        let summary = ProtocolWeekSummary.make(week: Fixture.week(monday: monday), calendar: Fixture.calendar, dayNumber: 21)
        // Monday 8 of 9 answered, Tuesday 5 of 5. Pending and unknown rules are not counted.
        XCTAssertEqual(summary.kept, 13)
        XCTAssertEqual(summary.decided, 14)
        XCTAssertEqual(summary.percent, 93)
        XCTAssertEqual(summary.line, "13 of 14 kept this week")
        XCTAssertEqual(summary.countingLine, "Counts checks with an answer. Skipped and not known are left out.")
    }

    func testThePercentWaitsForTheThirdDay() {
        let week = Fixture.week(monday: monday)
        XCTAssertNil(ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 1).percent)
        XCTAssertNil(ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 2).percent)
        XCTAssertEqual(ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 3).percent, 93)
        XCTAssertEqual(ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 1).line, "13 of 14 kept this week",
                       "Day 1 still says the count")
    }

    func testSkippedChecksAreNeitherKeptNorNotKept() {
        var sick = monday; sick["bed"] = .skipped; sick["screens"] = .skipped
        let summary = ProtocolWeekSummary.make(week: Fixture.week(monday: sick), calendar: Fixture.calendar, dayNumber: 21)
        // Monday 7 kept of 7 answered; the two skips leave the count, they do not lower the share.
        XCTAssertEqual(summary.decided, 12)
        XCTAssertEqual(summary.kept, 12)
        XCTAssertEqual(summary.percent, 100)
        XCTAssertNil(summary.slipLine)
    }

    func testTheSlipLineNamesTheDaysWithoutJudgingThem() {
        var kept = monday; kept["bed"] = .kept
        var slipped = monday; slipped["bed"] = .missed
        let week = (13...17).map { Fixture.input($0, .past, kept) }
            + [Fixture.input(18, .past, slipped), Fixture.input(19, .today, slipped)]
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar)
        XCTAssertEqual(summary.slippedRule, "bed")
        XCTAssertEqual(summary.slipLine, "Not kept on Saturday and Sunday: In bed by 22:30")
        XCTAssertEqual(summary.slippedDay, Fixture.day(19), "The line opens the last day it was not kept")
    }

    func testTheRuleNotKeptOnTheMostDaysIsTheOneNamed() {
        var once = monday; once["bed"] = .kept; once["screens"] = .missed
        var twice = monday; twice["bed"] = .missed
        let week = [Fixture.input(13, .past, once), Fixture.input(14, .past, twice), Fixture.input(15, .today, twice)]
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar)
        XCTAssertEqual(summary.slippedRule, "bed")
        XCTAssertEqual(summary.slipLine, "Not kept on Tuesday and Wednesday: In bed by 22:30")
    }

    func testNothingAnsweredHasNoShare() {
        let week = [Fixture.input(13, .past, [:]), Fixture.input(14, .today, [:])] + (15...19).map { Fixture.input($0, .future, [:]) }
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar)
        XCTAssertNil(summary.percent, "Nothing answered is never 0 percent")
        XCTAssertNil(summary.share)
        XCTAssertEqual(summary.line, "Nothing answered yet this week")
    }

    func testAProtocolThatStartedThisWeekSaysWhichDay() {
        let week = [Fixture.input(13, .beforeProtocol, [:]), Fixture.input(14, .today, ["light": .kept])]
            + (15...19).map { Fixture.input($0, .future, [:]) }
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, startedOn: Fixture.day(14))
        XCTAssertTrue(summary.countingLine.hasSuffix("Your protocol started on Tuesday, so the week counts from there."),
                      summary.countingLine)
        let mondayStart = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, startedOn: Fixture.day(13))
        XCTAssertFalse(mondayStart.countingLine.contains("started on"), "A Monday start is a whole week")
    }

    func testNoLineClaimsACause() {
        let cases: [[ProtocolDayInput]] = [
            Fixture.week(monday: monday), Fixture.week(monday: [:]),
            [Fixture.input(13, .past, ["bed": .missed, "screens": .missed]), Fixture.input(14, .today, ["bed": .missed])]
        ]
        for week in cases {
            let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar)
            let text = [summary.line, summary.hero, summary.countingLine, summary.slipLine ?? ""].joined(separator: " ").lowercased()
            for banned in ["cause", "because", "due to", "!", "\u{2014}", "missed", "slipped", "last week"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(text)")
            }
        }
    }

    /// R1-VET-01, R1-SEN-16: the review is last week's and says so with its dates. It leads only on Sunday evening and
    /// Monday.
    func testTheWeeklyReviewRowNamesLastWeekAndLeadsOnlyWhenTheWeekHasEnded() {
        let lastMonday = Fixture.day(6)
        let tuesday = ProtocolWeeklyReviewPlacement.make(monday: lastMonday, today: Fixture.day(14), nowMinute: 20 * 60,
                                                         calendar: Fixture.calendar)
        XCTAssertEqual(tuesday.title, "Last week, 6 to 12 Nov")
        XCTAssertFalse(tuesday.isProminent)
        let monday = ProtocolWeeklyReviewPlacement.make(monday: lastMonday, today: Fixture.day(13), nowMinute: 9 * 60,
                                                        calendar: Fixture.calendar)
        XCTAssertTrue(monday.isProminent)
        let sundayEvening = ProtocolWeeklyReviewPlacement.make(monday: Fixture.day(13), today: Fixture.day(19), nowMinute: 18 * 60,
                                                               calendar: Fixture.calendar)
        XCTAssertEqual(sundayEvening.title, "This week, 13 to 19 Nov")
        XCTAssertTrue(sundayEvening.isProminent)
        let sundayNoon = ProtocolWeeklyReviewPlacement.make(monday: lastMonday, today: Fixture.day(19), nowMinute: 12 * 60,
                                                            calendar: Fixture.calendar)
        XCTAssertFalse(sundayNoon.isProminent)
        let acrossMonths = ProtocolWeeklyReviewPlacement.make(monday: DayIdentity(year: 2023, month: 10, day: 30),
                                                              today: Fixture.day(7), nowMinute: 600, calendar: Fixture.calendar)
        XCTAssertEqual(acrossMonths.title, "Last week, 30 Oct to 5 Nov")
    }
}
