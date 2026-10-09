import XCTest
@testable import StorageKit

private actor Gen5DeletionFake: Gen5ExternalDeletionParticipant {
    let kind: String
    private var count: Int
    init(kind: String, count: Int = 1) { self.kind = kind; self.count = count }
    func deleteGen5Artifacts() { count = 0 }
    func remainingGen5Artifacts() -> Int { count }
}

final class Gen5SchemaMigrationTests: XCTestCase {
    func testBaselineRowsSurviveAndEveryGen5ArtifactTableAppears() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gen5-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try StorageDatabase(url: url, applicationVersion: "test")
        try db.write { database in
            try database.execute(sql: "INSERT INTO raw_archive(raw_payload, captured_at, reason) VALUES (X'01', 1, 'baseline')")
        }
        XCTAssertTrue(Set(Gen5StorageSchema.tableNames).isSubset(of: try db.tableNames()))
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM raw_archive") }, 1)
        XCTAssertTrue(try db.schemaMetadata().contains { $0.migrationIdentifier == StorageMigrationIdentifier.gen5Beta })
    }
}

final class Gen5ExportCoverageTests: XCTestCase {
    func testSchemaVersionSurvivesJSONDecoding() throws {
        let data = Data(#"{"schemaVersion":7,"validatedV18":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Gen5ValidatedExport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 7)
    }

    func testOnlyValidatedV18SubstrateIsExported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gen5-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try StorageDatabase(url: url, applicationVersion: "test")
        try db.write { database in
            for model in ["whoop5", "whoopMG"] {
                try database.execute(sql: """
                    INSERT INTO gen5_v18_canonical
                    (model, physiological_timestamp, record_index, heart_rate, rr_le, gravity_x, gravity_y, gravity_z)
                    VALUES (?, 1, 2, 60, X'E803', 0, 0, 1)
                    """, arguments: [model])
                try database.execute(
                    sql: "INSERT INTO gen5_raw_archive(model, raw_payload, record_version) VALUES (?, X'DEADBEEF', 26)",
                    arguments: [model]
                )
            }
        }
        let data = try db.exportValidatedGen5JSON()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("validatedV18"))
        XCTAssertTrue(text.contains("whoop5"))
        XCTAssertTrue(text.contains("whoopMG"))
        for forbidden in ["oxygen", "temperature", "steps", "waveform", "deadbeef", "raw_archive"] {
            XCTAssertFalse(text.lowercased().contains(forbidden))
        }
    }
}

final class Gen5DeletionCompletenessTests: XCTestCase {
    func testSyntheticEveryArtifactAndExternalSurfaceLeavesZero() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gen5-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try StorageDatabase(url: url, applicationVersion: "test")
        try db.write { database in
            for (suffix, model) in [("5", "whoop5"), ("mg", "whoopMG")] {
                try database.execute(sql: "INSERT INTO gen5_research_frames(model, connection_generation, burst_id, ordinal, raw_frame, decode_succeeded, decode_outcome, marker) VALUES (?, 1, ?, 0, X'01', 0, 'raw', X'0100')", arguments: [model, "b-\(suffix)"])
                try database.execute(sql: "INSERT INTO gen5_raw_archive(model, raw_payload, record_version) VALUES (?, X'01', 20)", arguments: [model])
                try database.execute(sql: "INSERT INTO gen5_v18_canonical(model, physiological_timestamp, record_index, rr_le, gravity_x, gravity_y, gravity_z) VALUES (?, 1, 1, X'', 0, 0, 1)", arguments: [model])
                try database.execute(sql: "INSERT INTO gen5_committed_batch(model, connection_generation, burst_id, token) VALUES (?, 1, ?, X'0102030405060708')", arguments: [model, "b-\(suffix)"])
                try database.execute(sql: "INSERT INTO gen5_capability_state(model, capability, state) VALUES (?, 'history', 'fixtureVerified')", arguments: [model])
                try database.execute(sql: "INSERT INTO gen5_band_profile(peripheral_id, model, model_confidence, service_uuid) VALUES (?, ?, 1, 'fd4b')", arguments: ["p-\(suffix)", model])
            }
        }
        let participants: [any Gen5ExternalDeletionParticipant] = [
            Gen5DeletionFake(kind: "keychain"),
            Gen5DeletionFake(kind: "notifications"),
            Gen5DeletionFake(kind: "liveActivities")
        ]
        let result = try await Gen5DeletionCoordinator(database: db, external: participants).deleteAll()
        XCTAssertTrue(result.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(Set(result.keys), Set(Gen5StorageSchema.tableNames + ["keychain", "notifications", "liveActivities"]))
    }
}
