import DesignSystem
import Foundation
import StorageKit

// LV-08b step 1: "Your vault · nothing leaves unless you send it". The file card reads the real databases: their size
// on disk and the days that have a stored value. The facts also hold the schema version, the number of the newest
// migration applied (`storage-021-experiments` is version 21), which the card does not show. The source rows and the
// header meta read real counts.

public struct DataVaultFacts: Equatable, Sendable {
    /// Both SQLite ledgers with their write-ahead and shared-memory files.
    public var fileBytes: Int64
    /// Local days with at least one stored daily value, from any source.
    public var daysOfData: Int
    /// The earliest such day, `yyyy-MM-dd`.
    public var firstDay: String?
    /// The newest applied migration's number. Nil when none is recorded.
    public var schemaVersion: Int?
    /// Days imported from a WHOOP account export.
    public var importedDays: Int

    public init(fileBytes: Int64 = 0, daysOfData: Int = 0, firstDay: String? = nil, schemaVersion: Int? = nil, importedDays: Int = 0) {
        self.fileBytes = fileBytes
        self.daysOfData = daysOfData
        self.firstDay = firstDay
        self.schemaVersion = schemaVersion
        self.importedDays = importedDays
    }
}

public enum DataVaultReader {
    /// Reads the facts from the products and band-history ledgers. Run it off the main thread.
    public static func read(_ databases: [StorageDatabase]) throws -> DataVaultFacts {
        var facts = DataVaultFacts()
        var days = Set<String>()
        for database in databases {
            for suffix in ["", "-wal", "-shm"] {
                facts.fileBytes += fileBytes(atPath: database.path + suffix)
            }
            try database.read { db in
                let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
                if tables.contains("metric_series") {
                    days.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT local_day FROM metric_series"))
                }
                if tables.contains("whoop_export_day") {
                    facts.importedDays += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM whoop_export_day") ?? 0
                }
                if tables.contains("grdb_migrations") {
                    let versions = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").compactMap(schemaNumber)
                    if let newest = versions.max() { facts.schemaVersion = max(facts.schemaVersion ?? 0, newest) }
                }
            }
        }
        facts.daysOfData = days.count
        facts.firstDay = days.min()
        return facts
    }

    /// 21 for "storage-021-experiments". Nil for an identifier without a number.
    public static func schemaNumber(_ identifier: String) -> Int? {
        let parts = identifier.split(separator: "-")
        guard parts.count >= 2, parts[0] == "storage" else { return nil }
        return Int(parts[1])
    }

    static func fileBytes(atPath path: String) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

/// The file you can hold: its name, how much room it takes on this iPhone and how many days it holds. The schema
/// version stays in `DataVaultFacts` for support and is not shown (ICP R2-LAB-16).
public struct DataVaultCard: Equatable, Sendable {
    /// `loopr-2026-10-25.sqlite`, today's date in the person's time zone.
    public let fileName: String
    /// "Storage on this iPhone: 186 MB · 412 days of data". The size uses the app's number locale.
    public let detail: String

    public var spokenLabel: String { "Your data, \(detail.replacingOccurrences(of: " · ", with: ", "))" }

    /// - Parameter locale: formats the size. The default is `LooprUnitFormatter.displayLocale`, the digits every other
    ///   number in Loopr uses (ICP R2-LAB-16, R2-LAB-18).
    public static func make(facts: DataVaultFacts, now: Date, calendar: Calendar,
                            locale: Locale = LooprUnitFormatter.displayLocale) -> DataVaultCard {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let name = String(format: "loopr-%04ld-%02ld-%02ld.sqlite", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let size = facts.fileBytes.formatted(.byteCount(style: .file).locale(locale))
        let days = facts.daysOfData == 0 ? "no days of data yet" : DataText.count(facts.daysOfData, "day", "days") + " of data"
        return DataVaultCard(fileName: name, detail: "Storage on this iPhone: \(size) · \(days)")
    }
}

// MARK: - Sources

public enum DataSourceKind: String, CaseIterable, Sendable, Hashable {
    case band
    case appleHealth = "apple-health"
    case labs
    case whoopExport = "whoop-export"

    /// `data-source-band`, `data-source-apple-health`, `data-source-labs`, `data-source-whoop-export`.
    public var identifier: String { "data-source-\(rawValue)" }

    public var accent: LooprColorToken {
        switch self {
        case .band: .brand
        case .appleHealth: .heart
        case .labs: .sleep
        case .whoopExport: .inkSecondary
        }
    }
}

/// What the source rows and the header meta count.
public struct DataSourceFacts: Equatable, Sendable {
    /// The band's model as the app names it, "WHOOP 4.0". Nil without a paired band.
    public var bandName: String?
    public var bandLastSync: Date?
    /// Apple Health's distinct writing apps and devices, by label.
    public var appleHealthSources: [String]
    /// The kinds Apple Health supplied, as the row names them: "VO₂max", "daylight", "weight".
    public var appleHealthKinds: [String]
    /// True when the person switched every Apple Health read off.
    public var appleHealthSwitchedOff: Bool
    public var labReports: Int
    public var labValues: Int
    /// The lab names on the reports; nil for a report without one.
    public var labNames: [String?]
    public var importedDays: Int

    public init(bandName: String? = nil, bandLastSync: Date? = nil, appleHealthSources: [String] = [],
                appleHealthKinds: [String] = [], appleHealthSwitchedOff: Bool = false, labReports: Int = 0, labValues: Int = 0,
                labNames: [String?] = [], importedDays: Int = 0) {
        self.bandName = bandName
        self.bandLastSync = bandLastSync
        self.appleHealthSources = appleHealthSources
        self.appleHealthKinds = appleHealthKinds
        self.appleHealthSwitchedOff = appleHealthSwitchedOff
        self.labReports = labReports
        self.labValues = labValues
        self.labNames = labNames
        self.importedDays = importedDays
    }

    /// A paired band counts one, each Apple Health app or device one, each lab one (reports without a lab name
    /// together count one), and a WHOOP account export one.
    public var sourceCount: Int {
        let labs = Set(labNames.map { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }).count
        return (bandName == nil ? 0 : 1) + Set(appleHealthSources).count + (labReports > 0 ? labs : 0) + (importedDays > 0 ? 1 : 0)
    }
}

public struct DataSourceRow: Equatable, Sendable, Identifiable {
    public let kind: DataSourceKind
    public let text: String

    public var id: DataSourceKind { kind }

    public static func rows(_ facts: DataSourceFacts, now: Date) -> [DataSourceRow] {
        var rows: [DataSourceRow] = []
        if let name = facts.bandName {
            let sync = LooprSyncAge.label(lastSync: facts.bandLastSync, now: now).map { $0.lowercasedFirst } ?? "not synced yet"
            rows.append(DataSourceRow(kind: .band, text: "\(name) · \(sync)"))
        } else {
            rows.append(DataSourceRow(kind: .band, text: "No band paired"))
        }
        let health: String
        if facts.appleHealthSwitchedOff {
            health = "reads switched off"
        } else if facts.appleHealthKinds.isEmpty {
            health = "nothing read yet"
        } else {
            health = DataText.list(facts.appleHealthKinds) + appleHealthApps(facts.appleHealthSources)
        }
        rows.append(DataSourceRow(kind: .appleHealth, text: "Apple Health · \(health)"))
        rows.append(DataSourceRow(kind: .labs, text: facts.labReports == 0 ? "No lab reports yet"
            : "\(DataText.count(facts.labReports, "lab report", "lab reports")) · \(DataText.count(facts.labValues, "value", "values"))"))
        if facts.importedDays > 0 {
            rows.append(DataSourceRow(kind: .whoopExport, text: "WHOOP account export · \(DataText.count(facts.importedDays, "day", "days"))"))
        }
        return rows
    }
}

extension DataSourceRow {
    /// " from Apple Watch and Withings": the apps and devices that wrote the kinds, three at most by name.
    static func appleHealthApps(_ sources: [String]) -> String {
        var seen = Set<String>()
        let names = sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !names.isEmpty else { return "" }
        if names.count <= 3 { return " from " + DataText.list(names) }
        return " from " + DataText.list(Array(names.prefix(2)) + ["\(names.count - 2) more"])
    }
}

public enum DataVaultMeta {
    /// "412 days · 7 sources · all on this iPhone". Without vault facts, only where the data lives; with no stored day,
    /// "No data yet · all on this iPhone", so an empty state never shows counts.
    public static func line(facts: DataVaultFacts?, sources: DataSourceFacts) -> String {
        guard let facts else { return "All on this iPhone" }
        guard facts.daysOfData > 0 else {
            // A blood test is data too: "No data yet" sat over a blood age of 29 (ICP R3-LAB-6).
            guard sources.labReports > 0 else { return "No data yet · all on this iPhone" }
            return "\(DataText.count(sources.labReports, "blood test", "blood tests")) · all on this iPhone"
        }
        return "\(DataText.count(facts.daysOfData, "day", "days")) · \(DataText.count(sources.sourceCount, "source", "sources")) · all on this iPhone"
    }
}
