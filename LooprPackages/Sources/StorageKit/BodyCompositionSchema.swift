import Foundation

public extension StorageMigrationIdentifier {
    static let bodyComposition = "storage-022-body-composition"
}

public enum BodyCompositionStorageSchema {
    public static let tableNames = ["body_composition"]
}

extension StorageMigrations {
    /// Body fat and lean mass a person types in next to a weight. The weight itself stays in `food_weight`, so the
    /// Food lens keeps reading the same readings. A row here belongs to one weight reading and goes with it: the
    /// foreign key cascades, so deleting the reading, deleting its local day or clearing the Food weights leaves no
    /// orphan. The table has no `local_day` column on purpose, because the weight row already carries the day.
    ///
    /// Both values are optional, but a row holds at least one: a weight with neither needs no row, and an absent
    /// value is NULL, never zero. The checks repeat the entry sheet's ranges (body fat 2 to 75 percent, lean mass
    /// 10 to 200 kg) so no code path can store a number outside them. "Lean mass below the weight" is checked in
    /// the model, because the weight sits in another table's payload.
    static func registerBodyCompositionMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.bodyComposition) { db in
            try db.execute(sql: """
                CREATE TABLE body_composition (
                    weight_id TEXT PRIMARY KEY NOT NULL REFERENCES food_weight(id) ON DELETE CASCADE,
                    body_fat_percent REAL CHECK(body_fat_percent IS NULL OR (body_fat_percent >= 2 AND body_fat_percent <= 75)),
                    lean_mass_kilograms REAL CHECK(lean_mass_kilograms IS NULL OR (lean_mass_kilograms >= 10 AND lean_mass_kilograms <= 200)),
                    created_at REAL NOT NULL,
                    CHECK(body_fat_percent IS NOT NULL OR lean_mass_kilograms IS NOT NULL)
                );
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.bodyComposition, "22", applicationVersion])
        }
    }
}
