import Foundation
import Testing
import StorageKit

struct ProductDocumentStoreTests {
    private struct Payload: Codable, Equatable, Sendable {
        let value: String
        let count: Int
    }

    @Test
    func documentsSurviveReopenAndAreNamespaced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprProductDocuments-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: "\(url.path)-wal")
            try? FileManager.default.removeItem(atPath: "\(url.path)-shm")
        }

        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let first = try StorageDocumentStore(database: database, namespace: "today")
        let other = try StorageDocumentStore(database: database, namespace: "sleep")
        let payload = Payload(value: "canonical", count: 2)
        try first.write(payload, key: "summary.2026-08-18")
        #expect(try first.read(Payload.self, key: "summary.2026-08-18") == payload)
        #expect(try other.read(Payload.self, key: "summary.2026-08-18") == nil)
        try database.databasePool.close()

        let reopened = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let reopenedStore = try StorageDocumentStore(database: reopened, namespace: "today")
        #expect(try reopenedStore.read(Payload.self, key: "summary.2026-08-18") == payload)
        try reopenedStore.removeAll(whereKeyPrefix: "summary.")
        #expect(try reopenedStore.keys().isEmpty)
        try reopened.databasePool.close()
    }

    @Test
    func deleteAllRemovesOnlyProductDocumentsAndLeavesStorageSchema() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprProductDocuments-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: "\(url.path)-wal")
            try? FileManager.default.removeItem(atPath: "\(url.path)-shm")
        }

        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let store = try StorageDocumentStore(database: database, namespace: "settings")
        try store.write(Payload(value: "settings", count: 1), key: "snapshot")
        try database.deleteAllData()
        #expect(try store.read(Payload.self, key: "snapshot") != nil)
        try store.removeAll()
        #expect(try store.read(Payload.self, key: "snapshot") == nil)
        #expect(try database.integrityCheck() == .ok)
        try database.databasePool.close()
    }

    @Test
    func mutationsCommitWritesAndRemovalsAtomically() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprProductMutation-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: "\(url.path)-wal")
            try? FileManager.default.removeItem(atPath: "\(url.path)-shm")
        }
        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let store = try StorageDocumentStore(database: database, namespace: "journal")
        try store.write(Payload(value: "old", count: 1), key: "remove")
        try store.mutate([
            try StorageDocumentMutation.write(Payload(value: "one", count: 1), key: "first"),
            try StorageDocumentMutation.write(Payload(value: "two", count: 2), key: "second"),
            .remove(key: "remove")
        ])
        #expect(try store.read(Payload.self, key: "first") == Payload(value: "one", count: 1))
        #expect(try store.read(Payload.self, key: "second") == Payload(value: "two", count: 2))
        #expect(try store.read(Payload.self, key: "remove") == nil)
        try database.databasePool.close()
    }
}
