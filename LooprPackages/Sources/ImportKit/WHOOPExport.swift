import Foundation
import CryptoKit

public enum WHOOPImportError: Error, LocalizedError, Sendable {
    case noCSV, invalidCSV(Int), duplicateHeader, missingHeader(String), invalidTimezone(String), invalidZIP, unsupportedZIP, oversized, corruptZIP
    public var errorDescription: String? {
        switch self {
        case .noCSV: "Choose the export zip, its folder, or an export CSV."
        case .invalidCSV(let row): "CSV row \(row) has invalid quoting or text."
        case .duplicateHeader: "The CSV has duplicate column names."
        case .missingHeader(let header): "The CSV is missing the \(header) column."
        case .invalidTimezone(let zone): "The export has an unrecognized timezone: \(zone)."
        case .invalidZIP: "The zip file is incomplete or invalid."
        case .unsupportedZIP: "Loopr cannot read this zip format. Extract the CSV files and choose them instead."
        case .oversized: "This export exceeds the import size limit."
        case .corruptZIP: "A file in the zip failed its integrity check."
        }
    }
}

public enum WHOOPExportKind: String, Codable, Sendable, CaseIterable {
    case cycle = "physiological_cycles", sleep = "sleeps", workout = "workouts", journal = "journal_entries"
}

public struct WHOOPExportRow: Codable, Equatable, Sendable {
    public let id: String
    public let kind: WHOOPExportKind
    public let day: String
    public let timezone: String
    public let start: Date
    public let end: Date?
    public let fields: [String: String]
    public func text(_ header: String) -> String? { fields[WHOOPExportParser.header(header)] }
    public var isNap: Bool { ["true", "yes", "1"].contains(text("Nap")?.lowercased() ?? "") }
    public func number(_ header: String) -> Double? {
        guard let text = text(header), let value = Double(text), value.isFinite, value >= 0, value <= 10_000_000 else { return nil }
        return value
    }
}

public struct WHOOPParseSummary: Equatable, Sendable {
    public var rows = 0
    public var missingDate = 0
    public var invalidRows = 0
    public init() {}
}

/// Header names and minute/bpm/ms units follow WHOOP's account data export
/// documentation. No upstream parsing logic is used here. CSV fields are read one row at a time.
public enum WHOOPExportParser {
    public static func header(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\([^)]*\)|%|\uFEFF"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @discardableResult
    public static func parse(url: URL, kind supplied: WHOOPExportKind? = nil,
                             consume: (WHOOPExportRow) throws -> Void) throws -> WHOOPParseSummary {
        let reader = try CSVRowReader(url: url)
        guard let headings = try reader.next(), !headings.isEmpty else { throw WHOOPImportError.noCSV }
        let names = headings.map(header)
        guard Set(names).count == names.count else { throw WHOOPImportError.duplicateHeader }
        let kind: WHOOPExportKind
        if let supplied { kind = supplied }
        else if names.contains("workout start time") { kind = .workout }
        else if names.contains("question text") { kind = .journal }
        else if names.contains("nap") || (names.contains("sleep onset") && !names.contains("recovery score") && !names.contains("day strain")) { kind = .sleep }
        else if names.contains("cycle start time") { kind = .cycle }
        else { throw WHOOPImportError.missingHeader("Cycle start time") }
        let required = kind == .workout ? "workout start time" : kind == .sleep ? "sleep onset" : "cycle start time"
        guard names.contains(required) else { throw WHOOPImportError.missingHeader(required) }
        var summary = WHOOPParseSummary()
        while let cells = try reader.next() {
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            guard cells.count == names.count else { summary.invalidRows += 1; continue }
            let fields = Dictionary(uniqueKeysWithValues: zip(names, cells).compactMap { name, cell -> (String, String)? in
                let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : (name, value)
            })
            let zoneText = fields["cycle timezone"] ?? fields["timezone"]
            // A zoneless timestamp without a row timezone cannot be resolved
            // honestly. Explicit offsets on the timestamp remain sufficient.
            let zone = zoneText.flatMap(timeZone)
            if let zoneText, zone == nil { throw WHOOPImportError.invalidTimezone(zoneText) }
            guard let start = date(fields[required], zone: zone) else { summary.missingDate += 1; continue }
            let endKey = kind == .workout ? "workout end time" : "wake onset"
            let end = date(fields[endKey], zone: zone ?? fields[required].flatMap(explicitZone))
            if (kind == .sleep || kind == .workout) && (end == nil || end! <= start) {
                summary.invalidRows += 1; continue
            }
            // NOOP docs/releases/v8.2.1.md describes the export's onset-cycle
            // convention. Wake timestamps label nights and recovery days.
            let dayDate = (kind == .cycle || kind == .sleep) ? (end ?? start) : start
            let dayZone = zone ?? explicitZone(fields[required]!)!
            let day = dayLabel(dayDate, zone: dayZone)
            let naturalKey = kind == .journal ? "\(Int64(start.timeIntervalSince1970)):\(fields["question text"] ?? "")" : "\(Int64(start.timeIntervalSince1970))"
            let id = "whoop-export:\(kind.rawValue):" + SHA256.hash(data: Data(naturalKey.utf8)).map { String(format: "%02x", $0) }.joined()
            try consume(WHOOPExportRow(id: id, kind: kind, day: day, timezone: dayZone.identifier, start: start, end: end, fields: fields))
            summary.rows += 1
        }
        return summary
    }

    public static func timeZone(_ text: String) -> TimeZone? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if clean == "UTC" || clean == "GMT" || clean == "Z" { return TimeZone(secondsFromGMT: 0) }
        let suffix = clean.replacingOccurrences(of: "UTC", with: "").replacingOccurrences(of: "GMT", with: "")
        if suffix.range(of: #"^[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil {
            let digits = suffix.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 14, minutes < 60,
                  hours < 14 || minutes == 0 else { return nil }
            return TimeZone(secondsFromGMT: (suffix.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
        }
        return TimeZone(identifier: text)
    }

    private static func explicitZone(_ text: String) -> TimeZone? {
        if text.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        guard let range = text.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) else { return nil }
        return timeZone(String(text[range]))
    }

    static func date(_ text: String?, zone: TimeZone?) -> Date? {
        guard let text else { return nil }
        let localDay = String(text.prefix(10))
        guard localDay.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard parts.count == 3, let civil = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayLabel(civil, zone: calendar.timeZone) == localDay else { return nil }
        if explicitZone(text) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let result = formatter.date(from: text.replacingOccurrences(of: " ", with: "T")) { return result }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text.replacingOccurrences(of: " ", with: "T"))
        }
        guard let zone else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.isLenient = false
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let result = formatter.date(from: text), formatter.string(from: result) == text { return result }
        }
        return nil
    }

    public static func dayLabel(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Bounded byte reader, including RFC 4180 escaped quotes and embedded CR/LF.
private final class CSVRowReader {
    private let handle: FileHandle
    private var bytes = Data()
    private var offset = 0
    private var pending: UInt8?
    private var rowNumber = 1
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        bytes = try handle.read(upToCount: 65_536) ?? Data()
        // Consume a UTF-8 BOM before CSV syntax, including quoted headers.
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { offset = 3 }
    }
    deinit { try? handle.close() }
    private func byte() throws -> UInt8? {
        if let pending { self.pending = nil; return pending }
        if offset == bytes.count {
            bytes = try handle.read(upToCount: 65_536) ?? Data(); offset = 0
            if bytes.isEmpty { return nil }
        }
        defer { offset += 1 }
        return bytes[offset]
    }
    func next() throws -> [String]? {
        var row: [String] = []; var field = Data(); var quoted = false; var closed = false; var saw = false
        func finish() throws {
            guard let value = String(data: field, encoding: .utf8) else { throw WHOOPImportError.invalidCSV(rowNumber) }
            row.append(value); field.removeAll(keepingCapacity: true); closed = false
        }
        while let value = try byte() {
            saw = true
            if quoted {
                if value == 34 {
                    if let next = try byte() {
                        if next == 34 { field.append(34) }
                        else { quoted = false; closed = true; pending = next }
                    } else { quoted = false; closed = true }
                } else { field.append(value) }
            } else if value == 34 {
                guard field.isEmpty && !closed else { throw WHOOPImportError.invalidCSV(rowNumber) }
                quoted = true
            } else if value == 44 { try finish() }
            else if value == 10 || value == 13 {
                if value == 13, let next = try byte(), next != 10 { pending = next }
                try finish(); rowNumber += 1; return row
            } else {
                guard !closed else { throw WHOOPImportError.invalidCSV(rowNumber) }
                field.append(value)
            }
            guard field.count <= 1_048_576, row.count <= 512 else { throw WHOOPImportError.oversized }
        }
        guard !quoted else { throw WHOOPImportError.invalidCSV(rowNumber) }
        guard saw || !row.isEmpty else { return nil }
        try finish(); rowNumber += 1; return row
    }
}
