import AnalyticsKit
import Foundation
import StorageKit

public enum LabStoreError: Error, Equatable, Sendable {
    case missingReport
    case missingValue
    case missingClockResult
    /// A stored row could not be read back. The message names the column.
    case corruptRow(String)
}

/// One stored value with the report it came from, for a marker's history and for the latest value.
public struct LabHistoryEntry: Sendable, Hashable {
    public let value: LabValue
    public let report: LabReport

    public init(value: LabValue, report: LabReport) {
        self.value = value
        self.report = report
    }
}

/// Blood test reports, their values and lab clock results, in the `lab_*` tables of `StorageDatabase`.
/// The store keeps what the lab printed: each value's own range, unit, flag text and source. Numbers are
/// stored as text in dot notation so the printed digits survive. Nothing here judges a value.
public final class LabStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Reports and values

    /// Saves a report and all its values in one transaction. Saving an existing report id replaces the report
    /// and its values. Values are stored in the order given.
    public func saveReport(_ report: LabReport, values: [LabValue]) throws {
        try report.validate()
        for value in values {
            try value.validate()
            guard value.reportID == report.id else { throw LabValidationError.valueBelongsToAnotherReport }
        }
        guard let day = report.collectedDay else { throw LabValidationError.unknownTimeZone(report.timeZoneIdentifier) }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO lab_report(id, collected_at, collected_day, time_zone_identifier, lab_name, fasting, source, created_at, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET collected_at = excluded.collected_at,
                    collected_day = excluded.collected_day, time_zone_identifier = excluded.time_zone_identifier,
                    lab_name = excluded.lab_name, fasting = excluded.fasting, source = excluded.source,
                    created_at = excluded.created_at, note = excluded.note
                """, arguments: [report.id.uuidString, report.collectedAt.timeIntervalSince1970, day,
                    report.timeZoneIdentifier, report.labName, report.fasting, report.source.rawValue,
                    report.createdAt.timeIntervalSince1970, report.note])
            try db.execute(sql: "DELETE FROM lab_value WHERE report_id = ?", arguments: [report.id.uuidString])
            for (position, value) in values.enumerated() {
                try Self.insert(value, position: position, in: db)
            }
        }
    }

    /// Replaces one value. The value stays in its report and at its position; a value whose `reportID`
    /// differs from the stored one is refused.
    public func updateValue(_ value: LabValue) throws {
        try value.validate()
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT report_id FROM lab_value WHERE id = ?",
                arguments: [value.id.uuidString]) else { throw LabStoreError.missingValue }
            guard (row["report_id"] as String) == value.reportID.uuidString else {
                throw LabValidationError.valueBelongsToAnotherReport
            }
            let (markerKey, otherName) = Self.subjectColumns(value.subject)
            try db.execute(sql: """
                UPDATE lab_value SET marker_key = ?, other_name = ?, assay = ?, value_text = ?, printed_value = ?, comparator = ?,
                    unit = ?, reference_low = ?, reference_high = ?, reference_text = ?, flag_text = ?, source = ?,
                    scan_confidence = ?, needs_review = ?
                WHERE id = ?
                """, arguments: [markerKey, otherName, value.assay, Self.text(value.value), value.printedValue,
                    value.comparator?.rawValue, value.unit,
                    value.referenceRange.low.map(Self.text), value.referenceRange.high.map(Self.text),
                    value.referenceRange.text, value.flagText, value.source.rawValue, value.scanConfidence,
                    value.needsReview, value.id.uuidString])
        }
    }

    /// Adds values to a saved report, after the ones it already holds: the next page of the same report. A value that
    /// repeats one already in the report (same test, number, sign and unit, as when a page header repeats) is left
    /// out. Returns the values that were added. A report that is gone is refused.
    @discardableResult
    public func appendValues(_ values: [LabValue], toReport reportID: UUID) throws -> [LabValue] {
        for value in values {
            try value.validate()
            guard value.reportID == reportID else { throw LabValidationError.valueBelongsToAnotherReport }
        }
        return try database.write { db -> [LabValue] in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report WHERE id = ?", arguments: [reportID.uuidString]) == 1 else {
                throw LabStoreError.missingReport
            }
            let existing = try Row.fetchAll(db, sql: "SELECT \(Self.valueColumns) FROM lab_value WHERE report_id = ? ORDER BY position, id",
                arguments: [reportID.uuidString]).map { try Self.value(from: $0, prefix: "") }
            var seen = Set(existing.map(Self.repeatKey))
            var position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM lab_value WHERE report_id = ?",
                arguments: [reportID.uuidString]) ?? -1) + 1
            var added: [LabValue] = []
            for value in values where seen.insert(Self.repeatKey(value)).inserted {
                try Self.insert(value, position: position, in: db)
                position += 1
                added.append(value)
            }
            return added
        }
    }

    /// Deletes the report and, through the cascade, all its values.
    public func deleteReport(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM lab_report WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw LabStoreError.missingReport }
        }
    }

    /// All reports, newest collection first. Reports collected at the same instant list the later-created first.
    public func reports() throws -> [LabReport] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.reportColumns) FROM lab_report ORDER BY collected_at DESC, created_at DESC, id DESC")
                .map { try Self.report(from: $0, prefix: "") }
        }
    }

    public func report(id: UUID) throws -> LabReport? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.reportColumns) FROM lab_report WHERE id = ?", arguments: [id.uuidString])
                .map { try Self.report(from: $0, prefix: "") }
        }
    }

    /// The values of one report in the order they were saved.
    public func values(reportID: UUID) throws -> [LabValue] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.valueColumns) FROM lab_value WHERE report_id = ? ORDER BY position, id",
                arguments: [reportID.uuidString]).map { try Self.value(from: $0, prefix: "") }
        }
    }

    /// Every value of one marker across reports, oldest collection first, for a chart. Values for an other
    /// name match the name ignoring case and accents.
    public func history(for subject: LabValueSubject) throws -> [LabHistoryEntry] {
        let entries: [LabHistoryEntry] = try database.read { db in
            switch subject {
            case .marker(let key):
                return try Self.entries(in: db, where: "v.marker_key = ?", arguments: [key.rawValue])
            case .other:
                return try Self.entries(in: db, where: "v.marker_key IS NULL", arguments: [])
            }
        }
        guard case .other(let name) = subject else { return entries }
        let wanted = Self.foldedName(name)
        return entries.filter { Self.foldedName($0.value.subject.displayName) == wanted }
    }

    /// The most recently collected value of every marker, and of every other name, that has one.
    public func latestValues() throws -> [LabValueSubject: LabHistoryEntry] {
        let entries = try database.read { db in try Self.entries(in: db, where: nil, arguments: []) }
        var latest: [String: LabHistoryEntry] = [:]
        for entry in entries { latest[Self.groupKey(entry.value.subject)] = entry }
        return Dictionary(latest.values.map { ($0.value.subject, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Lab clock results

    /// Saves a lab clock result as the lab reported it. Saving an existing id replaces it.
    public func saveClockResult(_ result: LabClockResult) throws {
        try result.validate()
        let (kind, name) = Self.clockColumns(result.kind)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO lab_clock_result(id, clock_kind, clock_name, value_text, unit, lab_name, collected_at,
                    time_zone_identifier, created_at, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET clock_kind = excluded.clock_kind, clock_name = excluded.clock_name,
                    value_text = excluded.value_text, unit = excluded.unit, lab_name = excluded.lab_name,
                    collected_at = excluded.collected_at, time_zone_identifier = excluded.time_zone_identifier,
                    created_at = excluded.created_at, note = excluded.note
                """, arguments: [result.id.uuidString, kind, name, Self.text(result.value), result.unit,
                    result.labName, result.collectedAt.timeIntervalSince1970, result.timeZoneIdentifier,
                    result.createdAt.timeIntervalSince1970, result.note])
        }
    }

    /// All clock results, newest collection first.
    public func clockResults() throws -> [LabClockResult] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, clock_kind, clock_name, value_text, unit, lab_name, collected_at, time_zone_identifier,
                    created_at, note
                FROM lab_clock_result ORDER BY collected_at DESC, created_at DESC, id DESC
                """).map { try Self.clockResult(from: $0) }
        }
    }

    public func deleteClockResult(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM lab_clock_result WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount > 0 else { throw LabStoreError.missingClockResult }
        }
    }
}

// MARK: Row mapping

private extension LabStore {
    static let reportColumnNames = ["id", "collected_at", "time_zone_identifier", "lab_name", "fasting", "source", "created_at", "note"]
    static let valueColumnNames = ["id", "report_id", "marker_key", "other_name", "assay", "value_text", "printed_value", "comparator", "unit",
        "reference_low", "reference_high", "reference_text", "flag_text", "source", "scan_confidence", "needs_review"]
    static var reportColumns: String { reportColumnNames.joined(separator: ", ") }
    static var valueColumns: String { valueColumnNames.joined(separator: ", ") }

    /// A joined query selects both tables under prefixed names so their `id` and `source` columns stay apart.
    static func joinedColumns() -> String {
        (reportColumnNames.map { "r.\($0) AS r_\($0)" } + valueColumnNames.map { "v.\($0) AS v_\($0)" }).joined(separator: ", ")
    }

    static func entries(in db: Database, where condition: String?, arguments: StatementArguments) throws -> [LabHistoryEntry] {
        let filter = condition.map { " WHERE \($0)" } ?? ""
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(joinedColumns()) FROM lab_value v JOIN lab_report r ON r.id = v.report_id\(filter)
            ORDER BY r.collected_at, r.created_at, r.id, v.position
            """, arguments: arguments)
        return try rows.map { LabHistoryEntry(value: try value(from: $0, prefix: "v_"), report: try report(from: $0, prefix: "r_")) }
    }

    static func insert(_ value: LabValue, position: Int, in db: Database) throws {
        let (markerKey, otherName) = subjectColumns(value.subject)
        try db.execute(sql: """
            INSERT INTO lab_value(id, report_id, position, marker_key, other_name, assay, value_text, printed_value, comparator,
                unit, reference_low, reference_high, reference_text, flag_text, source, scan_confidence, needs_review)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [value.id.uuidString, value.reportID.uuidString, position, markerKey, otherName,
                value.assay, text(value.value), value.printedValue, value.comparator?.rawValue, value.unit,
                value.referenceRange.low.map(text),
                value.referenceRange.high.map(text), value.referenceRange.text, value.flagText,
                value.source.rawValue, value.scanConfidence, value.needsReview])
    }

    /// What makes a value a repeat of another on the same report.
    static func repeatKey(_ value: LabValue) -> String {
        [groupKey(value.subject), text(value.value), value.comparator?.rawValue ?? "",
         (value.unit ?? "").trimmingCharacters(in: .whitespaces).lowercased()].joined(separator: "|")
    }

    /// Dot notation, whatever the device locale.
    static func text(_ number: Decimal) -> String { number.description }

    static func number(_ text: String, column: String) throws -> Decimal {
        guard let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else {
            throw LabStoreError.corruptRow(column)
        }
        return number
    }

    static func subjectColumns(_ subject: LabValueSubject) -> (markerKey: String?, otherName: String?) {
        switch subject {
        case .marker(let key): (key.rawValue, nil)
        case .other(let name): (nil, name)
        }
    }

    static func clockColumns(_ kind: LabClockKind) -> (kind: String, name: String?) {
        switch kind {
        case .dunedinPACE: ("dunedinpace", nil)
        case .grimAge: ("grimage", nil)
        case .other(let name): ("other", name)
        }
    }

    static func foldedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func groupKey(_ subject: LabValueSubject) -> String {
        switch subject {
        case .marker(let key): "m:\(key.rawValue)"
        case .other(let name): "o:\(foldedName(name))"
        }
    }

    static func source(_ raw: String, column: String) throws -> LabEntrySource {
        guard let source = LabEntrySource(rawValue: raw) else { throw LabStoreError.corruptRow(column) }
        return source
    }

    static func uuid(_ raw: String, column: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw LabStoreError.corruptRow(column) }
        return id
    }

    static func report(from row: Row, prefix: String) throws -> LabReport {
        LabReport(
            id: try uuid(row[prefix + "id"], column: "lab_report.id"),
            collectedAt: Date(timeIntervalSince1970: row[prefix + "collected_at"]),
            timeZoneIdentifier: row[prefix + "time_zone_identifier"],
            labName: row[prefix + "lab_name"],
            fasting: row[prefix + "fasting"],
            source: try source(row[prefix + "source"], column: "lab_report.source"),
            createdAt: Date(timeIntervalSince1970: row[prefix + "created_at"]),
            note: row[prefix + "note"])
    }

    /// A marker key this build does not know, written by a newer build, comes back as an other value under that
    /// key text rather than being dropped.
    static func value(from row: Row, prefix: String) throws -> LabValue {
        let subject: LabValueSubject
        if let raw: String = row[prefix + "marker_key"] {
            subject = LabMarkerKey(rawValue: raw).map(LabValueSubject.marker) ?? .other(name: raw)
        } else if let name: String = row[prefix + "other_name"] {
            subject = .other(name: name)
        } else {
            throw LabStoreError.corruptRow("lab_value.marker_key")
        }
        let valueText: String = row[prefix + "value_text"]
        let comparatorText: String? = row[prefix + "comparator"]
        let comparator = try comparatorText.map { raw in
            guard let sign = LabValueComparator(rawValue: raw) else { throw LabStoreError.corruptRow("lab_value.comparator") }
            return sign
        }
        let low: String? = row[prefix + "reference_low"]
        let high: String? = row[prefix + "reference_high"]
        return LabValue(
            id: try uuid(row[prefix + "id"], column: "lab_value.id"),
            reportID: try uuid(row[prefix + "report_id"], column: "lab_value.report_id"),
            subject: subject,
            assay: row[prefix + "assay"],
            value: try number(valueText, column: "lab_value.value_text"),
            printedValue: row[prefix + "printed_value"],
            comparator: comparator,
            unit: row[prefix + "unit"],
            referenceRange: LabReferenceRange(
                low: try low.map { try number($0, column: "lab_value.reference_low") },
                high: try high.map { try number($0, column: "lab_value.reference_high") },
                text: row[prefix + "reference_text"]),
            flagText: row[prefix + "flag_text"],
            source: try source(row[prefix + "source"], column: "lab_value.source"),
            scanConfidence: row[prefix + "scan_confidence"],
            needsReview: row[prefix + "needs_review"])
    }

    static func clockResult(from row: Row) throws -> LabClockResult {
        let kind: LabClockKind
        switch row["clock_kind"] as String {
        case "dunedinpace": kind = .dunedinPACE
        case "grimage": kind = .grimAge
        case "other":
            guard let name: String = row["clock_name"] else { throw LabStoreError.corruptRow("lab_clock_result.clock_name") }
            kind = .other(name: name)
        default: throw LabStoreError.corruptRow("lab_clock_result.clock_kind")
        }
        return LabClockResult(
            id: try uuid(row["id"], column: "lab_clock_result.id"),
            kind: kind,
            value: try number(row["value_text"], column: "lab_clock_result.value_text"),
            unit: row["unit"],
            labName: row["lab_name"],
            collectedAt: Date(timeIntervalSince1970: row["collected_at"]),
            timeZoneIdentifier: row["time_zone_identifier"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            note: row["note"])
    }
}
