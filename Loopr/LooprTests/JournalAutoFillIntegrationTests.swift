import DomainKit
import Foundation
import JournalKit
import StorageKit
import Testing
import WorkoutKit
@testable import Loopr

@MainActor struct JournalAutoFillIntegrationTests {
    @Test func completedWorkoutFillsJournalAndOverrideSurvivesDatabaseReopenRestoreAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-auto-fill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite")
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let habits = try SQLiteHabitRepository(database: database)
        let workouts = try SQLiteWorkoutStore(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = DayIdentity(year: 2023, month: 11, day: 15), zone = "Australia/Perth"
        let question = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001221")!),
            source: .preset(catalogID: "trained_today"), name: "Trained today", question: "Trained today?", sortOrder: 0, createdAt: now)
        try await habits.saveDefinition(question)
        var workout = WorkoutRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000001222")!,
            identity: .init(canonicalKey: "journal-auto-fill-workout"), activity: .run, source: .manual,
            state: .completed, createdAt: now, startedAt: now.addingTimeInterval(-3600), endedAt: now)
        try await workouts.save(workout)
        let provider = AppJournalAutoFillProvider(readTraining: { @Sendable [workouts] in try await workouts.journalAutoFillRecords() })
        let service = JournalAutoFillService(store: habits, clock: IntegrationAutoFillClock(value: now))
        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        let filled = try #require(try await habits.dayRecord(for: day))
        #expect(filled.response(for: question.id)?.answer == .yes)
        #expect(filled.response(for: question.id)?.autoFillProvenance?.summary == "Running")
        workout.activity = .strength
        workout.lastCheckpointAt = now.addingTimeInterval(1)
        try await workouts.save(workout)
        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        #expect(try await habits.dayRecord(for: day)?.response(for: question.id)?.autoFillProvenance?.summary == "Strength training")
        try await workouts.removeChecked(id: workout.id)
        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        #expect(try await habits.dayRecord(for: day)?.response(for: question.id) == nil)
        try await workouts.save(workout)
        try await service.reconcile(provider.snapshot(for: day, timeZoneID: zone))
        let manual = HabitCheckInService(store: habits, dateProvider: IntegrationAutoFillClock(value: now))
        try await manual.clearAnswer(habitID: question.id, day: day)
        let reopenedDatabase = try StorageDatabase(url: url, applicationVersion: "test")
        let reopened = try SQLiteHabitRepository(database: reopenedDatabase)
        let exported = JournalExport(entries: [], includesJournalContent: true).includingHabits(
            definitions: try await reopened.definitions(), dayRecords: try await reopened.dayRecords())
        let restored = try JSONDecoder().decode(JournalExport.self, from: JSONEncoder().encode(exported))
        try await reopened.replaceSourceRecords(definitions: restored.habitDefinitions, dayRecords: restored.habitDayRecords)
        try await JournalAutoFillService(store: reopened, clock: IntegrationAutoFillClock(value: now)).reconcile(provider.snapshot(for: day, timeZoneID: zone))
        #expect(try await reopened.dayRecord(for: day)?.hasUserOverride(for: question.id) == true)
        #expect(try await reopened.dayRecord(for: day)?.response(for: question.id) == nil)
        try await reopened.deleteHabit(id: question.id)
        #expect(try await reopened.dayRecord(for: day)?.userOverrideHabitIDs?.isEmpty == true)
    }

    @Test func unreadableWorkoutSourceThrowsInsteadOfWithdrawingJournalAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-auto-fill-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("journal.sqlite"), applicationVersion: "test")
        let workouts = try SQLiteWorkoutStore(database: database)
        let documents = try StorageDocumentStore(database: database, namespace: "workouts")
        try documents.writeData(Data("malformed".utf8), key: "workout.broken")
        let provider = AppJournalAutoFillProvider(readTraining: { @Sendable [workouts] in try await workouts.journalAutoFillRecords() })
        await #expect(throws: (any Error).self) {
            _ = try await provider.snapshot(for: .init(year: 2023, month: 11, day: 14), timeZoneID: "Australia/Perth")
        }
    }

    @Test func plannedInterruptedAndUndatedWorkoutsAreNotTrainingAnswers() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [WorkoutLifecycleState.selectedActivity, .interruptedAndRecoverable, .discarded, .completed].enumerated().map { index, state in
            WorkoutRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1300))!,
                identity: .init(canonicalKey: "session-\(index)"), activity: .run, source: .manual,
                state: state, createdAt: now, startedAt: state == .completed ? nil : now, endedAt: now.addingTimeInterval(60))
        }
        let provider = AppJournalAutoFillProvider(readTraining: { @Sendable [records] in records })
        let snapshot = try await provider.snapshot(for: .init(year: 2023, month: 11, day: 15), timeZoneID: "Australia/Perth")
        #expect(snapshot.answers.isEmpty)
    }
}

private nonisolated struct IntegrationAutoFillClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}
