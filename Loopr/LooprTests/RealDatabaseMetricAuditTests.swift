import XCTest
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import ProfileKit
import TodayKit
import HeartKit
import SleepKit
import BodyKit
import DesignSystem
@testable import Loopr

private struct FixedDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// Runs the production derivation over a real strap database exported from a
/// phone and prints every computed metric. The database is never modified: it
/// is copied into a temporary directory first.
///
/// The file is not in the repository, so the whole suite skips itself unless
/// `LOOPR_REAL_DB` points at one.
@MainActor
final class RealDatabaseMetricAuditTests: XCTestCase {
    // The zone the copy was recorded in. Set `LOOPR_REAL_DB_ZONE`; defaults to this Mac's zone.
    private static let zone = ProcessInfo.processInfo.environment["LOOPR_REAL_DB_ZONE"].flatMap(TimeZone.init(identifier:)) ?? .current

    private static var databasePath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["LOOPR_REAL_DB"],
            "/tmp/loopr-night/analytics/loopr.sqlite"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private func copiedHistory() throws -> (StorageDatabase, StorageDatabase, URL) {
        let source = try XCTUnwrap(Self.databasePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(atPath: source, toPath: destination.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try? FileManager.default.copyItem(atPath: source + suffix, toPath: destination.path + suffix)
        }
        return (try StorageDatabase(url: destination), try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
    }

    private func profile(height: Double? = 175, weight: Double? = 72, birthYear: Int? = 1990) -> Profile {
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!, displayName: "Audit",
            birthYear: birthYear, biologicalSex: .male, heightCentimeters: height, weightKilograms: weight,
            timezoneIdentifier: Self.zone.identifier, unitSystem: .metric,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testRealDatabaseDayProducesSaneMetrics() async throws {
        try XCTSkipIf(Self.databasePath == nil, "No real strap database available")
        let (history, products, root) = try copiedHistory()
        defer { try? FileManager.default.removeItem(at: root) }

        // The whole capture is one local day in the recording zone.
        let bounds = try history.read { db -> (Int64, Int64, Int, Int) in
            let lower = try Int64.fetchOne(db, sql: "SELECT MIN(absolute_timestamp) FROM decoded_second") ?? 0
            let upper = try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0
            let seconds = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second") ?? 0
            let beats = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rr_beat") ?? 0
            return (lower, upper, seconds, beats)
        }
        let zone = Self.zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: Date(timeIntervalSince1970: Double(bounds.1)))
        let day = DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
        let now = Date(timeIntervalSince1970: Double(bounds.1) + 5)

        let engine = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(profile: profile()),
            dateProvider: FixedDate(value: now), timeZoneProvider: SystemTimeZoneProvider(timeZone: zone))

        let readProjection = try await engine.read(day: day)
        let projection = try XCTUnwrap(readProjection)
        let readToday = try await engine.readToday(day: day)
        let today = try XCTUnwrap(readToday)
        let stress = try await engine.readStress(day: day)
        let workouts = try await engine.readDetectedWorkouts(day: day)

        var report: [String] = []
        report.append("=== REAL DATABASE AUDIT ===")
        report.append("rows=\(bounds.2) beats=\(bounds.3) first=\(Date(timeIntervalSince1970: Double(bounds.0))) last=\(Date(timeIntervalSince1970: Double(bounds.1)))")
        report.append("day=\(day.year)-\(day.month)-\(day.day) zone=\(zone.identifier) now=\(now)")
        report.append("-- TODAY (\(today.overallState)) freshness=\(today.freshness.state) age=\(String(describing: today.freshness.ageMinutes))m")
        for metric in today.metrics {
            report.append("  today.\(metric.id) | value=\(metric.value ?? "nil") \(metric.unit) | numeric=\(String(describing: metric.numericValue)) | state=\(metric.state) | caption=\(metric.confidence ?? "-")")
        }
        report.append("-- HEART (\(projection.heart.state))")
        for metric in projection.heart.metrics {
            report.append("  heart.\(metric.id) | value=\(metric.value ?? "nil") \(metric.unit) | numeric=\(String(describing: metric.numericValue)) | state=\(metric.state)")
        }
        report.append("-- SLEEP (\(projection.sleep.state)) main=\(String(describing: projection.sleep.mainSleep?.durationMinutes)) naps=\(projection.sleep.naps.count) hypnogram=\(projection.sleep.hypnogram.count) trend=\(projection.sleep.trend.count) need=\(String(describing: projection.sleep.needHours)) debt=\(String(describing: projection.sleep.debtHours)) alarm=\(String(describing: projection.sleep.suggestedAlarm))")
        for metric in projection.sleep.metrics {
            report.append("  sleep.\(metric.id) | value=\(metric.value ?? "nil") \(metric.unit) | numeric=\(String(describing: metric.numericValue)) | state=\(metric.state)")
        }
        report.append("-- BODY (\(projection.body.state))")
        for metric in projection.body.metrics {
            report.append("  body.\(metric.id) | value=\(metric.value ?? "nil") \(metric.unit) | state=\(metric.state) | caption=\(metric.confidence ?? "-")")
        }
        report.append("-- STRESS: \(stress.map { "score=\($0.score) si=\($0.stressIndex) level=\($0.level) coverage=\($0.coverage) confidence=\($0.confidence)" } ?? "nil")")
        report.append("-- STRAIN CONFIDENCE: \(projection.strainConfidence)")
        report.append("-- DETECTED WORKOUTS: \(workouts.count)")
        for session in workouts {
            report.append("  workout \(Date(timeIntervalSince1970: session.start)) -> \(Date(timeIntervalSince1970: session.end)) avg=\(session.averageBPM) peak=\(session.peakBPM) strain=\(String(describing: session.strain)) kcal=\(String(describing: session.caloriesKcal)) zones=\(String(describing: session.zones?.zoneTimePercent))")
        }
        print(report.joined(separator: "\n"))

        // Nothing may be NaN, infinite, or negative.
        let numbers: [(String, Double?)] = today.metrics.map { ("today.\($0.id)", $0.numericValue) }
            + projection.heart.metrics.map { ("heart.\($0.id)", $0.numericValue) }
            + projection.sleep.metrics.map { ("sleep.\($0.id)", $0.numericValue) }
            + [("stress.score", stress?.score), ("stress.index", stress?.stressIndex)]
        for (label, value) in numbers {
            guard let value else { continue }
            XCTAssertFalse(value.isNaN, "\(label) is NaN")
            XCTAssertFalse(value.isInfinite, "\(label) is infinite")
            XCTAssertGreaterThanOrEqual(value, 0, "\(label) is negative")
        }

        // Nobody slept on this day. An earlier build read the quiet evening as
        // a 46 minute night at 9% efficiency and then derived the whole heart
        // family from it.
        XCTAssertNil(projection.sleep.mainSleep, "a waking day must not produce a main sleep")
        XCTAssertNil(today.metric(.sleep)?.numericValue)
        XCTAssertTrue(projection.sleep.hypnogram.isEmpty)

        // Resting heart rate falls back to the quietest half hour of the day
        // and says so. An independent SQL pass over the same rows gives 75.16.
        let resting = try XCTUnwrap(projection.heart.metric(.restingHeartRate)?.numericValue)
        XCTAssertEqual(resting, 75.16, accuracy: 0.05)
        XCTAssertEqual(projection.heart.metric(.restingHeartRate)?.state, .lowConfidence)
        XCTAssertEqual(today.metric(.restingHeartRate)?.confidence, "From your quietest stretch today, not from sleep")

        // HRV still appears before the first night, from the day's own beats.
        let rmssd = try XCTUnwrap(projection.heart.metric(.rmssd)?.numericValue)
        XCTAssertTrue((20...150).contains(rmssd), "RMSSD \(rmssd) ms is outside anything physiological")
        XCTAssertEqual(projection.heart.metric(.rmssd)?.state, .lowConfidence)
        XCTAssertEqual(projection.heart.metric(.rmssd)?.confidence, "From your quiet stretches today, not from sleep")

        // Strain: an independent Banister TRIMP over the same heart rate rows
        // with the same anchors gives 10.61 on the 0 to 21 scale.
        let strain = try XCTUnwrap(today.metric(.strain)?.numericValue)
        XCTAssertEqual(strain, 10.61, accuracy: 0.1)

        // Active energy: 51 minutes above the heart-rate-reserve flex point.
        let energy = try XCTUnwrap(projection.body.metrics.first { $0.id == .energy })
        let kcal = try XCTUnwrap(Double(energy.value ?? ""))
        XCTAssertTrue((300...700).contains(kcal), "\(kcal) active kcal for seven hours of wear is not credible")

        // Steps wait on a personal movement floor, and the tile has to say so.
        XCTAssertEqual(today.metric(.steps)?.state, .absent)
        XCTAssertEqual(today.metric(.steps)?.confidence, "A few more days of wear and this is ready")

        // Recovery needs a night, and names how many are missing.
        XCTAssertNil(today.metric(.recovery)?.numericValue)
        XCTAssertEqual(today.metric(.recovery)?.state, .settling)
        XCTAssertNotNil(today.metric(.recovery)?.confidence)

        // Stress survives a partial day, at reduced confidence.
        let reading = try XCTUnwrap(stress)
        XCTAssertTrue((0...100).contains(reading.score))
        XCTAssertLessThanOrEqual(reading.confidence, 0.4)
    }

    /// The suggested alarm is the median recent bedtime plus the sleep need.
    /// It never appeared in the product because analytics never produced one.
    func testSuggestedAlarmFollowsTheMedianBedtimePlusTheNeed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        // Three nights starting at 23:00, 23:30 and 00:30 local: the median
        // bedtime is 23:30, so a 7.5 hour need wakes you at 07:00.
        let bedtimes = [(19, 23, 0), (20, 23, 30), (22, 0, 30)]
        let prior = try bedtimes.map { day, hour, minute -> CanonicalDailyProjection in
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)))
            return projection(mainSleepStart: start)
        }
        let alarm = try XCTUnwrap(CanonicalDailyAnalytics.suggestedAlarm(need: 7.5, prior: prior, calendar: calendar))
        XCTAssertEqual(alarm.localTime, "07:00")
        XCTAssertEqual(alarm.reason, "Your usual bedtime plus the 7.5 hours you need")
        XCTAssertNil(CanonicalDailyAnalytics.suggestedAlarm(need: nil, prior: prior, calendar: calendar))
        XCTAssertNil(CanonicalDailyAnalytics.suggestedAlarm(need: 7.5, prior: Array(prior.dropLast()), calendar: calendar))
    }

    private func projection(mainSleepStart start: Date) -> CanonicalDailyProjection {
        let day = DayIdentity(year: 2026, month: 9, day: 21)
        let session = SleepSessionSummary(id: "n", start: start, end: start.addingTimeInterval(7 * 3_600),
            durationMinutes: 420, isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial)
        return CanonicalDailyProjection(revision: 0, movementBaselineRevision: 0, profile: nil,
            timeZoneIdentifier: Self.zone.identifier, algorithmVersion: CanonicalDailyAnalytics.version, latestRecord: nil,
            today: TodaySummary(day: day, overallState: .partial, freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: ""), device: TodayDeviceSnapshot(model: "", generation: "", connection: .unknown, status: .partial), metrics: []),
            sleep: SleepDaySnapshot(day: day, state: .partial, mainSleep: session, metrics: [], source: "test"),
            heart: HeartDaySnapshot(day: day, state: .partial, metrics: [], source: "test"),
            body: BodyDaySnapshot(day: day, state: .partial, metrics: [],
                composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
                cardioAge: nil, looprAge: nil, source: "test"),
            strainConfidence: 0)
    }

    /// A profile with no height or weight must not crash or invent an energy
    /// figure; it must land in the documented "add your details" state.
    func testMissingBodyMeasurementsYieldTheDesignedEmptyState() async throws {
        try XCTSkipIf(Self.databasePath == nil, "No real strap database available")
        let (history, products, root) = try copiedHistory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upper = try history.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0 }
        let zone = Self.zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: Date(timeIntervalSince1970: Double(upper)))
        let day = DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
        let engine = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(profile: profile(height: nil, weight: nil)),
            dateProvider: FixedDate(value: Date(timeIntervalSince1970: Double(upper) + 5)),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: zone))
        let readProjection = try await engine.read(day: day)
        let projection = try XCTUnwrap(readProjection)
        let energy = try XCTUnwrap(projection.body.metrics.first { $0.id == .energy })
        XCTAssertNil(energy.value)
        XCTAssertEqual(energy.state, .absent)
        XCTAssertEqual(energy.confidence, "Add your age, height and weight to your profile to see this")
        // Strain and steps do not depend on height or weight, so the rest of
        // the day must still read exactly as it does with a full profile.
        let strain = try XCTUnwrap(projection.body.metrics.first { $0.id == .strain })
        XCTAssertNotNil(strain.value, "strain must survive a profile with no body measurements")
        let steps = try XCTUnwrap(projection.body.metrics.first { $0.id == .steps })
        XCTAssertEqual(steps.state, .absent)
        XCTAssertEqual(steps.confidence, "A few more days of wear and this is ready")
    }
}
