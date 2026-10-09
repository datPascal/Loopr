import Foundation
import ProtocolKit
import GRDB

public struct Gen5ResearchLedgerEntry: Equatable, Sendable {
    public let id: Int64?
    public let model: BandModel
    public let connectionGeneration: UInt64
    public let burstID: UUID
    public let ordinal: Int
    public let rawFrame: Data
    public let decodeSucceeded: Bool
    public let decodeOutcome: String
    public let marker: Data
    public let token: Data?

    public init(
        id: Int64? = nil,
        model: BandModel,
        connectionGeneration: UInt64,
        burstID: UUID,
        ordinal: Int,
        rawFrame: Data,
        decodeSucceeded: Bool,
        decodeOutcome: String,
        marker: Data,
        token: Data?
    ) {
        self.id = id
        self.model = model
        self.connectionGeneration = connectionGeneration
        self.burstID = burstID
        self.ordinal = ordinal
        self.rawFrame = Data(rawFrame)
        self.decodeSucceeded = decodeSucceeded
        self.decodeOutcome = decodeOutcome
        self.marker = Data(marker)
        self.token = token.map { Data($0) }
    }
}

/// Additive-only research storage. It has no API that writes canonical sensor
/// tables and no update/delete operation, keeping unvalidated bytes isolated.
public final class Gen5ResearchLedger: @unchecked Sendable {
    public static let tableName = "gen5_research_frames"
    private let database: StorageDatabase

    public init(database: StorageDatabase) throws {
        self.database = database
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS \(Self.tableName) (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    model TEXT NOT NULL,
                    connection_generation INTEGER NOT NULL,
                    burst_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    raw_frame BLOB NOT NULL,
                    decode_succeeded INTEGER NOT NULL CHECK (decode_succeeded IN (0, 1)),
                    decode_outcome TEXT NOT NULL,
                    marker BLOB NOT NULL,
                    token BLOB CHECK (token IS NULL OR length(token) = 8),
                    UNIQUE(connection_generation, burst_id, ordinal)
                )
                """)
        }
    }

    @discardableResult
    public func append(_ entry: Gen5ResearchLedgerEntry) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Self.tableName)
                    (model, connection_generation, burst_id, ordinal, raw_frame,
                     decode_succeeded, decode_outcome, marker, token)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    String(describing: entry.model), entry.connectionGeneration,
                    entry.burstID.uuidString.lowercased(), entry.ordinal, entry.rawFrame,
                    entry.decodeSucceeded, entry.decodeOutcome, entry.marker, entry.token
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func entries(burstID: UUID) throws -> [Gen5ResearchLedgerEntry] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM \(Self.tableName) WHERE burst_id = ? ORDER BY ordinal",
                arguments: [burstID.uuidString.lowercased()]
            )
            return rows.map { row in
                Gen5ResearchLedgerEntry(
                    id: row["id"],
                    model: Self.model(from: row["model"] as String),
                    connectionGeneration: row["connection_generation"],
                    burstID: UUID(uuidString: row["burst_id"] as String)!,
                    ordinal: row["ordinal"],
                    rawFrame: row["raw_frame"],
                    decodeSucceeded: row["decode_succeeded"],
                    decodeOutcome: row["decode_outcome"],
                    marker: row["marker"],
                    token: row["token"]
                )
            }
        }
    }

    private static func model(from value: String) -> BandModel {
        switch value {
        case "whoop5": return .whoop5
        case "whoopMG": return .whoopMG
        default: return .unknownGen5
        }
    }
}
