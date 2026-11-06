import Foundation

public extension StorageMigrationIdentifier {
    static let food = "storage-010-food"
    static let foodOverview = "storage-011-food-overview"
    static let foodCapture = "storage-012-food-capture"
    static let foodReview = "storage-013-food-review"
    static let foodWeight = "storage-015-food-weight"
}

public enum FoodStorageSchema {
    public static let tableNames = ["food_photo", "food_meal", "food_drink", "food_day", "food_target", "food_product_cache", "food_product_cache_epoch", "food_favorite", "food_weight"]
}

extension StorageMigrations {
    static func registerFoodWeightMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.foodWeight) { db in
            try db.execute(sql: """
                CREATE TABLE food_weight (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_day TEXT NOT NULL,
                    measured_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX food_weight_time ON food_weight(measured_at);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.foodWeight, "15", applicationVersion])
        }
    }

    static func registerFoodReviewMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.foodReview) { db in
            try db.execute(sql: "CREATE TABLE food_favorite (id TEXT PRIMARY KEY NOT NULL, confirmed_at REAL NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.foodReview, "13", applicationVersion])
        }
    }

    static func registerFoodCaptureMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.foodCapture) { db in
            try db.execute(sql: "CREATE TABLE food_product_cache (barcode TEXT PRIMARY KEY NOT NULL, fetched_at REAL NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE food_product_cache_epoch (id INTEGER PRIMARY KEY CHECK(id = 1), token TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.foodCapture, "12", applicationVersion])
        }
    }

    static func registerFoodOverviewMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.foodOverview) { db in
            try db.execute(sql: """
                CREATE TABLE food_drink (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_day TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX food_drink_day ON food_drink(local_day, occurred_at);
                CREATE TABLE food_day (local_day TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE food_target (
                    id TEXT PRIMARY KEY NOT NULL,
                    confirmed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX food_target_time ON food_target(confirmed_at);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.foodOverview, "11", applicationVersion])
        }
    }

    static func registerFoodMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.food) { db in
            try db.execute(sql: """
                CREATE TABLE food_meal (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_day TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    payload BLOB NOT NULL
                );
                CREATE INDEX food_meal_day ON food_meal(local_day, occurred_at);
                CREATE TABLE food_photo (
                    id TEXT PRIMARY KEY NOT NULL,
                    meal_id TEXT NOT NULL REFERENCES food_meal(id) ON DELETE CASCADE,
                    media_type TEXT NOT NULL CHECK(media_type IN ('image/jpeg', 'image/png', 'image/heic')),
                    captured_at REAL NOT NULL,
                    sha256 TEXT NOT NULL,
                    bytes BLOB NOT NULL CHECK(length(bytes) > 0)
                );
                CREATE INDEX food_photo_meal ON food_photo(meal_id);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.food, "10", applicationVersion])
        }
    }
}
