import Foundation
import StorageKit
import Testing
import TrainKit

struct CapacityStoreTests {
    typealias F = FitnessFixture
    let now = F.date(2026, 10, 24)

    func result(_ kind: CapacityTestKind, _ value: Double, side: CapacitySide? = nil, at date: Date? = nil,
                id: UUID = UUID()) throws -> CapacityResult {
        try CapacityResult(id: id, kind: kind, value: value, side: side ?? (kind.requiresSide ? .left : nil),
                           recordedAt: date ?? now, timeZoneIdentifier: "Europe/Berlin", createdAt: date ?? now)
    }

    @Test func everyKindSurvivesAReopenWithItsFields() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        let workoutID = UUID()
        let saved = [
            try result(.grip, 52.5, side: .right),
            try result(.deadHang, 84),
            try result(.sitToStand, 9.5),
            try result(.oneLegBalance, 18, side: .left),
            try CapacityResult(id: workoutID, kind: .heartRateRecovery, value: 31, recordedAt: now, timeZoneIdentifier: "Europe/Berlin",
                               workoutID: workoutID, algorithmVersion: "loopr.workout-hrr.1", createdAt: now)
        ]
        for item in saved { try store.save(item) }
        try context.database.databasePool.close()
        let database = try StorageDatabase(url: context.root.appendingPathComponent("train.sqlite"), applicationVersion: "train-tests")
        defer { try? database.databasePool.close() }
        let reopened = CapacityStore(database: database)
        for item in saved {
            #expect(try reopened.history(for: item.kind).results == [item])
            #expect(try reopened.latest(for: item.kind) == item)
        }
        #expect(try reopened.allResults().count == 5)
    }

    @Test func historyIsPerTestNewestFirst() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        let early = try result(.deadHang, 60, at: F.date(2026, 8, 1))
        let late = try result(.deadHang, 84, at: F.date(2026, 10, 1))
        let middle = try result(.deadHang, 70, at: F.date(2026, 9, 1))
        for item in [middle, early, late, try result(.grip, 50)] { try store.save(item) }
        let history = try store.history(for: .deadHang)
        #expect(history.results == [late, middle, early])
        #expect(history.latest == late && history.headline == 84)
        #expect(try store.history(for: .sitToStand).results.isEmpty)
        #expect(try store.latest(for: .sitToStand) == nil)
    }

    @Test func savingAnExistingIdReplacesItAndDeleteRemovesIt() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        let id = UUID()
        try store.save(try result(.deadHang, 60, id: id))
        let corrected = try result(.deadHang, 65, id: id)
        try store.save(corrected)
        #expect(try store.history(for: .deadHang).results == [corrected])
        try store.delete(id: id)
        #expect(try store.allResults().isEmpty)
        #expect(throws: CapacityError.missingResult) { try store.delete(id: id) }
    }

    @Test func anInvalidResultIsNotSaved() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        #expect(try store.allResults().isEmpty)
        // A result cannot be built invalid, so check the store's own gate with a hand-made row.
        #expect(throws: (any Error).self) {
            try context.database.write { db in
                try db.execute(sql: "INSERT INTO capacity_result VALUES ('x', 'grip', 5, 'kg', NULL, 1, 'UTC', 'typed', NULL, NULL, 1)")
            }
        }
        #expect(try store.allResults().isEmpty)
    }

    @Test func aWorkoutResultReplacesTheEarlierReadingOfTheSameWorkout() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        let workoutID = UUID()
        func recovery(_ value: Double, id: UUID) throws -> CapacityResult {
            try CapacityResult(id: id, kind: .heartRateRecovery, value: value, recordedAt: now, timeZoneIdentifier: "UTC",
                               workoutID: workoutID, algorithmVersion: "loopr.workout-hrr.1")
        }
        try store.save(try recovery(28, id: UUID()))
        let reread = try recovery(31, id: workoutID)
        try store.save(reread)
        #expect(try store.history(for: .heartRateRecovery).results == [reread])
        #expect(try context.database.tableRowCounts()["capacity_result"] == 1)
    }

    @Test func aGoalIsSavedPerTestAndReplacedOnTheNextSave() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        #expect(try store.goal(for: .grip) == nil && store.goals().isEmpty)
        let first = try CapacityGoal(kind: .grip, targetValue: 30, setAt: now)
        let hang = try CapacityGoal(kind: .deadHang, targetValue: 45, setAt: now)
        try store.save(first)
        try store.save(hang)
        #expect(try store.goal(for: .grip) == first)
        let raised = try CapacityGoal(kind: .grip, targetValue: 35, setAt: F.date(2026, 11, 1))
        try store.save(raised)
        #expect(try store.goals() == [.grip: raised, .deadHang: hang])
        try store.deleteGoal(for: .grip)
        #expect(try store.goal(for: .grip) == nil && store.goal(for: .deadHang) == hang)
    }

    @Test func goalsAndResultsLeaveWithDeleteAllAccountDataButNotWithADayDeletion() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        try store.save(try result(.grip, 52, side: .left, at: F.date(2024, 1, 1)))
        try store.save(try CapacityGoal(kind: .grip, targetValue: 30, setAt: now))
        try context.database.delete(localDay: "2024-01-01")
        let kept = try context.database.tableRowCounts()
        #expect(kept["capacity_result"] == 1 && kept["capacity_goal"] == 1)
        try context.database.deleteAllAccountData()
        let counts = try context.database.tableRowCounts()
        for table in CapacityStorageSchema.tableNames { #expect(counts[table] == 0, "\(table)") }
        #expect(try store.allResults().isEmpty && store.goals().isEmpty)
    }

    @Test func aStoredRowThatNoLongerMatchesTheModelIsReportedNotHidden() throws {
        let context = try TrainTestDatabase()
        let store = CapacityStore(database: context.database)
        try context.database.write { db in
            try db.execute(sql: "INSERT INTO capacity_result VALUES ('not-a-uuid', 'grip', 50, 'kg', 'left', 1, 'UTC', 'typed', NULL, NULL, 1)")
        }
        #expect(throws: CapacityError.corruptRow("id")) { try store.allResults() }
    }
}
