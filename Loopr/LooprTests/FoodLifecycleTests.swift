import DataKit
import FoodKit
import Foundation
import StorageKit
import TrainKit
import Testing
@testable import Loopr

@MainActor struct FoodLifecycleTests {
    @Test func jsonBackupRestoresFoodPhotosAndKeepsFoodWhenReadingAnOlderBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodJSONTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        defer { try? database.databasePool.close() }
        let repository = try SQLiteDataRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = FoodItem(name: "Rice", amount: 180, unit: .grams, provenance: [.init(source: .typed, recordedAt: date)])
        let image = try FoodPhoto(type: .png, capturedAt: date,
            bytes: #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9mQAAAAASUVORK5CYII=")))
        let meal = try FoodStore(database: database).confirm(.init(slot: .lunch, occurredAt: date,
            timeZoneIdentifier: "Australia/Perth", items: [item], photos: [image]), at: date)
        let encoded = try await repository.exportJSONChecked()
        let backup = try JSONDecoder().decode(DataBackup.self, from: encoded)
        #expect(backup.schemaVersion == 3)
        #expect(backup.train == TrainArchive())
        #expect(backup.food?.meals == [meal])
        try await repository.completeDeletionChecked()
        #expect(try FoodStore(database: database).meals().isEmpty)
        try await repository.restoreChecked(backup)
        #expect(try FoodStore(database: database).editDraft(id: meal.id).photos == [image])
        let old = try JSONDecoder().decode(DataBackup.self, from: Data(#"{"schemaVersion":1,"records":[]}"#.utf8))
        try await repository.restoreChecked(old)
        #expect(try FoodStore(database: database).meals() == [meal])
        let invalid = DataBackup(records: [], food: .init(meals: [meal], photos: []))
        await #expect(throws: (any Error).self) { try await repository.restoreChecked(invalid) }
        #expect(try FoodStore(database: database).meals() == [meal])
        let keep = DataRecord(id: "keep", day: meal.localDay, table: "metrics", payload: ["value": "42"], provenance: .imported)
        try await repository.insert(keep)
        try database.write { db in try db.execute(sql: "CREATE TRIGGER deny_food_insert BEFORE INSERT ON food_meal BEGIN SELECT RAISE(ABORT, 'restore failure'); END") }
        await #expect(throws: (any Error).self) { try await repository.restoreChecked(backup) }
        #expect(try FoodStore(database: database).editDraft(id: meal.id).photos == [image])
        #expect(try await repository.recordsChecked() == [keep])
        let fixture = DataRepository()
        try await fixture.restore(backup)
        #expect(await fixture.exportBackup() == backup)
        try database.write { db in try db.execute(sql: "UPDATE food_photo SET sha256 = 'corrupt'") }
        await #expect(throws: FoodError.invalidPhoto) { try await repository.exportBackupChecked() }
        await #expect(throws: FoodError.invalidPhoto) { try await repository.exportJSONChecked() }
        let rejected = await repository.exportBackup()
        #expect(throws: DataError.invalidBackup) { try rejected.validate() }
    }

    @Test func inventoryAndEverythingExportUseTheSameConfirmedMealAndPhotoSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        defer { try? database.databasePool.close() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9mQAAAAASUVORK5CYII="))
        let photo = try FoodPhoto(type: .png, capturedAt: date, bytes: bytes)
        let item = FoodItem(name: "Rice", amount: 180, unit: .grams, nutrients: .init([.energy: 234]),
            provenance: [.init(source: .label, recordedAt: date)])
        let meal = try FoodStore(database: database).confirm(.init(slot: .lunch, occurredAt: date,
            timeZoneIdentifier: "Australia/Perth", items: [item], photos: [photo]), at: date)
        let stores = YourDataStores(ledgers: [.init(name: "products", database: database)],
            supportDirectory: root, photosDirectory: root.appendingPathComponent("FoodPhotos"))
        let inventory = try stores.inventory()
        #expect(inventory.meals == 1 && inventory.photos == 1)
        #expect(inventory.contentBytes[.food, default: 0] >= bytes.count)
        let exporter = YourDataExporter(stores: stores,
            defaultsData: try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0), temporaryDirectory: root)
        let output = root.appendingPathComponent("export")
        try exporter.stage(.everything, at: output, now: date)
        #expect(try Data(contentsOf: output.appendingPathComponent("photos/products/\(photo.reference.fileName)")) == bytes)
        let snapshot = try StorageDatabase(url: output.appendingPathComponent("products/products.sqlite"))
        defer { try? snapshot.databasePool.close() }
        #expect(try FoodStore(database: snapshot).meals() == [meal])
        #expect(try FoodStore(database: snapshot).photo(id: photo.reference.id) == photo)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("products/food_photo.json"))) as? [[String: Any]])
        #expect((rows[0]["bytes"] as? [String: String])?["base64"] == bytes.base64EncodedString())
        try database.deleteAllAccountData()
        #expect(try stores.inventory().meals == 0)
        #expect(try stores.inventory().photos == 0)
    }

    @Test func existingDayDeletionAlsoDeletesFoodAndRollsBackOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodDayDeleteTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        defer { try? database.databasePool.close() }
        let repository = try SQLiteDataRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = FoodItem(name: "Rice", amount: 180, unit: .grams, provenance: [.init(source: .typed, recordedAt: date)])
        let meal = try FoodStore(database: database).confirm(.init(slot: .lunch, occurredAt: date,
            timeZoneIdentifier: "Australia/Perth", items: [item]), at: date)
        let record = DataRecord(id: "day-record", day: meal.localDay, table: "metrics", payload: ["value": "42"], provenance: .imported)
        try await repository.insert(record)
        try database.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_food_delete BEFORE DELETE ON food_meal BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END")
        }
        let before = try StorageDocumentStore(database: database, namespace: "data").readData(key: "records")
        await #expect(throws: (any Error).self) { try await repository.deleteDayChecked(meal.localDay) }
        #expect(try FoodStore(database: database).meals() == [meal])
        #expect(try StorageDocumentStore(database: database, namespace: "data").readData(key: "records") == before)
        #expect(try await repository.recordsChecked() == [record])
        try database.write { db in try db.execute(sql: "DROP TRIGGER deny_food_delete") }
        try await repository.deleteDayChecked(meal.localDay)
        #expect(try FoodStore(database: database).meals().isEmpty)
        #expect(try await repository.recordsChecked().isEmpty)
    }
}
