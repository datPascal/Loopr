import Foundation
import HeartKit
import StorageKit
import XCTest
@testable import Loopr

@MainActor
final class HeartLiveHistorySeedTests: XCTestCase {
    func testRelaunchSeedsOnlyRecentPersistedHeartRates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let now = Int64(Date().timeIntervalSince1970)
        try database.write { db in
            for (index, offset, bpm) in [(0, -3_700, 60), (1, -5, 71), (2, -4, 0), (3, -3, 72)] {
                let time = now + Int64(offset)
                try db.execute(sql: """
                    INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp,
                                               local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z)
                    VALUES (?, ?, ?, '2026-09-26', 24, ?, 0, 0, 1)
                    """, arguments: [time, index, time, bpm])
            }
        }
        let source = HeartLiveHistorySeed(database: database)
        let first = HeartLiveHistoryStore(seed: { await source.samples() })
        await first.seedIfNeeded()
        XCTAssertEqual(first.snapshot.recentSamples.map(\.heartRateBPM), [71, 72])
        XCTAssertEqual(first.snapshot.stats.count, 2)

        let relaunched = HeartLiveHistoryStore(seed: { await source.samples() })
        await relaunched.seedIfNeeded()
        XCTAssertEqual(relaunched.snapshot.recentSamples.map(\.heartRateBPM), [71, 72])
        XCTAssertEqual(relaunched.snapshot.stats.count, 2)
    }
}
