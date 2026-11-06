import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

/// ICP R2-DES-04, R2-VET-02, R2-HAB-10, R2-SEN-09: the review names its week by its dates, says how many days it
/// covers, fills a dot for every day with an answer and counts with the hero's function.
@Suite("Weekly review: the week it covers")
struct WeeklyStoryWeekTests {
    private func keptPage(_ input: WeeklyStoryInput, locale: Locale = WeeklyFixtures.enGB) throws -> (WeeklyStoryPage, WeeklyKeptDetail) {
        let story = try #require(WeeklyFixtures.writer(locale).write(input).story)
        let page = try #require(story.pages.first { $0.kind == .kept })
        guard case .kept(let detail) = page.detail else { throw KeptPageMissing() }
        return (page, detail)
    }

    private struct KeptPageMissing: Error {}

    @Test("A full week is titled by its dates, says 7 days and fills seven dots, a day with a miss included")
    func fullWeek() throws {
        let (page, detail) = try keptPage(WeeklyFixtures.input())
        #expect(page.kicker == "Week of 19 to 25 Oct \u{00B7} 1 of 5")
        #expect(detail.dayCount == 7)
        #expect(detail.dayCountText == "7 days")
        #expect(detail.days.allSatisfy { $0.isAnswered })
        #expect(detail.days.filter { $0.missed > 0 }.count == 3, "Friday, Saturday and Sunday had a rule not kept")
        #expect(page.note.daysCovered == "19 to 25 Oct, 7 days.")
        #expect(page.visibleStrings.contains("7 days"))
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("Across a month and in a month-first locale the dates stay whole")
    func ranges() throws {
        let days = (0..<7).compactMap { DayIdentity(year: 2023, month: 10, day: 30).adding(days: $0) }
        let rules = WeeklyFixtures.rules.map { week in
            WeeklyRuleWeek(rule: week.rule, days: zip(days, week.days).map { WeeklyRuleDay(day: $0, state: $1.state) })
        }
        let input = WeeklyFixtures.input(rules: rules, slips: [], days: days)
        #expect(try keptPage(input).0.kicker.hasPrefix("Week of 30 Oct to 5 Nov"))
        #expect(try keptPage(input, locale: WeeklyFixtures.enUS).0.kicker.hasPrefix("Week of Oct 30 to Nov 5"))
    }

    @Test("A protocol that started on Wednesday covers 5 days and has no dots before it")
    func partialWeek() throws {
        let rules = WeeklyFixtures.rules.map { week in
            WeeklyRuleWeek(rule: week.rule, days: Array(week.days.dropFirst(2)))
        }
        var input = WeeklyFixtures.input(rules: rules, slips: [])
        input = WeeklyStoryInput(days: input.days, protocolName: input.protocolName, versionNumber: input.versionNumber,
                                 rules: input.rules, outcomes: input.outcomes, startDay: WeeklyFixtures.day(2))
        let (page, detail) = try keptPage(input)
        #expect(detail.dayCount == 5)
        #expect(detail.days.map(\.counted) == [false, false, true, true, true, true, true])
        #expect(page.note.daysCovered == "19 to 25 Oct, 5 days.")
    }

    @Test("Skipped checks are left out and said once; the share is RoutineWeekCount's")
    func skippedAndShared() throws {
        let skipped = WeeklyRuleWeek(rule: WeeklyFixtures.rule("magnesium", "Magnesium", at: 21 * 60 + 30),
                                     days: WeeklyFixtures.week([.kept, .skipped, .kept, .skipped, .kept, .kept, .kept]))
        let rules = WeeklyFixtures.rules + [skipped]
        let (page, detail) = try keptPage(WeeklyFixtures.input(rules: rules))
        let count = RoutineWeekCount(states: rules.flatMap { $0.days.map { Optional($0.state) } })
        #expect(detail.keptRuleDays == count.kept && detail.decidedRuleDays == count.decided)
        #expect(detail.share.value == Double(count.percent ?? -1))
        #expect(detail.skippedRuleDays == 2)
        #expect(page.note.text.hasPrefix("You kept 23 of the 26 rule checks that had an answer. 2 skipped checks are left out too."))
        WeeklyFixtures.expectPageNumbers(page)
        WeeklyFixtures.expectWording(page)
    }

    @Test("The dots use the rosette's marks and a key names the days that were not all kept")
    func marksAndKey() throws {
        let (page, detail) = try keptPage(WeeklyFixtures.input())
        #expect(detail.days.map(\.mark) == [.kept, .kept, .kept, .kept, .notKept, .notKept, .notKept])
        #expect(detail.key.map(\.mark) == [.kept, .notKept])
        #expect(detail.key.map(\.text) == ["All kept", "Fri, Sat and Sun: a rule not kept"])
        #expect(page.visibleStrings.contains("Fri, Sat and Sun: a rule not kept"))
        WeeklyFixtures.expectPageNumbers(page)
        WeeklyFixtures.expectWording(page)
    }

    @Test("A day with nothing to answer, a skipped day and a day before the start each have their own mark")
    func emptyAndSkippedDays() throws {
        let light = WeeklyRuleWeek(rule: WeeklyFixtures.lightRule, days: WeeklyFixtures.week([.kept, .kept, .kept, .kept, .kept])
            + [WeeklyRuleDay(day: WeeklyFixtures.day(5), state: .skipped)])
        let screens = WeeklyRuleWeek(rule: WeeklyFixtures.screensRule, days: WeeklyFixtures.week([.kept, .kept, .kept, .kept, .kept]))
        let input = WeeklyStoryInput(days: WeeklyFixtures.days, versionNumber: 7, rules: [light, screens], startDay: WeeklyFixtures.day(1))
        let (_, detail) = try keptPage(input)
        #expect(detail.days.map(\.mark) == [.none, .kept, .kept, .kept, .kept, .skipped, .open])
        #expect(detail.key.map(\.text) == ["All kept", "Sat: skipped", "Sun: nothing to answer"])
        let every = WeeklyStoryInput(days: WeeklyFixtures.days, versionNumber: 7,
                                     rules: [WeeklyRuleWeek(rule: WeeklyFixtures.screensRule, days: WeeklyFixtures.week(Array(repeating: .kept, count: 7)))])
        #expect(try keptPage(every).1.key.map(\.text) == ["Every day: all kept"])
    }

    @Test("A day a rule was due with no answer is \"1 not known\", and weekly and quarterly rules are listed")
    func notKnownAndLongerRules() throws {
        // Morning light has no check on Sunday and is not known on Wednesday; magnesium starts on Thursday.
        let light = WeeklyRuleWeek(rule: WeeklyFixtures.lightRule, days: WeeklyFixtures.week([.kept, .kept, .unknown, .kept, .kept, .kept]))
        let magnesium = WeeklyRuleWeek(rule: WeeklyFixtures.rule("magnesium", "Magnesium", at: 21 * 60 + 30),
                                       days: [3, 4, 5, 6].map { WeeklyRuleDay(day: WeeklyFixtures.day($0), state: .kept) })
        let panel = WeeklyRuleWeek(rule: ProtocolRule(key: "panel", title: "Blood panel", cadence: RuleCadence(unit: .month, every: 3)),
                                   days: [])
        let weekly = WeeklyRuleWeek(rule: ProtocolRule(key: "walk", title: "Long walk", cadence: RuleCadence(unit: .week)),
                                    days: [WeeklyRuleDay(day: WeeklyFixtures.day(2), state: .unknown),
                                           WeeklyRuleDay(day: WeeklyFixtures.day(5), state: .kept)])
        let input = WeeklyStoryInput(days: WeeklyFixtures.days, versionNumber: 7, rules: [light, magnesium, panel, weekly])
        let (_, detail) = try keptPage(input)
        func row(_ key: RuleKey) throws -> WeeklyRuleRow { try #require(detail.rules.first { $0.key == key }) }
        #expect(try row("light").notKnownDays == 2)
        #expect(try row("light").countText == "5 of 5 \u{00B7} 2 not known")
        #expect(try row("magnesium").countText == "4 of 4", "Days before its first check are not missing")
        #expect(try row("panel").countText == "No answer this week")
        #expect(try row("walk").countText == "Done this week")
        #expect(try row("walk").notKnownDays == 0)
    }
}
