import Foundation
import FoodKit
import StorageKit

nonisolated enum YourDataExportKind: Sendable { case everything, databases }

nonisolated enum YourDataFileWorker {
    static let queue = DispatchQueue(label: "com.loopr.your-data.files", qos: .utility)
    // Screen loads and explicit exports are user-initiated. Only automatic
    // backups use utility priority; all operations still share the serial queue.
    static func run<Value: Sendable>(qos: DispatchQoS = .userInitiated,
                                    _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: qos) {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

nonisolated struct YourDataExporter: Sendable {
    let stores: YourDataStores
    let defaultsData: Data
    let temporaryDirectory: URL

    func prepare(_ kind: YourDataExportKind, now: Date = Date()) throws -> URL {
        let root = temporaryDirectory.appendingPathComponent("loopr-export-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Loopr", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        do {
            try stage(kind, at: contents, now: now)
            let archive = root.appendingPathComponent("Loopr-\(ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-" )).zip")
            try Self.archive(contents, to: archive)
            try FileManager.default.removeItem(at: contents)
            return archive
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Exposed internally so tests can inspect exact table data before ZIP packaging.
    func stage(_ kind: YourDataExportKind, at contents: URL, now: Date) throws {
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var tableManifest: [[String: Any]] = []
        for ledger in stores.ledgers {
            let folder = contents.appendingPathComponent(ledger.name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let snapshot = try ledger.database.export(to: folder.appendingPathComponent("\(ledger.name).sqlite"))
            if kind == .everything {
                // A read-only connection to the completed backup gives JSON, CSV
                // and SQLite one consistent state, without migrating the snapshot.
                var configuration = Configuration()
                configuration.readonly = true
                let database = try DatabaseQueue(path: snapshot.path, configuration: configuration)
                try database.read { db in
                    let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                    for table in tables {
                        let columns = try db.columns(in: table).map(\.name)
                        let count = try Self.exportTable(table, columns: columns, db: db, folder: folder)
                        tableManifest.append(["database": ledger.name, "table": table, "columns": columns, "rows": count, "filename": Self.fileStem(table)])
                    }
                    if tables.contains("food_photo") {
                        let photos = contents.appendingPathComponent("photos/\(ledger.name)", isDirectory: true)
                        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM food_photo ORDER BY id")
                        while let row = try rows.next() {
                            guard let id = UUID(uuidString: row["id"]), let type = FoodPhotoType(rawValue: row["media_type"]) else { throw FoodError.invalidPhoto }
                            let photo = try FoodPhoto(id: id, type: type, capturedAt: Date(timeIntervalSince1970: row["captured_at"]), bytes: row["bytes"])
                            guard photo.reference.sha256 == row["sha256"] as String else { throw FoodError.invalidPhoto }
                            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
                            try photo.bytes.write(to: photos.appendingPathComponent(photo.reference.fileName), options: .atomic)
                        }
                    }
                }
            }
        }
        if kind == .everything {
            try defaultsData.write(to: contents.appendingPathComponent("preferences.plist"), options: .atomic)
            for name in YourDataStores.integrationDirectories {
                let source = stores.supportDirectory.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: contents.appendingPathComponent(name, isDirectory: true))
                }
            }
            if FileManager.default.fileExists(atPath: stores.photosDirectory.path) {
                let photos = contents.appendingPathComponent("photos", isDirectory: true)
                if FileManager.default.fileExists(atPath: photos.path) {
                    try FileManager.default.copyItem(at: stores.photosDirectory, to: photos.appendingPathComponent("legacy", isDirectory: true))
                } else {
                    try FileManager.default.copyItem(at: stores.photosDirectory, to: photos)
                }
            }
        }
        let manifest: [String: Any] = [
            "formatVersion": 1, "createdAt": ISO8601DateFormatter().string(from: now),
            "kind": kind == .everything ? "everything" : "databases",
            "databases": stores.ledgers.map(\.name), "tables": tableManifest,
            "json": "SQL null is JSON null. BLOBs use an object with the base64 field. Integers remain integers.",
            "csv": "UTF-8. Every text value is quoted. SQL NULL is an unquoted empty field. BLOBs are base64: followed by Base64 bytes.",
            "excluded": ["API keys and other Keychain secrets", "Files folder permission bookmarks", "Previous exports and backups"],
            "consistency": "Each database is a consistent SQLite snapshot. Different databases and separate files are captured in sequence."
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: contents.appendingPathComponent("manifest.json"))
    }

    static func exportTable(_ table: String, columns: [String], db: Database, folder: URL) throws -> Int {
        // Keep ordinary table names readable. Unusual identifiers use a reversible hex name.
        let filename = Self.fileStem(table)
        let jsonURL = folder.appendingPathComponent(filename + ".json")
        let csvURL = folder.appendingPathComponent(filename + ".csv")
        FileManager.default.createFile(atPath: jsonURL.path, contents: nil)
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        let json = try FileHandle(forWritingTo: jsonURL)
        defer { try? json.close() }
        let csv = try FileHandle(forWritingTo: csvURL)
        defer { try? csv.close() }
        try json.write(contentsOf: Data("[".utf8))
        try csv.write(contentsOf: Data((columns.map(csvText).joined(separator: ",") + "\r\n").utf8))
        let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM \(YourDataStores.quote(table))")
        var count = 0
        while let row = try cursor.next() {
            var object: [String: Any] = [:]
            var fields: [String] = []
            for (index, value) in row.databaseValues.enumerated() {
                switch value.storage {
                case .null: object[columns[index]] = NSNull(); fields.append("")
                case .int64(let value): object[columns[index]] = value; fields.append(String(value))
                case .double(let value):
                    // SQLite may contain infinity; do not silently emit invalid JSON.
                    object[columns[index]] = value.isFinite ? value as Any : ["nonFinite": String(value)]
                    fields.append(String(value))
                case .string(let value): object[columns[index]] = value; fields.append(csvText(value))
                case .blob(let value): object[columns[index]] = ["base64": value.base64EncodedString()]; fields.append(csvText("base64:" + value.base64EncodedString()))
                }
            }
            if count > 0 { try json.write(contentsOf: Data(",".utf8)) }
            try json.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            try csv.write(contentsOf: Data((fields.joined(separator: ",") + "\r\n").utf8))
            count += 1
        }
        try json.write(contentsOf: Data("]".utf8))
        // The ZIP reader runs after staging finishes. Completed writes are
        // visible without flushing every disposable table file to disk.
        try json.close(); try csv.close()
        return count
    }
    static func fileStem(_ table: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if !table.isEmpty && !table.hasPrefix("table-") && table.unicodeScalars.allSatisfy(allowed.contains) { return table }
        return "table-" + Data(table.utf8).map { String(format: "%02x", $0) }.joined()
    }
    static func csvText(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func archive(_ directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { snapshot in
            result = Result { try FileManager.default.copyItem(at: snapshot, to: destination) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }
}
