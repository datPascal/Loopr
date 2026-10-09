import XCTest
import Foundation
import DesignSystem
import DomainKit
import HeartKit
import ProfileKit
import StorageKit
import WorkoutKit
@testable import Loopr

private struct HeartTabTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// The Heart tab's day timeline read from a real SQLite history: per-second
/// rows in, 5-minute buckets, the newest reading and the day's workouts out.
final class HeartTabDataTests: XCTestCase {
    private let dayStart: Int64 = 1_788_739_200 // 2026-09-07 00:00 UTC
    private let day = LooprDay(year: 2026, month: 9, day: 7)

    func testReaderReturnsOnlyValidSecondsInsideTheRange() throws {
        let (history, _, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(history, from: dayStart - 60, seconds: 60, heartRate: 70)       // the evening before
        try seed(history, from: dayStart, seconds: 600, heartRate: 55)
        try seed(history, from: dayStart + 600, seconds: 30, heartRate: 0)        // off the wrist
        try seed(history, from: dayStart + 86_400, seconds: 10, heartRate: 80)    // the next day

        let samples = try HeartDayTimelineReader.samples(history, from: dayStart, to: dayStart + 86_400)
        XCTAssertEqual(samples.count, 600)
        XCTAssertEqual(samples.first?.time, TimeInterval(dayStart))
        XCTAssertTrue(samples.allSatisfy { $0.bpm == 55 })

        let latest = try XCTUnwrap(HeartDayTimelineReader.latest(history))
        XCTAssertEqual(latest.bpm, 80)
        XCTAssertEqual(latest.at, Date(timeIntervalSince1970: TimeInterval(dayStart + 86_409)))
    }

    func testReaderHasNoLatestReadingForAnEmptyHistory() throws {
        let (history, _, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try HeartDayTimelineReader.latest(history))
        XCTAssertEqual(try HeartDayTimelineReader.samples(history, from: dayStart, to: dayStart + 86_400).count, 0)
    }

    func testSourceBuildsTheDayWithRecordedWorkouts() async throws {
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(history, from: dayStart, seconds: 4 * 3_600, heartRate: 55)
        let products = try StorageDatabase(url: productsURL)
        let now = Date(timeIntervalSince1970: TimeInterval(dayStart + 36_000))
        let utc = TimeZone(secondsFromGMT: 0)!
        let analytics = try CanonicalDailyAnalytics(
            history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: HeartTabTestDate(value: now), timeZoneProvider: SystemTimeZoneProvider(timeZone: utc))
        let workouts = try SQLiteWorkoutStore(database: products)
        let start = Date(timeIntervalSince1970: TimeInterval(dayStart + 3_600))
        try await workouts.save(WorkoutRecord(
            id: UUID(), identity: WorkoutIdentity(canonicalKey: "test-run"), activity: .run, source: .live,
            state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(1_800)))
        try await workouts.save(WorkoutRecord(
            id: UUID(), identity: WorkoutIdentity(canonicalKey: "test-discarded"), activity: .walk, source: .live,
            state: .discarded, createdAt: start, startedAt: start.addingTimeInterval(7_200), endedAt: start.addingTimeInterval(9_000)))

        let source = LooprHeartTabSource(history: history, analytics: analytics, workouts: workouts, timeZone: { utc })
        let timeline = try await XCTUnwrapAsync(await source.timeline(for: day))
        XCTAssertEqual(timeline.buckets.count, 48)
        XCTAssertEqual(timeline.dayStart, Date(timeIntervalSince1970: TimeInterval(dayStart)))
        XCTAssertEqual(timeline.summary?.lowest, 55)
        XCTAssertEqual(timeline.summary?.highest, 55)
        XCTAssertEqual(timeline.workouts.map(\.title), ["Running"])
        XCTAssertEqual(timeline.workouts.first?.start, start)

        let nextDay = await source.timeline(for: LooprDay(year: 2026, month: 9, day: 8))
        XCTAssertNil(nextDay, "A day with no recorded second has no timeline")
        let latest = await source.lastReading()
        XCTAssertEqual(latest?.at, Date(timeIntervalSince1970: TimeInterval(dayStart + 4 * 3_600 - 1)))
    }

    func testDetectorSportNamesReadAsTitles() {
        XCTAssertEqual(LooprHeartTabSource.sportTitle("running"), "Running")
        XCTAssertEqual(LooprHeartTabSource.sportTitle("detected"), "Workout")
        XCTAssertEqual(LooprHeartTabSource.sportTitle("  "), "Workout")
    }

    func testVisibleRangeReaderUsesOnlyRequestedSecondsAndSkipsBeats() throws {
        let (history, _, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(history, from: dayStart, seconds: 180, heartRate: 75)
        let readings = try HeartDayTimelineReader.samples(history, from: dayStart + 60, to: dayStart + 90, includingBeats: false)
        XCTAssertEqual(readings.count, 30)
        XCTAssertEqual(readings.first?.time, Double(dayStart + 60))
        XCTAssertEqual(readings.last?.time, Double(dayStart + 89))
        XCTAssertTrue(readings.allSatisfy { $0.rrMilliseconds.isEmpty })
    }

    func testWorkoutMaskReadsOnlyCompletedOverlappingIntervals() throws {
        let (_, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = try StorageDatabase(url: productsURL)
        let store = try StorageDocumentStore(database: products, namespace: "workouts")
        let start = Date(timeIntervalSince1970: Double(dayStart))
        let end = start.addingTimeInterval(3600)
        for (key, state, lower, upper) in [("workout.complete", "completed", start, end),
            ("workout.active", "active", start, end), ("workout.outside", "completed", end, end.addingTimeInterval(60))] {
            try store.write(HourlyStressWorkoutMask.Header(startedAt: lower, endedAt: upper, state: state), key: key)
        }
        XCTAssertEqual(try HourlyStressWorkoutMask.intervals(in: store, start: start, end: end), [DateInterval(start: start, end: end)])
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

    private func seed(_ database: StorageDatabase, from start: Int64, seconds: Int, heartRate: Int) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, ?, 0, 0, 1)", arguments: [timestamp, index, timestamp, heartRate])
            }
        }
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
