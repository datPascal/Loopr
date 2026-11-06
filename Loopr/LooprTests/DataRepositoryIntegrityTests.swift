import DataKit
import CycleKit
import DomainKit
import JournalKit
import AnalyticsKit
import Foundation
import StorageKit
import SettingsKit
import Testing
import WorkoutKit
@testable import Loopr

@MainActor
struct DataRepositoryIntegrityTests {
    @Test func concurrentHabitAnswersAndCompletionSurviveReopening() async throws {
        try await withStore { database, _, _ in
            let repository = try SQLiteHabitRepository(database: database)
            let day = DayIdentity(year: 2026, month: 10, day: 11)
            let habits = (0..<10).map {
                HabitDefinition(id: HabitID(rawValue: UUID()), source: .custom, name: "Habit \($0)",
                    question: "Done?", sortOrder: $0, createdAt: .now)
            }
            for habit in habits { try await repository.saveDefinition(habit) }
            try await HabitCheckInService(store: repository).answer(habitID: habits[0].id, day: day,
                timeZoneID: "Asia/Makassar", answer: .yes, source: .sameDay)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for habit in habits {
                    group.addTask {
                        try await HabitCheckInService(store: repository).answer(habitID: habit.id, day: day,
                            timeZoneID: "Asia/Makassar", answer: .yes, source: .sameDay)
                    }
                }
                group.addTask { try await HabitCheckInService(store: repository).finish(day: day) }
                try await group.waitForAll()
            }
            let reopened = try SQLiteHabitRepository(database: database)
            let record = try #require(try await reopened.dayRecord(for: day))
            #expect(Set(record.responses.map(\.habitID)) == Set(habits.map(\.id)))
            #expect(record.completedAt != nil)
        }
    }

    @Test func cycleEstimateUsesDistinctStartsUpToSelectedDay() async throws {
        try await withStore { database, _, _ in
            let repository = try SQLiteCycleRepository(database: database)
            try await repository.optIn()
            for day in ["2026-10-01", "2026-10-01", "2026-10-01", "2026-11-01"] {
                _ = try await repository.log(CycleEntry(day: day, kind: .periodStart))
            }
            let estimate = try await repository.estimate(today: "2026-10-11")
            #expect(estimate.sampleSize == 1)
            #expect(estimate.nextPeriodDay == "2026-10-29")
            #expect(estimate.uncertainty.contains("Only one"))
        }
    }

    private func record(_ id: String) -> DataRecord {
        DataRecord(id: id, day: "2026-10-11", table: "metrics", payload: ["value": "42"], provenance: .imported)
    }

    private func withStore(_ test: (StorageDatabase, SQLiteDataRepository, StorageDocumentStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-data-integrity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("data.sqlite"), applicationVersion: "test")
        try await test(database, SQLiteDataRepository(database: database), StorageDocumentStore(database: database, namespace: "data"))
    }

    @Test
    func malformedRestoreAndPersistedDuplicatesCannotOverwriteGoodDataOrCrashALookup() async throws {
        try await withStore { _, repository, documents in
            let original = record("original"), duplicate = record("duplicate")
            try await repository.insert(original)
            let malformed = DataBackup(records: [duplicate, duplicate])
            await #expect(throws: DataError.invalidBackup) { try await repository.restoreChecked(malformed) }
            #expect(try await repository.recordsChecked() == [original])

            // A file written by an older version can already contain duplicates.
            try documents.write(malformed, key: "records")
            await #expect(throws: DataError.invalidBackup) { _ = try await repository.recordsChecked() }
            await #expect(throws: DataError.invalidBackup) { try await repository.insert(original) }
            #expect(try documents.read(DataBackup.self, key: "records") == malformed)
        }
    }

    @Test
    func failedImportRollsBackItsReceiptAndRecordsTogether() async throws {
        try await withStore { database, repository, documents in
            let original = record("original")
            try await repository.insert(original)
            let preview = try await repository.validatedPreview(source: .whoopCSV, incoming: [record("new")])
            try database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_records BEFORE INSERT ON loopr_product_document
                    WHEN NEW.namespace = 'data' AND NEW.document_key = 'records'
                    BEGIN SELECT RAISE(ABORT, 'injected records failure'); END
                    """)
            }
            await #expect(throws: (any Error).self) { _ = try await repository.beginImport(preview) }
            #expect(try await repository.recordsChecked() == [original])
            #expect(try documents.keys() == ["records"])
        }
    }

    @Test
    func failedRollbackKeepsImportedDataAndItsReceiptForRetry() async throws {
        try await withStore { database, repository, documents in
            try await repository.insert(record("original"))
            let preview = try await repository.validatedPreview(source: .whoopCSV, incoming: [record("new")])
            let receipt = try await repository.beginImport(preview)
            let imported = try await repository.recordsChecked()
            try database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_receipt_removal BEFORE DELETE ON loopr_product_document
                    WHEN OLD.namespace = 'data' AND OLD.document_key LIKE 'receipt.%'
                    BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
                    """)
            }
            await #expect(throws: (any Error).self) { try await repository.rollback(receipt) }
            #expect(try await repository.recordsChecked() == imported)
            #expect(try documents.keys().contains("receipt.\(receipt.token.uuidString)"))
            try database.write { try $0.execute(sql: "DROP TRIGGER reject_receipt_removal") }
            try await repository.rollback(receipt)
            #expect(try await repository.recordsChecked() == [record("original")])
        }
    }

    @Test
    func corruptReanalysisDoesNotPartiallyDeleteADay() async throws {
        try await withStore { _, repository, documents in
            let original = record("original")
            try await repository.insert(original)
            try documents.writeData(Data("invalid JSON".utf8), key: "reanalysis")
            await #expect(throws: (any Error).self) { try await repository.deleteDayChecked(original.day) }
            #expect(try await repository.recordsChecked() == [original])
        }
    }

    @Test
    func checkedMethodsPropagateErrorsThroughConcreteAndProtocolCalls() async throws {
        try await withStore { _, repository, documents in
            try documents.writeData(Data("invalid JSON".utf8), key: "records")
            let checked: any CheckedDataStore = repository
            await #expect(throws: (any Error).self) { _ = try await checked.recordsChecked() }
            await #expect(throws: (any Error).self) { _ = try await repository.recordsChecked() }
            await #expect(throws: (any Error).self) { _ = try await repository.exportBackupChecked() }
            await #expect(throws: (any Error).self) { _ = try await repository.exportJSONChecked() }
            await #expect(throws: (any Error).self) { _ = try await repository.exportDayChecked("2026-10-11") }
            await #expect(throws: (any Error).self) { _ = try await repository.inventorySnapshotChecked() }
            await #expect(throws: (any Error).self) {
                _ = try await repository.reanalyzeChecked(day: "2026-10-11", algorithmVersion: 2)
            }
            #expect(try documents.readData(key: "records") == Data("invalid JSON".utf8))
        }
    }

    @Test
    func failedWorkoutDeletionIsReportedAndRetainsTheSelectedRecord() async throws {
        try await withStore { database, _, _ in
            let store = try SQLiteWorkoutStore(database: database)
            let workout = WorkoutFixtures.completedRun
            try await store.save(workout)
            let controller = WorkoutSessionController(store: store)
            _ = try await controller.select(id: workout.id)
            try database.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_workout_deletion BEFORE DELETE ON loopr_product_document
                    WHEN OLD.namespace = 'workouts'
                    BEGIN SELECT RAISE(ABORT, 'injected workout delete failure'); END
                    """)
            }
            await #expect(throws: (any Error).self) { try await controller.delete(id: workout.id) }
            #expect(await controller.selectedWorkoutID() == workout.id)
            #expect(await store.workout(id: workout.id) == workout)
        }
    }

    @Test
    func recoveryCacheCannotUndoEditsOrResurrectADeletedWorkout() async throws {
        try await withStore { database, _, _ in
            let store = try SQLiteWorkoutStore(database: database)
            var workout = WorkoutFixtures.completedRun
            let start = try #require(workout.startedAt), end = try #require(workout.endedAt)
            workout.activity = .cycle
            workout.endedAt = end.addingTimeInterval(60)
            try await store.save(workout)
            let assessment = TimedHeartRateRecovery(firstMinute: nil, secondMinute: nil, reason: "fixture")
            try await store.cacheHeartRateRecovery(assessment, workoutID: workout.id, startedAt: start, endedAt: end)
            #expect(await store.workout(id: workout.id) == workout)
            try await store.cacheHeartRateRecovery(assessment, workoutID: workout.id, startedAt: start, endedAt: end.addingTimeInterval(60))
            #expect(await store.workout(id: workout.id)?.heartRateRecovery == assessment)
            #expect(await store.workout(id: workout.id)?.activity == .cycle)
            try await store.removeChecked(id: workout.id)
            try await store.cacheHeartRateRecovery(assessment, workoutID: workout.id, startedAt: start, endedAt: end.addingTimeInterval(60))
            #expect(await store.workout(id: workout.id) == nil)
        }
    }

    @Test
    func checkedSettingsResetCannotReportSuccessAfterStorageCloses() async throws {
        try await withStore { database, _, _ in
            let settings = try SQLiteSettingsRepository(database: database)
            let protocolSettings: any SettingsRepository = settings
            try database.databasePool.close()
            await #expect(throws: (any Error).self) { try await settings.resetProfileChecked() }
            await #expect(throws: (any Error).self) { try await settings.resetAllChecked() }
            await #expect(throws: (any Error).self) { try await protocolSettings.resetAllChecked() }
        }
    }
}
