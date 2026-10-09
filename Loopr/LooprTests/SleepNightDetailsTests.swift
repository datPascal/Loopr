import XCTest
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import SleepKit
@testable import Loopr

/// The Sleep tab's app-side reads: the sleep goal, per-minute heart rate, and
/// (against a copy of the real snapshot when present) the per-night detail
/// the derivation now folds into the sleep trend.
@MainActor
final class SleepNightDetailsTests: XCTestCase {
    private func goal(_ type: GoalType, _ target: Double, _ unit: String, enabled: Bool = true) -> Goal {
        Goal(id: UUID(), type: type, target: target, unit: unit, isEnabled: enabled, updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testSleepGoalReadsHoursOrMinutesAndIgnoresEverythingElse() {
        XCTAssertEqual(SleepGoalReading.minutes([goal(.sleep, 8, "hours")]), 480)
        XCTAssertEqual(SleepGoalReading.minutes([goal(.sleep, 450, "min")]), 450)
        XCTAssertEqual(SleepGoalReading.minutes([goal(.sleep, 8, "hours", enabled: false)]), 480)
        XCTAssertEqual(SleepGoalReading.minutes([goal(.sleep, 8, "points")]), 480)
        XCTAssertEqual(SleepGoalReading.minutes([goal(.steps, 8_000, "steps")]), 480)
        XCTAssertEqual(SleepGoalReading.minutes([]), 480)
    }

    func testHeartRateFoldsSecondsIntoMinuteMeansAndSkipsMissingReadings() {
        let rows: [(timestamp: Int64, bpm: Double)] = [
            (600, 50), (601, 54), (659, 52),   // minute 10
            (660, 0), (661, 60),                // minute 11: the zero is no reading
            (840, 70)                           // minute 14
        ]
        let minutes = SleepHeartRateReading.minutes(rows)
        XCTAssertEqual(minutes.map(\.date.timeIntervalSince1970), [600, 660, 840])
        XCTAssertEqual(minutes.map(\.bpm), [52, 60, 70])
        XCTAssertTrue(SleepHeartRateReading.minutes([(1, 0), (2, -3)]).isEmpty)
    }

    // MARK: Real snapshot

    private static let zone = TimeZone(identifier: "Australia/Perth")!

    private static var databasePath: String? {
        [ProcessInfo.processInfo.environment["LOOPR_REAL_NIGHT_DB"], "/tmp/loopr-night/device-snapshot/loopr.sqlite"]
            .compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private struct Clock: DateProviding {
        let value: Date
        func now() -> Date { value }
    }

    func testTheRealNightCarriesTimesStagesAndAHeartLine() async throws {
        guard let source = Self.databasePath else { throw XCTSkip("No real night database") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(atPath: source, toPath: destination.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try? FileManager.default.copyItem(atPath: source + suffix, toPath: destination.path + suffix)
        }
        let history = try StorageDatabase(url: destination)
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let last = try history.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0 }
        let profile = Profile(id: UUID(), displayName: "Audit", birthYear: 1993, biologicalSex: .male, heightCentimeters: 180,
                              weightKilograms: 78, timezoneIdentifier: Self.zone.identifier, unitSystem: .metric,
                              createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let engine = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(profile: profile),
            dateProvider: Clock(value: Date(timeIntervalSince1970: Double(last) + 5)),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: Self.zone))

        let day = DayIdentity(year: 2026, month: 9, day: 23)
        let display = try await engine.readDisplay(day: day)
        let sleep = try XCTUnwrap(display?.projection.sleep)
        let main = try XCTUnwrap(sleep.mainSleep)
        let tonight = try XCTUnwrap(sleep.trend.first { $0.localDay == "2026-09-23" })
        XCTAssertEqual(tonight.start, main.start)
        XCTAssertEqual(tonight.end, main.end)
        XCTAssertEqual(tonight.values["deep"] ?? 0, 76, accuracy: 1)
        XCTAssertNotNil(tonight.values["efficiency"])
        let earlier = try XCTUnwrap(sleep.trend.first { $0.localDay == "2026-09-22" })
        XCTAssertNotNil(earlier.start)
        XCTAssertEqual(earlier.values["deep"] ?? 0, 63.5, accuracy: 1)

        let minutes = try await engine.overnightHeartRate(from: main.start, to: main.end)
        XCTAssertGreaterThan(minutes.count, 300, "Most of the night has heart rate")
        XCTAssertTrue(minutes.allSatisfy { (30...200).contains($0.bpm) })
        XCTAssertNotNil(SleepOvernightHeartRate.make(samples: minutes, start: main.start, end: main.end))

        // Two nights on record, no need yet: measured against the recommended
        // 7 hours, with the missing nights named.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let insights = SleepNightInsights(snapshot: sleep, calendar: calendar)
        XCTAssertNil(sleep.needHours)
        XCTAssertEqual(insights.target.source, .recommended)
        XCTAssertNil(insights.target.progress)
        XCTAssertEqual(insights.stages.first?.minutes ?? 0, 76, accuracy: 1)
        XCTAssertEqual(insights.consistency.measured.count, 2)
        XCTAssertFalse(insights.rows.contains { $0.id == "latency" || $0.id == "remLatency" })
    }
}
