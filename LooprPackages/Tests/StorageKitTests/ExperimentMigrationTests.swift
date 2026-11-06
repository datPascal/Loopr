import Foundation
import StorageKit
import XCTest

private func insertProtocol(_ db: Database, id: String = "p1") throws {
    try db.execute(sql: "INSERT INTO routine_protocol VALUES (?, 'Sleep first', 1, 0, X'7B7D')", arguments: [id])
}

private func insertExperiment(_ db: Database, id: String = "e1", protocolID: String = "p1", design: String = "alternating",
                              designLength: Int? = nil, washout: Int = 0, minimum: Int = 3, planned: Int = 14,
                              direction: String = "higher", status: String = "running", endDay: String? = nil) throws {
    try db.execute(sql: """
        INSERT INTO experiment(id, protocol_id, title, intervention_name, rule_key, design, design_length, washout,
            minimum_nights, planned_nights, outcome_key, outcome_title, outcome_unit, outcome_direction, start_day,
            time_zone_identifier, created_at, status, end_day)
        VALUES (?, ?, 'Magnesium', 'magnesium', 'magnesium', ?, ?, ?, ?, ?, 'deepSleepMinutes', 'Deep sleep', 'min', ?,
            '2026-10-12', 'Europe/Berlin', 1, ?, ?)
        """, arguments: [id, protocolID, design, designLength, washout, minimum, planned, direction, status, endDay])
}

/// `storage-021-experiments` adds the experiment and nightly record tables. A database that already ran every earlier
/// migration must open, gain the tables and keep its data, and the tables must refuse rows that break their rules.
final class ExperimentMigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("experiment-migration-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    private func openDatabase() throws -> StorageDatabase {
        try StorageDatabase(url: makeURL(), applicationVersion: "experiment-migration-test")
    }

    func testTheMigrationIsRegisteredAfterTheLabsMigration() {
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "test")
        XCTAssertEqual(StorageMigrationIdentifier.experiments, "storage-021-experiments")
        let experiments = identifiers.firstIndex(of: StorageMigrationIdentifier.experiments)
        XCTAssertNotNil(experiments)
        XCTAssertLessThan(identifiers.firstIndex(of: StorageMigrationIdentifier.labs) ?? .max, experiments ?? 0)
        XCTAssertLessThan(identifiers.firstIndex(of: StorageMigrationIdentifier.routine) ?? .max, experiments ?? 0)
    }

    func testADatabaseThatRanEveryEarlierMigrationGainsTheExperimentTablesAndKeepsItsData() throws {
        let url = makeURL()
        let identifiers = StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "1.0 (21)")
        let index = try XCTUnwrap(identifiers.firstIndex(of: StorageMigrationIdentifier.experiments))
        let previous = identifiers[index - 1]

        let queue = try DatabaseQueue(path: url.path)
        try StorageMigrations.makeMigrator(applicationVersion: "1.0 (21)").migrate(queue, upTo: previous)
        try queue.write { db in
            XCTAssertFalse(try db.tableExists("experiment"))
            XCTAssertFalse(try db.tableExists("experiment_night"))
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version) VALUES (1, 1, 1, '2026-10-12', 24)")
            try insertProtocol(db)
            try db.execute(sql: "INSERT INTO routine_check VALUES ('p1', 'magnesium', '2026-10-12', 1, 'kept', 'manual', NULL, 0, 1)")
            try db.execute(sql: "INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, source, created_at) VALUES ('r1', 1, '2026-10-12', 'UTC', 'typed', 2)")
        }
        try queue.close()

        let upgraded = try StorageDatabase(url: url, applicationVersion: "1.0 (22)")
        defer { try? upgraded.databasePool.close() }
        XCTAssertFalse(try upgraded.hasPendingMigrations())
        try upgraded.read { db in
            for table in ExperimentStorageSchema.tableNames {
                XCTAssertTrue(try db.tableExists(table), "\(table) was not created on upgrade")
            }
            for index in ["experiment_one_running", "experiment_protocol"] {
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [index]), index)
            }
            for trigger in ["experiment_start_immutable", "experiment_status_forward"] {
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?", arguments: [trigger]), trigger)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2026-10-12'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM routine_check"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM experiment"), 0)
            let applied = try String.fetchAll(db, sql: "SELECT migration_identifier FROM storage_schema_metadata")
            XCTAssertTrue(applied.contains("storage-021-experiments"))
        }
        // Later migrations register after this one, so check it ran rather than that it ran last.
        XCTAssertTrue(try upgraded.schemaMetadata().contains { $0.migrationIdentifier == StorageMigrationIdentifier.experiments })
    }

    func testEveryRegisteredVersionStillConvergesOnTheCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("experiment-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(directory: directory)
        XCTAssertTrue(results.contains { $0.migrationIdentifier == StorageMigrationIdentifier.experiments })
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }

    func testAnExperimentRefusesRowsThatBreakItsRules() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in try insertProtocol(db) }
        func fails(_ id: String, _ body: @escaping (Database) throws -> Void, _ message: String) {
            XCTAssertThrowsError(try database.write { db in try body(db) }, message)
        }
        fails("a", { try insertExperiment($0, id: "a", design: "random") }, "an unknown design")
        fails("b", { try insertExperiment($0, id: "b", design: "blocks") }, "blocks need a length")
        fails("c", { try insertExperiment($0, id: "c", design: "alternating", designLength: 3) }, "alternating has no length")
        fails("d", { try insertExperiment($0, id: "d", design: "blocks", designLength: 0) }, "a block has a night")
        fails("e", { try insertExperiment($0, id: "e", washout: -1) }, "washout is 0 or more")
        fails("f", { try insertExperiment($0, id: "f", minimum: 1) }, "each arm needs at least 2 nights")
        fails("g", { try insertExperiment($0, id: "g", planned: 1) }, "at least 2 planned nights")
        fails("h", { try insertExperiment($0, id: "h", direction: "sideways") }, "a direction of benefit is higher or lower")
        fails("i", { try insertExperiment($0, id: "i", status: "paused") }, "an unknown status")
        fails("j", { try insertExperiment($0, id: "j", status: "running", endDay: "2026-10-20") }, "running has no end day")
        fails("k", { try insertExperiment($0, id: "k", status: "finished", endDay: nil) }, "finished has an end day")
        fails("l", { try insertExperiment($0, id: "l", protocolID: "nobody") }, "an experiment belongs to a protocol")
        XCTAssertNoThrow(try database.write { db in
            try insertExperiment(db, id: "ok1", design: "blocks", designLength: 7, status: "finished", endDay: "2026-11-08")
            try insertExperiment(db, id: "ok2", design: "beforeAfter", designLength: 5)
        })
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM experiment"), 2)
    }

    func testOnlyOneExperimentCanRun() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertProtocol(db)
            try insertExperiment(db, id: "first")
            try insertExperiment(db, id: "done", status: "stopped", endDay: "2026-10-15")
            try insertExperiment(db, id: "done2", status: "finished", endDay: "2026-10-25")
        }
        XCTAssertThrowsError(try database.write { db in try insertExperiment(db, id: "second") })
    }

    func testTheStartRecordCannotChangeAndAnEndedExperimentCannotMove() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertProtocol(db)
            try insertExperiment(db, id: "e1")
        }
        for column in ["outcome_key = 'x'", "outcome_title = 'x'", "outcome_unit = 'x'", "outcome_direction = 'lower'",
                       "design = 'blocks', design_length = 3", "washout = 1", "minimum_nights = 4", "planned_nights = 20",
                       "start_day = '2026-10-13'", "rule_key = 'x'", "title = 'x'", "intervention_name = 'x'",
                       "time_zone_identifier = 'UTC'", "created_at = 2", "protocol_id = 'p2'", "id = 'e2'"] {
            XCTAssertThrowsError(try database.write { db in try db.execute(sql: "UPDATE experiment SET \(column)") }, column)
        }
        // Running may become finished once, and then nothing moves.
        XCTAssertNoThrow(try database.write { db in try db.execute(sql: "UPDATE experiment SET status = 'finished', end_day = '2026-10-25'") })
        XCTAssertThrowsError(try database.write { db in try db.execute(sql: "UPDATE experiment SET status = 'running', end_day = NULL") })
        XCTAssertThrowsError(try database.write { db in try db.execute(sql: "UPDATE experiment SET end_day = '2026-10-26'") })
        XCTAssertEqual(try database.readString(sql: "SELECT outcome_key FROM experiment"), "deepSleepMinutes")
    }

    func testANightRefusesBadRowsKeepsAbsentAsNullAndGoesWithItsExperiment() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertProtocol(db)
            try insertExperiment(db)
        }
        func insert(_ day: String, arm: String = "on", washout: Int = 0, adherence: String = "kept", value: String = "NULL") throws {
            try database.write { db in
                try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, outcome_value, recorded_at) VALUES ('e1', ?, ?, ?, ?, \(value), 1)",
                               arguments: [day, arm, washout, adherence])
            }
        }
        XCTAssertThrowsError(try insert("2026-10-12", arm: "both"))
        XCTAssertThrowsError(try insert("2026-10-12", washout: 2))
        XCTAssertThrowsError(try insert("2026-10-12", adherence: "maybe"))
        XCTAssertNoThrow(try insert("2026-10-12"))
        XCTAssertThrowsError(try insert("2026-10-12"), "a night is recorded once per day")
        XCTAssertNoThrow(try insert("2026-10-13", arm: "off", value: "0"))
        XCTAssertThrowsError(try database.write { db in
            try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, recorded_at) VALUES ('nobody', '2026-10-14', 'on', 0, 'kept', 1)")
        }, "a night belongs to an experiment")

        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM experiment_night WHERE outcome_value IS NULL"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM experiment_night WHERE outcome_value = 0"), 1)
        XCTAssertEqual(try database.readString(sql: "SELECT other_values FROM experiment_night WHERE local_day = '2026-10-12'"), "{}")

        try database.write { db in try db.execute(sql: "DELETE FROM experiment WHERE id = 'e1'") }
        XCTAssertEqual(try database.tableRowCounts()["experiment_night"], 0)
    }

    func testDeletingTheProtocolRemovesItsExperimentsAndNights() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertProtocol(db, id: "p1")
            try insertProtocol(db, id: "p2")
            try insertExperiment(db, id: "gone", protocolID: "p1", status: "finished", endDay: "2026-10-25")
            try insertExperiment(db, id: "stays", protocolID: "p2")
            try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, recorded_at) VALUES ('gone', '2026-10-12', 'on', 0, 'kept', 1)")
            try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, recorded_at) VALUES ('stays', '2026-10-12', 'on', 0, 'kept', 1)")
            try db.execute(sql: "DELETE FROM routine_protocol WHERE id = 'p1'")
        }
        let counts = try database.tableRowCounts()
        XCTAssertEqual(counts["experiment"], 1)
        XCTAssertEqual(counts["experiment_night"], 1)
        XCTAssertEqual(try database.readString(sql: "SELECT id FROM experiment"), "stays")
    }

    func testDeleteAllAccountDataEmptiesTheExperimentTablesAndADayDeletionRemovesOnlyThatNight() throws {
        let database = try openDatabase()
        defer { try? database.databasePool.close() }
        try database.write { db in
            try insertProtocol(db)
            try insertExperiment(db)
            for day in ["2026-10-12", "2026-10-13"] {
                try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, recorded_at) VALUES ('e1', ?, 'on', 0, 'kept', 1)", arguments: [day])
            }
        }
        let seeded = try database.tableRowCounts()
        XCTAssertEqual(seeded["experiment"], 1)
        XCTAssertEqual(seeded["experiment_night"], 2)

        try database.delete(localDay: "2026-10-12")
        let afterDay = try database.tableRowCounts()
        XCTAssertEqual(afterDay["experiment"], 1, "a band day deletion must keep the experiment")
        XCTAssertEqual(afterDay["experiment_night"], 1)

        try database.deleteAllAccountData()
        let after = try database.tableRowCounts()
        for table in ExperimentStorageSchema.tableNames { XCTAssertEqual(after[table], 0, "\(table) survived deleteAllAccountData") }
    }

    func testABackupWithoutTheExperimentTablesIsNotAValidExportOrRestore() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        let exportURL = makeURL()
        try source.export(to: exportURL)

        let queue = try DatabaseQueue(path: exportURL.path)
        try queue.write { db in try db.execute(sql: "DROP TABLE experiment_night; DROP TABLE experiment;") }
        try queue.close()

        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "experiment-migration-test")) { error in
            guard case StorageLifecycleError.missingRequiredTables(let missing) = error else {
                return XCTFail("Expected missingRequiredTables, got \(error)")
            }
            XCTAssertEqual(Set(missing), Set(ExperimentStorageSchema.tableNames))
        }
    }

    func testAnExportedDatabaseRoundTripsItsExperiments() throws {
        let source = try openDatabase()
        defer { try? source.databasePool.close() }
        try source.write { db in
            try insertProtocol(db)
            try insertExperiment(db, id: "e1", design: "blocks", designLength: 7, status: "finished", endDay: "2026-11-08")
            try db.execute(sql: "INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, outcome_value, recorded_at) VALUES ('e1', '2026-10-12', 'on', 0, 'kept', 71.5, 1)")
        }
        let exportURL = makeURL()
        try source.export(to: exportURL)
        let live = try openDatabase()
        defer { try? live.databasePool.close() }
        let restored = try live.restore(from: exportURL, applicationVersion: "experiment-migration-test")
        defer { try? restored.databasePool.close() }
        XCTAssertEqual(try restored.readString(sql: "SELECT outcome_key FROM experiment"), "deepSleepMinutes")
        XCTAssertEqual(try restored.tableRowCounts()["experiment_night"], 1)
    }
}
