import Foundation
import ImportKit

/// Errors emitted by the backup and legacy CSV parsers. ImportKit reports
/// account-export rows with missing dates or invalid fields in its summary.
public enum DataImportParserError: Error, Equatable, Sendable, LocalizedError {
    case emptyInput
    case invalidUTF8
    case unsupportedSchema(Int)
    case invalidBackup
    case invalidHeader
    case invalidRow(Int, String)
    case duplicateRecordID(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "The import file is empty."
        case .invalidUTF8: "The import file is not valid UTF-8."
        case .unsupportedSchema(let version): "Unsupported import schema version " + String(version) + "."
        case .invalidBackup: "The backup does not contain valid records."
        case .invalidHeader: "The CSV header is missing a required column or contains duplicates."
        case .invalidRow(let row, let reason): "CSV row " + String(row) + " is invalid: " + reason
        case .duplicateRecordID(let id): "The import contains duplicate record id " + id + "."
        }
    }
}

private enum DataImportValidation {
    static func validate(_ record: DataRecord, row: Int? = nil) throws {
        guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DataImportParserError.invalidRow(row ?? 0, "record id is empty")
        }
        guard !record.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DataImportParserError.invalidRow(row ?? 0, "table is empty")
        }
        guard isValidDay(record.day) else {
            throw DataImportParserError.invalidRow(row ?? 0, "day must be a valid ISO-8601 local day")
        }
    }

    static func isValidDay(_ day: String) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == pieces[0] && components.month == pieces[1] && components.day == pieces[2]
    }
}

/// Parses the deterministic JSON backup produced by Edge/Loopr's export
/// boundary.  The parser accepts the DataBackup envelope only; a random JSON
/// object or an unversioned array is rejected instead of being interpreted as
/// an Edge database.
public enum EdgeDatabaseMergeParser {
    public static let supportedSchemaVersion = 1

    public static func parse(_ data: Data) throws -> [DataRecord] {
        guard !data.isEmpty else { throw DataImportParserError.emptyInput }
        let backup: DataBackup
        do {
            backup = try JSONDecoder().decode(DataBackup.self, from: data)
        } catch {
            throw DataImportParserError.invalidBackup
        }
        guard backup.schemaVersion == supportedSchemaVersion else {
            throw DataImportParserError.unsupportedSchema(backup.schemaVersion)
        }
        return try normalize(backup.records, provenance: .edgeMerged)
    }

    public static func parseBackup(_ backup: DataBackup) throws -> [DataRecord] {
        guard backup.schemaVersion == supportedSchemaVersion else {
            throw DataImportParserError.unsupportedSchema(backup.schemaVersion)
        }
        return try normalize(backup.records, provenance: .edgeMerged)
    }

    private static func normalize(_ records: [DataRecord], provenance: DataProvenance) throws -> [DataRecord] {
        var seen = Set<String>()
        return try records.sorted { $0.id < $1.id }.map { record in
            try DataImportValidation.validate(record)
            guard seen.insert(record.id).inserted else {
                throw DataImportParserError.duplicateRecordID(record.id)
            }
            var normalized = record
            normalized.provenance = provenance
            // Imported Edge rows are inputs to Loopr's analysis and must not
            // claim a Loopr algorithm generation from the source database.
            normalized.algorithmVersion = nil
            return normalized
        }
    }
}

/// Account-export CSV adapter. Legacy Loopr-derived CSVs remain readable.
/// The streaming file/ZIP importer lives in ImportKit and also persists typed
/// day, sleep, workout and journal models.
public enum WHOOPCSVParser {
    public static func parse(_ data: Data) throws -> [DataRecord] {
        guard !data.isEmpty else { throw DataImportParserError.emptyInput }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DataImportParserError.invalidUTF8
        }
        if !text.hasPrefix("id,") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-csv-\(UUID().uuidString).csv")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            var records: [DataRecord] = []
            try WHOOPExportParser.parse(url: url) { row in
                records.append(DataRecord(id: row.id, day: row.day, table: row.kind.rawValue,
                    payload: row.fields, provenance: .whoopCSV))
            }
            return records
        }
        let rows = try CSV.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw DataImportParserError.invalidHeader }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(normalizedHeader).count == normalizedHeader.count else {
            throw DataImportParserError.invalidHeader
        }
        guard let idIndex = normalizedHeader.firstIndex(of: "id"),
              let dayIndex = normalizedHeader.firstIndex(of: "day"),
              let tableIndex = normalizedHeader.firstIndex(of: "table"),
              normalizedHeader.count > 3 else {
            throw DataImportParserError.invalidHeader
        }

        var seen = Set<String>()
        var records: [DataRecord] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard row.count == normalizedHeader.count else {
                throw DataImportParserError.invalidRow(rowNumber, "expected " + String(normalizedHeader.count) + " columns")
            }
            let id = row[idIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let day = row[dayIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let table = row[tableIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !table.isEmpty else {
                throw DataImportParserError.invalidRow(rowNumber, "id and table are required")
            }
            guard DataImportValidation.isValidDay(day) else {
                throw DataImportParserError.invalidRow(rowNumber, "day must be a valid ISO-8601 local day")
            }
            guard seen.insert(id).inserted else {
                throw DataImportParserError.duplicateRecordID(id)
            }

            var payload: [String: String] = [:]
            for index in normalizedHeader.indices where index != idIndex && index != dayIndex && index != tableIndex {
                let key = normalizedHeader[index]
                guard !key.isEmpty else { throw DataImportParserError.invalidHeader }
                payload[key] = row[index]
            }
            guard payload.values.contains(where: { !$0.isEmpty }) else {
                throw DataImportParserError.invalidRow(rowNumber, "at least one derived value is required")
            }
            records.append(DataRecord(
                id: id,
                day: day,
                table: table,
                payload: payload,
                provenance: .whoopCSV,
                algorithmVersion: nil
            ))
        }
        return records.sorted { $0.id < $1.id }
    }
}

/// Descriptive alias for call sites that use the product-language name.
public typealias WHOOPDerivedCSVParser = WHOOPCSVParser

/// Small coordinator used by import screens. It performs parse, repository
/// validation, and the transactional beginImport step in that order, so a
/// parser success is never presented as an applied import.
public struct DataImportCoordinator: Sendable {
    private let store: any DataStore

    public init(store: any DataStore) {
        self.store = store
    }

    public func previewWHOOPCSV(_ data: Data) async throws -> ImportPreview {
        try await store.validatedPreview(source: .whoopCSV, incoming: WHOOPCSVParser.parse(data))
    }

    public func importWHOOPCSV(_ data: Data) async throws -> ImportReceipt {
        try await store.beginImport(try await previewWHOOPCSV(data))
    }

    public func previewEdgeDatabaseMerge(_ data: Data) async throws -> ImportPreview {
        try await store.validatedPreview(source: .edgeMerge, incoming: EdgeDatabaseMergeParser.parse(data))
    }

    public func importEdgeDatabaseMerge(_ data: Data) async throws -> ImportReceipt {
        try await store.beginImport(try await previewEdgeDatabaseMerge(data))
    }
}

private enum CSV {
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        var atFieldStart = true
        let characters = Array(text)
        var index = 0

        func finishField() {
            row.append(field)
            field = ""
            atFieldStart = true
            closedQuote = false
        }

        func finishRow() {
            if !row.isEmpty || !field.isEmpty { finishField(); rows.append(row); row = [] }
        }

        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    quoted = false
                    closedQuote = true
                } else {
                    field.append(character)
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                guard atFieldStart else { throw DataImportParserError.invalidRow(rows.count + 1, "quote must start a field") }
                quoted = true
                atFieldStart = false
                index += 1
            case ",":
                finishField()
                index += 1
            case "\n":
                finishRow()
                index += 1
            case "\r":
                if index + 1 < characters.count, characters[index + 1] == "\n" { index += 2 } else { index += 1 }
                finishRow()
            default:
                guard !closedQuote else {
                    throw DataImportParserError.invalidRow(rows.count + 1, "characters after a quoted field require a delimiter")
                }
                field.append(character)
                atFieldStart = false
                index += 1
            }
        }
        guard !quoted else { throw DataImportParserError.invalidRow(rows.count + 1, "unterminated quote") }
        finishRow()
        while rows.last?.allSatisfy({ $0.isEmpty }) == true { rows.removeLast() }
        guard !rows.isEmpty else { throw DataImportParserError.emptyInput }
        return rows
    }
}
