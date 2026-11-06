import AIKit
import Foundation
import StorageKit
import Testing
import UIKit
@testable import Loopr

@MainActor struct YourDataTests {
    @Test func populatedCaptureCountsRealFilesAndRecords() async throws {
        let stores = try await YourDataFileWorker.run { try YourDataModel.fixtureStores() }
        defer { try? FileManager.default.removeItem(at: stores.supportDirectory) }
        let inventory = try await YourDataFileWorker.run { try stores.inventory() }
        #expect(inventory.bandRecords == 84)
        #expect(inventory.healthRecords == 28)
        #expect(inventory.importedDays == 1)
        #expect(inventory.workouts == 1)
        #expect(inventory.meals == 3)
        #expect(inventory.photos == 1)
        #expect(inventory.notes == 1)
        #expect(inventory.checkIns == 1)
        for domain in [YourDataDomain.band, .food, .training, .journal] {
            #expect(inventory.contentBytes[domain, default: 0] > 0)
        }
        let photo = stores.photosDirectory.appendingPathComponent("fixture.png")
        #expect(UIImage(contentsOfFile: photo.path) != nil)
    }
    @Test func accessChoicesPersistAndPrivateDomainsStartOff() throws {
        let name = "YourDataTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let access = AgentAccessPreferences(defaults: defaults)
        #expect(!access.allows(.journalNotes))
        #expect(!access.allows(.cycle))
        #expect(access.allows(.metrics))
        access.set(.metrics, allowed: false)
        access.set(.journalNotes, allowed: true)
        let restored = AgentAccessPreferences(defaults: defaults)
        #expect(!restored.allows(.metrics))
        #expect(restored.allows(.journalNotes))
        #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.contains(AgentAccessPreferences.key))
        #expect(FilesBackupPreferences.allKeys.allSatisfy(ProductRepositoryKeys.allOwnedDefaultsKeys.contains))
    }
    @Test func backupDueDateChangesOnlyOnSuccessAndFolderChangesResetIt() throws {
        let name = "BackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = FilesBackupPreferences(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!settings.isDue(at: start))
        settings.select(bookmark: Data([1]), name: "Backup")
        #expect(settings.isDue(at: start))
        settings.completed(at: start, renewedBookmark: nil)
        #expect(!settings.isDue(at: start.addingTimeInterval(6 * 86_400)))
        #expect(settings.isDue(at: start.addingTimeInterval(7 * 86_400)))
        let restored = FilesBackupPreferences(defaults: defaults)
        #expect(restored.lastSuccess == start)
        restored.setEnabled(false)
        #expect(!restored.isDue(at: start.addingTimeInterval(8 * 86_400)))
        restored.select(bookmark: Data([2]), name: "New folder")
        #expect(restored.lastSuccess == nil)
    }
    @Test func exportsBothLedgersAndPreservesNullBlobQuotesAndLargeInteger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        try products.write { db in
            try db.execute(sql: "CREATE TABLE example (number INTEGER, text TEXT, absent TEXT, bytes BLOB)")
            try db.execute(sql: "INSERT INTO example VALUES (?, ?, NULL, ?)", arguments: [Int64.max, "Alex, \"hello\"\nnext line", Data([0, 255])])
        }
        try history.write { db in
            try db.execute(sql: "CREATE TABLE band_evidence (value INTEGER)")
            try db.execute(sql: "INSERT INTO band_evidence VALUES (61)")
        }
        let stores = YourDataStores(ledgers: [.init(name: "products", database: products), .init(name: "band-history", database: history)], supportDirectory: root.appendingPathComponent("support"), photosDirectory: root.appendingPathComponent("photos"))
        let exporter = YourDataExporter(stores: stores, defaultsData: try PropertyListSerialization.data(fromPropertyList: ["name": "Alex"], format: .xml, options: 0), temporaryDirectory: root)
        let destination = root.appendingPathComponent("output")
        try exporter.stage(.everything, at: destination, now: Date(timeIntervalSince1970: 1_790_000_000))
        let name = "example"
        let json = try Data(contentsOf: destination.appendingPathComponent("products/\(name).json"))
        let rows = try #require(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        #expect((rows[0]["number"] as? NSNumber)?.int64Value == Int64.max)
        #expect(rows[0]["absent"] is NSNull)
        #expect((rows[0]["bytes"] as? [String: String])?["base64"] == Data([0, 255]).base64EncodedString())
        let csv = try String(contentsOf: destination.appendingPathComponent("products/\(name).csv"), encoding: .utf8)
        #expect(csv.contains("\"Alex, \"\"hello\"\"\nnext line\""))
        #expect(csv.contains(",,\"base64:"))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("band-history/band-history.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("products/products.sqlite").path))
        let inventory = try stores.inventory()
        #expect(inventory.diskBytes > 0)
        #expect(inventory.contentBytes[.band, default: 0] > 0)
    }
    @Test func preferencesExportExcludesFolderPermission() throws {
        let name = "YourDataExportDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data([1, 2, 3]), forKey: FilesBackupPreferences.bookmarkKey)
        defaults.set("train", forKey: MainTab.selectionKey)
        let data = try YourDataModel.preferencesData(defaults: defaults)
        let values = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(values[FilesBackupPreferences.bookmarkKey] == nil)
        #expect(values[MainTab.selectionKey] as? String == "train")
    }
    @Test func failedBackupKeepsItsPreviousSuccessAndRemovesTheTemporaryArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-export-backup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let stores = YourDataStores(ledgers: [.init(name: "products", database: database)],
            supportDirectory: root.appendingPathComponent("support"), photosDirectory: root.appendingPathComponent("photos"))
        let exporter = YourDataExporter(stores: stores,
            defaultsData: try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0), temporaryDirectory: root)
        let coordinator = YourDataBackupCoordinator(defaults: nil)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        coordinator.preferences.select(bookmark: Data([1]), name: "Backup")
        coordinator.preferences.completed(at: first, renewedBookmark: nil)
        let marker = root.appendingPathComponent("writer-visited")
        await coordinator.run(exporter: exporter, ifDue: false, now: first.addingTimeInterval(86_400), writer: { @Sendable archive, _ in
            let bytes = try Data(contentsOf: archive)
            #expect(Array(bytes.prefix(4)) == [0x50, 0x4b, 0x03, 0x04])
            try Data([1]).write(to: marker)
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(coordinator.preferences.lastSuccess == first)
        #expect(coordinator.error != nil)
        #expect(!coordinator.isRunning)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains { $0.hasPrefix("loopr-export-") })
        await coordinator.stopForDeletion()
        #expect(coordinator.preferences.bookmark == nil)
        #expect(!coordinator.preferences.enabled)
    }

    @Test func sourceCountsReadStoredDomainsAndIgnoreUnrelatedDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-export-inventory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        for (namespace, keys) in [("workouts", ["workout.1", "detected.1"]),
                                  ("journal", ["entry.1", "habit.day.2026-10-09", "settings"]),
                                  ("food", ["meal.1", "settings"])] {
            let store = try StorageDocumentStore(database: products, namespace: namespace)
            for key in keys { try store.write(["fixture": "Alex"], key: key) }
        }
        try history.write { db in
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES ('2026-10-09', 'rmssd', 'band', 61, 0), ('2026-10-09', 'steps', 'apple_health', 0, 0)")
        }
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: photos.appendingPathComponent("meal.jpg"))
        let stores = YourDataStores(ledgers: [.init(name: "products", database: products), .init(name: "band-history", database: history)], supportDirectory: root.appendingPathComponent("support"), photosDirectory: photos)
        let counts = try stores.inventory()
        #expect(counts.workouts == 1)
        #expect(counts.notes == 1)
        #expect(counts.checkIns == 1)
        #expect(counts.meals == 1)
        #expect(counts.photos == 1)
        #expect(counts.bandRecords == 1)
        #expect(counts.healthRecords == 1)
        #expect(counts.contentBytes[.food, default: 0] >= 3)
    }

}
