import FoodKit
import Foundation
import StorageKit
import Testing

struct FoodFavoriteTests {
    @Test func favoritesRequireConfirmationAndSurviveReopenArchiveRestoreAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoodFavoriteTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        let store = FoodStore(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = FoodItem(name: "Beans", amount: 100, unit: .grams, nutrients: .init([.energy: 120]), provenance: [.init(source: .typed, recordedAt: now)])
        let favorite = FoodFavorite(name: "Beans", items: [item], note: "", confirmedAt: now)
        #expect(try store.favorites().isEmpty && store.meals().isEmpty)
        try store.confirmFavorite(favorite)
        let reopened = try StorageDatabase(url: root.appendingPathComponent("food.sqlite"))
        defer { try? reopened.databasePool.close(); try? database.databasePool.close() }
        #expect(try FoodStore(database: reopened).favorites() == [favorite])
        let draft = try favorite.draft(slot: .lunch, at: now, timeZoneIdentifier: "Australia/Perth")
        #expect(draft.items[0].id != item.id && draft.items[0].nutrients == item.nutrients)
        #expect(try store.meals().isEmpty)
        let archive = try JSONDecoder().decode(FoodArchive.self, from: JSONEncoder().encode(store.exportArchive()))
        #expect(try store.exportArchive(localDay: "2023-11-14").favorites.isEmpty)
        #expect(archive.selectingDays { $0 == "2023-11-14" }.favorites.isEmpty)
        #expect(archive.selectingDays(includingFavorites: true) { $0 != "2023-11-14" }.favorites == [favorite])
        try store.deleteDay("2023-11-14")
        #expect(try store.favorites() == [favorite])
        try store.deleteAll()
        #expect(try store.favorites().isEmpty)
        try store.restore(archive)
        #expect(try store.favorites() == [favorite])
        try store.deleteFavorite(id: favorite.id)
        #expect(try store.favorites().isEmpty)
    }
}
