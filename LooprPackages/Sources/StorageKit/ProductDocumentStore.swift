import Foundation

public enum StorageDocumentMutation: Equatable, Sendable {
    case write(key: String, payload: Data)
    case remove(key: String)

    public static func write<T: Encodable & Sendable>(_ value: T, key: String) throws -> Self {
        .write(key: key, payload: try JSONEncoder.loopr.encode(value))
    }
}

/// A small, namespaced durable document store for product repositories.
///
/// Feature packages own their Codable domain values; StorageKit owns the
/// SQLite file and the transaction boundary.  Keeping the payload opaque here
/// avoids a second feature schema while still giving every product slice the
/// same crash-safe, local-first persistence seam.  A document is replaced in
/// one SQLite write and is never silently backed by an in-memory cache.
public final class StorageDocumentStore: @unchecked Sendable {
    public enum StoreError: Error, Equatable, Sendable {
        case invalidNamespace
        case invalidKey
    }

    private static let table = "loopr_product_document"
    private let database: StorageDatabase
    private let namespace: String

    public init(database: StorageDatabase, namespace: String) throws {
        let normalized = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw StoreError.invalidNamespace }
        self.database = database
        self.namespace = normalized
        // Every product repository builds its own store on the same file, so
        // the table check runs once per open database, not once per store.
        try database.performSetupOnce(Self.table) {
            try Self.createTable(in: database)
        }
    }

    private static func createTable(in database: StorageDatabase) throws {
        try database.write { db in
            try db.create(table: Self.table, ifNotExists: true) { table in
                table.column("namespace", .text).notNull()
                table.column("document_key", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .double).notNull()
                table.primaryKey(["namespace", "document_key"])
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS loopr_product_document_namespace ON \(Self.table)(namespace)")
        }
    }

    public func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        let payload: Data? = try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT payload FROM \(Self.table) WHERE namespace = ? AND document_key = ?",
                arguments: [namespace, key]
            )
        }
        guard let payload else { return nil }
        return try JSONDecoder.loopr.decode(type, from: payload)
    }

    public func readData(key: String) throws -> Data? {
        guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        return try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT payload FROM \(Self.table) WHERE namespace = ? AND document_key = ?",
                arguments: [namespace, key]
            )
        }
    }

    public func write<T: Encodable>(_ value: T, key: String) throws {
        guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        try writeData(JSONEncoder.loopr.encode(value), key: key)
    }

    public func writeData(_ payload: Data, key: String) throws {
        guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Self.table)(namespace, document_key, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, document_key) DO UPDATE SET
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [namespace, key, payload, Date().timeIntervalSince1970]
            )
        }
    }

    public func remove(key: String) throws {
        guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM \(Self.table) WHERE namespace = ? AND document_key = ?",
                arguments: [namespace, key]
            )
        }
    }

    public func removeAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM \(Self.table) WHERE namespace = ?", arguments: [namespace])
        }
    }

    public func removeAll(whereKeyPrefix prefix: String) throws {
        guard Self.isValidKey(prefix) else { throw StoreError.invalidKey }
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM \(Self.table) WHERE namespace = ? AND document_key LIKE ?",
                arguments: [namespace, "\(prefix)%"]
            )
        }
    }

    /// Applies a complete document change set in one SQLite transaction.
    /// Callers encode values before this method opens the transaction, so an
    /// encoding failure cannot leave a partial restore, migration, or delete.
    public func mutate(_ mutations: [StorageDocumentMutation]) throws {
        for mutation in mutations {
            let key: String
            switch mutation {
            case .write(let candidate, _), .remove(let candidate): key = candidate
            }
            guard Self.isValidKey(key) else { throw StoreError.invalidKey }
        }
        guard !mutations.isEmpty else { return }
        let timestamp = Date().timeIntervalSince1970
        try database.write { db in
            for mutation in mutations {
                switch mutation {
                case .write(let key, let payload):
                    try db.execute(
                        sql: """
                        INSERT INTO \(Self.table)(namespace, document_key, payload, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(namespace, document_key) DO UPDATE SET
                            payload = excluded.payload,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [namespace, key, payload, timestamp]
                    )
                case .remove(let key):
                    try db.execute(
                        sql: "DELETE FROM \(Self.table) WHERE namespace = ? AND document_key = ?",
                        arguments: [namespace, key]
                    )
                }
            }
        }
    }

    public func keys() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT document_key FROM \(Self.table) WHERE namespace = ? ORDER BY document_key",
                arguments: [namespace]
            )
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 512 && !value.contains("\u{0000}")
    }
}

private extension JSONEncoder {
    static var loopr: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var loopr: JSONDecoder { JSONDecoder() }
}
