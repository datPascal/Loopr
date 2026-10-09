import Foundation
import BluetoothKit
import GRDB
import HeartKit
import StorageKit

/// Loads only heart rates the band already saved in the local history DB.
actor HeartLiveHistorySeed {
    private let database: StorageDatabase

    init(database: StorageDatabase) { self.database = database }

    func samples() -> [HeartLiveSample] {
        let now = Date()
        let start = Int64(now.addingTimeInterval(-HeartLiveHistoryStore.windowSeconds).timeIntervalSince1970)
        let end = Int64(now.timeIntervalSince1970)
        let rows: [(Int64, Int64)] = (try? database.read { db in
            let saved = try Row.fetchAll(db, sql: """
                SELECT absolute_timestamp, heart_rate FROM decoded_second
                WHERE absolute_timestamp >= ? AND absolute_timestamp <= ?
                  AND heart_rate BETWEEN 25 AND 240
                ORDER BY absolute_timestamp DESC LIMIT ?
                """, arguments: [start, end, HeartLiveHistoryStore.maximumSamples])
            return saved.map { row in
                (row["absolute_timestamp"] as Int64, row["heart_rate"] as Int64)
            }
        }) ?? []
        return rows.reversed().map { row in
            HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: Double(row.1), rrMilliseconds: nil,
                            receivedAt: Date(timeIntervalSince1970: TimeInterval(row.0)))
        }
    }
}
