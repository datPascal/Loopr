import Foundation
import StorageKit

/// Capacity results and goals in the `capacity_*` tables of `StorageDatabase` (`storage-020-capacity`).
public final class CapacityStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Results

    /// Saves a result. Saving an existing id replaces it. A workout result replaces any earlier result for the same
    /// workout, so reading a workout again never adds a second row.
    public func save(_ result: CapacityResult) throws {
        try result.validate()
        try database.write { db in
            if let workoutID = result.workoutID {
                try db.execute(sql: "DELETE FROM capacity_result WHERE workout_id = ? AND id <> ?",
                    arguments: [workoutID.uuidString, result.id.uuidString])
            }
            try db.execute(sql: """
                INSERT INTO capacity_result(id, test_kind, value, unit, side, recorded_at, time_zone_identifier, source,
                    workout_id, algorithm_version, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET test_kind = excluded.test_kind, value = excluded.value, unit = excluded.unit,
                    side = excluded.side, recorded_at = excluded.recorded_at,
                    time_zone_identifier = excluded.time_zone_identifier, source = excluded.source,
                    workout_id = excluded.workout_id, algorithm_version = excluded.algorithm_version,
                    created_at = excluded.created_at
                """, arguments: [result.id.uuidString, result.kind.rawValue, result.value, result.unit, result.side?.rawValue,
                    result.recordedAt.timeIntervalSince1970, result.timeZoneIdentifier, result.source.rawValue,
                    result.workoutID?.uuidString, result.algorithmVersion, result.createdAt.timeIntervalSince1970])
        }
    }

    public func delete(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM capacity_result WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw CapacityError.missingResult }
        }
    }

    /// Every result of one test, newest first.
    public func history(for kind: CapacityTestKind) throws -> CapacityHistory {
        let results = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM capacity_result WHERE test_kind = ?",
                arguments: [kind.rawValue]).map(Self.result(from:))
        }
        return CapacityHistory(kind: kind, results: results)
    }

    public func latest(for kind: CapacityTestKind) throws -> CapacityResult? { try history(for: kind).latest }

    public func allResults() throws -> [CapacityResult] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM capacity_result").map(Self.result(from:))
        }
    }

    // MARK: Goals at 85

    /// Saves the goal for one test, replacing the earlier one.
    public func save(_ goal: CapacityGoal) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO capacity_goal(test_kind, target_value, unit, set_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(test_kind) DO UPDATE SET target_value = excluded.target_value, unit = excluded.unit,
                    set_at = excluded.set_at
                """, arguments: [goal.kind.rawValue, goal.targetValue, goal.unit, goal.setAt.timeIntervalSince1970])
        }
    }

    public func goal(for kind: CapacityTestKind) throws -> CapacityGoal? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT test_kind, target_value, set_at FROM capacity_goal WHERE test_kind = ?",
                arguments: [kind.rawValue]).map(Self.goal(from:))
        }
    }

    public func goals() throws -> [CapacityTestKind: CapacityGoal] {
        let all = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT test_kind, target_value, set_at FROM capacity_goal").map(Self.goal(from:))
        }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })
    }

    public func deleteGoal(for kind: CapacityTestKind) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM capacity_goal WHERE test_kind = ?", arguments: [kind.rawValue])
        }
    }

    // MARK: Rows

    private static let columns = "id, test_kind, value, side, recorded_at, time_zone_identifier, source, workout_id, algorithm_version, created_at"

    private static func result(from row: Row) throws -> CapacityResult {
        guard let id = UUID(uuidString: row["id"] as String) else { throw CapacityError.corruptRow("id") }
        guard let kind = CapacityTestKind(rawValue: row["test_kind"] as String) else { throw CapacityError.corruptRow("test_kind") }
        guard let source = CapacitySource(rawValue: row["source"] as String) else { throw CapacityError.corruptRow("source") }
        let side: CapacitySide?
        if let text = row["side"] as String? {
            guard let parsed = CapacitySide(rawValue: text) else { throw CapacityError.corruptRow("side") }
            side = parsed
        } else { side = nil }
        let workoutID: UUID?
        if let text = row["workout_id"] as String? {
            guard let parsed = UUID(uuidString: text) else { throw CapacityError.corruptRow("workout_id") }
            workoutID = parsed
        } else { workoutID = nil }
        do {
            return try CapacityResult(id: id, kind: kind, value: row["value"], side: side,
                recordedAt: Date(timeIntervalSince1970: row["recorded_at"]), timeZoneIdentifier: row["time_zone_identifier"],
                source: source, workoutID: workoutID, algorithmVersion: row["algorithm_version"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]))
        } catch { throw CapacityError.corruptRow("value") }
    }

    private static func goal(from row: Row) throws -> CapacityGoal {
        guard let kind = CapacityTestKind(rawValue: row["test_kind"] as String) else { throw CapacityError.corruptRow("test_kind") }
        do {
            return try CapacityGoal(kind: kind, targetValue: row["target_value"], setAt: Date(timeIntervalSince1970: row["set_at"]))
        } catch { throw CapacityError.corruptRow("target_value") }
    }
}
