import Testing
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import BodyKit
import SleepKit
import DesignSystem
import TodayKit
@testable import Loopr

private struct FixedDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// Cover for the day derivation repairs: the prior-day cache, the sleep
/// metrics that were computed and dropped, the step state that blocked every
/// export, active energy, and the stress reading.
@Suite("Canonical daily analytics coverage")
struct CanonicalDailyAnalyticsCoverageTests {
    private static let start: Int64 = 1_788_739_200 // 2026-09-07T00:00:00Z
    private static let day = DayIdentity(year: 2026, month: 9, day: 7)

    private func databases() throws -> (StorageDatabase, StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
                try StorageDatabase(url: root.appendingPathComponent("products.sqlite")),
                root)
    }

    private func engine(history: StorageDatabase, products: StorageDatabase) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: FixedDate(value: Date(timeIntervalSince1970: Double(Self.start + 86_400))),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    /// A still four-hour night plus a waking afternoon, the smallest record
    /// that exercises sleep, heart and activity together.
    private func seedDay(_ database: StorageDatabase, start: Int64) throws {
        try database.write { db in
            func insert(_ timestamp: Int64, index: Int, heartRate: Int, x: Double) throws {
                try db.execute(sql: """
                    INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, \
                    record_version, heart_rate, gravity_x, gravity_y, gravity_z) \
                    VALUES (?, ?, ?, '2026-09-07', 24, ?, ?, 0, 1)
                    """, arguments: [timestamp, index, timestamp, heartRate, x])
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)",
                               arguments: [id, interval, timestamp * 1_000])
            }
            for index in 0..<14_401 {
                try insert(start + Int64(index), index: index, heartRate: 55, x: 0)
            }
            for index in 0..<7_200 {
                let timestamp = start + 50_000 + Int64(index)
                try insert(timestamp, index: 14_401 + index, heartRate: 96, x: index.isMultiple(of: 2) ? 0.3 : 0)
            }
        }
    }

    @Test("Sleep cycles, latency and wake-ups reach the snapshot")
    func sleepHypnogramMetricsAreSurfaced() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let projection = try await engine(history: history, products: products).read(day: Self.day)
        let sleep = try #require(projection?.sleep)
        #expect(sleep.mainSleep != nil)
        for id in ["cycles", "latency", "remLatency", "disturbances"] {
            #expect(sleep.metric(id) != nil, "the \(id) metric must reach the Sleep screen")
        }
        #expect(sleep.metric("latency")?.numericUnit == .minutes)
    }

    @Test("A derived day carries its own trend point")
    func sleepTrendIsPopulated() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let projection = try await engine(history: history, products: products).read(day: Self.day)
        let sleep = try #require(projection?.sleep)
        #expect(sleep.trend.contains { $0.localDay == "2026-09-07" })
        #expect(sleep.trend.first { $0.localDay == "2026-09-07" }?.value != nil)
    }

    @Test("An estimated step count is partial, not low confidence")
    func stepsAreExportable() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let projection = try await engine(history: history, products: products).read(day: Self.day)
        let steps = try #require(projection?.today.metric(.steps))
        // Absent is still allowed on a cold movement baseline; low confidence
        // is not, because it silently blocked every Apple Health export.
        #expect(steps.state != .lowConfidence)
        if steps.numericValue != nil {
            #expect(steps.state == .partial)
            #expect(steps.confidence?.isEmpty == false)
        }
    }

    @Test("The energy metric reports kilocalories, not a unitless index")
    func energyIsKilocalories() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let projection = try await engine(history: history, products: products).read(day: Self.day)
        let energy = try #require(projection?.body.metrics.first { $0.id == .energy })
        #expect(energy.unit == "kcal")
        #expect(energy.title == "Active energy")
        #expect(energy.confidence?.isEmpty == false)
    }

    @Test("Strain explains how to set a maximum when age is missing")
    func strainExplainsTheMissingAge() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let projection = try await engine(history: history, products: products).read(day: Self.day)
        let strain = try #require(projection?.body.metrics.first { $0.id == .strain })
        #expect(strain.value == nil)
        #expect(strain.confidence == "Add your age or set a maximum heart rate to see strain")
        // Body reads this caption as "strain waits on the profile" and shows
        // its one profile prompt instead of an empty ring.
        #expect(BodyStrainHero.make(metric: strain, recovery: nil).state == .needsAge)
        let body = try #require(projection?.body)
        #expect(BodyProfileGaps.prompt(for: body)?.actionTitle == ProfileAgePrompt.action)
    }

    @Test("The night produces a stress reading on the 0 to 100 scale")
    func stressIsDerived() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let engine = try engine(history: history, products: products)
        let stress = try await engine.readStress(day: Self.day)
        let reading = try #require(stress)
        #expect(reading.score >= 0 && reading.score <= 100)
        #expect(reading.stressIndex > 0)
        #expect(reading.algorithmVersion == WellnessAlgorithm.version)
    }

    @Test("Reading a day twice derives it once")
    func priorDaysAreDerivedOnce() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDay(history, start: Self.start)
        let engine = try engine(history: history, products: products)
        let first = try await engine.read(day: Self.day)
        let started = Date()
        for _ in 0..<12 { _ = try await engine.read(day: Self.day) }
        let elapsed = Date().timeIntervalSince(started)
        #expect(first != nil)
        #expect(elapsed < 5, "a cached day must not be re-derived on every read")
    }
    // MARK: Wear gate for Strain and Stress

    private static let noon = start + 12 * 3_600

    /// Waking data that ends at noon: `minutes` of resting heart rate followed
    /// by `minutes` at 120 bpm, a beat per second, with arm motion throughout.
    private func seedMidday(_ database: StorageDatabase, minutes: Int, offWristMinutes: Int = 0) throws {
        try database.write { db in
            var index = 0
            func insert(_ timestamp: Int64, heartRate: Int, skin: Int?) throws {
                try db.execute(sql: """
                    INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, \
                    record_version, heart_rate, gravity_x, gravity_y, gravity_z, skin_contact) \
                    VALUES (?, ?, ?, '2026-09-07', 24, ?, ?, 0, 1, ?)
                    """, arguments: [timestamp, index, timestamp, heartRate, index.isMultiple(of: 2) ? 0.3 : 0, skin])
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)",
                               arguments: [id, interval, timestamp * 1_000])
                index += 1
            }
            let first = Self.noon - Int64(minutes * 60) - Int64(offWristMinutes * 60)
            for second in 0..<(minutes * 60) {
                try insert(first + Int64(second), heartRate: second < minutes * 30 ? 60 : 120, skin: nil)
            }
            for second in 0..<(offWristMinutes * 60) {
                try insert(first + Int64(minutes * 60 + second), heartRate: 170, skin: 0)
            }
        }
    }

    private func middayEngine(history: StorageDatabase, products: StorageDatabase) throws -> CanonicalDailyAnalytics {
        let profile = Profile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A6E1")!, displayName: "Wear",
            birthYear: 1990, unitSystem: .metric,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        return try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(profile: profile),
            dateProvider: FixedDate(value: Date(timeIntervalSince1970: Double(Self.noon))),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    @Test("Half an hour of wear leaves Strain and Stress settling with no number")
    func shortWearHasNoStrainOrStress() async throws {
        let zoneKey = "com.loopr.heart.zones.settings"
        let stored = UserDefaults.standard.data(forKey: zoneKey)
        UserDefaults.standard.removeObject(forKey: zoneKey)
        defer { UserDefaults.standard.set(stored, forKey: zoneKey) }
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedMidday(history, minutes: 30)
        let projection = try await middayEngine(history: history, products: products).read(day: Self.day)
        let today = try #require(projection?.today)
        for id in [TodayMetricID.strain, .stress] {
            let metric = try #require(today.metric(id))
            #expect(metric.numericValue == nil)
            #expect(metric.value == nil)
            #expect(metric.state == .settling)
            #expect(metric.confidence == "30 of 60 min worn")
        }
        #expect(projection?.stress == nil)
        let body = try #require(projection?.body.metrics.first { $0.id == .strain })
        #expect(body.value == nil)
        #expect(body.state == .settling)
    }

    @Test("Two hours of wear gives Strain and Stress a value")
    func enoughWearShowsStrainAndStress() async throws {
        let zoneKey = "com.loopr.heart.zones.settings"
        let stored = UserDefaults.standard.data(forKey: zoneKey)
        UserDefaults.standard.removeObject(forKey: zoneKey)
        defer { UserDefaults.standard.set(stored, forKey: zoneKey) }
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedMidday(history, minutes: 120)
        let projection = try await middayEngine(history: history, products: products).read(day: Self.day)
        let today = try #require(projection?.today)
        let strain = try #require(today.metric(.strain))
        #expect(strain.numericValue != nil)
        #expect(strain.state != .settling)
        let stress = try #require(today.metric(.stress))
        #expect(stress.numericValue != nil)
        #expect(stress.state != .settling)
    }

    @Test("Minutes with the band off the wrist do not count toward the hour or the strain")
    func offWristMinutesAreNotWear() async throws {
        let zoneKey = "com.loopr.heart.zones.settings"
        let stored = UserDefaults.standard.data(forKey: zoneKey)
        UserDefaults.standard.removeObject(forKey: zoneKey)
        defer { UserDefaults.standard.set(stored, forKey: zoneKey) }
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedMidday(history, minutes: 40, offWristMinutes: 60)
        let projection = try await middayEngine(history: history, products: products).read(day: Self.day)
        let strain = try #require(projection?.today.metric(.strain))
        #expect(strain.state == .settling)
        #expect(strain.confidence == "40 of 60 min worn")
    }
}
