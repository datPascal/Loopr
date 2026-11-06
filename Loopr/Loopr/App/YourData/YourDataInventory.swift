import Foundation
import StorageKit

nonisolated enum YourDataDomain: String, CaseIterable, Codable, Sendable {
    case band, food, training, journal, other
    var title: String {
        switch self {
        case .band: "Band"
        case .food: "Food photos"
        case .training: "Fitness"
        case .journal: "Protocol"
        case .other: "Other"
        }
    }
    static func document(_ namespace: String) -> Self {
        switch namespace {
        case "sleep", "heart", "body", "stress", "today", "daily-analytics": .band
        case "food": .food
        case "workouts", "route": .training
        case "journal", "patterns": .journal
        // The request log and agent proposals. Stored text, listed under Other.
        case "agent": .other
        default: .other
        }
    }
    static func table(_ name: String) -> Self {
        if name.contains("workout") || name.contains("route") { return .training }
        if name.contains("journal") || name.contains("habit") { return .journal }
        if name.contains("food") { return .food }
        if name.contains("schema") || name.contains("migration") || name.contains("audit") { return .other }
        return .band
    }
}

nonisolated struct YourDataInventory: Sendable {
    var diskBytes: Int64 = 0
    var contentBytes: [YourDataDomain: Int64] = [:]
    var bandRecords: Int64 = 0
    var healthRecords: Int64 = 0
    var importedDays: Int64 = 0
    var meals: Int64 = 0
    var photos: Int64 = 0
    var workouts: Int64 = 0
    var checkIns: Int64 = 0
    var notes: Int64 = 0
}

/// Inventory reads the same two ledgers that the app uses. Domain sizes are
/// stored field bytes, not an invented allocation of SQLite pages or WAL space.
nonisolated struct YourDataStores: Sendable {
    struct Ledger: Sendable {
        let name: String
        let database: StorageDatabase
    }
    let ledgers: [Ledger]
    let supportDirectory: URL
    let photosDirectory: URL
    static let integrationDirectories = ["AIKit", "HealthKitBridge", "NotificationKit"]

    func inventory() throws -> YourDataInventory {
        var result = YourDataInventory()
        for ledger in ledgers {
            for suffix in ["", "-wal", "-shm"] {
                result.diskBytes += try Self.bytesIfPresent(URL(fileURLWithPath: ledger.database.path + suffix))
            }
            try ledger.database.read { db in
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                for table in tables {
                    let columns = try db.columns(in: table).map(\.name)
                    let bytes = columns.map { "COALESCE(length(CAST(\(Self.quote($0)) AS BLOB)),0)" }.joined(separator: "+")
                    let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(\(bytes)),0) FROM \(Self.quote(table))") ?? 0
                    if table == "loopr_product_document" {
                        let rows = try Row.fetchAll(db, sql: "SELECT namespace, SUM(\(bytes)) AS bytes FROM \(Self.quote(table)) GROUP BY namespace")
                        for row in rows {
                            result.contentBytes[YourDataDomain.document(row["namespace"]), default: 0] += row["bytes"] as Int64
                        }
                        result.workouts += try Self.documents(db, namespace: "workouts", prefix: "workout.")
                        result.checkIns += try Self.documents(db, namespace: "journal", prefix: "habit.day.")
                        result.notes += try Self.documents(db, namespace: "journal", prefix: "entry.")
                        result.meals += try Self.documents(db, namespace: "food", prefix: "meal.")
                    } else {
                        result.contentBytes[YourDataDomain.table(table), default: 0] += total
                    }
                    if table == "metric_series" {
                        result.bandRecords += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_series WHERE source = 'band'") ?? 0
                        result.healthRecords += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_series WHERE source = 'apple_health'") ?? 0
                    }
                    if table == "food_meal" {
                        result.meals += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM food_meal") ?? 0
                    }
                    if table == "food_photo" {
                        result.photos += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM food_photo") ?? 0
                    }
                    if table == "whoop_export_day" {
                        result.importedDays += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM whoop_export_day") ?? 0
                    }
                    if table == "whoop_export_workout" {
                        result.workouts += try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM whoop_export_workout") ?? 0
                    }
                }
            }
        }
        let photos = try Self.files(in: photosDirectory)
        result.photos += Int64(photos.count)
        for url in photos {
            let count = try Self.bytesIfPresent(url)
            result.diskBytes += count
            result.contentBytes[.food, default: 0] += count
        }
        for directory in Self.integrationDirectories {
            for url in try Self.files(in: supportDirectory.appendingPathComponent(directory)) {
                let count = try Self.bytesIfPresent(url)
                result.diskBytes += count
                result.contentBytes[.other, default: 0] += count
            }
        }
        return result
    }

    static func quote(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func documents(_ db: Database, namespace: String, prefix: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM loopr_product_document WHERE namespace = ? AND document_key LIKE ?", arguments: [namespace, prefix + "%"]) ?? 0
    }
    static func bytesIfPresent(_ url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    static func files(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var failure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
        }
        if let failure { throw failure }
        return files
    }
}
