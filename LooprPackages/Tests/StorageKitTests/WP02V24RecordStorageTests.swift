import Foundation
import ProtocolKit
import StorageKit
import XCTest

final class WP02V24RecordStorageTests: XCTestCase {
    func testMigrationInventoryIncludesV24ADCFieldsMigration() throws {
        XCTAssertTrue(StorageMigrationHarness.registeredMigrationIdentifiers(applicationVersion: "WP-2").contains("storage-007-v24-adc-fields"))
    }

    func testStoredRecordDecodingKeepsLegacyMissingFieldsAbsent() throws {
        let legacy = "{\"physiologicalTimestamp\":1,\"bandCounter\":2,\"absoluteTimestamp\":1,\"localDay\":\"2026-04-05\",\"version\":12,\"rrBeats\":[],\"rawPayload\":null}"
        let record = try JSONDecoder().decode(StoredHistoricalRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(record.ppgGreen)
        XCTAssertNil(record.ambientRaw)
    }

    func testLegacyJSONPreservesByte68UnderItsHonestName() throws {
        let legacy = "{\"physiologicalTimestamp\":1,\"bandCounter\":2,\"localDay\":\"2026-10-07\",\"skinTemperatureRaw\":700}"
        let record = try JSONDecoder().decode(StoredHistoricalRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(record.unidentified68, 700)
        XCTAssertNil(record.skinTemperatureCelsius)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        XCTAssertNil(encoded["skinTemperatureRaw"])
        XCTAssertEqual(encoded["unidentified68"] as? Int, 700)
    }

    func testV24ZeroADCValuesRemainZeroAndAreNotTreatedAsAbsent() throws {
        var raw = try v24Fixture()
        raw[29] = 0; raw[30] = 0; raw[31] = 0; raw[32] = 0; raw[51] = 0
        raw[64] = 0; raw[65] = 0; raw[66] = 0; raw[67] = 0; raw[68] = 0; raw[69] = 0; raw[70] = 0; raw[71] = 0
        guard case .decoded(let record) = try HistoricalRecord.decode(raw) else { return XCTFail("Expected v24 fixture to decode") }
        XCTAssertEqual(record.ppgGreen, 0)
        XCTAssertEqual(record.ppgRedIR, 0)
        XCTAssertEqual(record.skinContact, 0)
        XCTAssertEqual(record.ambientRaw, 0)
    }

    func testV24DecodedFieldsRoundTripThroughStoredRecordAndCommitPath() async throws {
        let raw = try v24Fixture()
        guard case .decoded(let decoded) = try HistoricalRecord.decode(raw) else {
            return XCTFail("Expected v24 fixture to decode")
        }
        let stored = StoredHistoricalRecord(decoded: decoded, localDay: "2026-04-05")
        XCTAssertEqual(stored.ppgGreen, 3_999)
        XCTAssertEqual(stored.ppgRedIR, 33_023)
        XCTAssertEqual(stored.skinContact, 70)
        XCTAssertEqual(stored.spo2RedRaw, 534)
        XCTAssertEqual(stored.spo2IRRaw, 644)
        XCTAssertEqual(stored.unidentified68, 700)
        XCTAssertEqual(stored.skinTemperatureCelsius, 35)
        XCTAssertEqual(stored.ambientRaw, 646)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp02-roundtrip-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + "-wal"); try? FileManager.default.removeItem(atPath: url.path + "-shm") }
        let database = try StorageDatabase(url: url)
        let store = SQLiteHistoryBatchStore(database: database)
        let token = try HistoryToken(bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        _ = try await store.commit(records: [stored], archived: [], boundary: .tokenized(token), diagnostics: HistoryBatchDiagnostics(batchID: "wp02", receivedAt: 1, recordCount: 1))
        XCTAssertEqual(try database.storedHistoricalSecond(physiologicalTimestamp: Int64(decoded.timestampSeconds)), stored)
    }

    func testTemperatureMigrationBackfillsRetainedBytesAndIsIdempotent() throws {
        let queue = try DatabaseQueue()
        let migrator = StorageMigrations.makeMigrator(applicationVersion: "SI-vitals")
        try migrator.migrate(queue, upTo: "storage-008-metric-series-source")
        var valid = try v24Fixture(); valid[72] = 0x60; valid[73] = 0x01 // 35.2°C
        var tooHot = valid; tooHot[72] = 0xc3; tooHot[73] = 0x01 // 45.1°C
        var wrongVersion = valid; wrongVersion[1] = 18
        var wrongType = valid; wrongType[0] = 0
        let payloads: [Data?] = [valid, tooHot, wrongVersion, wrongType, Data(valid.prefix(88)), nil]
        try queue.write { db in
            for (index, payload) in payloads.enumerated() {
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, skin_temp_raw, raw_payload) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [index + 1, index + 1, index + 1, "2026-10-07", 24, 700, payload])
            }
        }
        try migrator.migrate(queue)
        let revision = try queue.read { db in try Int64.fetchOne(db, sql: "SELECT revision FROM analytics_input_revision") }
        try migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT unidentified_68, skin_temperature_celsius, raw_payload FROM decoded_second ORDER BY id")
            XCTAssertEqual(rows.count, payloads.count)
            XCTAssertEqual(rows[0]["skin_temperature_celsius"] as Double?, 35.2)
            XCTAssertEqual(rows[0]["raw_payload"] as Data?, valid)
            for row in rows { XCTAssertEqual(row["unidentified_68"] as Int64?, 700) }
            for row in rows.dropFirst() { XCTAssertNil(row["skin_temperature_celsius"] as Double?) }
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT revision FROM analytics_input_revision"), revision)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM storage_schema_metadata WHERE migration_identifier = 'storage-009-v24-skin-temperature'"), 1)
        }
    }

    func testV24MigrationBackfillsRawPayloadFieldsOnLegacyRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp02-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + "-wal"); try? FileManager.default.removeItem(atPath: url.path + "-shm") }
        let raw = try v24Fixture()
        let migrator = StorageMigrations.makeMigrator(applicationVersion: "WP-2")
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue, upTo: "storage-006-analytics-range-revision")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, raw_payload) VALUES (?, ?, ?, ?, ?, ?)", arguments: [1_775_395_266, 32_324_849, 1_775_395_266, "2026-04-05", 24, raw])
            try db.execute(sql: "UPDATE decoded_second SET heart_rate = 98 WHERE physiological_timestamp = 1775395266")
            try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds) SELECT id, 0, 728 FROM decoded_second WHERE physiological_timestamp = 1775395266")
            var wrongType = raw; wrongType[0] = 0
            var wrongVersion = raw; wrongVersion[1] = 25
            let invalidPayloads: [Data?] = [Data(raw.prefix(71)), Data(raw.prefix(72)), Data(raw.prefix(88)), wrongType, wrongVersion, nil]
            for (index, payload) in invalidPayloads.enumerated() {
                let timestamp = index + 2
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, raw_payload) VALUES (?, ?, ?, ?, ?, ?)", arguments: [timestamp, timestamp, timestamp, "2026-04-05", 24, payload])
            }
        }
        try queue.close()
        let database = try StorageDatabase(url: url, applicationVersion: "WP-2")
        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT ppg_green, ppg_red_ir, skin_contact, spo2_red_raw, spo2_ir_raw, unidentified_68, ambient_raw FROM decoded_second WHERE physiological_timestamp = 1775395266")
        }
        XCTAssertEqual(row?["ppg_green"] as Int64?, 3_999)
        XCTAssertEqual(row?["ppg_red_ir"] as Int64?, 33_023)
        XCTAssertEqual(row?["skin_contact"] as Int64?, 70)
        XCTAssertEqual(row?["spo2_red_raw"] as Int64?, 534)
        XCTAssertEqual(row?["spo2_ir_raw"] as Int64?, 644)
        XCTAssertEqual(row?["unidentified_68"] as Int64?, 700)
        XCTAssertEqual(row?["ambient_raw"] as Int64?, 646)
        let stored = try XCTUnwrap(database.storedHistoricalSecond(physiologicalTimestamp: 1_775_395_266))
        XCTAssertEqual(stored.heartRate, 98)
        XCTAssertEqual(stored.rrBeats.map(\.intervalMilliseconds), [728])
        XCTAssertEqual(stored.rawPayload, raw)
        for timestamp in 2...7 {
            let invalid = try XCTUnwrap(database.storedHistoricalSecond(physiologicalTimestamp: Int64(timestamp)))
            XCTAssertNil(invalid.ppgGreen, "Malformed or missing raw payload at \(timestamp)")
            XCTAssertNil(invalid.ambientRaw)
        }
    }
}

private func v24Fixture() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Fixtures/Protocol/records/v24_literal_96b.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let hex = object["raw_hex"] as! String
    var data = Data(); var index = hex.startIndex
    while index < hex.endIndex { let end = hex.index(index, offsetBy: 2); data.append(UInt8(hex[index..<end], radix: 16)!); index = end }
    return data
}
