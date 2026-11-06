import DomainKit
import Foundation
import JournalKit
import StorageKit
import Testing
@testable import Loopr

private typealias F = PatternsFixtures4b

/// Everything Patterns keeps survives a relaunch: tests with their kept days, found patterns, dismissals with the
/// evidence they had, reviews and settings. Progress is computed from stored day keys, so it follows the clock.
@Suite(.serialized)
struct PatternsRestartTests {
    private struct Rig {
        let root: URL
        let url: URL
        func open(now: Date = F.now, data: PatternDataBox = PatternDataBox(), reminders: any PatternReminderScheduling = NoPatternReminders()) throws
            -> (engine: PatternsEngine, store: SQLitePatternStore, database: StorageDatabase) {
            let database = try StorageDatabase(url: url)
            let store = try SQLitePatternStore(database: database)
            return (F.engine(store: store, data: data, reminders: reminders, now: now), store, database)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func rig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Rig(root: root, url: root.appendingPathComponent("products.sqlite"))
    }

    @Test func aRunningTestKeepsItsDaysAcrossARelaunchAndProgressFollowsTheClock() async throws {
        let rig = try rig(); defer { rig.cleanup() }
        let first = try rig.open(reminders: SpyPatternReminders())
        let started = try await first.engine.startTest(candidateID: "food.lateMeal", metric: "deepSleepMinutes", reminderMinuteOfDay: 20 * 60 + 15)
        try await first.engine.keepToday(testID: started.id)

        // Three days later, in a new process.
        let later = F.now.addingTimeInterval(3 * 86_400)
        let second = try rig.open(now: later)
        let snapshot = try await second.engine.snapshot()
        let test = try #require(snapshot.running.first)
        #expect(test.id == started.id && test.keptDayKeys == ["2026-10-16"] && test.outcomeMetric == .deepSleepMinutes)
        let progress = test.progress(at: later)
        #expect(progress.dayNumber == 4 && progress.keptCount == 1 && progress.missedCount == 2 && progress.elapsedDays == 4)
        #expect(PatternsCopy.status(test: test, progress: progress, verdict: nil, locale: Locale(identifier: "en_GB")) == "Kept on 1 of 4 nights. Too early to tell. A reminder comes at 20:15.")
    }

    @Test func aTestThatEndedWhileTheAppWasClosedIsFinishedOnNextOpen() async throws {
        let rig = try rig(); defer { rig.cleanup() }
        let first = try rig.open()
        let reminders = SpyPatternReminders()
        let started = try await first.engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: nil)
        let afterTheEnd = F.now.addingTimeInterval(15 * 86_400)
        let second = try rig.open(now: afterTheEnd, reminders: reminders)
        let snapshot = try await second.engine.snapshot()
        let test = try #require(snapshot.tests.first)
        #expect(test.id == started.id && test.state == .completed && snapshot.running.isEmpty)
        #expect(reminders.cancelled == [started.id], "the finished test's reminders are cancelled")
        #expect(PatternsCopy.dayChip(test.progress(at: afterTheEnd), test: test) == "Finished")
    }

    @Test func foundPatternsDismissalsReviewsAndSettingsSurvive() async throws {
        let rig = try rig(); defer { rig.cleanup() }
        let first = try rig.open()
        try await first.store.replaceFoundPatterns([F.alcohol, F.lateDinner, F.legDay])
        try await first.engine.dismiss(key: F.legDay.key)
        try await first.engine.setLookForNewPatterns(true)
        let review = try #require(try await first.engine.ensureWeeklyReview())
        #expect(review.patternKeys.sorted() == [F.alcohol.key, F.lateDinner.key].sorted())

        let second = try rig.open()
        let snapshot = try await second.engine.snapshot()
        #expect(snapshot.found.map(\.key) == [F.alcohol.key, F.lateDinner.key])
        let dismissed = try #require(snapshot.dismissed.first)
        #expect(dismissed.key == F.legDay.key && dismissed.evidence == F.legDay, "the dismissal keeps the evidence it had")
        #expect(snapshot.review == review)
        #expect(snapshot.settings.lookForNewPatterns)

        // Restore after a relaunch brings back exactly what was dismissed.
        try await second.engine.restore(key: F.legDay.key)
        let third = try rig.open()
        let restored = try await third.engine.snapshot()
        #expect(restored.dismissed.isEmpty && restored.found.contains { $0 == F.legDay })
    }

    @Test func aDismissedPatternStaysOffTheListWhenDiscoveryRunsAgain() async throws {
        let rig = try rig(); defer { rig.cleanup() }
        let box = F.lateDinnerData()
        let first = try rig.open(data: box)
        let result = try #require(try await first.engine.discover(force: true))
        let key = try #require(result.headline.first { $0.key == "food.lateMeal.sleepScore" }?.key)
        try await first.engine.dismiss(key: key)

        let second = try rig.open(data: box)
        _ = try await second.engine.discover(force: true)
        let snapshot = try await second.engine.snapshot()
        #expect(!snapshot.found.contains { $0.key == key } && snapshot.dismissed.contains { $0.key == key })
    }

    @Test func aStoredTestFromAnOlderBuildStillDecodes() async throws {
        let rig = try rig(); defer { rig.cleanup() }
        let opened = try rig.open()
        let store = try StorageDocumentStore(database: opened.database, namespace: SQLitePatternStore.namespace)
        let id = UUID()
        // Only the fields a first build would have written.
        let json = #"{"id":"\#(id.uuidString)","habitID":{"rawValue":"\#(UUID().uuidString)"},"startDay":"2026-10-14"}"#
        try store.writeData(Data(json.utf8), key: "test.\(id.uuidString)")
        let stored = try #require(try await opened.store.test(id: id))
        #expect(stored.testDays == 14 && stored.baselineDays == 30 && stored.state == .running && stored.keptDays.isEmpty)
    }
}
