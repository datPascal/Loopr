import Foundation

public extension StorageMigrationIdentifier {
    static let train = "storage-014-train"
}

public enum TrainStorageSchema {
    /// `workout_set` is listed last; it also disappears with its session through the cascade.
    public static let tableNames = ["workout_template", "workout_program", "workout_exercise_custom", "workout_session", "workout_set"]
}

extension StorageMigrations {
    static func registerTrainMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.train) { db in
            try db.execute(sql: """
                CREATE TABLE workout_template (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    payload BLOB NOT NULL
                );
                CREATE TABLE workout_program (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('draft', 'active', 'paused', 'completed', 'archived')),
                    updated_at REAL NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    payload BLOB NOT NULL
                );
                CREATE INDEX workout_program_status ON workout_program(status, updated_at);
                CREATE TABLE workout_exercise_custom (
                    key TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    payload BLOB NOT NULL
                );
                CREATE TABLE workout_session (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_day TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    workout_id TEXT,
                    status TEXT NOT NULL CHECK(status IN ('active', 'completed', 'abandoned')),
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    payload BLOB NOT NULL
                );
                CREATE INDEX workout_session_day ON workout_session(local_day, started_at);
                CREATE INDEX workout_session_workout ON workout_session(workout_id);
                CREATE TABLE workout_set (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES workout_session(id) ON DELETE CASCADE,
                    session_exercise_id TEXT NOT NULL,
                    exercise_key TEXT NOT NULL,
                    position INTEGER NOT NULL CHECK(position >= 0),
                    logged_at REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX workout_set_session ON workout_set(session_id, session_exercise_id, position);
                CREATE INDEX workout_set_exercise ON workout_set(exercise_key, logged_at);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.train, "14", applicationVersion])
        }
    }
}
