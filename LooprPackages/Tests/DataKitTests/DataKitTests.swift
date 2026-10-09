import DataKit
import XCTest

final class DataKitTests: XCTestCase {
    private func record(_ id: String, provenance: DataProvenance = .looprComputed, algorithm: Int? = 1) -> DataRecord {
        DataRecord(id: id, day: "2026-08-18", table: "metrics", payload: ["value": id], provenance: provenance, algorithmVersion: algorithm)
    }

    func testPreviewDistinguishesProvenanceAndRollbackRestoresDurableBackup() async throws {
        let repository = DataRepository()
        let existing = record("metric-1")
        try await repository.insert(existing)
        let incoming = record("metric-1", provenance: .whoopCSV, algorithm: nil)
        let conflictPreview = await repository.preview(source: .whoopCSV, incoming: [incoming])
        XCTAssertEqual(conflictPreview.conflicts.count, 1)
        do {
            _ = try await repository.beginImport(conflictPreview)
            XCTFail("conflicts require an explicit resolution")
        } catch DataError.conflictRequiresResolution { }

        let addition = record("metric-2", provenance: .imported, algorithm: nil)
        let preview = await repository.preview(source: .whoopCSV, incoming: [addition])
        let receipt = try await repository.beginImport(preview)
        let importedRows = await repository.records()
        XCTAssertEqual(importedRows.count, 2)
        try await repository.rollback(receipt)
        let rolledBackRows = await repository.records()
        XCTAssertEqual(rolledBackRows, [existing])
    }

    func testBackupIsDeterministicReanalysisUpdatesRowsAndDeletionKeepsHealthKit() async throws {
        let repository = DataRepository()
        try await repository.insert(record("b"))
        try await repository.insert(record("a"))
        let firstJSON = try await repository.exportJSON()
        let secondJSON = try await repository.exportJSON()
        XCTAssertEqual(firstJSON, secondJSON)
        let statuses = await repository.reanalyzeAll(algorithmVersion: 3)
        XCTAssertEqual(statuses.map(\.algorithmVersion), [3])
        let reanalyzedRows = await repository.records()
        XCTAssertTrue(reanalyzedRows.allSatisfy { $0.algorithmVersion == 3 })

        await repository.setInventory(DataStoreInventory(files: 2, notifications: 1, healthKitSamples: 4))
        await repository.completeDeletion()
        let inventory = await repository.inventorySnapshot()
        XCTAssertTrue(inventory.nonHealthKitIsEmpty)
        XCTAssertEqual(inventory.healthKitSamples, 4)
        await repository.removeHealthKitSamples()
        let clearedInventory = await repository.inventorySnapshot()
        XCTAssertEqual(clearedInventory.healthKitSamples, 0)
    }

    func testBackupRestoreAndImportProvenanceRoundTrip() async throws {
        let repository = DataRepository()
        let computed = record("computed", provenance: .looprComputed, algorithm: 4)
        try await repository.insert(computed)
        let backup = await repository.exportBackup()
        await repository.completeDeletion()
        try await repository.restore(backup)
        let restoredRows = await repository.records()
        XCTAssertEqual(restoredRows, [computed])

        let edge = DataRecord(id: "edge", day: "2026-08-18", table: "derived", payload: ["value": "1"], provenance: .looprComputed, algorithmVersion: 9)
        let whoop = DataRecord(id: "whoop", day: "2026-08-18", table: "derived", payload: ["value": "2"], provenance: .looprComputed, algorithmVersion: 9)
        let raw = DataRecord(id: "raw", day: "2026-08-18", table: "raw", payload: ["frame": "AA"], provenance: .looprComputed, algorithmVersion: 9)
        let edgePreview = try await repository.validatedPreview(source: .edgeMerge, incoming: [edge])
        let whoopPreview = try await repository.validatedPreview(source: .whoopCSV, incoming: [whoop])
        let rawPreview = try await repository.validatedPreview(source: .noopRaw, incoming: [raw])
        XCTAssertEqual(edgePreview.additions.first?.provenance, .edgeMerged)
        XCTAssertEqual(whoopPreview.additions.first?.provenance, .whoopCSV)
        XCTAssertEqual(rawPreview.additions.first?.provenance, .noopRaw)
        XCTAssertNil(edgePreview.additions.first?.algorithmVersion)
        do {
            _ = try await repository.validatedPreview(source: .noopRaw, incoming: [DataRecord(id: "bad-raw", day: "2026-08-18", table: "raw", payload: [:], provenance: .noopRaw)])
            XCTFail("empty NOOP/raw rows must be rejected")
        } catch DataError.invalidImport { }
    }

    func testPerDayExportDeletionAndDiagnosticsExposeRealGenerationState() async throws {
        let repository = DataRepository()
        let first = DataRecord(id: "day-1", day: "2026-08-17", table: "metrics", payload: ["value": "1"], provenance: .looprComputed, algorithmVersion: 1)
        let second = DataRecord(id: "day-2", day: "2026-08-18", table: "metrics", payload: ["value": "2"], provenance: .looprComputed, algorithmVersion: 1)
        try await repository.insert(first)
        try await repository.insert(second)
        let exportedDay = await repository.exportDay("2026-08-17")
        XCTAssertEqual(exportedDay.records, [first])
        await repository.deleteDay("2026-08-17")
        let afterDelete = await repository.records()
        XCTAssertEqual(afterDelete, [second])
        let status = await repository.reanalyze(day: "2026-08-18", algorithmVersion: 5)
        XCTAssertEqual(status.algorithmVersion, 5)
        let reanalyzed = await repository.records()
        XCTAssertEqual(reanalyzed.first?.algorithmVersion, 5)
        let diagnostics = await repository.diagnostics(capture: "ready", storage: "ready", frame: "ready", compute: "idle")
        XCTAssertEqual(diagnostics.reanalysis, [status])
    }

    func testLegacyMigrationIsOneShotAndInvalidDaysAreRejected() async throws {
        let repository = DataRepository()
        do {
            try await repository.insert(DataRecord(id: "bad", day: "08/18/2026", table: "x", payload: [:], provenance: .imported))
            XCTFail("day labels must be ISO local days")
        } catch DataError.invalidDay { }
        do {
            try await repository.insert(DataRecord(id: "bad-calendar-day", day: "2026-02-31", table: "x", payload: [:], provenance: .imported))
            XCTFail("calendar-invalid ISO days must be rejected")
        } catch DataError.invalidDay { }
        await repository.setLegacyMigrationAvailable()
        let migrated = try await repository.runLegacyMigration(records: [record("legacy", provenance: .noopRaw, algorithm: 8)])
        XCTAssertEqual(migrated.first?.provenance, .imported)
        do {
            _ = try await repository.runLegacyMigration(records: [])
            XCTFail("legacy migration must not run twice")
        } catch DataError.alreadyMigrated { }
    }

    func testDataFixturesExposeConflictAndTypedControlRoutes() {
        XCTAssertEqual(DataFixtures.conflict.recordID, DataFixtures.importedRecord.id)
        XCTAssertNotEqual(DataFixtures.conflict.existing.payload, DataFixtures.conflict.incoming.payload)
        XCTAssertTrue(DataRoute.allCases.contains(.diagnostics))
        XCTAssertTrue(DataRoute.allCases.contains(.deletion))
    }

    func testDataScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(DataScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(DataScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(DataScreenStateFixtures.accessibilitySummary(for: .absent), DataScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(DataScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

    func testEdgeMergeJSONIsStrictAndNormalizesProvenance() throws {
        let backup = DataBackup(records: [
            DataRecord(id: "edge-b", day: "2026-08-18", table: "derived", payload: ["score": "72"], provenance: .looprComputed, algorithmVersion: 9),
            DataRecord(id: "edge-a", day: "2026-08-17", table: "derived", payload: ["score": "70"], provenance: .imported, algorithmVersion: 3)
        ])
        let data = try JSONEncoder().encode(backup)
        let parsed = try EdgeDatabaseMergeParser.parse(data)
        XCTAssertEqual(parsed.map(\.id), ["edge-a", "edge-b"])
        XCTAssertTrue(parsed.allSatisfy { $0.provenance == .edgeMerged && $0.algorithmVersion == nil })

        var unsupported = backup
        unsupported = DataBackup(schemaVersion: 2, records: unsupported.records)
        XCTAssertThrowsError(try EdgeDatabaseMergeParser.parse(try JSONEncoder().encode(unsupported))) { error in
            XCTAssertEqual(error as? DataImportParserError, .unsupportedSchema(2))
        }
    }

    func testWHOOPCSVParserPreservesPayloadAndFailsClosed() throws {
        let csv = "id,day,table,recovery_score,notes\n"
            + "whoop-2,2026-08-18,recovery,82,\"steady day\"\n"
            + "whoop-1,2026-08-17,recovery,74,rest\n"
        let parsed = try WHOOPCSVParser.parse(Data(csv.utf8))
        XCTAssertEqual(parsed.map(\.id), ["whoop-1", "whoop-2"])
        XCTAssertEqual(parsed.first?.provenance, .whoopCSV)
        XCTAssertEqual(parsed.last?.payload["notes"], "steady day")
        XCTAssertNil(parsed.first?.algorithmVersion)

        XCTAssertThrowsError(try WHOOPCSVParser.parse(Data("id,day\nmissing-table,2026-08-18\n".utf8))) { error in
            XCTAssertEqual(error as? DataImportParserError, .invalidHeader)
        }
        XCTAssertThrowsError(try WHOOPCSVParser.parse(Data("id,day,table,value\na,2026-02-31,t,1\n".utf8)))
        XCTAssertThrowsError(try WHOOPCSVParser.parse(Data("id,day,table,value\na,2026-08-18,t,\na,2026-08-18,t,2\n".utf8)))
    }

    func testWHOOPCSVParserReadsRealAccountExportColumns() throws {
        let csv = "Cycle start time,Wake onset,Cycle timezone,Recovery score %,Heart rate variability (ms)\n"
            + "2022-06-04 22:00:00,2022-06-05 07:00:00,UTC+08:00,76,\n"
        let rows = try WHOOPCSVParser.parse(Data(csv.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.day, "2022-06-05")
        XCTAssertEqual(rows.first?.table, "physiological_cycles")
        XCTAssertEqual(rows.first?.payload["recovery score"], "76")
        XCTAssertNil(rows.first?.payload["heart rate variability"])
        XCTAssertEqual(rows.first?.provenance, .whoopCSV)
        XCTAssertEqual(try WHOOPCSVParser.parse(Data(csv.utf8)), rows)
    }

    func testImportCoordinatorRequiresPreviewBeforeCommit() async throws {
        let repository = DataRepository()
        let coordinator = DataImportCoordinator(store: repository)
        let receipt = try await coordinator.importWHOOPCSV(Data("id,day,table,value\na,2026-08-18,metrics,1\n".utf8))
        XCTAssertEqual(receipt.preview.source, .whoopCSV)
        let importedRows = await repository.records()
        XCTAssertEqual(importedRows.first?.provenance, .whoopCSV)
    }
}
