import Foundation

public extension StorageMigrationIdentifier {
    static let experiments = "storage-021-experiments"
}

public enum ExperimentStorageSchema {
    /// `experiment_night` is listed after its experiment; it also disappears with the experiment through the cascade.
    public static let tableNames = ["experiment", "experiment_night"]
}

extension StorageMigrations {
    /// An experiment tests one protocol rule on the person's own nights. The start record is written once: a trigger
    /// refuses an UPDATE of every column that defines the experiment, above all the outcome metric and its direction,
    /// so no code path can change what a result is measured by after day 1. Only `status` and `end_day` move, and
    /// only from running to finished or stopped. A night is keyed by experiment and local day; an absent outcome is
    /// NULL, never zero.
    ///
    /// Only one experiment runs at a time, because two interventions on the same nights confound each other.
    /// `experiment_night` keeps the `local_day` column name on purpose: deleting a day of data removes that day's
    /// night record, the same as a routine check.
    static func registerExperimentsMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.experiments) { db in
            try db.execute(sql: """
                CREATE TABLE experiment (
                    id TEXT PRIMARY KEY NOT NULL,
                    protocol_id TEXT NOT NULL REFERENCES routine_protocol(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    intervention_name TEXT NOT NULL,
                    rule_key TEXT NOT NULL,
                    design TEXT NOT NULL CHECK(design IN ('alternating', 'blocks', 'beforeAfter')),
                    design_length INTEGER,
                    washout INTEGER NOT NULL CHECK(washout >= 0),
                    minimum_nights INTEGER NOT NULL CHECK(minimum_nights >= 2),
                    planned_nights INTEGER NOT NULL CHECK(planned_nights >= 2),
                    outcome_key TEXT NOT NULL,
                    outcome_title TEXT NOT NULL,
                    outcome_unit TEXT NOT NULL,
                    outcome_direction TEXT NOT NULL CHECK(outcome_direction IN ('higher', 'lower')),
                    start_day TEXT NOT NULL,
                    time_zone_identifier TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('running', 'finished', 'stopped')),
                    end_day TEXT,
                    CHECK((design = 'alternating' AND design_length IS NULL)
                          OR (design <> 'alternating' AND design_length IS NOT NULL AND design_length >= 1)),
                    CHECK((status = 'running') = (end_day IS NULL))
                );
                CREATE UNIQUE INDEX experiment_one_running ON experiment(status) WHERE status = 'running';
                CREATE INDEX experiment_protocol ON experiment(protocol_id, start_day);
                CREATE TRIGGER experiment_start_immutable BEFORE UPDATE OF
                    id, protocol_id, title, intervention_name, rule_key, design, design_length, washout,
                    minimum_nights, planned_nights, outcome_key, outcome_title, outcome_unit, outcome_direction,
                    start_day, time_zone_identifier, created_at ON experiment
                BEGIN
                    SELECT RAISE(ABORT, 'an experiment start record cannot change');
                END;
                CREATE TRIGGER experiment_status_forward BEFORE UPDATE OF status, end_day ON experiment
                WHEN OLD.status <> 'running'
                BEGIN
                    SELECT RAISE(ABORT, 'a finished experiment cannot change');
                END;
                CREATE TABLE experiment_night (
                    experiment_id TEXT NOT NULL REFERENCES experiment(id) ON DELETE CASCADE,
                    local_day TEXT NOT NULL,
                    arm TEXT NOT NULL CHECK(arm IN ('on', 'off')),
                    washout INTEGER NOT NULL CHECK(washout IN (0, 1)),
                    adherence TEXT NOT NULL CHECK(adherence IN ('kept', 'missed', 'unknown')),
                    outcome_value REAL,
                    other_values TEXT NOT NULL DEFAULT '{}',
                    recorded_at REAL NOT NULL,
                    PRIMARY KEY (experiment_id, local_day)
                );
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.experiments, "21", applicationVersion])
        }
    }
}
