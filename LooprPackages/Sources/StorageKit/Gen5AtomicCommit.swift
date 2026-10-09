import Foundation
import ProtocolKit
import GRDB

public struct Gen5CanonicalV18Row: Equatable, Sendable {
    public let timestamp: UInt32
    public let index: UInt32
    public let heartRate: UInt8?
    public let rrMilliseconds: [UInt16]
    public let gravity: (Double, Double, Double)

    public init(
        timestamp: UInt32,
        index: UInt32,
        heartRate: UInt8?,
        rrMilliseconds: [UInt16],
        gravity: (Double, Double, Double)
    ) {
        self.timestamp = timestamp
        self.index = index
        self.heartRate = heartRate
        self.rrMilliseconds = rrMilliseconds
        self.gravity = gravity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.index == rhs.index &&
        lhs.heartRate == rhs.heartRate && lhs.rrMilliseconds == rhs.rrMilliseconds &&
        lhs.gravity.0 == rhs.gravity.0 && lhs.gravity.1 == rhs.gravity.1 &&
        lhs.gravity.2 == rhs.gravity.2
    }
}

public struct Gen5CommitRequest: Sendable {
    public let model: BandModel
    public let connectionGeneration: UInt64
    public let burstID: UUID
    public let token: Data
    public let rawFrames: [Data]
    public let canonicalRows: [Gen5CanonicalV18Row]

    public init(
        model: BandModel,
        connectionGeneration: UInt64,
        burstID: UUID,
        token: Data,
        rawFrames: [Data],
        canonicalRows: [Gen5CanonicalV18Row]
    ) throws {
        guard token.count == 8 else {
            throw ProtocolDecodeError.invalidValue(offset: 0, reason: "Gen 5 commit token must be exactly 8 bytes")
        }
        self.model = model
        self.connectionGeneration = connectionGeneration
        self.burstID = burstID
        self.token = Data(token)
        self.rawFrames = rawFrames.map { Data($0) }
        self.canonicalRows = canonicalRows
    }
}

public enum Gen5CommitBoundary: String, CaseIterable, Sendable {
    case beforeCommit, duringArchive, duringCanonicalRows, beforeCursor, afterCommit
    case acknowledgementTimeout, sessionReplacement, lateEnd, duplicateDelivery, radioLoss
}

public enum Gen5AtomicCommitError: Error, Equatable, Sendable {
    case injected(Gen5CommitBoundary)
}

public final class Gen5AtomicCommitStore: @unchecked Sendable {
    private let database: StorageDatabase

    public init(database: StorageDatabase) throws {
        self.database = database
        try database.write { db in
            try Self.createTables(in: db)
        }
    }

    @discardableResult
    public func commit(
        _ request: Gen5CommitRequest,
        acknowledgementSequence: UInt8,
        injecting boundary: Gen5CommitBoundary? = nil
    ) throws -> Data {
        if boundary == .beforeCommit { throw Gen5AtomicCommitError.injected(.beforeCommit) }

        // `StorageDatabase.write` is already GRDB's serialized transactional
        // writer. Starting another transaction here fails with "cannot start
        // a transaction within a transaction" and prevents the durable token
        // boundary from ever committing.
        try database.write { db in
                if boundary == .duringArchive { throw Gen5AtomicCommitError.injected(.duringArchive) }
                for raw in request.rawFrames {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO gen5_raw_archive(model, raw_payload) VALUES (?, ?)",
                        arguments: [String(describing: request.model), raw]
                    )
                }

                if boundary == .duringCanonicalRows { throw Gen5AtomicCommitError.injected(.duringCanonicalRows) }
                for row in request.canonicalRows {
                    var rr = Data()
                    for value in row.rrMilliseconds {
                        rr.append(UInt8(truncatingIfNeeded: value))
                        rr.append(UInt8(truncatingIfNeeded: value >> 8))
                    }
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO gen5_v18_canonical
                            (model, physiological_timestamp, record_index, heart_rate, rr_le,
                             gravity_x, gravity_y, gravity_z)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [String(describing: request.model), row.timestamp, row.index,
                                    row.heartRate, rr, row.gravity.0, row.gravity.1, row.gravity.2]
                    )
                }

                if boundary == .beforeCursor { throw Gen5AtomicCommitError.injected(.beforeCursor) }
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO gen5_committed_batch
                        (model, connection_generation, burst_id, token) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [String(describing: request.model), request.connectionGeneration,
                                request.burstID.uuidString.lowercased(), request.token]
                )
                return ()
        }

        if let boundary, [.afterCommit, .acknowledgementTimeout, .sessionReplacement,
                          .lateEnd, .radioLoss].contains(boundary) {
            throw Gen5AtomicCommitError.injected(boundary)
        }
        // Duplicate delivery intentionally converges through INSERT OR IGNORE
        // and may produce the same ACK from the same durable token.
        return Data([0x23, acknowledgementSequence, 0x17, 0x01]) + request.token
    }

    public func committedToken(burstID: UUID, model: BandModel) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT token FROM gen5_committed_batch WHERE burst_id = ? AND model = ?",
                arguments: [burstID.uuidString.lowercased(), String(describing: model)]
            )
        }
    }

    public func counts() throws -> (batches: Int, archive: Int, canonical: Int) {
        try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gen5_committed_batch") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gen5_raw_archive") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gen5_v18_canonical") ?? 0
            )
        }
    }

    private static func createTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS gen5_raw_archive (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                raw_payload BLOB NOT NULL,
                UNIQUE(model, raw_payload)
            );
            CREATE TABLE IF NOT EXISTS gen5_v18_canonical (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                model TEXT NOT NULL,
                physiological_timestamp INTEGER NOT NULL,
                record_index INTEGER NOT NULL,
                heart_rate INTEGER,
                rr_le BLOB NOT NULL,
                gravity_x REAL NOT NULL,
                gravity_y REAL NOT NULL,
                gravity_z REAL NOT NULL,
                UNIQUE(model, physiological_timestamp, record_index)
            );
            CREATE TABLE IF NOT EXISTS gen5_committed_batch (
                model TEXT NOT NULL,
                connection_generation INTEGER NOT NULL,
                burst_id TEXT NOT NULL,
                token BLOB NOT NULL CHECK(length(token) = 8),
                PRIMARY KEY(model, burst_id)
            );
            """)
    }
}
