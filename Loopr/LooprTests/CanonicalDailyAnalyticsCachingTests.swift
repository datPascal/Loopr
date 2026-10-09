import XCTest
import Foundation
import AnalyticsKit
import DomainKit
import ProfileKit
import StorageKit
@testable import Loopr

private struct CachingTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// The scheduling and persistence rules behind every tab screen. Nothing here
/// asserts a number the analytics produce; it asserts that a day is derived
/// once, saved, and reused.
final class CanonicalDailyAnalyticsCachingTests: XCTestCase {
    private let dayStart: Int64 = 1_788_739_200 // 2026-09-07 00:00 UTC
    private let day = DayIdentity(year: 2026, month: 9, day: 7)

    func testSecondLaunchPaintsTheSavedGenerationWithoutDerivingAgain() async throws {
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let now = Date(timeIntervalSince1970: Double(dayStart + 36_000))

        let first = try makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        let derived = try await first.readDisplay(day: day)
        XCTAssertNotNil(derived?.today)

        let saved = try StorageDatabase(url: productsURL)
        let written = try savedAt(saved, key: "display.1-2026-9-7")
        XCTAssertNotNil(written, "A finished day must be saved for the next launch")

        // A second process reads the same day. Nothing may be written again,
        // which is only true if nothing was derived again.
        let second = try makeEngine(history: history, products: saved, now: now)
        let reused = try await second.readDisplay(day: day)
        XCTAssertEqual(reused?.projection.revision, derived?.projection.revision)
        XCTAssertEqual(reused?.today, derived?.today)
        XCTAssertEqual(try savedAt(saved, key: "display.1-2026-9-7"), written)
    }

    func testEveryScreenReadsOneGenerationRatherThanDerivingItsOwn() async throws {
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let products = try StorageDatabase(url: productsURL)
        let engine = try makeEngine(history: history, products: products, now: Date(timeIntervalSince1970: Double(dayStart + 36_000)))

        let today = try await SQLiteTodayRepository(database: products, analytics: engine).readSummary(for: day)
        let stamp = try savedAt(products, key: "display.1-2026-9-7")
        let sleep = try await SQLiteSleepRepository(database: products, analytics: engine).readSleepDay(for: day)
        let heart = try await SQLiteHeartRepository(database: products, analytics: engine).readHeartDay(for: day)
        let body = try await SQLiteBodyRepository(database: products, analytics: engine).readBodyDay(for: day)

        XCTAssertNotNil(today)
        XCTAssertNotNil(sleep)
        XCTAssertNotNil(heart)
        XCTAssertNotNil(body)
        XCTAssertEqual(try savedAt(products, key: "display.1-2026-9-7"), stamp,
                       "Sleep, Heart and Body must reuse the generation Today derived")
    }

    func testNewSecondsPaintTheFinishedGenerationInsteadOfWaitingOnTheCatchUp() async throws {
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let now = Date(timeIntervalSince1970: Double(dayStart + 36_000))
        let products = try StorageDatabase(url: productsURL)
        let first = try makeEngine(history: history, products: products, now: now)
        let derived = try await first.readDisplay(day: day)
        let derivedRevision = try XCTUnwrap(derived?.projection.revision)

        try appendSecond(history, at: dayStart + 20_000)
        let currentRevision = try history.historicalAnalyticsRevision(from: dayStart - 43_200, to: dayStart + 86_400)
        XCTAssertNotEqual(currentRevision, derivedRevision, "The new second must change the day's revision")

        // A cold process, as after a relaunch: the saved generation paints and
        // the catch-up runs behind it.
        let second = try makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        let painted = try await second.readDisplay(day: day)
        XCTAssertEqual(painted?.projection.revision, derivedRevision)
    }

    func testDeletedHistoryIsNeverPaintedFromTheSavedGeneration() async throws {
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let now = Date(timeIntervalSince1970: Double(dayStart + 36_000))
        let products = try StorageDatabase(url: productsURL)
        let derived = try await makeEngine(history: history, products: products, now: now).readDisplay(day: day)
        XCTAssertNotNil(derived)

        try history.deleteAllAccountData()
        let reopened = try makeEngine(history: history, products: try StorageDatabase(url: productsURL), now: now)
        let painted = try await reopened.readDisplay(day: day)
        XCTAssertNil(painted)
    }

    func testAnEmptyBaselineWindowKeepsItsRevisionWhileTheDayItselfGrows() throws {
        let (history, _, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 60)
        // The seven days before the recorded day hold nothing. Their revision
        // is what a saved generation is keyed by, so it must not move when an
        // unrelated second lands.
        let baseline = try history.historicalAnalyticsRevision(from: dayStart - 7 * 86_400, to: dayStart)
        try appendSecond(history, at: dayStart + 20_000)
        XCTAssertEqual(try history.historicalAnalyticsRevision(from: dayStart - 7 * 86_400, to: dayStart), baseline)
        XCTAssertEqual(baseline, 0)
    }

    // MARK: Helpers

    private func databases() throws -> (StorageDatabase, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (
            try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
            root.appendingPathComponent("products.sqlite"),
            root
        )
    }

    private func savedAt(_ products: StorageDatabase, key: String) throws -> Double? {
        try products.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT updated_at FROM loopr_product_document WHERE namespace = ? AND document_key = ?",
                arguments: ["daily-analytics", key]
            )
        }
    }

    private func makeEngine(history: StorageDatabase, products: StorageDatabase, now: Date) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(
            history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: CachingTestDate(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )
    }

    private func seedNight(_ database: StorageDatabase, seconds: Int, heartRate: Int = 55) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = self.dayStart + Int64(index)
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, ?, 0, 0, 1)", arguments: [timestamp, index, timestamp, heartRate])
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)", arguments: [id, interval, timestamp * 1_000])
            }
        }
    }

    private func appendSecond(_ database: StorageDatabase, at timestamp: Int64) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, 60, 0, 0, 1)", arguments: [timestamp, 99_999, timestamp])
        }
    }
}
