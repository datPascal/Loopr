import Foundation

public extension StorageMigrationIdentifier {
    static let labs = "storage-017-labs"
    static let labValueComparator = "storage-023-lab-value-comparator"
}

public enum LabStorageSchema {
    /// `lab_value` is listed after its report; it also disappears with the report through the cascade.
    public static let tableNames = ["lab_report", "lab_value", "lab_clock_result"]
}

extension StorageMigrations {
    /// Blood tests keep what the lab printed. Numbers are stored as TEXT in dot notation so the digits survive
    /// exactly and no locale can turn a decimal point into a comma. Nothing here classifies a value: the
    /// reference range, unit and flag are the lab's own words.
    ///
    /// The report's day column is `collected_day`, not `local_day`, on purpose: deleting one day of band data
    /// through `delete(localDay:)` must not erase a blood test that happened to be drawn that day.
    static func registerLabsMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.labs) { db in
            try db.execute(sql: """
                CREATE TABLE lab_report (
                    id TEXT PRIMARY KEY NOT NULL,
                    collected_at REAL NOT NULL,
                    collected_day TEXT NOT NULL,
                    time_zone_identifier TEXT NOT NULL,
                    lab_name TEXT,
                    fasting INTEGER CHECK(fasting IS NULL OR fasting IN (0, 1)),
                    source TEXT NOT NULL CHECK(source IN ('typed', 'scan')),
                    created_at REAL NOT NULL,
                    note TEXT
                );
                CREATE INDEX lab_report_collected ON lab_report(collected_at, created_at);
                CREATE TABLE lab_value (
                    id TEXT PRIMARY KEY NOT NULL,
                    report_id TEXT NOT NULL REFERENCES lab_report(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL CHECK(position >= 0),
                    marker_key TEXT,
                    other_name TEXT,
                    assay TEXT,
                    value_text TEXT NOT NULL,
                    printed_value TEXT,
                    unit TEXT,
                    reference_low TEXT,
                    reference_high TEXT,
                    reference_text TEXT,
                    flag_text TEXT,
                    source TEXT NOT NULL CHECK(source IN ('typed', 'scan')),
                    scan_confidence REAL CHECK(scan_confidence IS NULL OR (scan_confidence >= 0 AND scan_confidence <= 1)),
                    needs_review INTEGER NOT NULL DEFAULT 0 CHECK(needs_review IN (0, 1)),
                    CHECK((marker_key IS NOT NULL AND other_name IS NULL) OR (marker_key IS NULL AND other_name IS NOT NULL)),
                    CHECK(source = 'scan' OR (scan_confidence IS NULL AND needs_review = 0))
                );
                CREATE INDEX lab_value_report ON lab_value(report_id, position);
                CREATE INDEX lab_value_marker ON lab_value(marker_key);
                CREATE TABLE lab_clock_result (
                    id TEXT PRIMARY KEY NOT NULL,
                    clock_kind TEXT NOT NULL CHECK(clock_kind IN ('dunedinpace', 'grimage', 'other')),
                    clock_name TEXT,
                    value_text TEXT NOT NULL,
                    unit TEXT,
                    lab_name TEXT NOT NULL,
                    collected_at REAL NOT NULL,
                    time_zone_identifier TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    note TEXT,
                    CHECK((clock_kind = 'other' AND clock_name IS NOT NULL) OR (clock_kind <> 'other' AND clock_name IS NULL))
                );
                CREATE INDEX lab_clock_result_collected ON lab_clock_result(collected_at);
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.labs, "17", applicationVersion])
        }
    }

    /// A result the lab printed as a limit, "<0.3" below detection or ">200" above the measuring range, keeps its sign
    /// in `comparator`; `value_text` holds the limit. NULL is an exact result, so every row stored before this
    /// migration reads as it did. The column is added in place, so no row is copied or rewritten.
    static func registerLabValueComparatorMigration(on migrator: inout DatabaseMigrator, applicationVersion: String) {
        migrator.registerMigration(StorageMigrationIdentifier.labValueComparator) { db in
            try db.execute(sql: """
                ALTER TABLE lab_value ADD COLUMN comparator TEXT
                    CHECK(comparator IS NULL OR comparator IN ('<', '<=', '>', '>='));
                """)
            try db.execute(sql: "INSERT INTO \(metadataTable) VALUES (?, ?, ?)",
                arguments: [StorageMigrationIdentifier.labValueComparator, "23", applicationVersion])
        }
    }
}
