import DomainKit
import Foundation
import RoutineKit
import Testing
@testable import CoachKit

/// Counts what the controller calls, so a test can say exactly what ran.
@MainActor
private final class Calls {
    var started: [WeeklyReviewProposal] = []
    var declined: [WeeklyProposalDecision] = []
}

@MainActor
@Suite("LV-09.2 weekly story proposal")
struct WeeklyStoryControllerTests {
    private func makeController(_ input: WeeklyStoryInput? = nil, calls: Calls) throws -> WeeklyStoryController {
        let story = try #require(WeeklyFixtures.story(input))
        return WeeklyStoryController(story: story,
                                     startExperiment: { calls.started.append($0) },
                                     recordDecline: { calls.declined.append($0) })
    }

    @Test("Building the story, moving through it and closing it start and save nothing")
    func nothingWithoutATap() throws {
        let calls = Calls()
        let controller = try makeController(calls: calls)
        #expect(controller.story.proposal != nil)
        for _ in 0..<6 { controller.next() }
        for _ in 0..<6 { controller.previous() }
        controller.go(to: 3)
        controller.go(to: 99)
        #expect(controller.offersProposal)
        #expect(calls.started.isEmpty)
        #expect(calls.declined.isEmpty)
        #expect(controller.resolution == nil)
    }

    @Test("Start the experiment hands the proposal over once and saves no decline")
    func startOnce() throws {
        let calls = Calls()
        let controller = try makeController(calls: calls)
        controller.go(to: 3)
        controller.startExperiment()
        controller.startExperiment()
        controller.notNow()
        #expect(calls.started == [try #require(controller.story.proposal)])
        #expect(calls.declined.isEmpty)
        #expect(controller.resolution == .started(try #require(controller.story.proposal)))
        #expect(!controller.offersProposal)
    }

    @Test("Not now records only the decline and starts nothing")
    func notNowRecordsOnlyTheDecline() throws {
        let calls = Calls()
        let controller = try makeController(calls: calls)
        controller.go(to: 3)
        controller.notNow()
        controller.notNow()
        controller.startExperiment()
        #expect(calls.started.isEmpty)
        #expect(calls.declined.count == 1)
        let decision = try #require(calls.declined.first)
        #expect(decision == WeeklyProposalDecision(weekKey: "2026-10-19", ruleKey: "kitchen", outcome: .sleepHeartRate,
                                                   missedNights: 9, gap: 5))
        #expect(controller.resolution == .declined(decision))
        #expect(!controller.offersProposal)
    }

    @Test("A story without a proposal has nothing to start or decline")
    func noProposal() throws {
        let calls = Calls()
        let controller = try makeController(WeeklyFixtures.input(version: nil), calls: calls)
        #expect(controller.story.proposal == nil)
        controller.startExperiment()
        controller.notNow()
        #expect(calls.started.isEmpty && calls.declined.isEmpty)
        #expect(controller.resolution == nil)
        #expect(!controller.offersProposal)
    }

    @Test("The proposal buttons are offered only on the proposal page")
    func offeredOnlyOnItsPage() throws {
        let calls = Calls()
        let controller = try makeController(calls: calls)
        var offered: [Bool] = []
        for index in controller.pages.indices {
            controller.go(to: index)
            offered.append(controller.offersProposal)
        }
        #expect(offered == [false, false, false, true, false])
    }

    @Test("Moving through pages stops at both ends")
    func navigation() throws {
        let calls = Calls()
        let controller = try makeController(calls: calls)
        #expect(controller.pageIndex == 0 && !controller.canGoBack && controller.canGoForward)
        controller.previous()
        #expect(controller.pageIndex == 0)
        for _ in 0..<10 { controller.next() }
        #expect(controller.pageIndex == 4 && controller.isOnLastPage && !controller.canGoForward)
        #expect(controller.page?.kind == .nextWeek)
        controller.go(to: -1)
        #expect(controller.pageIndex == 4)
        controller.go(to: 1)
        #expect(controller.page?.kind == .moved)
    }

    @Test("A declined proposal is stored as one small value and does not come back with the same evidence")
    func declineDoesNotRepeat() throws {
        let suite = "lv09-2-decisions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsWeeklyProposalDecisionStore(defaults: defaults)
        #expect(store.decisions().isEmpty)

        let calls = Calls()
        let controller = try makeController(calls: calls)
        controller.go(to: 3)
        controller.notNow()
        let decision = try #require(calls.declined.first)
        store.record(decision)
        #expect(store.decisions() == [decision])

        // Next week: the same rule, a week later, with nights 9 and a gap of 5 again.
        let next = WeeklyFixtures.input(declined: store.decisions())
        let story = try #require(WeeklyFixtures.story(next))
        #expect(story.proposal == nil)
        #expect(!story.pages.contains { $0.kind == .proposal })
        #expect(story.pages.contains { $0.kind == .change })
    }

    @Test("A declined proposal returns when the evidence has changed")
    func declineExpires() throws {
        let decision = WeeklyProposalDecision(weekKey: "2026-10-12", ruleKey: "kitchen", outcome: .sleepHeartRate, missedNights: 9, gap: 5)
        func proposal(missed: Int, keptMean: Double = 50, missedMean: Double = 55, decisions: [WeeklyProposalDecision]) throws -> WeeklyReviewProposal? {
            let history = WeeklyFixtures.slipHistory(missed: missed, kept: 28, missedMean: missedMean, keptMean: keptMean)
            let input = WeeklyFixtures.input(slips: [WeeklyFixtures.slip(history: history)], declined: decisions)
            return try #require(WeeklyFixtures.story(input)).proposal
        }
        #expect(try proposal(missed: 9, decisions: []) != nil)
        #expect(try proposal(missed: 9, decisions: [decision]) == nil)
        // Fewer than 7 more missed nights is not new evidence.
        #expect(try proposal(missed: 15, decisions: [decision]) == nil)
        // 7 more missed nights is.
        #expect(try proposal(missed: 16, decisions: [decision]) != nil)
        // A gap that grew by half is new evidence, one that grew by less is not.
        #expect(try proposal(missed: 9, missedMean: 57, decisions: [decision]) == nil)
        #expect(try proposal(missed: 9, missedMean: 58, decisions: [decision]) != nil)
        // A decision about another rule or outcome does not hold this one back.
        let other = WeeklyProposalDecision(weekKey: "2026-10-12", ruleKey: "screens", outcome: .sleepHeartRate, missedNights: 9, gap: 5)
        let otherOutcome = WeeklyProposalDecision(weekKey: "2026-10-12", ruleKey: "kitchen", outcome: .hrv, missedNights: 9, gap: 5)
        #expect(try proposal(missed: 9, decisions: [other, otherOutcome]) != nil)
    }

    @Test("The decision store keeps the newest decision for a rule and outcome and a short list")
    func storeBehaviour() throws {
        let suite = "lv09-2-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsWeeklyProposalDecisionStore(defaults: defaults)
        let older = WeeklyProposalDecision(weekKey: "2026-10-05", ruleKey: "kitchen", outcome: .hrv, missedNights: 8, gap: 4)
        let newer = WeeklyProposalDecision(weekKey: "2026-10-12", ruleKey: "kitchen", outcome: .hrv, missedNights: 12, gap: 6)
        store.record(older)
        store.record(newer)
        #expect(store.decisions() == [newer])

        for index in 0..<(UserDefaultsWeeklyProposalDecisionStore.capacity + 5) {
            store.record(WeeklyProposalDecision(weekKey: "w\(index)", ruleKey: RuleKeyFixture.key(index), outcome: .hrv, missedNights: 8, gap: 4))
        }
        #expect(store.decisions().count == UserDefaultsWeeklyProposalDecisionStore.capacity)
        #expect(store.decisions().last?.weekKey == "w\(UserDefaultsWeeklyProposalDecisionStore.capacity + 4)")

        // A fresh store on the same defaults reads the same list.
        #expect(UserDefaultsWeeklyProposalDecisionStore(defaults: defaults).decisions() == store.decisions())
    }

    @Test("A decision with unreadable stored data reads as empty")
    func unreadableStore() throws {
        let suite = "lv09-2-bad-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: UserDefaultsWeeklyProposalDecisionStore.key)
        #expect(UserDefaultsWeeklyProposalDecisionStore(defaults: defaults).decisions().isEmpty)
    }
}

private enum RuleKeyFixture {
    static func key(_ index: Int) -> RuleKey { RuleKey(rawValue: "rule-\(index)") }
}
