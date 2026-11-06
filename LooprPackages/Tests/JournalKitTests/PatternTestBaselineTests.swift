import DomainKit
import Foundation
import JournalKit
import XCTest

final class PatternTestBaselineTests: XCTestCase {
    private typealias F = PatternFixtures

    /// Alex keeps the listed test days (0 is Sunday 20 September), each recorded at 21:00 Perth that day.
    private func keptTest(_ offsets: [Int], candidate: PatternCandidate = .trainingDay,
                          metric: HabitOutcomeMetricID = .sleepScore) throws -> PatternTest {
        var test = try F.startTest(candidate: candidate, metric: metric)
        for offset in offsets {
            let day = PatternDays.add(offset, to: F.testStart)!
            try test.keep(day: day, at: F.date(day, hour: 21))
        }
        return test
    }

    // MARK: Shape

    func testATestStartsTodayInAlexsZoneWithFourteenDaysAndThirtyBaselineDays() throws {
        let test = try F.startTest()
        XCTAssertEqual(test.startDay, "2026-09-20")
        XCTAssertEqual(test.timeZoneID, "Australia/Perth")
        XCTAssertEqual(test.testDays, 14)
        XCTAssertEqual(test.baselineDays, 30)
        XCTAssertEqual(test.testDayKeys.first, "2026-09-20")
        XCTAssertEqual(test.testDayKeys.last, "2026-10-03")
        XCTAssertEqual(test.endDay, "2026-10-03")
        XCTAssertEqual(test.baselineDayKeys.count, 30)
        XCTAssertEqual(test.baselineDayKeys.first, "2026-08-21")
        XCTAssertEqual(test.baselineDayKeys.last, "2026-09-19")
        XCTAssertEqual(test.outcomeMetric, .sleepScore)
        XCTAssertEqual(test.reminder, PatternReminder(enabled: true, minuteOfDay: 20 * 60 + 15))
        XCTAssertEqual(test.reminder?.hour, 20)
        XCTAssertEqual(test.reminder?.minute, 15)
        XCTAssertEqual(test.state, .running)
        // 20:00 UTC on 25 September is already 26 September in Perth.
        let utcEvening = Date(timeIntervalSince1970: 1_790_366_400)
        XCTAssertEqual(PatternDays.key(at: utcEvening, timeZoneID: F.zoneID), "2026-09-26")
        XCTAssertEqual(PatternDays.key(at: utcEvening, timeZoneID: "UTC"), "2026-09-25")
    }

    func testOutcomeMetricDefaultsToTheCandidatesAndStaysFixed() throws {
        let test = try PatternTest.start(candidate: F.lateDinner, now: F.date("2026-09-20"), timeZone: F.zone)
        XCTAssertEqual(test.outcomeMetric, .sleepScore, "the candidate's first target metric")
        var changed = try keptTest([0, 1])
        changed.reminder = nil
        XCTAssertEqual(changed.outcomeMetric, .sleepScore, "nothing a caller can mutate changes the outcome metric")
    }

    // MARK: Baseline and answers

    func testBaselineIsNoKeptIsYesAndMissedIsSkipped() throws {
        // Day 6, Friday 25 September. Alex kept 20, 21, 23, 24 and 25 and missed the 22nd.
        let test = try keptTest([0, 1, 3, 4, 5])
        let now = F.date("2026-09-25", hour: 22)
        let records = test.records(at: now)
        let answers = Dictionary(uniqueKeysWithValues: records.map { ($0.behaviorDay.habitKey, $0.responses[0]) })
        XCTAssertEqual(records.count, 30 + 6, "30 baseline days and the 6 test days so far")
        for key in test.baselineDayKeys { XCTAssertEqual(answers[key]?.answer, .no, key) }
        for key in ["2026-09-20", "2026-09-21", "2026-09-23", "2026-09-24", "2026-09-25"] {
            XCTAssertEqual(answers[key]?.answer, .yes, key)
        }
        XCTAssertEqual(answers["2026-09-22"]?.answer, .skipped)
        XCTAssertNil(answers["2026-09-26"], "future days have no record")
        XCTAssertTrue(records.allSatisfy { $0.behaviorTimeZoneID == "Australia/Perth" })
        XCTAssertTrue(records.allSatisfy { $0.responses[0].habitID == F.trainingHabit })

        // The engine's own eligibility rules agree: missed is excluded, kept and baseline count.
        XCTAssertEqual(HabitEligibility.exclusion(for: answers["2026-09-22"]!), .skipped)
        XCTAssertNil(HabitEligibility.exclusion(for: answers["2026-09-21"]!))
        XCTAssertNil(HabitEligibility.exclusion(for: answers["2026-09-01"]!))
    }

    func testTodayHasNoAnswerUntilItIsKeptAndThenItIsYes() throws {
        var test = try keptTest([0, 1, 2, 3, 4])
        let evening = F.date("2026-09-25", hour: 22)
        XCTAssertNil(test.records(at: evening).first { $0.behaviorDay.habitKey == "2026-09-25" }, "pending, neither yes nor no")
        try test.keep(day: "2026-09-25", at: evening)
        XCTAssertEqual(test.records(at: evening).first { $0.behaviorDay.habitKey == "2026-09-25" }?.responses[0].answer, .yes)
        let nextMorning = F.date("2026-09-26", hour: 7)
        var skipped = try keptTest([0, 1, 2, 3])
        XCTAssertEqual(skipped.records(at: nextMorning).first { $0.behaviorDay.habitKey == "2026-09-25" }?.responses[0].answer, .skipped)
        skipped.unkeep(day: "2026-09-23")
        XCTAssertEqual(skipped.records(at: nextMorning).first { $0.behaviorDay.habitKey == "2026-09-23" }?.responses[0].answer, .skipped)
    }

    func testProgressComesFromStoredDayKeysAndSurvivesEncoding() throws {
        let test = try keptTest([0, 1, 3, 4, 5])
        let now = F.date("2026-09-25", hour: 22)
        let progress = test.progress(at: now)
        XCTAssertEqual(progress.dayNumber, 6)
        XCTAssertEqual(progress.totalDays, 14)
        XCTAssertEqual(progress.elapsedDays, 6)
        XCTAssertEqual(progress.keptCount, 5)
        XCTAssertEqual(progress.missedCount, 1)
        XCTAssertEqual(progress.keptSummary, "5 of 6 kept")
        XCTAssertFalse(progress.isOver)
        XCTAssertEqual(progress.days["2026-09-22"], .missed)
        XCTAssertEqual(progress.days["2026-09-25"], .kept)
        XCTAssertEqual(progress.days["2026-09-26"], .upcoming)
        XCTAssertEqual(test.keptDayKeys, ["2026-09-20", "2026-09-21", "2026-09-23", "2026-09-24", "2026-09-25"])

        let reopened = try JSONDecoder().decode(PatternTest.self, from: JSONEncoder().encode(test))
        XCTAssertEqual(reopened, test)
        XCTAssertEqual(reopened.progress(at: now), progress)

        var today = try F.startTest()
        XCTAssertEqual(today.progress(at: F.date("2026-09-20", hour: 21)).dayNumber, 1)
        XCTAssertEqual(today.progress(at: F.date("2026-09-20", hour: 21)).days["2026-09-20"], .pending)
        XCTAssertEqual(today.progress(at: F.date("2026-10-03", hour: 21)).dayNumber, 14)
        XCTAssertFalse(today.progress(at: F.date("2026-10-03", hour: 21)).isOver)
        let over = today.progress(at: F.date("2026-10-04", hour: 8))
        XCTAssertTrue(over.isOver)
        XCTAssertEqual(over.dayNumber, 14)
        XCTAssertEqual(over.missedCount, 14)
        today.refreshState(at: F.date("2026-10-03", hour: 21))
        XCTAssertEqual(today.state, .running)
        today.refreshState(at: F.date("2026-10-04", hour: 8))
        XCTAssertEqual(today.state, .completed)
        XCTAssertEqual(today.endedAt, F.date("2026-10-04", hour: 0))
    }

    func testKeepingFollowsTheJournalAnswerWindow() throws {
        var test = try F.startTest()
        XCTAssertThrowsError(try test.keep(day: "2026-09-19", at: F.date("2026-09-20"))) { XCTAssertEqual($0 as? PatternTestError, .notATestDay) }
        XCTAssertThrowsError(try test.keep(day: "2026-09-22", at: F.date("2026-09-21"))) { XCTAssertEqual($0 as? PatternTestError, .futureDay) }
        // 48 hours after the end of 20 September is midnight at the start of 23 September.
        try test.keep(day: "2026-09-20", at: F.date("2026-09-22", hour: 23, minute: 59))
        XCTAssertEqual(test.keptDayKeys, ["2026-09-20"])
        XCTAssertThrowsError(try test.keep(day: "2026-09-21", at: F.date("2026-09-24", hour: 0, minute: 1))) {
            XCTAssertEqual($0 as? PatternTestError, .tooLate)
        }
        try test.keep(day: "2026-09-20", at: F.date("2026-09-22", hour: 23, minute: 59))
        XCTAssertEqual(test.keptDayKeys, ["2026-09-20"], "keeping twice is one kept night")
        test.stop(at: F.date("2026-09-22"))
        XCTAssertEqual(test.state, .stopped)
        XCTAssertThrowsError(try test.keep(day: "2026-09-22", at: F.date("2026-09-22"))) { XCTAssertEqual($0 as? PatternTestError, .notRunning) }
    }

    // MARK: Gates, on engine output

    private func makeVerdict(_ status: HabitInsightStatus, kept: Int, baseline: Int,
                         adjusted: Double? = -8, raw: Double? = -9) throws -> PatternTestVerdict {
        let test = try F.startTest()
        let metric = F.metric(.sleepScore, status: status, adjusted: adjusted, raw: raw, yes: kept, no: baseline)
        return PatternTestVerdict.make(test: test, estimate: F.estimate(habit: test.habitID, metrics: [metric]),
                                       now: F.date("2026-10-04"), policy: F.shortPolicy)
    }

    func testBelowFiveKeptNightsTheVerdictIsTooEarlyWhateverTheEngineSays() throws {
        for kept in 0...4 {
            let verdict = try makeVerdict(.clearAssociation, kept: kept, baseline: 30)
            XCTAssertEqual(verdict.kind, .tooEarly, "\(kept) kept")
            XCTAssertEqual(verdict.headline, "Too early to tell")
            XCTAssertNil(verdict.difference, "no number below the first gate")
            XCTAssertFalse(verdict.isConclusive)
        }
        let none = PatternTestVerdict.make(test: try F.startTest(), estimate: nil, now: F.date("2026-10-04"))
        XCTAssertEqual(none.kind, .tooEarly)
        XCTAssertEqual(none.keptNights, 0)
        let thin = try makeVerdict(.earlySignal, kept: 7, baseline: 4)
        XCTAssertEqual(thin.kind, .tooEarly, "the other side needs 5 as well")
    }

    func testFiveToNineKeptNightsGiveAnEarlyLookAtMost() throws {
        for kept in 5...9 {
            let verdict = try makeVerdict(.clearAssociation, kept: kept, baseline: 30)
            XCTAssertEqual(verdict.kind, .early, "\(kept) kept")
            XCTAssertEqual(verdict.headline, "Too early to tell", "below the clear gate the headline stays")
            XCTAssertTrue(verdict.detail.contains("A first look only."))
            XCTAssertTrue(verdict.detail.contains("Loopr needs 10 kept nights before it calls this clear."))
            XCTAssertEqual(verdict.difference, -8)
            XCTAssertFalse(verdict.isConclusive)
        }
        XCTAssertEqual(try makeVerdict(.noClearAssociation, kept: 9, baseline: 30).kind, .early)
        XCTAssertEqual(try makeVerdict(.earlySignal, kept: 5, baseline: 30).kind, .early)
    }

    func testClearNeedsTenAndTenAndThirtyEligibleDays() throws {
        let clear = try makeVerdict(.clearAssociation, kept: 10, baseline: 30)
        XCTAssertEqual(clear.kind, .clear)
        XCTAssertEqual(clear.headline, "Clear difference")
        XCTAssertTrue(clear.isConclusive)
        XCTAssertEqual(try makeVerdict(.clearAssociation, kept: 10, baseline: 20).kind, .clear, "30 eligible days is enough")
        XCTAssertEqual(try makeVerdict(.clearAssociation, kept: 10, baseline: 19).kind, .early, "29 eligible days is not")
        XCTAssertEqual(try makeVerdict(.clearAssociation, kept: 9, baseline: 30).kind, .early)
        XCTAssertEqual(try makeVerdict(.clearAssociation, kept: 14, baseline: 9).kind, .early, "10 nights on each side")
        let none = try makeVerdict(.noClearAssociation, kept: 12, baseline: 30)
        XCTAssertEqual(none.kind, .noClearDifference)
        XCTAssertEqual(none.headline, "No clear difference")
        XCTAssertTrue(none.isConclusive)
        XCTAssertEqual(try makeVerdict(.clearAssociation, kept: 12, baseline: 30, adjusted: nil, raw: -9).kind, .tooEarly,
                       "a clear status with no adjusted number cannot be shown")
        for status in [HabitInsightStatus.collecting, .stale, .unavailable, .cannotSeparate] {
            XCTAssertEqual(try makeVerdict(status, kept: 12, baseline: 30).kind, .tooEarly, "\(status)")
        }
    }

    func testNowAndBeforeAreDisplayMeansTheEngineAlreadyComputed() throws {
        let verdict = try makeVerdict(.clearAssociation, kept: 12, baseline: 30, adjusted: 7.4, raw: 10)
        XCTAssertEqual(verdict.nowMean, 80)
        XCTAssertEqual(verdict.beforeMean, 70)
        XCTAssertEqual(verdict.difference, 7.4, "the verdict reports the adjusted effect, not Now minus Before")
        XCTAssertEqual(verdict.keptNights, 12)
        XCTAssertEqual(verdict.baselineNights, 30)
        XCTAssertEqual(verdict.unit, .scorePoints)
        XCTAssertEqual(verdict.detail, "Sleep score was 7.4 points higher on 12 nights you kept than on the 30 nights before. These compare your own nights. They do not show cause.")
        let lower = try makeVerdict(.clearAssociation, kept: 12, baseline: 30, adjusted: -8, raw: -9)
        XCTAssertTrue(lower.detail.hasPrefix("Sleep score was 8 points lower on 12 nights you kept"))
        let flat = try makeVerdict(.noClearAssociation, kept: 12, baseline: 30, adjusted: 0.4, raw: 0.6)
        XCTAssertEqual(flat.detail, "Sleep score looked about the same on 12 nights you kept and the 30 nights before. These compare your own nights. They do not show cause.")
        XCTAssertEqual(try makeVerdict(.collecting, kept: 3, baseline: 30).detail,
                       "3 kept nights with sleep score data so far. Loopr needs 5 for a first look and 10 for a clear read.")
        XCTAssertTrue(verdict.algorithmVersion.hasPrefix("patterns.v1/"))
    }

    // MARK: Engine

    private func evaluate(_ test: PatternTest, outcomes: [String: HabitOutcomeSnapshot], now: Date) async throws -> PatternTestVerdict {
        try await PatternTestEvaluator(policy: F.shortPolicy)
            .evaluateInBackground(test, outcomes: F.OutcomeOnly(byDay: outcomes), now: now)
    }

    func testAllFourteenNightsKeptReadsClearOnTheChosenMetric() async throws {
        let test = try keptTest(Array(0..<14))
        let outcomes = F.testOutcomes(test: test, keptDays: Set(test.keptDayKeys))
        let verdict = try await evaluate(test, outcomes: outcomes, now: F.date("2026-10-04", hour: 8))
        XCTAssertEqual(verdict.kind, .clear)
        XCTAssertEqual(verdict.keptNights, 14)
        XCTAssertEqual(verdict.baselineNights, 30)
        XCTAssertEqual(try XCTUnwrap(verdict.difference), 7.5, accuracy: 2.5)
        let keptMean = test.keptDayKeys.map { outcomes[$0]!.metrics[.sleepScore]! }.reduce(0, +) / 14
        let baselineMean = test.baselineDayKeys.map { outcomes[$0]!.metrics[.sleepScore]! }.reduce(0, +) / 30
        XCTAssertEqual(try XCTUnwrap(verdict.nowMean), keptMean, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(verdict.beforeMean), baselineMean, accuracy: 1e-9)
        XCTAssertGreaterThan(keptMean - baselineMean, 8, "the display means differ from the adjusted effect, and only the engine decides")
    }

    func testMissedNightsAreSkippedNotCountedAsNo() async throws {
        // Alex misses the 22nd, 23rd and 28th. Those nights still have sleep data, at the usual 70.
        let kept = [0, 1, 4, 5, 6, 7, 9, 10, 11, 12, 13]
        let test = try keptTest(kept)
        let outcomes = F.testOutcomes(test: test, keptDays: Set(test.keptDayKeys))
        XCTAssertNotNil(outcomes["2026-09-22"], "a missed night still has an outcome")
        let verdict = try await evaluate(test, outcomes: outcomes, now: F.date("2026-10-04", hour: 8))
        XCTAssertEqual(verdict.keptNights, 11)
        XCTAssertEqual(verdict.baselineNights, 30, "missed nights are not baseline nights")
        XCTAssertEqual(verdict.kind, .clear)
        XCTAssertEqual(test.progress(at: F.date("2026-10-04", hour: 8)).missedCount, 3)
    }

    func testMidTestVerdictsStayBelowTheGates() async throws {
        let sixDays = try keptTest([0, 1, 3, 4, 5])
        let outcomes = F.testOutcomes(test: sixDays, keptDays: Set(sixDays.keptDayKeys))
        let early = try await evaluate(sixDays, outcomes: outcomes, now: F.date("2026-09-25", hour: 22))
        XCTAssertEqual(early.kind, .early, "5 kept nights is a first look, not a result")
        XCTAssertEqual(early.keptNights, 5)
        XCTAssertEqual(early.headline, "Too early to tell")

        let threeDays = try keptTest([0, 1, 2])
        let few = try await evaluate(threeDays, outcomes: F.testOutcomes(test: threeDays, keptDays: Set(threeDays.keptDayKeys)),
                                     now: F.date("2026-09-22", hour: 22))
        XCTAssertEqual(few.kind, .tooEarly)
        XCTAssertEqual(few.keptNights, 3)
        XCTAssertNil(few.difference)
    }

    func testVerdictFollowsTheMetricChosenAtTheStartNotTheBestOne() async throws {
        // Sleep score does not move. HRV moves by 20 ms on kept nights, and would look impressive if anyone went looking.
        let test = try keptTest(Array(0..<14))
        let outcomes = F.testOutcomes(test: test, keptDays: Set(test.keptDayKeys), decoys: [.hrvRMSSD: 20], ownEffect: 0)
        let verdict = try await evaluate(test, outcomes: outcomes, now: F.date("2026-10-04", hour: 8))
        XCTAssertEqual(verdict.metric, .sleepScore)
        XCTAssertEqual(verdict.kind, .noClearDifference)
        XCTAssertEqual(verdict.headline, "No clear difference")
        XCTAssertLessThan(abs(try XCTUnwrap(verdict.difference)), 3)
    }

    func testOldStoredTestsDecodeWithMissingFields() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-0000000A1E01","habitID":{"rawValue":"FC200000-0000-4000-8000-000000000001"},"startDay":"2026-09-20"}
        """.data(using: .utf8)!
        let test = try JSONDecoder().decode(PatternTest.self, from: json)
        XCTAssertEqual(test.testDays, 14)
        XCTAssertEqual(test.baselineDays, 30)
        XCTAssertEqual(test.state, .running)
        XCTAssertEqual(test.keptDays, [])
        XCTAssertNil(test.reminder)
        XCTAssertEqual(test.outcomeMetric, .sleepScore)
        let odd = try JSONDecoder().decode(PatternTest.self, from: """
        {"id":"00000000-0000-0000-0000-0000000A1E02","habitID":{"rawValue":"FC200000-0000-4000-8000-000000000001"},"startDay":"2026-09-20","state":"paused"}
        """.data(using: .utf8)!)
        XCTAssertEqual(odd.state, .running, "an unknown state does not make the test unreadable")
        let reminder = try JSONDecoder().decode(PatternReminder.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(reminder.minuteOfDay, 20 * 60 + 15)
    }
}
