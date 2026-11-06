import Foundation

public extension StorageMigrationIdentifier {
    static let capacity = "storage-020-capacity"
}

public enum CapacityStorageSchema {
    public static let tableNames = ["capacity_result", "capacity_goal"]
}

extension StorageMigrations {
    /// Capacity tests: grip, dead hang, sit to stand, one-leg balance and heart rate recovery, plus the goal a person
    /// sets for age 85. The tables carry no `local_day` column on purpose: deleting one day of band data through
    /// `delete(localDay:)` must not erase a test the person did that day. A result keeps the time zone it was
    /// recorded in instead.
    ///
    /// The checks repeat the model's rules so no code path can store a unit that does not belong to a test, a side
    /// where none applies, or a source the test does not use: grip and sit to stand are typed, dead hang and balance
    /// are timed by the phone, heart rate recovery is read from a workout.
    static func registerCapacityMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.capacity) { db in
            try db.execute(sql: """
                CREATE TABLE capacity_result (
                    id TEXT PRIMARY KEY NOT NULL,
                    test_kind TEXT NOT NULL CHECK(test_kind IN ('grip', 'dead_hang', 'sit_to_stand', 'one_leg_balance', 'heart_rate_recovery')),
                    value REAL NOT NULL CHECK(value >= 0 AND value <= 1000),
                    unit TEXT NOT NULL,
                    side TEXT CHECK(side IS NULL OR side IN ('left', 'right')),
                    recorded_at REAL NOT NULL,
                    time_zone_identifier TEXT NOT NULL,
                    source TEXT NOT NULL CHECK(source IN ('typed', 'timed', 'workout')),
                    workout_id TEXT,
                    algorithm_version TEXT,
                    created_at REAL NOT NULL,
                    CHECK((test_kind = 'grip' AND unit = 'kg')
                        OR (test_kind IN ('dead_hang', 'one_leg_balance') AND unit = 's')
                        OR (test_kind = 'sit_to_stand' AND unit = 'points')
                        OR (test_kind = 'heart_rate_recovery' AND unit = 'bpm')),
                    CHECK((test_kind IN ('grip', 'one_leg_balance') AND side IS NOT NULL)
                        OR (test_kind NOT IN ('grip', 'one_leg_balance') AND side IS NULL)),
                    CHECK((test_kind IN ('grip', 'sit_to_stand') AND source = 'typed')
                        OR (test_kind IN ('dead_hang', 'one_leg_balance') AND source = 'timed')
                        OR (test_kind = 'heart_rate_recovery' AND source = 'workout')),
                    CHECK(source = 'workout' OR (workout_id IS NULL AND algorithm_version IS NULL)),
                    CHECK(source <> 'workout' OR (workout_id IS NOT NULL AND algorithm_version IS NOT NULL))
                );
                CREATE INDEX capacity_result_kind ON capacity_result(test_kind, recorded_at);
                CREATE UNIQUE INDEX capacity_result_workout ON capacity_result(workout_id) WHERE workout_id IS NOT NULL;
                CREATE TABLE capacity_goal (
                    test_kind TEXT PRIMARY KEY NOT NULL CHECK(test_kind IN ('grip', 'dead_hang', 'sit_to_stand', 'one_leg_balance', 'heart_rate_recovery')),
                    target_value REAL NOT NULL CHECK(target_value > 0 AND target_value <= 1000),
                    unit TEXT NOT NULL,
                    set_at REAL NOT NULL,
                    CHECK((test_kind = 'grip' AND unit = 'kg')
                        OR (test_kind IN ('dead_hang', 'one_leg_balance') AND unit = 's')
                        OR (test_kind = 'sit_to_stand' AND unit = 'points')
                        OR (test_kind = 'heart_rate_recovery' AND unit = 'bpm'))
                );
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.capacity, "20", applicationVersion])
        }
    }
}
