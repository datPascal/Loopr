import DomainKit
import Foundation
import StorageKit

/// The protocol shown on the Protocol tab and Today's rail: the active protocol and its newest version.
public struct ActiveProtocol: Equatable, Sendable {
    public let routineProtocol: RoutineProtocol
    public let latestVersion: ProtocolVersion
    public init(routineProtocol: RoutineProtocol, latestVersion: ProtocolVersion) {
        self.routineProtocol = routineProtocol; self.latestVersion = latestVersion
    }
}

/// Protocols, their immutable versions and the check history, in the app's one SQLite database
/// (`storage-016-routine`). A version is written once and never updated. Checks are keyed by protocol, rule key and
/// local day, so a rule's history follows its key across versions. Deleting a protocol removes its versions and checks
/// in one statement through the foreign-key cascade.
public final class RoutineStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Protocols and versions

    /// Saves a new protocol with version 1, dated `protocol.createdAt`. With `activate`, it becomes the one active
    /// protocol and the previous one stays stored but inactive.
    @discardableResult
    public func createProtocol(_ routineProtocol: RoutineProtocol, rules: [ProtocolRule], note: String? = nil,
                               activate: Bool = true) throws -> ProtocolVersion {
        try routineProtocol.validate()
        let first = try ProtocolVersion(protocolID: routineProtocol.id, number: 1,
                                        createdAt: routineProtocol.createdAt, note: note, rules: rules)
        return try database.write { db in
            try Self.insertProtocol(routineProtocol, first: first, activate: activate, in: db)
            return first
        }
    }

    /// Writes a new protocol row and its first version. With `activate`, every other protocol becomes inactive.
    static func insertProtocol(_ routineProtocol: RoutineProtocol, first: ProtocolVersion, activate: Bool,
                               in db: Database) throws {
        if activate { try db.execute(sql: "UPDATE routine_protocol SET is_active = 0 WHERE is_active = 1") }
        try db.execute(sql: """
            INSERT INTO routine_protocol(id, name, created_at, is_active, payload) VALUES (?, ?, ?, ?, ?)
            """, arguments: [routineProtocol.id.rawValue.uuidString, routineProtocol.name,
                             routineProtocol.createdAt.timeIntervalSince1970, activate ? 1 : 0,
                             try encode(routineProtocol)])
        try insert(first, in: db)
    }

    /// Saves the next version of a protocol. The number is the highest saved number plus one, and earlier versions
    /// stay as they were.
    @discardableResult
    public func saveVersion(protocolID: ProtocolID, rules: [ProtocolRule], note: String? = nil,
                            at date: Date) throws -> ProtocolVersion {
        try database.write { db in
            guard try Self.protocolExists(protocolID, in: db) else { throw RoutineError.missingProtocol }
            let highest = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM routine_version WHERE protocol_id = ?",
                                           arguments: [protocolID.rawValue.uuidString]) ?? 0
            let next = try ProtocolVersion(protocolID: protocolID, number: highest + 1, createdAt: date,
                                           note: note, rules: rules)
            try Self.insert(next, in: db)
            return next
        }
    }

    /// Makes one protocol the active one and every other inactive.
    public func setActive(protocolID: ProtocolID) throws {
        try database.write { db in
            guard try Self.protocolExists(protocolID, in: db) else { throw RoutineError.missingProtocol }
            try db.execute(sql: "UPDATE routine_protocol SET is_active = 0 WHERE is_active = 1")
            try db.execute(sql: "UPDATE routine_protocol SET is_active = 1 WHERE id = ?",
                           arguments: [protocolID.rawValue.uuidString])
        }
    }

    public func routineProtocol(id: ProtocolID) throws -> RoutineProtocol? {
        try database.read { db in try Self.routineProtocol(id: id, in: db) }
    }

    /// Every stored protocol, oldest first.
    public func protocols() throws -> [RoutineProtocol] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM routine_protocol ORDER BY created_at, id")
                .map { try Self.decode(RoutineProtocol.self, from: $0) }
        }
    }

    /// The active protocol with its newest version, or nil when the person has none.
    public func activeProtocol() throws -> ActiveProtocol? {
        try database.read { db in
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM routine_protocol WHERE is_active = 1") else {
                return nil
            }
            let routineProtocol = try Self.decode(RoutineProtocol.self, from: payload)
            guard let latest = try Self.latestVersion(of: routineProtocol.id, in: db) else { throw RoutineError.corruptRecord }
            return ActiveProtocol(routineProtocol: routineProtocol, latestVersion: latest)
        }
    }

    public func version(protocolID: ProtocolID, number: Int) throws -> ProtocolVersion? {
        try database.read { db in try Self.version(protocolID, number, in: db) }
    }

    public func latestVersion(protocolID: ProtocolID) throws -> ProtocolVersion? {
        try database.read { db in try Self.latestVersion(of: protocolID, in: db) }
    }

    /// The version in force at `date`: the newest one created on or before it. Nil when every version is newer.
    public func versionInForce(protocolID: ProtocolID, at date: Date) throws -> ProtocolVersion? {
        try database.read { db in
            try Data.fetchOne(db, sql: """
                SELECT payload FROM routine_version WHERE protocol_id = ? AND created_at <= ? ORDER BY version DESC LIMIT 1
                """, arguments: [protocolID.rawValue.uuidString, date.timeIntervalSince1970]).map(Self.decodeVersion)
        }
    }

    /// Every version of a protocol, version 1 first.
    public func versions(protocolID: ProtocolID) throws -> [ProtocolVersion] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM routine_version WHERE protocol_id = ? ORDER BY version",
                              arguments: [protocolID.rawValue.uuidString])
                .map { try Self.decodeVersion($0) }
        }
    }

    /// Removes a protocol with all its versions and checks. Returns false when there was no such protocol.
    @discardableResult
    public func deleteProtocol(id: ProtocolID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM routine_protocol WHERE id = ?", arguments: [id.rawValue.uuidString])
            return db.changesCount > 0
        }
    }

    // MARK: Checks

    /// Records the outcome of one rule on one day, replacing an earlier automatic outcome for that day. A day the
    /// person overrode keeps their decision: a later automatic check does not replace it, and the stored check is
    /// returned. The rule must belong to the version the check names.
    @discardableResult
    public func recordCheck(_ check: RuleCheck, protocolID: ProtocolID) throws -> RuleCheck {
        try database.write { db in try Self.record(check, protocolID: protocolID, in: db) }
    }

    /// Records several checks in one transaction, with the rules of `recordCheck`. Returns what is stored for each, in
    /// the order given. Nothing is stored if one check is rejected.
    @discardableResult
    public func recordChecks(_ checks: [RuleCheck], protocolID: ProtocolID) throws -> [RuleCheck] {
        try database.write { db in try checks.map { try Self.record($0, protocolID: protocolID, in: db) } }
    }

    /// Removes one stored check, such as a tick taken back. Returns false when there was none.
    @discardableResult
    public func removeCheck(protocolID: ProtocolID, ruleKey: RuleKey, day: DayIdentity) throws -> Bool {
        guard let dayKey = day.routineDayKey else { throw RoutineError.invalidCheck }
        return try database.write { db in
            try db.execute(sql: "DELETE FROM routine_check WHERE protocol_id = ? AND rule_key = ? AND local_day = ?",
                           arguments: [protocolID.rawValue.uuidString, ruleKey.rawValue, dayKey])
            return db.changesCount > 0
        }
    }

    /// A person marks a rule kept, missed or skipped, whatever a source said. The source becomes `manual`, the measured
    /// value stays as the source measured it, so the day sheet can still say what the source saw, and automatic checks
    /// stop replacing the day. Without an earlier check the rule is looked up in the newest version.
    /// `answeredFrom` names where the answer came from when it was not in the app, such as a rule reminder.
    @discardableResult
    public func overrideCheck(protocolID: ProtocolID, ruleKey: RuleKey, day: DayIdentity, state: CheckState,
                              at date: Date, answeredFrom: AnswerOrigin? = nil) throws -> RuleCheck {
        guard state == .kept || state == .missed || state == .skipped else { throw RoutineError.invalidOverride }
        return try database.write { db in
            guard try Self.protocolExists(protocolID, in: db) else { throw RoutineError.missingProtocol }
            let existing = try Self.check(protocolID, ruleKey, day, in: db)
            let versionNumber: Int
            if let existing {
                versionNumber = existing.version
            } else {
                guard let latest = try Self.latestVersion(of: protocolID, in: db) else { throw RoutineError.missingVersion }
                guard latest.rule(for: ruleKey) != nil else { throw RoutineError.unknownRule(ruleKey) }
                versionNumber = latest.number
            }
            let overridden = try RuleCheck(ruleKey: ruleKey, day: day, version: versionNumber, state: state,
                                           source: .manual, measuredValue: existing?.measuredValue,
                                           overriddenByPerson: true, recordedAt: date, answeredFrom: answeredFrom)
            try Self.upsert(overridden, protocolID: protocolID, in: db)
            return overridden
        }
    }

    public func check(protocolID: ProtocolID, ruleKey: RuleKey, day: DayIdentity) throws -> RuleCheck? {
        try database.read { db in try Self.check(protocolID, ruleKey, day, in: db) }
    }

    /// Every check recorded for one day, ordered by rule key. A rule with no row has not been checked: callers show
    /// it as pending or unknown, they do not read the gap as missed.
    public func checks(protocolID: ProtocolID, day: DayIdentity) throws -> [RuleCheck] {
        guard let key = day.routineDayKey else { throw RoutineError.invalidCheck }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM routine_check WHERE protocol_id = ? AND local_day = ? ORDER BY rule_key",
                             arguments: [protocolID.rawValue.uuidString, key]).map(Self.check(from:))
        }
    }

    /// One rule's checks across every version of the protocol, oldest day first. `from` and `through` are inclusive.
    public func history(protocolID: ProtocolID, ruleKey: RuleKey, from: DayIdentity? = nil,
                        through: DayIdentity? = nil) throws -> [RuleCheck] {
        var sql = "SELECT * FROM routine_check WHERE protocol_id = ? AND rule_key = ?"
        var arguments: StatementArguments = [protocolID.rawValue.uuidString, ruleKey.rawValue]
        if let from {
            guard let key = from.routineDayKey else { throw RoutineError.invalidCheck }
            sql += " AND local_day >= ?"; arguments += StatementArguments([key])
        }
        if let through {
            guard let key = through.routineDayKey else { throw RoutineError.invalidCheck }
            sql += " AND local_day <= ?"; arguments += StatementArguments([key])
        }
        sql += " ORDER BY local_day"
        return try database.read { [sql, arguments] db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.check(from:))
        }
    }

    /// The earliest day with a check of this protocol, from any version. A protocol moved over from the Journal carries
    /// answers from before it was created, so its history starts here rather than on its creation day.
    public func firstCheckDay(protocolID: ProtocolID) throws -> DayIdentity? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT MIN(local_day) FROM routine_check WHERE protocol_id = ?",
                                arguments: [protocolID.rawValue.uuidString])
        }.flatMap(DayIdentity.init(routineDayKey:))
    }

    // MARK: Storage helpers

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw RoutineError.corruptRecord }
    }

    private static func decodeVersion(_ data: Data) throws -> ProtocolVersion {
        try decode(ProtocolVersion.self, from: data)
    }

    static func insert(_ version: ProtocolVersion, in db: Database) throws {
        try db.execute(sql: "INSERT INTO routine_version(protocol_id, version, created_at, payload) VALUES (?, ?, ?, ?)",
                       arguments: [version.protocolID.rawValue.uuidString, version.number,
                                   version.createdAt.timeIntervalSince1970, try encode(version)])
    }

    static func protocolExists(_ id: ProtocolID, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM routine_protocol WHERE id = ?", arguments: [id.rawValue.uuidString]) != nil
    }

    private static func routineProtocol(id: ProtocolID, in db: Database) throws -> RoutineProtocol? {
        try Data.fetchOne(db, sql: "SELECT payload FROM routine_protocol WHERE id = ?",
                          arguments: [id.rawValue.uuidString]).map { try decode(RoutineProtocol.self, from: $0) }
    }

    private static func version(_ id: ProtocolID, _ number: Int, in db: Database) throws -> ProtocolVersion? {
        try Data.fetchOne(db, sql: "SELECT payload FROM routine_version WHERE protocol_id = ? AND version = ?",
                          arguments: [id.rawValue.uuidString, number]).map(decodeVersion)
    }

    static func latestVersion(of id: ProtocolID, in db: Database) throws -> ProtocolVersion? {
        try Data.fetchOne(db, sql: "SELECT payload FROM routine_version WHERE protocol_id = ? ORDER BY version DESC LIMIT 1",
                          arguments: [id.rawValue.uuidString]).map(decodeVersion)
    }

    private static func check(_ id: ProtocolID, _ key: RuleKey, _ day: DayIdentity, in db: Database) throws -> RuleCheck? {
        guard let dayKey = day.routineDayKey else { throw RoutineError.invalidCheck }
        return try Row.fetchOne(db, sql: "SELECT * FROM routine_check WHERE protocol_id = ? AND rule_key = ? AND local_day = ?",
                                arguments: [id.rawValue.uuidString, key.rawValue, dayKey]).map(check(from:))
    }

    static func record(_ check: RuleCheck, protocolID: ProtocolID, in db: Database) throws -> RuleCheck {
        guard try Self.protocolExists(protocolID, in: db) else { throw RoutineError.missingProtocol }
        guard let saved = try Self.version(protocolID, check.version, in: db) else { throw RoutineError.missingVersion }
        guard saved.rule(for: check.ruleKey) != nil else { throw RoutineError.unknownRule(check.ruleKey) }
        if let existing = try Self.check(protocolID, check.ruleKey, check.day, in: db),
           existing.overriddenByPerson, !check.overriddenByPerson {
            return existing
        }
        try upsert(check, protocolID: protocolID, in: db)
        return check
    }

    private static func upsert(_ check: RuleCheck, protocolID: ProtocolID, in db: Database) throws {
        guard let dayKey = check.day.routineDayKey else { throw RoutineError.invalidCheck }
        try db.execute(sql: """
            INSERT INTO routine_check(protocol_id, rule_key, local_day, version, state, source, measured_value,
                                      overridden, recorded_at, answered_from)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(protocol_id, rule_key, local_day) DO UPDATE SET version = excluded.version,
                state = excluded.state, source = excluded.source, measured_value = excluded.measured_value,
                overridden = excluded.overridden, recorded_at = excluded.recorded_at, answered_from = excluded.answered_from
            """, arguments: [protocolID.rawValue.uuidString, check.ruleKey.rawValue, dayKey, check.version,
                             check.state.rawValue, check.source.rawValue, check.measuredValue,
                             check.overriddenByPerson ? 1 : 0, check.recordedAt.timeIntervalSince1970,
                             check.answeredFrom?.rawValue])
    }

    private static func check(from row: Row) throws -> RuleCheck {
        guard let day = DayIdentity(routineDayKey: row["local_day"] as String),
              let state = CheckState(rawValue: row["state"] as String),
              let source = CheckSource(rawValue: row["source"] as String) else { throw RoutineError.corruptRecord }
        return try RuleCheck(ruleKey: RuleKey(rawValue: row["rule_key"] as String), day: day,
                             version: row["version"] as Int, state: state, source: source,
                             measuredValue: row["measured_value"] as Double?,
                             overriddenByPerson: (row["overridden"] as Int) == 1,
                             recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double),
                             answeredFrom: (row["answered_from"] as String?).flatMap(AnswerOrigin.init(rawValue:)))
    }
}
