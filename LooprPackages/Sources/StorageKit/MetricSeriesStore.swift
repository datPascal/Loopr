import Foundation

public extension StorageMigrationIdentifier {
    /// Adds the `source` dimension (band or Apple Health) and optional
    /// within-day extremes to `metric_series`.
    static let metricSeriesSource = "storage-008-metric-series-source"
}

/// Where one stored daily value came from. Raw values are durable data.
public enum StoredMetricSeriesSource: String, CaseIterable, Codable, Hashable, Sendable {
    case band
    case appleHealth = "apple_health"
    case whoopExport = "whoop_export"
}

/// One day of one metric from one source.
///
/// `localDay` is the civil day as `YYYY-MM-DD` in the time zone the value was
/// derived in. `metricKey` is an opaque string owned by the caller.
public struct StoredMetricSeriesValue: Equatable, Hashable, Sendable {
    public let localDay: String
    public let metricKey: String
    public let source: StoredMetricSeriesSource
    public let value: Double
    public let low: Double?
    public let high: Double?

    public init(localDay: String, metricKey: String, source: StoredMetricSeriesSource,
                value: Double, low: Double? = nil, high: Double? = nil) {
        self.localDay = localDay
        self.metricKey = metricKey
        self.source = source
        self.value = value
        self.low = low
        self.high = high
    }

    /// Non-finite numbers are never stored. A day without a real value is
    /// absent, not zero and not NaN.
    var isStorable: Bool {
        value.isFinite && (low?.isFinite ?? true) && (high?.isFinite ?? true)
            && StoredMetricSeriesValue.isLocalDay(localDay) && !metricKey.isEmpty
    }

    static func isLocalDay(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

public extension StorageMigrations {
    /// Rebuilds `metric_series` with a source column in its primary key, so a
    /// band value and an Apple Health value for the same day can coexist.
    /// Existing rows (written before sources existed) are band rows.
    static func registerMetricSeriesSourceMigration(
        on migrator: inout DatabaseMigrator,
        applicationVersion: String
    ) {
        migrator.registerMigration(StorageMigrationIdentifier.metricSeriesSource) { db in
            try db.execute(sql: """
                CREATE TABLE metric_series_v8 (
                    local_day TEXT NOT NULL,
                    metric_key TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'band',
                    value REAL,
                    low REAL,
                    high REAL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY(metric_key, source, local_day)
                )
                """)
            try db.execute(sql: """
                INSERT INTO metric_series_v8(local_day, metric_key, source, value, updated_at)
                SELECT local_day, metric_key, 'band', value, updated_at FROM metric_series
                """)
            try db.execute(sql: "DROP TABLE metric_series")
            try db.execute(sql: "ALTER TABLE metric_series_v8 RENAME TO metric_series")
            // Day-scoped deletion walks every table with a local_day column.
            try db.execute(sql: "CREATE INDEX metric_series_by_day ON metric_series(local_day)")
            try db.execute(
                sql: """
                INSERT INTO \(StorageMigrations.metadataTable)
                    (migration_identifier, schema_version, application_version)
                VALUES (?, ?, ?)
                """,
                arguments: [StorageMigrationIdentifier.metricSeriesSource, "8", applicationVersion]
            )
        }
    }
}

public extension StorageDatabase {
    /// Inserts or updates daily values. Writing the same value twice leaves
    /// the row untouched, so repeated derivations and re-imports are free.
    /// Non-finite values are skipped.
    func upsertMetricSeries(_ values: [StoredMetricSeriesValue], updatedAt: Int64) throws {
        let storable = values.filter(\.isStorable)
        guard !storable.isEmpty else { return }
        try write { db in
            for value in storable {
                try Self.upsert(value, updatedAt: updatedAt, in: db)
            }
        }
    }

    /// Replaces one source's values for a set of keys on one day.
    ///
    /// Keys in `keys` with no entry in `values` are deleted for that day and
    /// source, so a value that is no longer derivable disappears instead of
    /// lingering. Keys outside `keys` are not touched.
    func replaceMetricSeries(localDay: String, source: StoredMetricSeriesSource, keys: Set<String>,
                             with values: [StoredMetricSeriesValue], updatedAt: Int64) throws {
        guard StoredMetricSeriesValue.isLocalDay(localDay) else { return }
        let storable = values.filter { $0.isStorable && $0.localDay == localDay && $0.source == source }
        let present = Set(storable.map(\.metricKey))
        let cleared = keys.subtracting(present)
        guard !storable.isEmpty || !cleared.isEmpty else { return }
        try write { db in
            for key in cleared.sorted() {
                try db.execute(
                    sql: "DELETE FROM metric_series WHERE metric_key = ? AND source = ? AND local_day = ?",
                    arguments: [key, source.rawValue, localDay])
            }
            for value in storable {
                try Self.upsert(value, updatedAt: updatedAt, in: db)
            }
        }
    }

    /// Replaces one source's values for one key across an inclusive day range.
    /// Days in the range without a new value are deleted. Used by imports that
    /// re-read a window and must reflect deletions made at the source.
    func replaceMetricSeries(metricKey: String, source: StoredMetricSeriesSource,
                             from lowerDay: String, through upperDay: String,
                             with values: [StoredMetricSeriesValue], updatedAt: Int64) throws {
        guard StoredMetricSeriesValue.isLocalDay(lowerDay), StoredMetricSeriesValue.isLocalDay(upperDay),
              lowerDay <= upperDay else { return }
        let storable = values.filter {
            $0.isStorable && $0.metricKey == metricKey && $0.source == source
                && $0.localDay >= lowerDay && $0.localDay <= upperDay
        }
        let keep = Set(storable.map(\.localDay))
        try write { db in
            let existing = try String.fetchAll(db, sql: """
                SELECT local_day FROM metric_series
                WHERE metric_key = ? AND source = ? AND local_day >= ? AND local_day <= ?
                """, arguments: [metricKey, source.rawValue, lowerDay, upperDay])
            for day in existing where !keep.contains(day) {
                try db.execute(
                    sql: "DELETE FROM metric_series WHERE metric_key = ? AND source = ? AND local_day = ?",
                    arguments: [metricKey, source.rawValue, day])
            }
            for value in storable {
                try Self.upsert(value, updatedAt: updatedAt, in: db)
            }
        }
    }

    /// Every stored value for one key in an inclusive day range, ascending by
    /// day. Pass `source` to read one source only.
    func metricSeries(metricKey: String, from lowerDay: String, through upperDay: String,
                      source: StoredMetricSeriesSource? = nil) throws -> [StoredMetricSeriesValue] {
        try read { db in
            var sql = """
                SELECT local_day, metric_key, source, value, low, high FROM metric_series
                WHERE metric_key = ? AND local_day >= ? AND local_day <= ? AND value IS NOT NULL
                """
            var arguments: StatementArguments = [metricKey, lowerDay, upperDay]
            if let source {
                sql += " AND source = ?"
                arguments += [source.rawValue]
            }
            sql += " ORDER BY local_day ASC, source ASC"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.value(from:))
        }
    }

    /// One value per day for one key, ascending, taking the first source in
    /// `preference` that has a value for that day.
    func preferredMetricSeries(metricKey: String, from lowerDay: String, through upperDay: String,
                               preference: [StoredMetricSeriesSource] = [.band, .whoopExport, .appleHealth]) throws -> [StoredMetricSeriesValue] {
        let rank = Dictionary(uniqueKeysWithValues: preference.enumerated().map { ($0.element, $0.offset) })
        var chosen: [String: StoredMetricSeriesValue] = [:]
        for value in try metricSeries(metricKey: metricKey, from: lowerDay, through: upperDay) {
            guard let candidate = rank[value.source] else { continue }
            if let current = chosen[value.localDay], let currentRank = rank[current.source], currentRank <= candidate {
                continue
            }
            chosen[value.localDay] = value
        }
        return chosen.values.sorted { $0.localDay < $1.localDay }
    }

    /// The days in an inclusive range that hold at least one value from
    /// `source`.
    func metricSeriesDays(source: StoredMetricSeriesSource, from lowerDay: String,
                          through upperDay: String) throws -> Set<String> {
        try read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT local_day FROM metric_series
                WHERE source = ? AND local_day >= ? AND local_day <= ? AND value IS NOT NULL
                """, arguments: [source.rawValue, lowerDay, upperDay]))
        }
    }

    /// Removes every value from one source, for example after the person
    /// disconnects an import.
    func deleteMetricSeries(source: StoredMetricSeriesSource) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM metric_series WHERE source = ?", arguments: [source.rawValue])
        }
    }

    // MARK: Health import cursor

    /// The opaque progress marker an importer saved for `source`.
    func healthImportCursor(source: String) throws -> Data? {
        try read { db in
            try Data.fetchOne(db, sql: "SELECT anchor FROM health_import_cursor WHERE source = ?", arguments: [source])
        }
    }

    func setHealthImportCursor(_ anchor: Data?, source: String, updatedAt: Int64) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO health_import_cursor(source, anchor, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET anchor = excluded.anchor, updated_at = excluded.updated_at
                """, arguments: [source, anchor, updatedAt])
        }
    }

    func removeHealthImportCursors(prefix: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM health_import_cursor WHERE substr(source, 1, ?) = ?",
                           arguments: [prefix.count, prefix])
        }
    }

    private static func upsert(_ value: StoredMetricSeriesValue, updatedAt: Int64, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO metric_series(local_day, metric_key, source, value, low, high, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(metric_key, source, local_day) DO UPDATE SET
                value = excluded.value, low = excluded.low, high = excluded.high, updated_at = excluded.updated_at
            WHERE metric_series.value IS NOT excluded.value
               OR metric_series.low IS NOT excluded.low
               OR metric_series.high IS NOT excluded.high
            """, arguments: [value.localDay, value.metricKey, value.source.rawValue,
                             value.value, value.low, value.high, updatedAt])
    }

    private static func value(from row: Row) -> StoredMetricSeriesValue? {
        guard let source = StoredMetricSeriesSource(rawValue: row["source"]),
              let number: Double = row["value"] else { return nil }
        return StoredMetricSeriesValue(localDay: row["local_day"], metricKey: row["metric_key"],
                                       source: source, value: number, low: row["low"], high: row["high"])
    }
}
