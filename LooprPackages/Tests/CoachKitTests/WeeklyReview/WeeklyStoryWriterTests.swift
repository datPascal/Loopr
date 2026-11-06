import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

@Suite("LV-09.2 weekly story pages")
struct WeeklyStoryWriterTests {
    private func makeStory(_ input: WeeklyStoryInput? = nil, _ writer: WeeklyStoryWriter? = nil) throws -> WeeklyStory {
        try #require(WeeklyFixtures.story(input, writer))
    }

    private func pageOf(_ kind: WeeklyStoryPageKind, in story: WeeklyStory) throws -> WeeklyStoryPage {
        try #require(story.pages.first { $0.kind == kind })
    }

    @Test("A full week gives five pages in order, each with its own place and identifier")
    func fivePages() throws {
        let story = try makeStory()
        #expect(story.pages.map(\.kind) == [.kept, .moved, .change, .proposal, .nextWeek])
        #expect(story.pages.map(\.position) == [1, 2, 3, 4, 5])
        #expect(story.pages.map(\.total) == [5, 5, 5, 5, 5])
        #expect(story.pages.map(\.kicker) == (1...5).map { "Week of 19 to 25 Oct \u{00B7} \($0) of 5" })
        #expect(story.pages.map(\.identifier) == (1...5).map { "weekly-review-page-\($0)" })
        #expect(story.pages.map(\.title) == ["What you kept.", "What moved.", "One change worth trying.", "One proposal.", "Next week."])
        #expect(story.footer == "Written by rules on this iPhone. Nothing was sent.")
        #expect(story.weekKey == WeeklyFixtures.weekKey)
        #expect(story.pages.allSatisfy { $0.note.kind == .weeklyPage })
    }

    @Test("Page 1 states the kept share, the longest run and the rule not kept most, without judging it")
    func keptPage() throws {
        let page = try pageOf(.kept, in: try makeStory())
        #expect(page.note.text == "You kept 18 of the 21 rule checks that had an answer. "
            + "Screens off was kept 7 days in a row, the longest run this week. Kitchen closes was not kept on 2 days, more than any other rule.")
        guard case .kept(let detail) = page.detail else { Issue.record("Expected kept detail"); return }
        #expect(detail.share.displayed == "86%")
        #expect(detail.share.value == 86)
        #expect(detail.keptRuleDays == 18 && detail.decidedRuleDays == 21)
        #expect(detail.rules.map(\.title) == ["Morning light", "Kitchen closes", "Screens off"])
        #expect(detail.rules.map(\.keptDays) == [6, 5, 7])
        #expect(detail.rules.map(\.decidedDays) == [7, 7, 7])
        #expect(detail.rules.map(\.streak) == [2, 0, 7])
        #expect(detail.rules.map(\.missedDays) == [1, 2, 0])
        #expect(detail.days.map(\.weekday) == ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"])
        #expect(detail.days.map(\.kept) == [3, 3, 3, 3, 2, 2, 2])
        #expect(detail.days.map(\.decided) == [3, 3, 3, 3, 3, 3, 3])
        #expect(page.note.runs.filter(\.isHighlighted).map(\.text) == ["18"])
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("Checks without an answer are left out and counted")
    func keptPageUnknowns() throws {
        let plunge = WeeklyRuleWeek(rule: WeeklyFixtures.rule("plunge", "Cold plunge", at: nil),
                                    days: WeeklyFixtures.week([.unknown, .unknown, .pending, .unknown, .kept, .unknown, .unknown]))
        let rules = WeeklyFixtures.rules + [plunge]
        let page = try pageOf(.kept, in: try makeStory(WeeklyFixtures.input(rules: rules)))
        #expect(page.note.text.hasPrefix("You kept 19 of the 22 rule checks that had an answer. 5 checks had no answer and are left out."))
        let one = WeeklyRuleWeek(rule: WeeklyFixtures.rule("plunge", "Cold plunge", at: nil),
                                 days: WeeklyFixtures.week([.unknown, .kept]))
        let single = try self.pageOf(.kept, in: try makeStory(WeeklyFixtures.input(rules: WeeklyFixtures.rules + [one])))
        #expect(single.note.text.contains("1 check had no answer and is left out."))
        WeeklyFixtures.expectPageNumbers(page)
    }

    /// ICP R4 Q3: the review counts what Today and the check-in count. A day a rule was not due on adds nothing unless
    /// it has an answer that day.
    @Test("A not known check on a day the rule was not due is left out")
    func notDueDaysAreLeftOut() throws {
        // A weekly walk the band checks: not known on Monday, kept on Tuesday, then done for the week.
        let walk = WeeklyRuleWeek(rule: ProtocolRule(key: "walk", title: "Long walk", cadence: RuleCadence(unit: .week)),
                                  days: WeeklyFixtures.week([.unknown, .kept, .unknown, .unknown, .unknown, .unknown, .unknown]))
        // A blood panel done on 1 Oct is not due until January, though its source left a not known check every day.
        let panel = WeeklyRuleWeek(rule: ProtocolRule(key: "panel", title: "Blood panel", cadence: RuleCadence(unit: .month, every: 3)),
                                   days: WeeklyFixtures.week(Array(repeating: .unknown, count: 7)),
                                   lastDone: DayIdentity(year: 2026, month: 10, day: 1))
        let page = try pageOf(.kept, in: try makeStory(WeeklyFixtures.input(rules: WeeklyFixtures.rules + [walk, panel])))
        #expect(page.note.text.hasPrefix("You kept 19 of the 22 rule checks that had an answer. 1 check had no answer and is left out."),
                "\(page.note.text)")
        // Without the last done day the panel reads as never done, so every day was due.
        let never = WeeklyRuleWeek(rule: panel.rule, days: panel.days)
        let unread = try pageOf(.kept, in: try makeStory(WeeklyFixtures.input(rules: WeeklyFixtures.rules + [never])))
        #expect(unread.note.text.contains("7 checks had no answer and are left out."))
    }

    @Test("A streak ends at the last decided day, a pending day at the end does not break it, an unknown day does")
    func streaks() throws {
        let states: [(String, [CheckState])] = [
            ("trailingPending", [.kept, .kept, .kept, .kept, .kept, .kept, .pending]),
            ("unknownBreaks", [.kept, .kept, .kept, .kept, .kept, .unknown, .kept]),
            ("missedBreaks", [.kept, .kept, .kept, .missed, .kept, .kept, .kept]),
        ]
        let rules = states.map { WeeklyRuleWeek(rule: WeeklyFixtures.rule($0.0, $0.0, at: nil), days: WeeklyFixtures.week($0.1)) }
        let page = try pageOf(.kept, in: try makeStory(WeeklyFixtures.input(rules: rules, slips: [])))
        guard case .kept(let detail) = page.detail else { Issue.record("Expected kept detail"); return }
        let streaks = Dictionary(uniqueKeysWithValues: detail.rules.map { ($0.title, $0.streak) })
        #expect(streaks["trailingPending"] == 6)
        #expect(streaks["unknownBreaks"] == 1)
        #expect(streaks["missedBreaks"] == 3)
    }

    @Test("Page 2 compares the week's outcomes with the usual and counts the nights")
    func movedPage() throws {
        let page = try pageOf(.moved, in: try makeStory())
        #expect(page.note.text == "Sleep heart rate averaged 51 bpm over 6 nights, 2 bpm above your usual over 28 nights. "
            + "HRV averaged 60 ms over 6 nights, in line with your usual over 28 nights.")
        guard case .moved(let rows) = page.detail else { Issue.record("Expected moved detail"); return }
        #expect(rows.map(\.kind) == [.sleepHeartRate, .hrv])
        #expect(rows.map(\.direction) == [.above, .inLine])
        #expect(rows.map(\.comparison) == ["2 bpm above your usual", "in line with your usual"])
        #expect(page.note.numbers.contains { $0.displayed == "28 nights" && $0.value == 28 })
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("An outcome with too few nights or no usual is never stated, and the page goes when none is left")
    func movedPageGates() throws {
        let minimum = WeeklyStoryThresholds.standard.minimumOutcomeNights
        let usual = NoteUsual(median: 49, nights: 28, windowDays: 30)
        let edge = [
            WeeklyOutcomeWeek(kind: .sleepHeartRate, weekMean: 51, nights: minimum - 1, usual: usual),
            WeeklyOutcomeWeek(kind: .hrv, weekMean: 60, nights: minimum, usual: NoteUsual(median: 60, nights: 6, windowDays: 30)),
            WeeklyOutcomeWeek(kind: .deepSleep, weekMean: nil, nights: 6, usual: usual),
            WeeklyOutcomeWeek(kind: .sleepDuration, weekMean: .nan, nights: 6, usual: usual),
        ]
        let none = try makeStory(WeeklyFixtures.input(outcomes: edge))
        #expect(!none.pages.contains { $0.kind == .moved })
        #expect(none.pages.map(\.position) == [1, 2, 3, 4])

        let atMinimum = [WeeklyOutcomeWeek(kind: .sleepHeartRate, weekMean: 51, nights: minimum, usual: usual)]
        #expect(try makeStory(WeeklyFixtures.input(outcomes: atMinimum)).pages.contains { $0.kind == .moved })
    }

    @Test("Page 2 names at most three outcomes, the biggest moves first")
    func movedPageLimit() throws {
        let usual = NoteUsual(median: 100, nights: 20, windowDays: 30)
        let outcomes = [
            WeeklyOutcomeWeek(kind: .hrv, weekMean: 102, nights: 5, usual: usual),
            WeeklyOutcomeWeek(kind: .deepSleep, weekMean: 130, nights: 5, usual: usual),
            WeeklyOutcomeWeek(kind: .sleepHeartRate, weekMean: 90, nights: 5, usual: usual),
            WeeklyOutcomeWeek(kind: .restingHeartRate, weekMean: 105, nights: 5, usual: usual),
        ]
        let page = try pageOf(.moved, in: try makeStory(WeeklyFixtures.input(outcomes: outcomes)))
        guard case .moved(let rows) = page.detail else { Issue.record("Expected moved detail"); return }
        #expect(rows.map(\.kind) == [.deepSleep, .sleepHeartRate, .restingHeartRate])
        #expect(!page.note.text.contains("HRV"))
    }

    @Test("Page 3 names the slip, how the outcome differed, and draws the nights as a receipt")
    func changePage() throws {
        let page = try pageOf(.change, in: try makeStory())
        #expect(page.note.text == "Kitchen closes was not kept on Saturday and Sunday. "
            + "On the 9 nights it was not kept, sleep heart rate averaged 5 bpm higher than on the 28 nights it was kept.")
        #expect(page.note.runs.filter(\.isHighlighted).map(\.text) == ["5 bpm"])
        let chart = try #require(page.note.receipt)
        #expect(chart.groups.map(\.label) == ["9 nights, not kept", "28 nights, kept"])
        #expect(chart.groups.map(\.nightCount) == [9, 28])
        #expect(chart.groups.map(\.nights.count) == [9, 28])
        #expect(chart.groups.map(\.mean) == [55, 50])
        #expect(chart.lastNightValue == nil)
        #expect(chart.outcome == .sleepHeartRate)
        let stated = Dictionary(uniqueKeysWithValues: page.note.numbers.filter { $0.unit == .nights }.map { ($0.displayed, Int($0.value)) })
        #expect(stated["9 nights"] == chart.groups[0].nightCount)
        #expect(stated["28 nights"] == chart.groups[1].nightCount)
        guard case .change(let detail) = page.detail else { Issue.record("Expected change detail"); return }
        #expect(detail.missedWeekdays == ["Saturday", "Sunday"])
        #expect(detail.receipt == chart)
        #expect(page.note.comparisonGroup == "9 nights not kept, against 28 nights kept")
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("More than three missed days are counted instead of named")
    func changePageManyDays() throws {
        let kitchen = WeeklyRuleWeek(rule: WeeklyFixtures.kitchenRule, days: WeeklyFixtures.week([.kept, .missed, .missed, .missed, .missed, .kept, .kept]))
        let page = try pageOf(.change, in: try makeStory(WeeklyFixtures.input(rules: [kitchen] + WeeklyFixtures.rules.dropFirst())))
        #expect(page.note.text.hasPrefix("Kitchen closes was not kept on 4 days this week. On the 9 nights it was not kept"))
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("A slip is named only when it coincided with a worse outcome")
    func slipMustBeWorse() throws {
        // Lower sleep heart rate is the better way, so a slip that came with a lower one is not a change worth trying.
        let better = WeeklyFixtures.slip(history: WeeklyFixtures.slipHistory(missedMean: 45, keptMean: 50))
        #expect(!(try makeStory(WeeklyFixtures.input(slips: [better]))).pages.contains { $0.kind == .change })

        // Higher HRV is the better way, so a slip that came with a higher one is not named either.
        let hrvBetter = WeeklyFixtures.slip(outcome: .hrv, history: WeeklyFixtures.slipHistory(missedMean: 70, keptMean: 60))
        #expect(!(try makeStory(WeeklyFixtures.input(slips: [hrvBetter]))).pages.contains { $0.kind == .change })

        let hrvWorse = WeeklyFixtures.slip(outcome: .hrv, history: WeeklyFixtures.slipHistory(missedMean: 52, keptMean: 60))
        let page = try pageOf(.change, in: try makeStory(WeeklyFixtures.input(slips: [hrvWorse])))
        #expect(page.note.text.contains("HRV averaged 8 ms lower than on the 28 nights it was kept."))
    }

    @Test("A slip under the minimum nights in either group, with no gap, or with no missed day this week is never named")
    func slipGates() throws {
        let minimum = WeeklyStoryThresholds.standard.notes.minimumNightsPerGroup
        let cases: [(String, WeeklySlip)] = [
            ("few missed", WeeklyFixtures.slip(history: WeeklyFixtures.slipHistory(missed: minimum - 1))),
            ("few kept", WeeklyFixtures.slip(history: WeeklyFixtures.slipHistory(kept: minimum - 1))),
            ("no gap", WeeklyFixtures.slip(history: WeeklyFixtures.slipHistory(missedMean: 50.2, keptMean: 50))),
            ("kept all week", WeeklyFixtures.slip(rule: WeeklyFixtures.screensRule)),
            ("rule not in the protocol", WeeklyFixtures.slip(rule: WeeklyFixtures.rule("gone", "Gone", at: nil))),
        ]
        for (name, slip) in cases {
            let story = try makeStory(WeeklyFixtures.input(slips: [slip]))
            #expect(!story.pages.contains { $0.kind == .change || $0.kind == .proposal }, "\(name)")
            #expect(story.proposal == nil, "\(name)")
        }
        let atMinimum = WeeklyFixtures.slip(history: WeeklyFixtures.slipHistory(missed: minimum, kept: minimum))
        #expect(try makeStory(WeeklyFixtures.input(slips: [atMinimum])).pages.contains { $0.kind == .change })
    }

    @Test("Nights without an outcome stay out of the receipt")
    func slipMissingOutcomes() throws {
        var history = WeeklyFixtures.slipHistory(missed: 7, kept: 7)
        history += (0..<9).map { _ in WeeklySlipNight(missed: true, outcome: nil) }
        history += [WeeklySlipNight(missed: false, outcome: .infinity)]
        let page = try pageOf(.change, in: try makeStory(WeeklyFixtures.input(slips: [WeeklyFixtures.slip(history: history)])))
        #expect(page.note.receipt?.groups.map(\.nightCount) == [7, 7])
    }

    @Test("The strongest slip wins, and the order of the slips does not matter")
    func strongestSlip() throws {
        let light = WeeklyFixtures.slip(rule: WeeklyFixtures.lightRule, history: WeeklyFixtures.slipHistory(missedMean: 52, keptMean: 50))
        let weak = WeeklyFixtures.slip()
        let first = try makeStory(WeeklyFixtures.input(slips: [light, weak]))
        let second = try makeStory(WeeklyFixtures.input(slips: [weak, light]))
        #expect(first == second)
        let page = try pageOf(.change, in: first)
        #expect(page.note.text.hasPrefix("Kitchen closes was not kept"))
        #expect(first.proposal?.ruleKey == "kitchen")
    }

    @Test("Page 4 is the proposal: version, change, outcome and design, and it starts nothing")
    func proposalPage() throws {
        let story = try makeStory(WeeklyFixtures.input(), WeeklyFixtures.writer(WeeklyFixtures.enGB))
        let page = try pageOf(.proposal, in: story)
        #expect(page.note.text == "Run it as a 14-day experiment first. Outcome: sleep heart rate. Version 7 stays until you decide.")
        let proposal = try #require(story.proposal)
        guard case .proposal(let shown) = page.detail else { Issue.record("Expected proposal detail"); return }
        #expect(shown == proposal)
        #expect(proposal.label == "Proposed for version 8")
        #expect(proposal.changeTitle == "Kitchen closes at 18:30 on weekends too")
        #expect(proposal.ruleKey == "kitchen" && proposal.ruleTitle == "Kitchen closes")
        #expect(proposal.outcome == .sleepHeartRate)
        #expect(proposal.design == .beforeAndAfter)
        #expect(proposal.experimentDays == 14)
        #expect(proposal.fromVersion == 7 && proposal.toVersion == 8)
        #expect(proposal.missedNights == 9 && proposal.keptNights == 28 && proposal.gap == 5)
        #expect(proposal.weekKey == "2026-10-19")
        #expect(proposal.id == "2026-10-19/kitchen/sleepHeartRate")
        #expect(page.visibleStrings.contains("Proposed for version 8"))
        WeeklyFixtures.expectPageNumbers(page)
    }

    @Test("The change title and the rule times follow the locale clock")
    func proposalFollowsClock() throws {
        let us = try #require(try makeStory(WeeklyFixtures.input(), WeeklyFixtures.writer(WeeklyFixtures.enUS)).proposal)
        let expected = NoteFixtures.clock(18 * 60 + 30, WeeklyFixtures.enUS)
        #expect(us.changeTitle == "Kitchen closes at \(expected) on weekends too")
        #expect(us.changeTitle.contains("PM"))
        let de = try #require(try makeStory(WeeklyFixtures.input(), WeeklyFixtures.writer(WeeklyFixtures.deDE)).proposal)
        #expect(de.changeTitle == "Kitchen closes at 18:30 on weekends too")
        for writer in [WeeklyFixtures.writer(WeeklyFixtures.enUS), WeeklyFixtures.writer(WeeklyFixtures.enGB), WeeklyFixtures.writer(WeeklyFixtures.deDE)] {
            for page in try makeStory(WeeklyFixtures.input(), writer).pages { WeeklyFixtures.expectPageNumbers(page) }
        }
    }

    @Test("Without a change title the proposal keeps the rule every day")
    func defaultChangeTitle() throws {
        let slip = WeeklyFixtures.slip(changeTitle: nil)
        let proposal = try #require(try makeStory(WeeklyFixtures.input(slips: [slip])).proposal)
        #expect(proposal.changeTitle == "Keep Kitchen closes every day")
        let unclean = WeeklyFixtures.slip(changeTitle: "Close the kitchen because it helps")
        #expect(try #require(try makeStory(WeeklyFixtures.input(slips: [unclean])).proposal).changeTitle == "Keep Kitchen closes every day")
    }

    @Test("No proposal without a version, or while an experiment runs")
    func proposalGates() throws {
        let noVersion = try makeStory(WeeklyFixtures.input(version: nil))
        #expect(noVersion.proposal == nil)
        #expect(noVersion.pages.map(\.kind) == [.kept, .moved, .change, .nextWeek])
        #expect(try pageOf(.nextWeek, in: noVersion).note.text.hasPrefix("Your protocol carries on with 3 rules"))

        let running = WeeklyRunningExperiment(title: "Kitchen closes at 18:30 on weekends too", outcome: .sleepHeartRate, dayNumber: 6, totalDays: 14)
        let busy = try makeStory(WeeklyFixtures.input(experiment: running))
        #expect(busy.proposal == nil)
        #expect(busy.pages.map(\.kind) == [.kept, .moved, .change, .nextWeek])
    }

    @Test("Page 5 lists the rules by time and any running experiment")
    func nextWeekPage() throws {
        let running = WeeklyRunningExperiment(title: "Kitchen closes at 18:30 on weekends too", outcome: .sleepHeartRate, dayNumber: 6, totalDays: 14)
        let story = try makeStory(WeeklyFixtures.input(experiment: running))
        let page = try pageOf(.nextWeek, in: story)
        #expect(page.note.text == "Version 7 carries on with 3 rules, from Morning light at 07:00 to Screens off at 21:45. "
            + "Your experiment, Kitchen closes at 18:30 on weekends too, is on day 6 of 14. It measures sleep heart rate.")
        guard case .nextWeek(let detail) = page.detail else { Issue.record("Expected next week detail"); return }
        #expect(detail.rules.map(\.title) == ["Morning light", "Kitchen closes", "Screens off"])
        #expect(detail.rules.map(\.time) == ["07:00", "18:30", "21:45"])
        #expect(detail.experiment == running)
        WeeklyFixtures.expectPageNumbers(page)

        let us = try self.makeStory(WeeklyFixtures.input(), WeeklyFixtures.writer(WeeklyFixtures.enUS))
        let usText = try self.pageOf(.nextWeek, in: us).note.text
        #expect(usText.contains("Morning light at \(NoteFixtures.clock(420, WeeklyFixtures.enUS))"))
        #expect(usText.contains("PM"))
    }

    @Test("One rule reads as one rule, and an experiment day outside its length is not stated")
    func nextWeekEdges() throws {
        let only = [WeeklyRuleWeek(rule: WeeklyFixtures.lightRule, days: WeeklyFixtures.week([.kept, .kept, .kept, .kept, .kept, .kept, .kept]))]
        let bad = WeeklyRunningExperiment(title: "Odd", outcome: .hrv, dayNumber: 15, totalDays: 14)
        let story = try makeStory(WeeklyFixtures.input(rules: only, slips: [], experiment: bad))
        let page = try pageOf(.nextWeek, in: story)
        #expect(page.note.text == "Version 7 carries on with 1 rule, Morning light at 07:00.")
    }

    @Test("A page with no data is skipped and the rest are renumbered")
    func skippedPages() throws {
        let bare = try makeStory(WeeklyFixtures.input(outcomes: [], slips: []))
        #expect(bare.pages.map(\.kind) == [.kept, .nextWeek])
        #expect(bare.pages.map(\.position) == [1, 2])
        #expect(bare.pages.map(\.kicker) == ["Week of 19 to 25 Oct \u{00B7} 1 of 2", "Week of 19 to 25 Oct \u{00B7} 2 of 2"])
        #expect(bare.pages.map(\.identifier) == ["weekly-review-page-1", "weekly-review-page-2"])
        #expect(bare.proposal == nil)
    }

    @Test("Fewer decided rule days than the minimum gives no review and says why")
    func absentWithReason() {
        let few = [WeeklyRuleWeek(rule: WeeklyFixtures.kitchenRule, days: WeeklyFixtures.week([.kept, .missed, .kept]))]
        let result = WeeklyFixtures.writer().write(WeeklyFixtures.input(rules: few))
        #expect(result == .absent(.tooFewDecidedRuleDays(have: 3, need: 7)))
        #expect(result.story == nil)
        if case .absent(let reason) = result {
            #expect(reason.reason == "A review needs 7 rule checks with an answer, and this week has 3.")
        }
        // Unknown and pending checks are not answers.
        let unanswered = [WeeklyRuleWeek(rule: WeeklyFixtures.kitchenRule, days: WeeklyFixtures.week([.unknown, .unknown, .pending, .unknown, .pending, .unknown, .unknown]))]
        #expect(WeeklyFixtures.writer().write(WeeklyFixtures.input(rules: unanswered)) == .absent(.tooFewDecidedRuleDays(have: 0, need: 7)))
        // Exactly the minimum is enough.
        let enough = [WeeklyRuleWeek(rule: WeeklyFixtures.kitchenRule, days: WeeklyFixtures.week([.kept, .kept, .kept, .kept, .kept, .kept, .missed]))]
        #expect(WeeklyFixtures.writer().write(WeeklyFixtures.input(rules: enough, slips: [])).story != nil)
    }

    @Test("No rules, no days or only unusable rules give no review")
    func absentInputs() {
        let writer = WeeklyFixtures.writer()
        #expect(writer.write(WeeklyFixtures.input(rules: [])) == .absent(.noRules))
        #expect(writer.write(WeeklyFixtures.input(days: [])) == .absent(.noRules))
        #expect(writer.write(WeeklyFixtures.input(days: [DayIdentity(year: 2026, month: 2, day: 30)])) == .absent(.noRules))
        let unusable = [WeeklyRuleWeek(rule: WeeklyFixtures.rule("a", "Cut it, because of sleep", at: nil), days: WeeklyFixtures.week(Array(repeating: .kept, count: 7)))]
        #expect(writer.write(WeeklyFixtures.input(rules: unusable)) == .absent(.noRules))
        #expect(!AbsenceCopy.isUnclean(WeeklyStoryAbsence.noRules.reason))
    }

    @Test("A rule whose title claims a cause is left out of every page")
    func uncleanTitlesLeftOut() throws {
        let bad = WeeklyRuleWeek(rule: WeeklyFixtures.rule("bad", "No screens because of sleep", at: 22 * 60), days: WeeklyFixtures.week(Array(repeating: .missed, count: 7)))
        let story = try makeStory(WeeklyFixtures.input(rules: WeeklyFixtures.rules + [bad]))
        for page in story.pages {
            #expect(!page.visibleStrings.joined(separator: " ").contains("No screens"))
        }
        guard case .kept(let detail) = story.pages[0].detail else { Issue.record("Expected kept detail"); return }
        #expect(detail.decidedRuleDays == 21)
    }

    @Test("Every page carries its own number set, and every digit on a page is in it")
    func numberSets() throws {
        let running = WeeklyRunningExperiment(title: "Zone 2, 45 min", outcome: .hrv, dayNumber: 3, totalDays: 14)
        let titled = WeeklyFixtures.rules + [WeeklyRuleWeek(rule: WeeklyFixtures.rule("z2", "Zone 2, 45 min", at: 17 * 60 + 30),
                                                           days: WeeklyFixtures.week(Array(repeating: .kept, count: 7)))]
        for locale in [WeeklyFixtures.enGB, WeeklyFixtures.enUS, WeeklyFixtures.deDE] {
            for input in [WeeklyFixtures.input(), WeeklyFixtures.input(rules: titled, experiment: running)] {
                for page in try makeStory(input, WeeklyFixtures.writer(locale)).pages {
                    WeeklyFixtures.expectPageNumbers(page)
                    #expect(!page.note.numbers.isEmpty || page.kind == .nextWeek)
                }
            }
        }
        // A number in one page's text is not assumed by another.
        let story = try makeStory()
        #expect(story.pages[0].note.displayedNumbers.contains("21"))
        #expect(!story.pages[1].note.displayedNumbers.contains("21"))
    }

    @Test("No page says caused, because or due to, uses an exclamation mark or a dash, and titles are sentence case")
    func wording() throws {
        let running = WeeklyRunningExperiment(title: "Kitchen closes at 18:30 on weekends too", outcome: .sleepHeartRate, dayNumber: 6, totalDays: 14)
        for input in [WeeklyFixtures.input(), WeeklyFixtures.input(experiment: running), WeeklyFixtures.input(outcomes: [], slips: [])] {
            for page in try makeStory(input).pages { WeeklyFixtures.expectWording(page) }
        }
        for reason in [WeeklyStoryAbsence.noRules, .tooFewDecidedRuleDays(have: 2, need: 7)] {
            #expect(!AbsenceCopy.isUnclean(reason.reason))
        }
        #expect(!AbsenceCopy.isUnclean(WeeklyStory.footer))
    }

    @Test("The weekday names follow the injected locale and calendar")
    func weekdays() throws {
        let de = try makeStory(WeeklyFixtures.input(), WeeklyFixtures.writer(WeeklyFixtures.deDE))
        // The kept page names its week by dates now (ICP R2-DES-04); the month follows the locale.
        #expect(de.pages[0].kicker.hasPrefix("Week of 19 to 25") && de.pages[0].kicker.contains("Okt"))
        #expect(try pageOf(.change, in: de).note.text.hasPrefix("Kitchen closes was not kept on Samstag and Sonntag."))
    }

    @Test("The same input gives the same story, whatever order the days and rules arrive in")
    func deterministic() throws {
        let input = WeeklyFixtures.input()
        let first = try makeStory(input)
        #expect(first == (try makeStory(input)))
        let shuffled = WeeklyFixtures.input(rules: WeeklyFixtures.rules.reversed(), days: WeeklyFixtures.days.reversed() + [WeeklyFixtures.day(2)])
        #expect(first == (try makeStory(shuffled)))
    }

    @Test("Days beyond the first seven and checks outside the week are ignored")
    func daysOutsideTheWeek() throws {
        let extra = WeeklyFixtures.days + [WeeklyFixtures.day(7), WeeklyFixtures.day(8)]
        let outside = WeeklyRuleWeek(rule: WeeklyFixtures.screensRule,
                                     days: WeeklyFixtures.week(Array(repeating: .kept, count: 7)) + [WeeklyRuleDay(day: WeeklyFixtures.day(9), state: .missed)])
        let rules = Array(WeeklyFixtures.rules.prefix(1)) + [outside, WeeklyFixtures.rules[2]]
        let story = try makeStory(WeeklyFixtures.input(rules: rules, days: extra))
        guard case .kept(let detail) = story.pages[0].detail else { Issue.record("Expected kept detail"); return }
        #expect(detail.decidedRuleDays == 21)
        #expect(detail.days.count == 7)
    }
}

/// The wording check for strings that are not pages.
private enum AbsenceCopy {
    static func isUnclean(_ text: String) -> Bool { !NoteGuard.isClean(text) }
}
