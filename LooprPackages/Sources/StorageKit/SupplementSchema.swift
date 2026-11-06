import Foundation

public extension StorageMigrationIdentifier {
    static let foodLongevity = "storage-019-food-longevity"
}

public enum SupplementStorageSchema {
    /// `supplement_tick` is listed after its item; it also disappears with the item through the cascade.
    public static let tableNames = ["supplement_item", "supplement_tick"]
}

extension StorageMigrations {
    /// The supplement stacks, the medication lane and the taken ticks (DEC-12.10).
    ///
    /// Items and ticks share two tables, with `lane` telling the two lanes apart. The Swift API never returns both
    /// lanes in one list. A tick is keyed by item, local day and slot, so ticking twice is one row. A missing row
    /// means "not recorded"; only an explicit `skipped` row means skipped.
    ///
    /// The tick's day column is `local_day`, so deleting one day of food data also deletes that day's ticks, like
    /// meals and drinks. The item has no day column and survives a day deletion.
    static func registerFoodLongevityMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.foodLongevity) { db in
            try db.execute(sql: """
                CREATE TABLE supplement_item (
                    id TEXT PRIMARY KEY NOT NULL,
                    lane TEXT NOT NULL CHECK(lane IN ('supplement', 'medication')),
                    item_key TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    is_active INTEGER NOT NULL CHECK(is_active IN (0, 1)),
                    start_day TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    UNIQUE(lane, item_key)
                );
                CREATE INDEX supplement_item_order ON supplement_item(lane, sort_order, created_at);
                CREATE TABLE supplement_tick (
                    item_id TEXT NOT NULL REFERENCES supplement_item(id) ON DELETE CASCADE,
                    local_day TEXT NOT NULL,
                    slot TEXT NOT NULL CHECK(slot IN ('morning', 'evening')),
                    state TEXT NOT NULL CHECK(state IN ('taken', 'skipped')),
                    recorded_at REAL NOT NULL,
                    note TEXT,
                    PRIMARY KEY (item_id, local_day, slot)
                );
                CREATE INDEX supplement_tick_day ON supplement_tick(local_day);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.foodLongevity, "19", applicationVersion])
        }
    }
}
