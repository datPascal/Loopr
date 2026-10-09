import Foundation
import StorageKit
import XCTest

private enum StorageLifecycleTestSupport {
    static func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprStorageLifecycle-\(name)")
            .appendingPathExtension("sqlite")
    }

    static func remove(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        try? manager.removeItem(atPath: "\(url.path)-wal")
        try? manager.removeItem(atPath: "\(url.path)-shm")
    }

    static func open(_ name: String) throws -> (StorageDatabase, URL) {
        let url = url(name)
        remove(url)
        return (try StorageDatabase(url: url, applicationVersion: "4.0 (40)"), url)
    }

    static func contentSnapshot(_ database: StorageDatabase) throws -> [String: [[DatabaseValue]]] {
        let tableNames = try database.schemaSnapshot().tables.map(\.name)
        return try database.read { db in
            try Dictionary(uniqueKeysWithValues: tableNames.map { tableName in
                let escaped = tableName.replacingOccurrences(of: "\"", with: "\"\"")
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \"\(escaped)\" ORDER BY rowid")
                return (tableName, rows.map { Array($0.databaseValues) })
            })
        }
    }

    static func seedEveryTable(_ database: StorageDatabase) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO decoded_second(
                    physiological_timestamp, band_counter, absolute_timestamp,
                    local_day, record_version, subsecond_ticks, heart_rate,
                    gravity_x, gravity_y, gravity_z, raw_payload
                ) VALUES (1704067200, 7, 1704067200, '2024-01-01', 1, 2, 68,
                          0.1, 0.2, 0.3, X'0102')
                """)
            let decodedID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM decoded_second WHERE physiological_timestamp = 1704067200"
            )!
            try db.execute(sql: """
                INSERT INTO rr_beat(
                    decoded_second_id, beat_index, rr_milliseconds,
                    beat_timestamp_milliseconds
                ) VALUES (?, 0, 880, 1704067200123)
                """, arguments: [decodedID])
            try db.execute(sql: """
                INSERT INTO raw_archive(
                    raw_payload, packet_type, record_version, band_counter,
                    physiological_timestamp, captured_at, reason
                ) VALUES (X'0304', 9, 1, 7, 1704067200, 1704067200, 'unsupported')
                """)
            try db.execute(sql: """
                UPDATE sync_cursor
                SET token = X'0102030405060708', counter_high_water = 7,
                    timestamp_high_water = 1704067200, updated_at = 1704067200
                WHERE id = 1
                """)
            try db.execute(sql: """
                INSERT INTO sync_batch(
                    batch_id, state, token, received_at, updated_at, error
                ) VALUES ('batch-export', 'committed', X'0102030405060708',
                          1704067200, 1704067201, NULL)
                """)
            try db.execute(sql: """
                INSERT INTO sync_failure(
                    batch_id, stage, retry_classification, reason, created_at
                ) VALUES ('batch-export', 'decode', 'retryable', 'fixture', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO day_result(
                    day_id, algorithm_version, status, payload, computed_at
                ) VALUES ('2024-01-01', 1, 'complete', X'05', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO metric_series(local_day, metric_key, value, updated_at)
                VALUES ('2024-01-01', 'heart_rate', 68.0, 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO baseline(baseline_key, version, payload, updated_at)
                VALUES ('resting-heart-rate', 1, X'06', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO workout(
                    id, kind, status, started_at, ended_at, payload, updated_at
                ) VALUES ('workout-export', 'detected', 'complete',
                          1704067200, 1704067260, X'07', 1704067260)
                """)
            try db.execute(sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('workout-export', 0, 1704067200000, 13.75, 100.50, 4.0)
                """)
            try db.execute(sql: """
                INSERT INTO health_import_cursor(source, anchor, updated_at)
                VALUES ('healthkit', X'08', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO health_export_item(
                    object_id, object_type, status, error, updated_at
                ) VALUES ('health-object-export', 'heartRate', 'exported', NULL, 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO notification_claim(claim_key, claimed_at)
                VALUES ('daily-summary-2024-01-01', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO surface_generation(id, generation, snapshot, published_at)
                VALUES (1, 1, X'09', 1704067200)
                """)
            try db.execute(sql: """
                INSERT INTO gen5_research_frames(
                    model, connection_generation, burst_id, ordinal, raw_frame,
                    decode_succeeded, decode_outcome, marker, token
                ) VALUES ('MGX', 1, 'burst-export', 0, X'10', 1, 'decoded', X'11', X'0102030405060708')
                """)
            try db.execute(sql: """
                INSERT INTO gen5_raw_archive(model, raw_payload, record_version)
                VALUES ('MGX', X'12', 18)
                """)
            try db.execute(sql: """
                INSERT INTO gen5_v18_canonical(
                    model, physiological_timestamp, record_index, heart_rate,
                    rr_le, gravity_x, gravity_y, gravity_z
                ) VALUES ('MGX', 1704067200, 1, 68, X'1303', 0.1, 0.2, 0.3)
                """)
            try db.execute(sql: """
                INSERT INTO gen5_committed_batch(
                    model, connection_generation, burst_id, token
                ) VALUES ('MGX', 1, 'burst-export', X'0102030405060708')
                """)
            try db.execute(sql: """
                INSERT INTO gen5_capability_state(model, capability, state, firmware)
                VALUES ('MGX', 'history-v18', 'validated', '1.0.0')
                """)
            try db.execute(sql: """
                INSERT INTO gen5_band_profile(
                    peripheral_id, model, model_confidence, service_uuid, name,
                    hello_identity, firmware
                ) VALUES ('band-export', 'MGX', 1, 'service', 'Loopr', X'14', '1.0.0')
                """)
            try db.execute(sql: """
                INSERT INTO release_action_audit(action, scope, performed_at)
                VALUES ('export', 'full-account', 1704067200)
                """)
        }
    }

    static func seedDay(_ database: StorageDatabase, localDay: String, epoch: Int64, suffix: Int) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO decoded_second(
                    physiological_timestamp, band_counter, absolute_timestamp,
                    local_day, record_version, subsecond_ticks, heart_rate,
                    gravity_x, gravity_y, gravity_z, raw_payload
                ) VALUES (?, ?, ?, ?, 1, 0, 60, 0, 0, 0, ?)
                """, arguments: [epoch, suffix, epoch, localDay, Data([UInt8(suffix)])])
            let decodedID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM decoded_second WHERE physiological_timestamp = ?",
                arguments: [epoch]
            )!
            try db.execute(sql: """
                INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds,
                                    beat_timestamp_milliseconds)
                VALUES (?, 0, 900, ?)
                """, arguments: [decodedID, epoch * 1000])
            try db.execute(sql: """
                INSERT INTO raw_archive(raw_payload, packet_type, record_version,
                                        band_counter, physiological_timestamp,
                                        captured_at, reason)
                VALUES (?, 1, 1, ?, ?, ?, 'day fixture')
                """, arguments: [Data([UInt8(suffix + 10)]), suffix, epoch, epoch])
            try db.execute(sql: """
                INSERT INTO day_result(day_id, algorithm_version, status, payload, computed_at)
                VALUES (?, 1, 'complete', ?, ?)
                """, arguments: [localDay, Data([UInt8(suffix + 20)]), epoch])
            try db.execute(sql: """
                INSERT INTO metric_series(local_day, metric_key, value, updated_at)
                VALUES (?, 'heart_rate', ?, ?)
                """, arguments: [localDay, Double(60 + suffix), epoch])
            let workoutID = "workout-\(localDay)"
            try db.execute(sql: """
                INSERT INTO workout(id, kind, status, started_at, ended_at, payload, updated_at)
                VALUES (?, 'manual', 'complete', ?, ?, ?, ?)
                """, arguments: [workoutID, epoch, epoch + 60, Data([UInt8(suffix + 30)]), epoch + 60])
            try db.execute(sql: """
                INSERT INTO route_point(workout_id, sequence, timestamp_milliseconds,
                                       latitude, longitude, altitude)
                VALUES (?, 0, ?, 13.0, 100.0, 1.0)
                """, arguments: [workoutID, epoch * 1000])
        }
    }
}

final class ExportTests: XCTestCase {
    func test_exportCopiesEveryLedgerTableRowForRow() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("export-source")
        let exportURL = StorageLifecycleTestSupport.url("export-destination")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        let exportedURL = try source.export(to: exportURL)
        XCTAssertEqual(exportedURL.standardizedFileURL, exportURL.standardizedFileURL)

        let exported = try StorageDatabase(url: exportURL, applicationVersion: "4.0 (40)")
        defer { try? exported.databasePool.close() }
        let sourceCounts = try source.tableRowCounts()
        let exportedCounts = try exported.tableRowCounts()
        XCTAssertEqual(sourceCounts, exportedCounts)
        XCTAssertEqual(
            try StorageLifecycleTestSupport.contentSnapshot(source),
            try StorageLifecycleTestSupport.contentSnapshot(exported)
        )
        let dataTables = Set(sourceCounts.keys).subtracting([
            StorageMigrations.metadataTable,
            "grdb_migrations"
        ])
        for tableName in dataTables {
            XCTAssertGreaterThan(sourceCounts[tableName] ?? 0, 0, tableName)
        }
        XCTAssertEqual(try source.schemaSnapshot(), try exported.schemaSnapshot())
    }
}

final class RestoreTests: XCTestCase {
    func test_restoreReplacesLiveDatabaseWithValidatedExport() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("restore-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-export")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        let expectedContent = try StorageLifecycleTestSupport.contentSnapshot(source)
        try source.export(to: exportURL)
        let expected = try StorageDatabase(url: exportURL, applicationVersion: "4.0 (40)")
        let expectedCounts = try expected.tableRowCounts()
        try expected.databasePool.close()

        try source.write { db in
            try db.execute(sql: "INSERT INTO raw_archive(raw_payload, captured_at, reason) VALUES (X'AAAA', 1, 'live mutation')")
        }
        let restored = try source.restore(from: exportURL, applicationVersion: "4.0 (40)")
        defer { try? restored.databasePool.close() }
        XCTAssertEqual(try restored.tableRowCounts(), expectedCounts)
        XCTAssertEqual(try StorageLifecycleTestSupport.contentSnapshot(restored), expectedContent)
        XCTAssertEqual(try restored.integrityCheck(), .ok)
    }

    func test_restoreAcceptsCompatibleExportCreatedByOlderApplicationVersion() throws {
        let (live, liveURL) = try StorageLifecycleTestSupport.open("restore-newer-live")
        let oldURL = StorageLifecycleTestSupport.url("restore-older-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-older-export")
        StorageLifecycleTestSupport.remove(oldURL)
        StorageLifecycleTestSupport.remove(exportURL)
        let old = try StorageDatabase(url: oldURL, applicationVersion: "3.0 (30)")
        defer {
            try? live.databasePool.close()
            try? old.databasePool.close()
            StorageLifecycleTestSupport.remove(liveURL)
            StorageLifecycleTestSupport.remove(oldURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(old)
        try old.export(to: exportURL)
        let restored = try live.restore(from: exportURL, applicationVersion: "4.0 (40)")
        defer { try? restored.databasePool.close() }

        XCTAssertEqual(
            try restored.readInteger(sql: "SELECT COUNT(*) FROM decoded_second"),
            1
        )
        XCTAssertEqual(try restored.integrityCheck(), .ok)
        XCTAssertTrue(try restored.schemaMetadata().allSatisfy { !$0.applicationVersion.isEmpty })
    }

    func test_corruptedRestoreLeavesLiveDatabaseUntouched() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("restore-corrupt-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-corrupt-export")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        try source.export(to: exportURL)
        let beforeCounts = try source.tableRowCounts()
        let beforeBytes = try Data(contentsOf: sourceURL)
        let exportBytes = try Data(contentsOf: exportURL)
        XCTAssertGreaterThan(exportBytes.count, 2)
        try Data(exportBytes.prefix(exportBytes.count / 2)).write(to: exportURL, options: .atomic)

        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "4.0 (40)"))
        XCTAssertEqual(try source.tableRowCounts(), beforeCounts)
        XCTAssertEqual(try Data(contentsOf: sourceURL), beforeBytes)
    }

    func test_restoreRejectsSchemaIncompatibleCandidateBeforeSwap() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("restore-schema-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-schema-export")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        try source.export(to: exportURL)

        var configuration = Configuration()
        configuration.journalMode = .wal
        let candidate = try DatabaseQueue(path: exportURL.path, configuration: configuration)
        try candidate.write { db in
            try db.execute(sql: "ALTER TABLE workout ADD COLUMN incompatible_fixture TEXT")
        }
        try candidate.close()

        let beforeCounts = try source.tableRowCounts()
        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "4.0 (40)")) { error in
            XCTAssertEqual(
                error as? StorageLifecycleError,
                .schemaMismatch(migrationIdentifier: "restore-current-schema")
            )
        }
        XCTAssertEqual(try source.tableRowCounts(), beforeCounts)
    }

    func test_restoreRejectsForeignKeyViolationBeforeSwap() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("restore-fk-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-fk-export")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        try source.export(to: exportURL)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.journalMode = .wal
        let candidate = try DatabaseQueue(path: exportURL.path, configuration: configuration)
        try candidate.write { db in
            try db.execute(
                sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('orphan-restore-fixture', 0, 1704067200000, 1, 1, NULL)
                """
            )
        }
        try candidate.close()

        let beforeCounts = try source.tableRowCounts()
        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "4.0 (40)")) { error in
            guard case .foreignKeyCheckFailed = error as? StorageLifecycleError else {
                return XCTFail("expected a typed foreign-key restore failure, got \(error)")
            }
        }
        XCTAssertEqual(try source.tableRowCounts(), beforeCounts)
    }

    func test_restoreRollsBackWhenReplacementCannotReopen() throws {
        let (source, sourceURL) = try StorageLifecycleTestSupport.open("restore-rollback-source")
        let exportURL = StorageLifecycleTestSupport.url("restore-rollback-export")
        StorageLifecycleTestSupport.remove(exportURL)
        defer {
            try? source.databasePool.close()
            StorageLifecycleTestSupport.remove(sourceURL)
            StorageLifecycleTestSupport.remove(exportURL)
        }

        try StorageLifecycleTestSupport.seedEveryTable(source)
        try source.export(to: exportURL)
        let beforeCounts = try source.tableRowCounts()

        // The candidate passes staging validation, but the replacement cannot
        // open with an empty application version. This deterministically enters
        // the post-swap rollback path.
        XCTAssertThrowsError(try source.restore(from: exportURL, applicationVersion: "")) { error in
            guard case .restoreFailed = error as? StorageLifecycleError else {
                return XCTFail("expected a typed restore failure, got \(error)")
            }
        }
        let reopened = try StorageDatabase(url: sourceURL, applicationVersion: "4.0 (40)")
        defer { try? reopened.databasePool.close() }
        XCTAssertEqual(try reopened.tableRowCounts(), beforeCounts)
        XCTAssertEqual(try reopened.integrityCheck(), .ok)
    }
}

final class DeletionTests: XCTestCase {
    func test_perDayDeletionRemovesTargetDayAcrossDayScopedTables() throws {
        let (database, url) = try StorageLifecycleTestSupport.open("delete-day")
        defer {
            try? database.databasePool.close()
            StorageLifecycleTestSupport.remove(url)
        }

        try StorageLifecycleTestSupport.seedDay(database, localDay: "2024-01-01", epoch: 1704067200, suffix: 1)
        try StorageLifecycleTestSupport.seedDay(database, localDay: "2024-01-02", epoch: 1704153600, suffix: 2)
        try StorageLifecycleTestSupport.seedDay(database, localDay: "2024-01-03", epoch: 1704240000, suffix: 3)
        try database.delete(localDay: "2024-01-02")

        let counts = try database.tableRowCounts()
        for table in ["decoded_second", "rr_beat", "raw_archive", "day_result", "metric_series", "workout", "route_point"] {
            XCTAssertEqual(counts[table], 2, table)
        }
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM decoded_second WHERE local_day = '2024-01-02'"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM day_result WHERE day_id = '2024-01-02'"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM metric_series WHERE local_day = '2024-01-02'"), 0)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM rr_beat"), 2)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM route_point"), 2)
    }

    func test_fullDeletionEmptiesLedgerTablesAndPreservesMetadata() throws {
        let (database, url) = try StorageLifecycleTestSupport.open("delete-all")
        defer {
            try? database.databasePool.close()
            StorageLifecycleTestSupport.remove(url)
        }

        try StorageLifecycleTestSupport.seedEveryTable(database)
        try database.deleteAllData()
        let counts = try database.tableRowCounts()
        for tableName in StorageDatabase.requiredLedgerTableNames where tableName != "sync_cursor" {
            XCTAssertEqual(counts[tableName], 0, tableName)
        }
        XCTAssertEqual(counts["sync_cursor"], 1)
        let cursor = try database.syncCursorSnapshot()
        XCTAssertNil(cursor.token)
        XCTAssertNil(cursor.counterHighWater)
        XCTAssertNil(cursor.timestampHighWater)
        XCTAssertEqual(cursor.updatedAt, 0)
        XCTAssertEqual(
            try database.readInteger(
                sql: "SELECT COUNT(*) FROM sqlite_sequence WHERE seq <> 0"
            ),
            0
        )
        XCTAssertGreaterThan(counts[StorageMigrations.metadataTable] ?? 0, 0)
        XCTAssertGreaterThan(counts["grdb_migrations"] ?? 0, 0)
        XCTAssertEqual(try database.integrityCheck(), .ok)
    }

    func test_crossDayWorkoutDeletionFailsClosedAndLeavesAdjacentDataUntouched() throws {
        let (database, url) = try StorageLifecycleTestSupport.open("delete-cross-day")
        defer {
            try? database.databasePool.close()
            StorageLifecycleTestSupport.remove(url)
        }

        let dayStart: Int64 = 1_704_067_200 // 2024-01-01T00:00:00Z
        let dayEnd = dayStart + 86_400
        let workoutStart = dayStart + 86_000
        let workoutEnd = dayEnd + 3_600
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO workout(
                    id, kind, status, started_at, ended_at, payload, updated_at
                ) VALUES ('cross-midnight', 'manual', 'complete', ?, ?, X'AA', ?)
                """,
                arguments: [workoutStart, workoutEnd, workoutEnd]
            )
            try db.execute(
                sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('cross-midnight', 0, ?, 13.1, 100.1, 1)
                """,
                arguments: [workoutStart * 1_000]
            )
            try db.execute(
                sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('cross-midnight', 1, ?, 13.2, 100.2, 1)
                """,
                arguments: [(dayEnd + 1_000) * 1_000]
            )
        }

        XCTAssertThrowsError(
            try database.delete(
                localDayWindow: StorageLocalDayWindow(
                    localDay: "2024-01-01",
                    unixSeconds: dayStart..<dayEnd
                )
            )
        ) { error in
            guard case .crossDayWorkoutDeletionUnsupported(let ids) = error as? StorageLifecycleError else {
                return XCTFail("expected cross-day deletion rejection, got \(error)")
            }
            XCTAssertEqual(ids, ["cross-midnight"])
        }
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM workout"), 1)
        XCTAssertEqual(try database.readInteger(sql: "SELECT COUNT(*) FROM route_point"), 2)
        XCTAssertEqual(
            try database.readInteger(
                sql: "SELECT COUNT(*) FROM route_point WHERE timestamp_milliseconds = ?",
                arguments: [(dayEnd + 1_000) * 1_000]
            ),
            1
        )
    }

    func test_whollyContainedWorkoutDeletionCascadesRoutesWithoutAdjacentPoints() throws {
        let (database, url) = try StorageLifecycleTestSupport.open("delete-contained-workout")
        defer {
            try? database.databasePool.close()
            StorageLifecycleTestSupport.remove(url)
        }

        let dayStart: Int64 = 1_704_067_200
        let dayEnd = dayStart + 86_400
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO workout(
                    id, kind, status, started_at, ended_at, payload, updated_at
                ) VALUES ('contained', 'manual', 'complete', ?, ?, X'AB', ?)
                """,
                arguments: [dayStart + 100, dayStart + 200, dayStart + 200]
            )
            try db.execute(
                sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('contained', 0, ?, 13.3, 100.3, 1)
                """,
                arguments: [(dayStart + 150) * 1_000]
            )
            try db.execute(
                sql: """
                INSERT INTO workout(
                    id, kind, status, started_at, ended_at, payload, updated_at
                ) VALUES ('adjacent', 'manual', 'complete', ?, ?, X'AC', ?)
                """,
                arguments: [dayEnd + 100, dayEnd + 200, dayEnd + 200]
            )
            try db.execute(
                sql: """
                INSERT INTO route_point(
                    workout_id, sequence, timestamp_milliseconds,
                    latitude, longitude, altitude
                ) VALUES ('adjacent', 0, ?, 13.4, 100.4, 1)
                """,
                arguments: [(dayEnd + 150) * 1_000]
            )
        }

        try database.delete(
            localDayWindow: StorageLocalDayWindow(
                localDay: "2024-01-01",
                unixSeconds: dayStart..<dayEnd
            )
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM workout WHERE id = 'contained'"),
            0
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM route_point WHERE workout_id = 'contained'"),
            0
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM workout WHERE id = 'adjacent'"),
            1
        )
        XCTAssertEqual(
            try database.readInteger(sql: "SELECT COUNT(*) FROM route_point WHERE workout_id = 'adjacent'"),
            1
        )
    }
}

final class MigrationHarnessTests: XCTestCase {
    func test_everyRegisteredMigrationReachesCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprStorageMigrationHarness-test", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedIdentifiers = StorageMigrationHarness.registeredMigrationIdentifiers(
            applicationVersion: "4.0 (40)"
        )
        let results = try StorageMigrationHarness.verifyAllRegisteredVersions(
            applicationVersion: "4.0 (40)",
            directory: directory
        )
        XCTAssertEqual(results.map(\.migrationIdentifier), expectedIdentifiers)
        XCTAssertTrue(results.allSatisfy(\.schemaMatchesCurrent))
    }
}
