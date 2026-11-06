import Foundation

public extension StorageMigrationIdentifier {
    static let routine = "storage-016-routine"
    static let routineCheckSkipped = "storage-024-routine-check-skipped"
    static let routineCheckAnsweredFrom = "storage-025-routine-check-answered-from"
}

public enum RoutineStorageSchema {
    /// `routine_version` and `routine_check` disappear with their protocol through the cascade.
    public static let tableNames = ["routine_protocol", "routine_version", "routine_check"]
}

extension StorageMigrations {
    /// A protocol is a versioned list of rules. Versions are append-only: the trigger rejects an UPDATE so a saved
    /// version can never change, whichever code path writes it. Checks are keyed by protocol, rule key and local day,
    /// not by version, so a rule's history follows its key across version bumps.
    static func registerRoutineMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.routine) { db in
            try db.execute(sql: """
                CREATE TABLE routine_protocol (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    is_active INTEGER NOT NULL CHECK(is_active IN (0, 1)),
                    payload BLOB NOT NULL
                );
                CREATE UNIQUE INDEX routine_protocol_one_active ON routine_protocol(is_active) WHERE is_active = 1;
                CREATE TABLE routine_version (
                    protocol_id TEXT NOT NULL REFERENCES routine_protocol(id) ON DELETE CASCADE,
                    version INTEGER NOT NULL CHECK(version > 0),
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (protocol_id, version)
                );
                CREATE TRIGGER routine_version_immutable BEFORE UPDATE ON routine_version
                BEGIN
                    SELECT RAISE(ABORT, 'a saved protocol version cannot change');
                END;
                CREATE TABLE routine_check (
                    protocol_id TEXT NOT NULL REFERENCES routine_protocol(id) ON DELETE CASCADE,
                    rule_key TEXT NOT NULL,
                    local_day TEXT NOT NULL,
                    version INTEGER NOT NULL CHECK(version > 0),
                    state TEXT NOT NULL CHECK(state IN ('kept', 'missed', 'pending', 'unknown')),
                    source TEXT NOT NULL CHECK(source IN ('band', 'food', 'fitness', 'appleHealth', 'manual')),
                    measured_value REAL,
                    overridden INTEGER NOT NULL CHECK(overridden IN (0, 1)),
                    recorded_at REAL NOT NULL,
                    PRIMARY KEY (protocol_id, rule_key, local_day),
                    CHECK(state <> 'unknown' OR measured_value IS NULL)
                );
                CREATE INDEX routine_check_day ON routine_check(protocol_id, local_day);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.routine, "16", applicationVersion])
        }
    }

    /// "Skip today" (`CheckState.skipped`): a rule the person skipped for the day is neither kept nor missed. SQLite
    /// cannot change a CHECK constraint in place, so `routine_check` is rebuilt with the fifth state allowed and every
    /// stored check copied over as it was. Nothing references `routine_check`, so the copy breaks no foreign key.
    static func registerRoutineCheckSkippedMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.routineCheckSkipped) { db in
            try db.execute(sql: """
                CREATE TABLE routine_check_next (
                    protocol_id TEXT NOT NULL REFERENCES routine_protocol(id) ON DELETE CASCADE,
                    rule_key TEXT NOT NULL,
                    local_day TEXT NOT NULL,
                    version INTEGER NOT NULL CHECK(version > 0),
                    state TEXT NOT NULL CHECK(state IN ('kept', 'missed', 'pending', 'unknown', 'skipped')),
                    source TEXT NOT NULL CHECK(source IN ('band', 'food', 'fitness', 'appleHealth', 'manual')),
                    measured_value REAL,
                    overridden INTEGER NOT NULL CHECK(overridden IN (0, 1)),
                    recorded_at REAL NOT NULL,
                    PRIMARY KEY (protocol_id, rule_key, local_day),
                    CHECK(state <> 'unknown' OR measured_value IS NULL)
                );
                INSERT INTO routine_check_next(protocol_id, rule_key, local_day, version, state, source, measured_value,
                                               overridden, recorded_at)
                    SELECT protocol_id, rule_key, local_day, version, state, source, measured_value, overridden, recorded_at
                    FROM routine_check;
                DROP TABLE routine_check;
                ALTER TABLE routine_check_next RENAME TO routine_check;
                CREATE INDEX routine_check_day ON routine_check(protocol_id, local_day);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.routineCheckSkipped, "24", applicationVersion])
        }
    }

    /// Where an answer came from (`RuleCheck.answeredFrom`): "reminder" for Done or Skip today on a rule reminder, NULL
    /// for everything else (ICP round 4, SEN and VET). Adding a column that may be NULL keeps every stored check as it
    /// was, and a build that does not know the column reads and writes the table as before.
    static func registerRoutineCheckAnsweredFromMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.routineCheckAnsweredFrom) { db in
            try db.execute(sql: "ALTER TABLE routine_check ADD COLUMN answered_from TEXT")
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.routineCheckAnsweredFrom, "25", applicationVersion])
        }
    }
}
