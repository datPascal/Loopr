import Testing
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import TodayKit
import HeartKit
import SleepKit
import DesignSystem
@testable import Loopr

private struct RecoveryDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// A day with no recorded night must not score recovery from daytime heart
/// values. Wearing the band again at midday after days off once read a resting
/// heart rate far above the nightly baseline and published a recovery of 3.
@Suite("Recovery without a night")
struct RecoveryWithoutNightTests {
    private static let target: Int64 = 1_788_739_200 // 2026-09-07T00:00:00Z
    private static let day = DayIdentity(year: 2026, month: 9, day: 7)

    private func databases() throws -> (StorageDatabase, StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
                try StorageDatabase(url: root.appendingPathComponent("products.sqlite")),
                root)
    }

    private func engine(history: StorageDatabase, products: StorageDatabase, now: Int64) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: RecoveryDate(value: Date(timeIntervalSince1970: Double(now))),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    private func localDay(_ start: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(start)))
    }

    /// Seconds of still records with a respiratory sine in the beat intervals.
    private func insert(_ database: StorageDatabase, start: Int64, seconds: Int, heartRate: Int,
                        amplitude: Double, moving: Bool, counterBase: Int) throws {
        let day = localDay(start)
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                let x = moving && index.isMultiple(of: 2) ? 0.3 : 0
                try db.execute(sql: """
                    INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, \
                    record_version, heart_rate, gravity_x, gravity_y, gravity_z) \
                    VALUES (?, ?, ?, ?, 24, ?, ?, 0, 1)
                    """, arguments: [timestamp, counterBase + index, timestamp, day, heartRate, x])
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + amplitude * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)",
                               arguments: [id, interval, timestamp * 1_000])
            }
        }
    }

    /// Four-hour still night from midnight and a waking afternoon after it, so
    /// the night is complete rather than the end of the record.
    private func seedNightDay(_ database: StorageDatabase, start: Int64, heartRate: Int, amplitude: Double) throws {
        try insert(database, start: start, seconds: 14_401, heartRate: heartRate, amplitude: amplitude, moving: false, counterBase: 0)
        try insert(database, start: start + 50_000, seconds: 3_600, heartRate: 96, amplitude: 60, moving: true, counterBase: 14_401)
    }

    /// Four nights a little apart from each other, so a baseline exists.
    private func seedBaseline(_ database: StorageDatabase) throws {
        for back in 1...4 {
            let start = Self.target - Int64(back) * 86_400
            try seedNightDay(database, start: start, heartRate: 52 + back, amplitude: Double(60 + 8 * back))
        }
    }

    private func recovery(_ engine: CanonicalDailyAnalytics, products: StorageDatabase) async throws -> TodayMetricValue? {
        let summary = try await SQLiteTodayRepository(database: products, analytics: engine).readSummary(for: Self.day)
        return summary?.metric(.recovery)
    }

    @Test("A midday wear after days off scores no recovery")
    func daytimeOnlyDayHasNoRecovery() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBaseline(history)
        // Two waking hours around midday, resting well above the nightly values.
        try insert(history, start: Self.target + 39_600, seconds: 7_200, heartRate: 80, amplitude: 40, moving: true, counterBase: 0)
        let engine = try engine(history: history, products: products, now: Self.target + 14 * 3_600)
        let projection = try #require(try await engine.read(day: Self.day))
        #expect(projection.sleep.mainSleep == nil)
        #expect(projection.heart.metric(.heartRateDip)?.numericValue == nil)
        #expect(projection.heart.metric(.sleepingHeartRate)?.numericValue == nil)
        #expect(projection.heart.metric(.maxHeartRate)?.numericValue == 80)
        let metric = try #require(try await recovery(engine, products: products))
        #expect(metric.numericValue == nil)
        #expect(metric.state == .settling)
    }

    @Test("The same baseline scores recovery once the day has a night")
    func dayWithANightHasRecovery() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBaseline(history)
        try seedNightDay(history, start: Self.target, heartRate: 55, amplitude: 70)
        let engine = try engine(history: history, products: products, now: Self.target + 16 * 3_600)
        let projection = try #require(try await engine.read(day: Self.day))
        #expect(projection.sleep.mainSleep != nil)
        let metric = try #require(try await recovery(engine, products: products))
        #expect(metric.numericValue != nil)
    }
}
