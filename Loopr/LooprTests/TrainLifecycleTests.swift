import DataKit
import Foundation
import StorageKit
import Testing
import TrainKit
@testable import Loopr

@MainActor struct TrainLifecycleTests {
    private nonisolated static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private nonisolated static let zone = "Australia/Perth"

    private struct Seeded {
        let template: WorkoutTemplate
        let program: Program
        let custom: ExerciseDefinition
        let session: TrainSession
    }

    /// One of each Train record for Alex, with logged sets, so every table has a row.
    private static func seed(_ store: TrainStore, on date: Date = date) throws -> Seeded {
        let bench = ExerciseRef(key: "barbell-bench-press", name: "Barbell bench press")
        let planned = TemplateExercise(exercise: bench, sets: 4, repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150)
        let template = try store.saveTemplate(WorkoutTemplate(name: "Upper A", weekdays: [.tuesday], exercises: [planned]), at: date)
        let program = try store.saveProgram(Program(name: "Strength block", status: .active, startDay: "2023-10-30",
            weeks: [[ProgramSlot(weekday: .tuesday, templateID: template.id, kind: .normal, tag: "UA")]]), at: date)
        let custom = try store.saveCustomExercise(.custom(name: "Sled push", equipment: "sled"))
        let sets = [LoggedSet(loadKg: 80, reps: 8, rpe: 7, loggedAt: date.addingTimeInterval(120), prefillSource: .template),
                    LoggedSet(loadKg: 80, reps: 7, rpe: 8, loggedAt: date.addingTimeInterval(300), prefillSource: .previousSet)]
        let session = try store.saveSession(TrainSession(templateID: template.id, name: "Upper A", startedAt: date,
            timeZoneIdentifier: zone, endedAt: date.addingTimeInterval(3_600), status: .completed,
            exercises: [SessionExercise(planned: planned, status: .done, sets: sets)]))
        return Seeded(template: template, program: program, custom: custom, session: session)
    }

    private static func makeDatabase(_ name: String) throws -> (StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        return (try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
    }

    @Test func jsonBackupRestoresTrainAndKeepsTrainWhenReadingAnOlderBackup() async throws {
        let (database, root) = try Self.makeDatabase("TrainJSONTests")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? database.databasePool.close() }
        let repository = try SQLiteDataRepository(database: database)
        let store = TrainStore(database: database)
        let seeded = try Self.seed(store)

        let encoded = try await repository.exportJSONChecked()
        let backup = try JSONDecoder().decode(DataBackup.self, from: encoded)
        #expect(backup.schemaVersion == 3)
        #expect(backup.train?.templates == [seeded.template])
        #expect(backup.train?.programs == [seeded.program])
        #expect(backup.train?.customExercises == [seeded.custom])
        #expect(backup.train?.sessions == [seeded.session])

        try await repository.completeDeletionChecked()
        #expect(try store.exportArchive() == TrainArchive())
        try await repository.restoreChecked(backup)
        #expect(try store.exportArchive() == backup.train)
        #expect(try store.session(id: seeded.session.id)?.exercises[0].sets.count == 2)

        // Version 1 and version 2 files carry no train section, so a restore leaves Train alone.
        let one = try JSONDecoder().decode(DataBackup.self, from: Data(#"{"schemaVersion":1,"records":[]}"#.utf8))
        try await repository.restoreChecked(one)
        #expect(try store.exportArchive() == backup.train)
        let twoJSON = #"{"schemaVersion":2,"records":[],"food":{"schemaVersion":3,"meals":[],"photos":[]}}"#
        let two = try JSONDecoder().decode(DataBackup.self, from: Data(twoJSON.utf8))
        try await repository.restoreChecked(two)
        #expect(try store.exportArchive() == backup.train)

        // A bad train section is rejected before any table changes.
        let duplicate = TrainArchive(templates: [seeded.template, seeded.template])
        await #expect(throws: (any Error).self) { try await repository.restoreChecked(DataBackup(records: [], train: duplicate)) }
        #expect(try store.exportArchive() == backup.train)

        // A failing insert rolls the whole restore back, records and train together.
        let keep = DataRecord(id: "keep", day: "2023-11-15", table: "metrics", payload: ["value": "42"], provenance: .imported)
        try await repository.insert(keep)
        try database.write { db in try db.execute(sql: "CREATE TRIGGER deny_train_insert BEFORE INSERT ON workout_session BEGIN SELECT RAISE(ABORT, 'restore failure'); END") }
        await #expect(throws: (any Error).self) { try await repository.restoreChecked(backup) }
        #expect(try store.exportArchive() == backup.train)
        #expect(try await repository.recordsChecked() == [keep])
        try database.write { db in try db.execute(sql: "DROP TRIGGER deny_train_insert") }

        let fixture = DataRepository()
        try await fixture.restore(backup)
        #expect(await fixture.exportBackup() == backup)
    }

    @Test func existingDayDeletionAlsoDeletesThatDaysSessionsAndRollsBackOnFailure() async throws {
        let (database, root) = try Self.makeDatabase("TrainDayDeleteTests")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? database.databasePool.close() }
        let repository = try SQLiteDataRepository(database: database)
        let store = TrainStore(database: database)
        let seeded = try Self.seed(store)
        let nextDay = try store.saveSession(TrainSession(name: "Upper A", startedAt: Self.date.addingTimeInterval(86_400),
            timeZoneIdentifier: Self.zone, endedAt: Self.date.addingTimeInterval(90_000), status: .completed))
        let record = DataRecord(id: "day-record", day: seeded.session.localDay, table: "metrics", payload: ["value": "42"], provenance: .imported)
        try await repository.insert(record)

        let dayExport = try await repository.exportDayChecked(seeded.session.localDay)
        #expect(dayExport.train?.sessions == [seeded.session])
        #expect(dayExport.train?.templates.isEmpty == true)

        try database.write { db in try db.execute(sql: "CREATE TRIGGER deny_session_delete BEFORE DELETE ON workout_session BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END") }
        let before = try StorageDocumentStore(database: database, namespace: "data").readData(key: "records")
        await #expect(throws: (any Error).self) { try await repository.deleteDayChecked(seeded.session.localDay) }
        #expect(try store.sessions().count == 2)
        #expect(try StorageDocumentStore(database: database, namespace: "data").readData(key: "records") == before)
        try database.write { db in try db.execute(sql: "DROP TRIGGER deny_session_delete") }

        try await repository.deleteDayChecked(seeded.session.localDay)
        #expect(try store.sessions() == [nextDay])
        #expect(try database.tableRowCounts()["workout_set"] == 0)
        #expect(try store.templates() == [seeded.template])
        #expect(try store.programs() == [seeded.program])
        #expect(try store.customExercises() == [seeded.custom])
        #expect(try await repository.recordsChecked().isEmpty)
    }

    @Test func fullDeletionAuditCoversEveryTrainTable() async throws {
        let (database, root) = try Self.makeDatabase("TrainFullDeleteTests")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? database.databasePool.close() }
        let repository = try SQLiteDataRepository(database: database)
        _ = try Self.seed(TrainStore(database: database))
        let before = try database.tableRowCounts()
        for table in TrainStorageSchema.tableNames { #expect((before[table] ?? 0) > 0, "\(table) was not seeded") }

        try await repository.completeDeletionChecked()
        var after = try database.tableRowCounts()
        for table in TrainStorageSchema.tableNames { #expect(after[table] == 0, "\(table) survived completeDeletionChecked") }

        _ = try Self.seed(TrainStore(database: database))
        try database.deleteAllAccountData()
        after = try database.tableRowCounts()
        for table in TrainStorageSchema.tableNames { #expect(after[table] == 0, "\(table) survived deleteAllAccountData") }

        _ = try Self.seed(TrainStore(database: database))
        try database.deleteAllData()
        after = try database.tableRowCounts()
        for table in TrainStorageSchema.tableNames { #expect(after[table] == 0, "\(table) survived deleteAllData") }
    }

    @Test func inventoryAndEverythingExportIncludeTrainTables() throws {
        let (database, root) = try Self.makeDatabase("TrainExportTests")
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? database.databasePool.close() }
        let store = TrainStore(database: database)
        let seeded = try Self.seed(store)
        let stores = YourDataStores(ledgers: [.init(name: "products", database: database)],
            supportDirectory: root, photosDirectory: root.appendingPathComponent("FoodPhotos"))
        #expect(try stores.inventory().contentBytes[.training, default: 0] > 0)

        let exporter = YourDataExporter(stores: stores,
            defaultsData: try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0), temporaryDirectory: root)
        let output = root.appendingPathComponent("export")
        try exporter.stage(.everything, at: output, now: Self.date)
        let snapshot = try StorageDatabase(url: output.appendingPathComponent("products/products.sqlite"))
        defer { try? snapshot.databasePool.close() }
        #expect(try TrainStore(database: snapshot).exportArchive() == store.exportArchive())
        for table in TrainStorageSchema.tableNames {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("products/\(table).json").path), "\(table).json missing")
        }
        let sets = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("products/workout_set.json"))) as? [[String: Any]])
        #expect(sets.count == seeded.session.exercises[0].sets.count)

        try database.deleteAllAccountData()
        #expect(try stores.inventory().contentBytes[.training, default: 0] == 0)
    }
}
