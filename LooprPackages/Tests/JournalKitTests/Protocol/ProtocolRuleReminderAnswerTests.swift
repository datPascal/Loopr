import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP R3-HAB-02: "Done" and "Skip today" on a rule reminder write the day's check the way the deck does, for the day
/// the reminder came on, and nothing for a rule that is gone or not due that day.
final class ProtocolRuleReminderAnswerTests: XCTestCase {
    private typealias Data_ = ProtocolTestData

    private func save(_ choice: ProtocolDeckChoice, _ key: RuleKey, day: Int = 14, rules: [ProtocolRule] = Data_.rules,
                      source: RecordingSource) async throws -> ProtocolRuleReminderAnswer.Outcome {
        try await ProtocolRuleReminderAnswer.save(choice, key: key, day: Data_.day(day), rules: rules, to: source, now: Data_.now)
    }

    func testDoneTicksARuleThePersonTicks() async throws {
        let source = RecordingSource()
        let outcome = try await save(.yes, "magnesium", source: source)
        XCTAssertEqual(outcome, .saved)
        let calls = await source.calls
        XCTAssertEqual(calls, ["tick magnesium 2023-11-14"])
    }

    /// ICP round 4, VET: Done at 20:30 on "In bed by 22:30" would write "kept" before the band could tell. A rule a
    /// source checks takes no answer from a reminder, however old the reminder is.
    func testARuleASourceChecksTakesNoAnswerFromAReminder() async throws {
        let source = RecordingSource()
        let done = try await save(.yes, "bed", source: source)
        let skipped = try await save(.skip, "bed", source: source)
        XCTAssertEqual([done, skipped], [.checkedBySource, .checkedBySource])
        let calls = await source.calls
        XCTAssertEqual(calls, [])
    }

    /// ICP round 4, Q1b: a reminder delivered before the schedule changed can still be answered on an off night. The
    /// answer writes nothing, so no tick lands among the test's off nights.
    func testAnOffNightWritesNothing() async throws {
        let source = RecordingSource()
        let outcome = try await ProtocolRuleReminderAnswer.save(.yes, key: "magnesium", day: Data_.day(14), rules: Data_.rules,
                                                                offNightTest: "magnesium", to: source, now: Data_.now)
        XCTAssertEqual(outcome, .offNight)
        let calls = await source.calls
        XCTAssertEqual(calls, [])
    }

    func testSkipTodaySkipsTheRuleForTheReminderDay() async throws {
        let source = RecordingSource()
        _ = try await save(.skip, "screens", day: 13, source: source)
        let calls = await source.calls
        XCTAssertEqual(calls, ["skip screens 2023-11-13"], "an answer after midnight still counts for the day the reminder came")
    }

    func testARemovedRuleOrADayOffWritesNothing() async throws {
        let source = RecordingSource()
        let gone = try await save(.yes, "sauna", source: source)
        XCTAssertEqual(gone, .ruleGone)
        // Tue 14 Nov 2023: a rule on Mondays and Fridays is not due.
        let gym = ProtocolRule(key: "gym", title: "Gym", cadence: .on([.monday, .friday]))
        let off = try await save(.yes, "gym", rules: Data_.rules + [gym], source: source)
        XCTAssertEqual(off, .notDue)
        let calls = await source.calls
        XCTAssertEqual(calls, [])
    }

    func testAFailedWriteIsReported() async {
        let source = RecordingSource(failsWrites: true)
        do {
            _ = try await save(.yes, "magnesium", source: source)
            XCTFail("the failure reaches the caller, which leaves the rule open")
        } catch {}
    }

    /// ICP round 4, SEN and VET: the day sheet says which answers came from a reminder, so the person can see it worked.
    func testTheDaySheetSaysAnAnswerCameFromTheReminder() throws {
        let tick = try RuleCheck(ruleKey: "magnesium", day: Data_.day(13), version: 1, state: .kept, source: .manual,
                                 recordedAt: Data_.now, answeredFrom: .reminder)
        let skip = try RuleCheck(ruleKey: "screens", day: Data_.day(13), version: 1, state: .skipped, source: .manual,
                                 overriddenByPerson: true, recordedAt: Data_.now, answeredFrom: .reminder)
        let inApp = try RuleCheck(ruleKey: "light", day: Data_.day(13), version: 1, state: .kept, source: .manual, recordedAt: Data_.now)
        let day = ProtocolDayInput(day: Data_.day(13), phase: .past, rules: [
            ProtocolRuleDay(rule: Data_.magnesium, check: tick), ProtocolRuleDay(rule: Data_.screens, check: skip),
            ProtocolRuleDay(rule: Data_.light, check: inApp)
        ])
        let rows = ProtocolDayRules.rows(for: day)
        XCTAssertEqual(rows.map(\.detail), ["Answered from your reminder.", "Answered from your reminder.", "Your answer."])
        XCTAssertTrue(rows[0].accessibilityLabel.contains("Answered from your reminder"))
    }
}

