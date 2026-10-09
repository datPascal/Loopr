import XCTest
import Foundation
import AnalyticsKit
import StorageKit
import ProtocolKit
import DomainKit
import ProfileKit
import TodayKit
import HeartKit
import SleepKit
import CoachKit
@testable import Loopr

private struct DailyTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

@MainActor
final class CanonicalDailyAnalyticsTests: XCTestCase {
    func testProductionUsesCurrentLocalDayAndFixturesKeepTheirDate() {
        let environment = environment(at: Date(timeIntervalSince1970: 1_788_739_200), timeZone: "Asia/Bangkok")
        let expected = SystemCalendarProvider().components(in: TimeZone(identifier: "Asia/Bangkok")!, from: environment.dateProvider.now())
        let actual = environment.productDay(fixture: TodayFixtures.day)
        XCTAssertEqual(actual.year, expected.year)
        XCTAssertEqual(actual.month, expected.month)
        XCTAssertEqual(actual.day, expected.day)
        XCTAssertNotEqual(actual, TodayFixtures.day)
    }

    func testSavedWHOOPNightPopulatesAllThreeDailyRepositoriesAndSurvivesReopen() async throws {
        let (history, products, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        let start: Int64 = 1_788_739_200 // 2026-09-07 UTC
        // The automatic path needs three hours before it calls a window the
        // main sleep, so this fixture seeds a four-hour night.
        try seedNight(history, start: start, seconds: 14_401, skinCelsius: 35)
        let engine = try makeEngine(history: history, products: products, now: Date(timeIntervalSince1970: Double(start + 36_000)))
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let today = try await SQLiteTodayRepository(database: products, analytics: engine).readSummary(for: day)
        let heart = try await SQLiteHeartRepository(database: products, analytics: engine).readHeartDay(for: day)
        let sleep = try await SQLiteSleepRepository(database: products, analytics: engine).readSleepDay(for: day)
        XCTAssertNotNil(sleep?.mainSleep)
        XCTAssertGreaterThan(sleep?.mainSleep?.durationMinutes ?? 0, 30)
        XCTAssertEqual(heart?.metric(.restingHeartRate)?.numericValue, 55)
        XCTAssertNotNil(heart?.metric(.rmssd)?.numericValue)
        XCTAssertNotNil(heart?.metric(.respiration)?.numericValue)
        XCTAssertEqual(heart?.metric(.respiration)?.numericUnit, .breathsPerMinute)
        XCTAssertEqual(heart?.metric(.respiration)?.algorithmVersion, AnalyticsAlgorithmVersion.respiration)
        XCTAssertEqual(try XCTUnwrap(heart?.vitals?.skinTemperature.nightlyCelsius), 35, accuracy: 1e-9)
        XCTAssertEqual(heart?.vitals?.skinTemperature.deviation, .calibrating(nightsRemaining: 3))
        let assessment = try XCTUnwrap(heart?.vitals?.assessment)
        XCTAssertEqual(assessment.signals.map(\.metric), OvernightVitalMetric.monitored)
        XCTAssertFalse(assessment.isFlagged)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let source = ProjectionOvernightSource(database: products, analytics: engine)
        let cached = await source.assessments(endingOn: Date(timeIntervalSince1970: Double(start + 36_000)), days: 2, calendar: calendar)
        XCTAssertEqual(cached.last, assessment)
        XCTAssertEqual(today?.metric(.hrv)?.numericValue, heart?.metric(.rmssd)?.numericValue)
        XCTAssertEqual(today?.metric(.sleep)?.numericValue, sleep?.metrics.first(where: { $0.id == "duration" })?.numericValue)
        XCTAssertNil(today?.metric(.calories)?.numericValue)
        let reopened = try makeEngine(history: history, products: StorageDatabase(url: url.appendingPathComponent("products.sqlite")), now: Date(timeIntervalSince1970: Double(start + 36_000)))
        let saved = try await reopened.read(day: day)
        XCTAssertEqual(saved?.heart, heart)
    }

    func testSparseAndOffWristRecordsDoNotInventSleepOrHeartMetrics() async throws {
        let (history, products, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        let start: Int64 = 1_788_739_200
        try seedNight(history, start: start, seconds: 20, heartRate: 0)
        let engine = try makeEngine(history: history, products: products, now: Date(timeIntervalSince1970: Double(start + 36_000)))
        let value = try await engine.read(day: DayIdentity(year: 2026, month: 9, day: 7))
        XCTAssertNotNil(value)
        XCTAssertNil(value?.sleep.mainSleep)
        XCTAssertNil(value?.today.metric(.hrv)?.numericValue)
        XCTAssertNil(value?.heart.metric(.restingHeartRate)?.numericValue)
    }

    func testWorkoutCrossingMidnightIsOneSuggestionOnTheNextDay() async throws {
        let (history, products, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        // Workout detection abstains without a maximum heart rate. It comes
        // from the profile's age, raised by an observed peak or replaced by a
        // manual value, both kept in the host app's shared zone settings. Give
        // the profile an age and hide whatever settings the simulator holds, so
        // the maximum is the age estimate (182.8 at 36) on every run.
        let zoneSettingsKey = "com.loopr.heart.zones.settings"
        let storedZoneSettings = UserDefaults.standard.data(forKey: zoneSettingsKey)
        UserDefaults.standard.removeObject(forKey: zoneSettingsKey)
        defer { UserDefaults.standard.set(storedZoneSettings, forKey: zoneSettingsKey) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = Int64(calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!.timeIntervalSince1970)
        try seedNight(history, start: midnight + 3_600, seconds: 14_401, localDay: "2026-09-08")
        try history.write { db in
            for second in (midnight - 600)...(midnight + 900) {
                let day = second < midnight ? "2026-09-07" : "2026-09-08"
                let x = second.isMultiple(of: 2) ? 0.6 : -0.6
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, ?, 24, 150, ?, 0, 1)",
                    arguments: [second, second - midnight + 600, second, day, x])
            }
        }
        let engine = try makeEngine(history: history, products: products,
            now: Date(timeIntervalSince1970: Double(midnight + 12 * 3_600)), profile: workoutProfile(birthYear: 1990))
        let sessions = try await engine.readDetectedWorkouts(day: DayIdentity(year: 2026, month: 9, day: 8))
        XCTAssertEqual(sessions.count, 1)
        guard let session = sessions.first else { return }
        XCTAssertEqual(session.start, Double(midnight - 600), accuracy: 60)
        XCTAssertEqual(session.end, Double(midnight + 900), accuracy: 60)
    }

    func testDeletionInvalidatesPreviouslyDerivedDay() async throws {
        let (history, products, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        let start: Int64 = 1_788_739_200
        try seedNight(history, start: start, seconds: 20)
        let engine = try makeEngine(history: history, products: products, now: Date(timeIntervalSince1970: Double(start + 36_000)))
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let first = try await engine.read(day: day)
        XCTAssertNotNil(first)
        try history.deleteAllAccountData()
        let deleted = try await engine.read(day: day)
        XCTAssertNil(deleted)
        try seedNight(history, start: start, seconds: 21)
        let replaced = try await engine.read(day: day)
        XCTAssertNotEqual(first?.revision, replaced?.revision)
    }

    func testLateCoachPublicationCannotRepopulateDeletedData() async throws {
        let (history, products, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try makeEngine(history: history, products: products, now: Date())
        let coach = try SQLiteCoachRepository(database: products, analytics: engine)
        try await engine.deleteAll()
        try products.deleteAllAccountData()
        do {
            try await coach.save(.abstain(CoachAbstention(reason: "Not enough data", missingEvidence: [.sleep])),
                for: DayIdentity(year: 2026, month: 9, day: 7))
            XCTFail("Stopped analytics must reject a late plan")
        } catch is CancellationError { }
        let documents = try StorageDocumentStore(database: products, namespace: "coach")
        XCTAssertTrue(try documents.keys().isEmpty)
    }

    func testHistoricalRRDecodeReachesDurableLedger() throws {
        let (history, _, url) = try databases()
        defer { try? FileManager.default.removeItem(at: url) }
        var raw = Data(repeating: 0, count: 96)
        raw[0] = 0x2f; raw[1] = 24; raw[17] = 60; raw[18] = 2
        raw[19] = 0xe8; raw[20] = 3; raw[21] = 0xd4; raw[22] = 3
        guard case .decoded(let decoded) = try HistoricalRecord.decode(raw) else { return XCTFail("v24") }
        try history.replaceHistoricalSecond(StoredHistoricalRecord(decoded: decoded, localDay: "1970-01-01"))
        let stored = try history.storedHistoricalSecond(physiologicalTimestamp: 0)
        XCTAssertEqual(stored?.rrBeats.map(\.intervalMilliseconds), [1_000, 980])
        XCTAssertEqual(stored?.rrBeats.map(\.timestampMilliseconds), [0, 0])
    }

    private func databases() throws -> (StorageDatabase, StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try StorageDatabase(url: root.appendingPathComponent("history.sqlite")), try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
    }

    private func makeEngine(history: StorageDatabase, products: StorageDatabase, now: Date,
                            profile: Profile? = nil) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(profile: profile),
            dateProvider: DailyTestDate(value: now), timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    private func workoutProfile(birthYear: Int) -> Profile {
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A6E0")!, displayName: "Workout",
            birthYear: birthYear, unitSystem: .metric,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func seedNight(_ database: StorageDatabase, start: Int64, seconds: Int, heartRate: Int = 55,
                           localDay: String = "2026-09-07", skinCelsius: Double? = nil) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z, skin_temperature_celsius) VALUES (?, ?, ?, ?, 24, ?, 0, 0, 1, ?)", arguments: [timestamp, index, timestamp, localDay, heartRate, skinCelsius])
                let id = db.lastInsertedRowID
                let respiratoryInterval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)", arguments: [id, respiratoryInterval, timestamp * 1_000])
            }
        }
    }

    private func environment(at date: Date, timeZone: String) -> AppEnvironment {
        AppEnvironment(composition: .production, root: .main, storageURL: nil, applicationVersion: "test",
            dateProvider: DailyTestDate(value: date), calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: timeZone)!),
            uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())
    }
}
