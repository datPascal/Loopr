import DomainKit
import Foundation
import JournalKit
import StorageKit
import XCTest

/// Stores for Alex's patterns, closed and reopened the way a relaunch does.
final class PatternStoreRestartTests: XCTestCase {
    private typealias F = PatternFixtures

    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PatternStoreRestart-\(UUID().uuidString)")
        private(set) var database: StorageDatabase
        init() throws { database = try StorageDatabase(url: root.appendingPathComponent("loopr.sqlite")) }
        func reopen() throws -> SQLitePatternStore {
            try database.databasePool.close()
            database = try StorageDatabase(path: database.path)
            return try SQLitePatternStore(database: database)
        }
        func store() throws -> SQLitePatternStore { try SQLitePatternStore(database: database) }
        deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
    }

    private func found(_ candidate: PatternCandidate, _ metric: HabitOutcomeMetricID, _ strength: PatternStrength,
                       difference: Double, with: Int = 26, without: Int = 34) -> FoundPattern {
        FoundPattern(
            candidateID: candidate.id, habitID: candidate.habitID, title: candidate.title, predicate: candidate.predicate,
            metric: metric, strength: strength,
            effect: PatternEffect(adjustedDifference: difference, rawDifference: difference * 1.1, withMean: 60, withoutMean: 72,
                                  intervalLower: difference - 3, intervalUpper: difference + 3, pValue: 0.004,
                                  practicalThreshold: PatternPolicy.default.practicalThreshold(for: metric), unit: metric.unit),
            nights: PatternNights(with: with, without: without), windowEnd: F.discoveryEnd,
            algorithmVersion: "patterns.v1/journal.habit-impact.v2", foundAt: F.date(F.discoveryEnd, hour: 21))
    }

    private var strongLate: FoundPattern { found(F.lateDinner, .sleepScore, .strong, difference: -12) }
    private var clearAlcohol: FoundPattern { found(F.alcohol, .hrvRMSSD, .clear, difference: -7, with: 34, without: 26) }
    private var earlySteps: FoundPattern { found(F.steps, .sleepDuration, .early, difference: 30, with: 6, without: 6) }

    private func review() -> WeeklyReview {
        WeeklyReview(weekStartDay: "2026-09-21", weekEndDay: "2026-09-27", text: "Nothing clear yet.", patternKeys: [strongLate.key],
                     testIDs: [UUID(uuidString: "00000000-0000-0000-0000-0000000A1E01")!], generatedAt: F.date("2026-09-27", hour: 18))
    }

    // MARK: Restart

    func testEverythingSurvivesARestartInTheirNamedKeys() async throws {
        let context = try Context()
        let store = try context.store()
        var test = try F.startTest()
        for offset in [0, 1, 3, 4, 5] {
            let day = PatternDays.add(offset, to: F.testStart)!
            try test.keep(day: day, at: F.date(day, hour: 21))
        }
        try await store.saveTest(test)
        try await store.replaceFoundPatterns([strongLate, clearAlcohol, earlySteps])
        try await store.dismiss(clearAlcohol, at: F.date("2026-09-30", hour: 22))
        try await store.saveReview(review())
        let settings = PatternSettings(lookForNewPatterns: true, defaultReminderMinuteOfDay: 19 * 60,
                                       lastDiscoveryDay: F.discoveryEnd, lastDiscoveryAt: F.date(F.discoveryEnd, hour: 21))
        try await store.saveSettings(settings)

        let documents = try StorageDocumentStore(database: context.database, namespace: "patterns")
        XCTAssertEqual(try documents.keys(), [
            "dismissed.\(clearAlcohol.key)", "found.\(clearAlcohol.key)", "found.\(earlySteps.key)", "found.\(strongLate.key)",
            "review.2026-09-21", "settings", "test.\(test.id.uuidString)"
        ].sorted())

        let reopened = try context.reopen()
        let storedTest = try await reopened.test(id: test.id)
        XCTAssertEqual(storedTest, test)
        let now = F.date("2026-09-25", hour: 22)
        XCTAssertEqual(storedTest?.progress(at: now).keptSummary, "5 of 6 kept", "progress is rebuilt from stored day keys")
        let value1 = try await reopened.tests()
        XCTAssertEqual(value1, [test])
        let value2 = Set(try await reopened.foundPatterns().map(\.key))
        XCTAssertEqual(value2, [strongLate.key, clearAlcohol.key, earlySteps.key])
        let value3 = try await reopened.foundPatterns().map(\.strength)
        XCTAssertEqual(value3, [.strong, .clear, .early], "ordered strongest first")
        let value4 = try await reopened.visibleFoundPatterns().map(\.key)
        XCTAssertEqual(value4, [strongLate.key, earlySteps.key])
        let value5 = try await reopened.dismissedPatterns().map(\.evidence)
        XCTAssertEqual(value5, [clearAlcohol])
        let value6 = try await reopened.review(weekStartDay: "2026-09-21")
        XCTAssertEqual(value6, review())
        let value7 = try await reopened.reviews()
        XCTAssertEqual(value7, [review()])
        let value8 = try await reopened.settings()
        XCTAssertEqual(value8, settings)
    }

    func testDismissalKeepsItsEvidenceAndRestoreBringsThePatternBack() async throws {
        let context = try Context()
        var store = try context.store()
        try await store.replaceFoundPatterns([strongLate, clearAlcohol])
        try await store.dismiss(clearAlcohol, at: F.date("2026-09-30", hour: 22))
        let value9 = try await store.visibleFoundPatterns().map(\.key)
        XCTAssertEqual(value9, [strongLate.key], "dismissed stays off Today")

        // Discovery runs again with newer numbers; the dismissal still holds the evidence Alex saw.
        let newer = found(F.alcohol, .hrvRMSSD, .clear, difference: -8, with: 40, without: 30)
        try await store.replaceFoundPatterns([strongLate, newer])
        let value10 = try await store.visibleFoundPatterns().map(\.key)
        XCTAssertEqual(value10, [strongLate.key])
        let value11 = try await store.dismissedPatterns().first?.evidence
        XCTAssertEqual(value11, clearAlcohol)
        store = try context.reopen()
        let value12 = try await store.dismissedPatterns().first?.dismissedAt
        XCTAssertEqual(value12, F.date("2026-09-30", hour: 22))

        let restored = try await store.restore(key: clearAlcohol.key)
        XCTAssertEqual(restored, newer, "a newer result wins over the stored evidence")
        let value13 = try await store.visibleFoundPatterns().map(\.key)
        XCTAssertEqual(value13, [strongLate.key, clearAlcohol.key])
        let value14 = try await store.dismissedPatterns().isEmpty
        XCTAssertTrue(value14)
        let value15 = try await store.restore(key: "never.dismissed")
        XCTAssertNil(value15)

        // With no newer result, Restore puts the evidence itself back.
        try await store.dismiss(strongLate, at: F.date("2026-10-01"))
        try await store.replaceFoundPatterns([])
        let value16 = try await store.foundPatterns().isEmpty
        XCTAssertTrue(value16)
        let value17 = try await store.restore(key: strongLate.key)
        XCTAssertEqual(value17, strongLate)
        let value18 = try await store.foundPatterns()
        XCTAssertEqual(value18, [strongLate])
    }

    func testFoundListIsRebuiltAfterADeletionAndDerivedDataCanBeCleared() async throws {
        let context = try Context()
        var store = try context.store()
        let test = try F.startTest()
        try await store.saveTest(test)
        try await store.saveSettings(PatternSettings(lookForNewPatterns: true))
        try await store.replaceFoundPatterns([strongLate, clearAlcohol, earlySteps])
        try await store.dismiss(earlySteps, at: F.date("2026-10-01"))
        try await store.saveReview(review())

        // Alex deletes the food log. Discovery reruns without it and the list is replaced, not merged.
        try await store.replaceFoundPatterns([clearAlcohol])
        store = try context.reopen()
        let value19 = try await store.foundPatterns().map(\.key)
        XCTAssertEqual(value19, [clearAlcohol.key])
        let documents = try StorageDocumentStore(database: context.database, namespace: "patterns")
        XCTAssertFalse(try documents.keys().contains("found.\(strongLate.key)"))

        try await store.clearDerived()
        let value20 = try await store.foundPatterns().isEmpty
        XCTAssertTrue(value20)
        // DEC-07 line 2: a dismissal is the person's choice, so it survives; its numbers are marked out of date.
        let value21 = try await store.dismissedPatterns()
        XCTAssertEqual(value21.map(\.key), [earlySteps.key])
        XCTAssertTrue(value21.allSatisfy(\.evidenceIsStale))
        let value22 = try await store.reviews().isEmpty
        XCTAssertTrue(value22)
        let value23 = try await store.tests()
        XCTAssertEqual(value23, [test], "tests are the person's own record")
        let value24 = try await store.settings().lookForNewPatterns
        XCTAssertTrue(value24)

        try await store.deleteAll()
        XCTAssertTrue(try documents.keys().isEmpty)
        let value25 = try await store.settings()
        XCTAssertEqual(value25, PatternSettings())
        let value26 = try await store.settings().lookForNewPatterns
        XCTAssertFalse(value26, "off until Alex turns it on")
    }

    func testDeletingATestRemovesOnlyThatTest() async throws {
        let context = try Context()
        let store = try context.store()
        let first = try F.startTest(id: UUID(uuidString: "00000000-0000-0000-0000-0000000A1E01")!)
        let second = try F.startTest(candidate: .legDay, metric: .deepSleepMinutes, id: UUID(uuidString: "00000000-0000-0000-0000-0000000A1E02")!)
        try await store.saveTest(first)
        try await store.saveTest(second)
        try await store.deleteTest(id: first.id)
        let reopened = try context.reopen()
        let value27 = try await reopened.tests()
        XCTAssertEqual(value27, [second])
        let value28 = try await reopened.test(id: first.id)
        XCTAssertNil(value28)
        let value29 = try await reopened.test(id: second.id)?.outcomeMetric
        XCTAssertEqual(value29, .deepSleepMinutes)
    }

    func testOldAndDamagedDocumentsDoNotBreakTheScreens() async throws {
        let context = try Context()
        let store = try context.store()
        let documents = try StorageDocumentStore(database: context.database, namespace: "patterns")
        try documents.writeData(Data("{}".utf8), key: "settings")
        try documents.writeData(Data("""
        {"id":"00000000-0000-0000-0000-0000000A1E01","habitID":{"rawValue":"FC200000-0000-4000-8000-000000000001"},"startDay":"2026-09-20"}
        """.utf8), key: "test.00000000-0000-0000-0000-0000000A1E01")
        try documents.writeData(Data("""
        {"candidateID":"training","habitID":{"rawValue":"FC200000-0000-4000-8000-000000000001"},"metric":"sleepScore"}
        """.utf8), key: "found.training.sleepScore")
        try documents.writeData(Data("not json".utf8), key: "found.broken.sleepScore")
        try documents.writeData(Data(#"{"weekStartDay":"2026-09-14"}"#.utf8), key: "review.2026-09-14")

        let reopened = try context.reopen()
        let value30 = try await reopened.settings()
        XCTAssertEqual(value30, PatternSettings())
        let value31 = try await reopened.tests().first?.testDays
        XCTAssertEqual(value31, 14)
        let value32 = try await reopened.foundPatterns().map(\.key)
        XCTAssertEqual(value32, ["training.sleepScore"], "a damaged derived row is skipped, not fatal")
        let old = try await reopened.review(weekStartDay: "2026-09-14")
        XCTAssertEqual(old?.weekEndDay, "2026-09-20")
        XCTAssertEqual(old?.text, "")
        _ = store
    }

    func testInMemoryTwinFollowsTheSameRules() async throws {
        let memory = InMemoryPatternStore()
        let test = try F.startTest()
        await memory.saveTest(test)
        await memory.replaceFoundPatterns([earlySteps, strongLate, clearAlcohol])
        let value33 = await memory.foundPatterns().map(\.strength)
        XCTAssertEqual(value33, [.strong, .clear, .early])
        await memory.dismiss(clearAlcohol, at: F.date("2026-10-01"))
        let value34 = try await memory.visibleFoundPatterns().map(\.key)
        XCTAssertEqual(value34, [strongLate.key, earlySteps.key])
        await memory.replaceFoundPatterns([strongLate])
        let value35 = await memory.restore(key: clearAlcohol.key)
        XCTAssertEqual(value35, clearAlcohol)
        let value36 = await memory.foundPatterns().map(\.key)
        XCTAssertEqual(value36, [strongLate.key, clearAlcohol.key])
        await memory.saveReview(review())
        let value37 = await memory.reviews()
        XCTAssertEqual(value37, [review()])
        await memory.clearDerived()
        let value38 = await memory.tests()
        XCTAssertEqual(value38, [test])
        let value39 = await memory.foundPatterns().isEmpty
        XCTAssertTrue(value39)
        await memory.deleteAll()
        let value40 = await memory.tests().isEmpty
        XCTAssertTrue(value40)
    }
}

final class WeeklyReviewBuilderTests: XCTestCase {
    private typealias F = PatternFixtures
    private let monday = "2026-09-21"
    private var now: Date { F.date("2026-09-25", hour: 22) }

    private func pattern(_ candidate: PatternCandidate, _ metric: HabitOutcomeMetricID, _ strength: PatternStrength,
                         _ difference: Double, with: Int = 26, without: Int = 34) -> FoundPattern {
        FoundPattern(
            candidateID: candidate.id, habitID: candidate.habitID, title: candidate.title, predicate: candidate.predicate,
            metric: metric, strength: strength,
            effect: PatternEffect(adjustedDifference: difference, rawDifference: difference, withMean: nil, withoutMean: nil,
                                  intervalLower: nil, intervalUpper: nil, pValue: 0.001, practicalThreshold: 3, unit: metric.unit),
            nights: .init(with: with, without: without), windowEnd: "2026-09-25", algorithmVersion: "x", foundAt: now)
    }

    private func runningTest() throws -> PatternTest {
        var test = try F.startTest()
        for offset in [0, 1, 3, 4, 5] {
            let day = PatternDays.add(offset, to: F.testStart)!
            try test.keep(day: day, at: F.date(day, hour: 21))
        }
        return test
    }

    func testWeekStartFollowsTheCalendarWeek() {
        XCTAssertEqual(PatternDays.weekStart(containing: "2026-09-25"), "2026-09-21")
        XCTAssertEqual(PatternDays.weekStart(containing: "2026-09-21"), "2026-09-21")
        XCTAssertEqual(PatternDays.weekStart(containing: "2026-09-27"), "2026-09-21")
        XCTAssertEqual(PatternDays.weekStart(containing: "2026-09-25", firstWeekday: 1), "2026-09-20")
    }

    func testReviewNamesTheStrongPatternAndTheRunningTestAndEndsWithTheFootnote() throws {
        let late = pattern(F.lateDinner, .sleepScore, .strong, -12)
        let review = WeeklyReviewBuilder().build(weekStartDay: monday, found: [late], tests: [try runningTest()], now: now)
        XCTAssertEqual(review.text, """
        Sleep score was 12 points lower on nights after a late dinner than on other nights. That comes from 26 nights with and 34 without.

        Your 14-day test "Training day" is on day 6. You kept 5 of 6 nights.

        These compare your own nights. They do not show cause.
        """)
        XCTAssertEqual(review.weekStartDay, monday)
        XCTAssertEqual(review.weekEndDay, "2026-09-27")
        XCTAssertEqual(review.patternKeys, [late.key])
        XCTAssertEqual(review.testIDs.count, 1)
    }

    func testReviewIsDeterministic() throws {
        let found = [pattern(F.lateDinner, .sleepScore, .strong, -12), pattern(F.alcohol, .hrvRMSSD, .clear, -7)]
        let test = try runningTest()
        let builder = WeeklyReviewBuilder()
        XCTAssertEqual(builder.build(weekStartDay: monday, found: found, tests: [test], now: now),
                       builder.build(weekStartDay: monday, found: found.reversed(), tests: [test], now: now))
    }

    func testEarlyAndDismissedPatternsStayOutAndAnEmptyWeekSaysSo() {
        let early = pattern(F.steps, .sleepDuration, .early, 30, with: 6, without: 6)
        let clear = pattern(F.alcohol, .hrvRMSSD, .clear, -7)
        let empty = WeeklyReviewBuilder().build(weekStartDay: monday, found: [early, clear], dismissedKeys: [clear.key], now: now)
        XCTAssertEqual(empty.text, "Nothing clear yet. Loopr needs about 5 nights on each side before it says anything.")
        XCTAssertTrue(empty.patternKeys.isEmpty)
        XCTAssertEqual(WeeklyReviewBuilder().build(weekStartDay: monday, found: [], now: now).text, empty.text)
    }

    func testAtMostTwoPatternsAreMentioned() {
        let found = [pattern(F.lateDinner, .sleepScore, .strong, -12), pattern(F.alcohol, .hrvRMSSD, .clear, -7),
                     pattern(F.steps, .sleepDuration, .clear, 25)]
        let review = WeeklyReviewBuilder().build(weekStartDay: monday, found: found, now: now)
        XCTAssertEqual(review.patternKeys.count, 2)
        XCTAssertEqual(review.patternKeys.first, found[0].key, "strong first")
        XCTAssertTrue(review.text.contains("A second pattern. "))
        XCTAssertEqual(review.text.components(separatedBy: "These compare your own nights.").count - 1, 1, "one footnote")
    }

    func testAFinishedTestUsesItsVerdictWithoutRepeatingTheFootnote() throws {
        var test = try F.startTest()
        for offset in 0..<14 {
            let day = PatternDays.add(offset, to: F.testStart)!
            try test.keep(day: day, at: F.date(day, hour: 21))
        }
        let after = F.date("2026-10-04", hour: 8)
        test.refreshState(at: after)
        let metric = F.metric(.sleepScore, status: .clearAssociation, adjusted: 7.5, raw: 10, yes: 14, no: 30)
        let verdict = PatternTestVerdict.make(test: test, estimate: F.estimate(habit: test.habitID, metrics: [metric]), now: after)
        XCTAssertEqual(verdict.kind, .clear)
        let review = WeeklyReviewBuilder().build(weekStartDay: "2026-09-28", found: [], tests: [test], verdicts: [test.id: verdict], now: after)
        XCTAssertEqual(review.text, """
        Your 14-day test "Training day" has ended. Sleep score was 7.5 points higher on 14 nights you kept than on the 30 nights before.

        These compare your own nights. They do not show cause.
        """)
        let tooFew = PatternTestVerdict.make(test: test, estimate: nil, now: after)
        let thin = WeeklyReviewBuilder().build(weekStartDay: "2026-09-28", found: [], tests: [test], verdicts: [test.id: tooFew], now: after)
        XCTAssertEqual(thin.text, "Your 14-day test \"Training day\" has ended with too few nights to tell.")
        let earlier = WeeklyReviewBuilder().build(weekStartDay: "2026-09-14", found: [], tests: [test], now: after)
        XCTAssertEqual(earlier.text, "Nothing clear yet. Loopr needs about 5 nights on each side before it says anything.",
                       "a test that ended after the week does not belong in it")
    }

    func testReviewTextIsObservationalAndFreeOfDashesAndColons() throws {
        let review = WeeklyReviewBuilder().build(
            weekStartDay: monday, found: [pattern(F.lateDinner, .sleepScore, .strong, -12)], tests: [try runningTest()], now: now)
        for word in ["because", "caused", "leads to", "due to", "results in"] {
            XCTAssertFalse(review.text.lowercased().contains(word))
        }
        XCTAssertFalse(review.text.contains("\u{2014}"))
        XCTAssertFalse(review.text.contains(":"))
    }
}
