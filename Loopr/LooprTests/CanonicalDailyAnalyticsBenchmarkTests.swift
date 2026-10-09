import XCTest
import Foundation
import StorageKit
import DomainKit
import ProfileKit
@testable import Loopr

private struct BenchmarkDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// Timings for the read path that every tab screen sits behind, measured
/// against a copy of a real phone history database.
///
/// The copy is not in the repository, so the whole suite skips itself unless
/// `LOOPR_REAL_HISTORY_DB` points at one (or the night-shift copy is present).
/// Nothing here asserts a wall-clock budget: the numbers are printed so a
/// before and after run can be compared on the same machine.
final class CanonicalDailyAnalyticsBenchmarkTests: XCTestCase {
    private static var sourcePath: String {
        ProcessInfo.processInfo.environment["LOOPR_REAL_HISTORY_DB"]
            ?? "/tmp/loopr-night/perf/loopr.sqlite"
    }

    /// The zone the copy was recorded in, so the recorded seconds fall inside
    /// one local day. Set `LOOPR_REAL_DB_ZONE`; defaults to this Mac's zone.
    private static let timeZone = ProcessInfo.processInfo.environment["LOOPR_REAL_DB_ZONE"].flatMap(TimeZone.init(identifier:)) ?? .current
    private static let day = DayIdentity(year: 2026, month: 9, day: 21)

    func testRealDatabaseReadTimings() async throws {
        guard let (history, root) = try Self.openRealHistory() else {
            throw XCTSkip("No real history copy at \(Self.sourcePath)")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let productsURL = root.appendingPathComponent("products.sqlite")
        let now = Date(timeIntervalSince1970: try Self.latestRecordSeconds(history) + 60)

        let counts = try Self.rowCounts(history)
        print("[bench] rows \(counts)")

        // Cold: no products database, so nothing is cached anywhere.
        let cold = try Self.makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        let coldToday = try await Self.time("cold readToday") { try await cold.readToday(day: Self.day) }
        XCTAssertNotNil(coldToday.0, "The real day should derive a Today summary")
        _ = try await Self.time("warm readToday (same actor)") { try await cold.readToday(day: Self.day) }
        _ = try await Self.time("warm read (same actor)") { try await cold.read(day: Self.day) }

        // Warm start: a second process against the same products database.
        // This is the cold launch a person sees after the first derivation.
        let reopened = try Self.makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        _ = try await Self.time("second process readToday") { try await reopened.readToday(day: Self.day) }
        _ = try await Self.time("second process read") { try await reopened.read(day: Self.day) }

        // Four screens open in turn against one shared engine.
        let screens = try Self.makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        _ = try await Self.time("five screens, shared engine") {
            _ = try await screens.readToday(day: Self.day)
            _ = try await screens.read(day: Self.day)
            _ = try await screens.read(day: Self.day)
            _ = try await screens.read(day: Self.day)
            _ = try await screens.readStress(day: Self.day)
        }

        // One new second arrives, as it does every second while the band
        // streams. The screens keep painting the finished generation while one
        // background pass catches the day up.
        try Self.appendSecond(history, at: Int64(now.timeIntervalSince1970) - 30)
        let stale = try await Self.time("readDisplay after one new second") { try await screens.readDisplay(day: Self.day) }
        XCTAssertNotNil(stale.0, "A finished generation must still paint after new seconds land")
        XCTAssertLessThan(stale.1, 1_000, "A screen must not wait on the catch-up pass")
        _ = try await Self.time("readToday after one new second (authoritative)") { try await screens.readToday(day: Self.day) }

        // Where the cold time goes, so the split between reading the day and
        // deriving it is on the record.
        let window = try Self.dayWindow()
        _ = try await Self.time("historicalAnalyticsSnapshot for the day window") {
            try history.historicalAnalyticsSnapshot(from: window.0, to: window.1).records.count
        }
    }

    /// Previous noon through the end of the local day: the exact window one
    /// day's derivation reads.
    private static func dayWindow() throws -> (Int64, Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        let sleepStart = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: previous)!
        return (Int64(sleepStart.timeIntervalSince1970), Int64(end.timeIntervalSince1970))
    }

    // MARK: Helpers

    private static func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "[bench] %@: %.1f ms", label, elapsed))
        return (value, elapsed)
    }

    private static func openRealHistory() throws -> (StorageDatabase, URL)? {
        let source = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.isReadableFile(atPath: source.path) else { return nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.isReadableFile(atPath: sidecar.path) else { continue }
            try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return (try StorageDatabase(url: destination, applicationVersion: "bench"), root)
    }

    private static func rowCounts(_ database: StorageDatabase) throws -> String {
        try database.read { db in
            let seconds = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second") ?? 0
            let beats = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rr_beat") ?? 0
            return "decoded_second=\(seconds) rr_beat=\(beats)"
        }
    }

    private static func latestRecordSeconds(_ database: StorageDatabase) throws -> Double {
        try database.read { db in
            Double(try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0)
        }
    }

    private static func appendSecond(_ database: StorageDatabase, at timestamp: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-21', 24, 60, 0, 0, 1)",
                arguments: [timestamp, 1, timestamp]
            )
        }
    }

    private static func makeEngine(history: StorageDatabase, products: StorageDatabase, now: Date) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(
            history: history,
            products: products,
            profile: InMemoryProfileRepository(),
            dateProvider: BenchmarkDate(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: timeZone)
        )
    }
}
