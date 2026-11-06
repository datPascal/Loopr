import Foundation
import StorageKit

extension FoodStore: FoodProductCache {
    public func cachedProduct(barcode: String) throws -> FoodProductCacheEntry? {
        let code = try FoodBarcode.normalized(barcode)
        return try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM food_product_cache WHERE barcode = ?", arguments: [code]) else { return nil }
            let entry = try JSONDecoder().decode(FoodProductCacheEntry.self, from: data)
            guard entry.barcode == code, entry.fetchedAt.timeIntervalSince1970.isFinite else { throw FoodBarcodeError.storage }
            return entry
        }
    }
    public func productCacheGeneration() throws -> UUID {
        try database.write { db in
            if let value = try String.fetchOne(db, sql: "SELECT token FROM food_product_cache_epoch WHERE id = 1"), let token = UUID(uuidString: value) { return token }
            let token = UUID()
            try db.execute(sql: "INSERT OR REPLACE INTO food_product_cache_epoch VALUES (1, ?)", arguments: [token.uuidString])
            return token
        }
    }
    public func cacheProduct(_ entry: FoodProductCacheEntry, generation: UUID) throws {
        guard try FoodBarcode.normalized(entry.barcode) == entry.barcode, entry.fetchedAt.timeIntervalSince1970.isFinite else { throw FoodBarcodeError.storage }
        if let response = entry.response { _ = try FoodProductDecoder.decode(response, barcode: entry.barcode, fetchedAt: entry.fetchedAt) }
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT token FROM food_product_cache_epoch WHERE id = 1") == generation.uuidString else { throw FoodBarcodeError.storage }
            try db.execute(sql: "INSERT OR REPLACE INTO food_product_cache VALUES (?, ?, ?)",
                arguments: [entry.barcode, entry.fetchedAt.timeIntervalSince1970, try JSONEncoder().encode(entry)])
            // Bound public product snapshots independently of the user's meals.
            try db.execute(sql: "DELETE FROM food_product_cache WHERE barcode IN (SELECT barcode FROM food_product_cache ORDER BY fetched_at DESC, barcode LIMIT -1 OFFSET 500)")
        }
    }
}
