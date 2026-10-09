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

private struct AuditClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// Real-data audit of the canonical daily derivation, night by night.
///
/// Runs the production engine over a copy of a strap history database taken
/// from a phone and prints, for every local day in it, each derived metric and
/// the night's hypnogram. The physiological checks below are deliberately
/// loose: they catch a staging or accounting defect (such as the night that
/// read 0 minutes of deep sleep) without pinning one person's numbers.
///
/// The database is not in the repository. The suite skips unless
/// `LOOPR_REAL_NIGHT_DB` names one or the night-build snapshot is present.
/// Set `LOOPR_AUDIT_OUT` to also write the report to a file. The source file
/// is never opened for writing: it is copied first.
@MainActor
final class RealNightSleepAuditTests: XCTestCase {
    // The zone the copy was recorded in. Set `LOOPR_REAL_DB_ZONE`; defaults to this Mac's zone.
    private static let zone = ProcessInfo.processInfo.environment["LOOPR_REAL_DB_ZONE"].flatMap(TimeZone.init(identifier:)) ?? .current

    private static var databasePath: String? {
        [ProcessInfo.processInfo.environment["LOOPR_REAL_NIGHT_DB"],
         "/tmp/loopr-night/device-snapshot/loopr.sqlite"]
            .compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private func copiedHistory(_ source: String) throws -> (StorageDatabase, StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(atPath: source, toPath: destination.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try? FileManager.default.copyItem(atPath: source + suffix, toPath: destination.path + suffix)
        }
        return (try StorageDatabase(url: destination), try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
    }

    private func profile() -> Profile {
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-0000000051EE")!, displayName: "Audit",
            birthYear: 1990, biologicalSex: .male, heightCentimeters: 175, weightKilograms: 72,
            timezoneIdentifier: Self.zone.identifier, unitSystem: .metric,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testEveryRealNightHasPlausibleStagesAndMetrics() async throws {
        let source = try XCTUnwrap(Self.databasePath)
        let (history, products, root) = try copiedHistory(source)
        defer { try? FileManager.default.removeItem(at: root) }

        let bounds = try history.read { db -> (Int64, Int64) in
            (try Int64.fetchOne(db, sql: "SELECT MIN(absolute_timestamp) FROM decoded_second") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.zone
        let clock = DateFormatter()
        clock.timeZone = Self.zone
        clock.dateFormat = "yyyy-MM-dd HH:mm"
        let now = Date(timeIntervalSince1970: Double(bounds.1) + 5)
        let engine = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(profile: profile()),
            dateProvider: AuditClock(value: now), timeZoneProvider: SystemTimeZoneProvider(timeZone: Self.zone))

        var days: [DayIdentity] = []
        var cursor = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(bounds.0)))
        while cursor <= now {
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: cursor)
            days.append(DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }

        var report = ["=== REAL NIGHT AUDIT (\(Self.zone.identifier)) ===",
                      "records \(clock.string(from: Date(timeIntervalSince1970: Double(bounds.0)))) -> \(clock.string(from: now))"]
        var nightsWithSleep = 0
        for day in days {
            let label = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
            guard let projection = try await engine.read(day: day) else {
                report.append("\n## \(label): no projection")
                continue
            }
            let today = try await engine.readToday(day: day)
            let stress = try await engine.readStress(day: day)
            report.append("\n## \(label)")
            for metric in today?.metrics ?? [] {
                report.append("  today.\(metric.id) = \(metric.value ?? "-") \(metric.unit) [\(metric.state)] \(metric.confidence ?? "")")
            }
            for metric in projection.heart.metrics {
                report.append("  heart.\(metric.id) = \(metric.value ?? "-") \(metric.unit) [\(metric.state)] \(metric.confidence ?? "")")
            }
            for metric in projection.sleep.metrics {
                report.append("  sleep.\(metric.id) = \(metric.value ?? "-") \(metric.unit) numeric=\(metric.numericValue.map { String(format: "%.1f", $0) } ?? "-") [\(metric.state)]")
            }
            for metric in projection.body.metrics {
                report.append("  body.\(metric.id) = \(metric.value ?? "-") \(metric.unit) [\(metric.state)] \(metric.confidence ?? "")")
            }
            report.append("  stress = \(stress.map { String(format: "score %.0f, index %.1f, %@, coverage %.2f", $0.score, $0.stressIndex, $0.level, $0.coverage) } ?? "-")")
            report.append("  sleep need \(projection.sleep.needHours.map { String(format: "%.2f h", $0) } ?? "-"), debt \(projection.sleep.debtHours.map { String(format: "%.2f h", $0) } ?? "-"), naps \(projection.sleep.naps.count)")

            guard let main = projection.sleep.mainSleep else {
                report.append("  main sleep: none")
                continue
            }
            nightsWithSleep += 1
            report.append("  main sleep \(clock.string(from: main.start)) -> \(clock.string(from: main.end)), \(main.durationMinutes) min asleep")
            var hypnogram = ""
            for segment in projection.sleep.hypnogram {
                let letter = switch segment.stage { case .awake: "W"; case .rem: "R"; case .light: "L"; case .deep: "D" }
                hypnogram += String(repeating: letter, count: segment.durationMinutes)
            }
            let fiveMinute = stride(from: 0, to: hypnogram.count, by: 5).map { start -> Character in
                let slice = Array(hypnogram)[start..<min(hypnogram.count, start + 5)]
                let counts = Dictionary(grouping: slice, by: { $0 }).mapValues(\.count)
                return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
            }
            report.append("  hypnogram, 5 min per letter: \(String(fiveMinute))")

            // Independent reference: the lowest one-minute mean heart rate
            // inside the sleep window, straight from SQL.
            let lowestMinute = try history.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT MIN(m) FROM (SELECT AVG(heart_rate) AS m FROM decoded_second
                    WHERE absolute_timestamp >= ? AND absolute_timestamp < ? AND heart_rate BETWEEN 25 AND 230
                    GROUP BY absolute_timestamp / 60 HAVING COUNT(*) >= 30)
                    """, arguments: [Int64(main.start.timeIntervalSince1970), Int64(main.end.timeIntervalSince1970)])
            }
            report.append("  reference: lowest 1-min mean HR in window \(lowestMinute.map { String(format: "%.1f", $0) } ?? "-")")

            // Physiological plausibility for a healthy adult night.
            func sleepValue(_ id: String) -> Double? { projection.sleep.metric(id)?.numericValue }
            let asleep = try XCTUnwrap(sleepValue("duration"), "\(label): no duration")
            let deep = try XCTUnwrap(sleepValue("deep"), "\(label): no deep minutes")
            let light = try XCTUnwrap(sleepValue("light"), "\(label): no light minutes")
            let rem = try XCTUnwrap(sleepValue("rem"), "\(label): no REM minutes")
            XCTAssertGreaterThan(deep, 0, "\(label): a full night with 0 minutes of deep sleep")
            XCTAssertTrue((0.05...0.35).contains(deep / asleep), "\(label): deep is \(deep) of \(asleep) minutes")
            XCTAssertTrue((0.08...0.35).contains(rem / asleep), "\(label): REM is \(rem) of \(asleep) minutes")
            XCTAssertEqual(deep + light + rem, asleep, accuracy: 1.5, "\(label): stages do not add up to time asleep")
            XCTAssertTrue(projection.sleep.hypnogram.contains { $0.stage == .deep }, "\(label): hypnogram has no deep")
            let efficiency = try XCTUnwrap(sleepValue("efficiency"))
            XCTAssertTrue((70...100).contains(efficiency), "\(label): efficiency \(efficiency)%")
            let onsetHour = calendar.component(.hour, from: main.start)
            let wakeHour = calendar.component(.hour, from: main.end)
            XCTAssertTrue(onsetHour >= 19 || onsetHour <= 3, "\(label): bedtime at \(onsetHour):00 local")
            XCTAssertTrue((4...11).contains(wakeHour), "\(label): wake at \(wakeHour):00 local")

            let resting = try XCTUnwrap(projection.heart.metric(.restingHeartRate)?.numericValue)
            XCTAssertTrue((35...85).contains(resting), "\(label): resting HR \(resting)")
            if let lowestMinute {
                XCTAssertGreaterThanOrEqual(resting, lowestMinute - 0.5, "\(label): resting HR below the lowest minute of the night")
            }
            let rmssd = try XCTUnwrap(projection.heart.metric(.rmssd)?.numericValue)
            XCTAssertTrue((10...200).contains(rmssd), "\(label): RMSSD \(rmssd) ms")
            if let sdnn = projection.heart.metric(.sdnn)?.numericValue { XCTAssertTrue((10...250).contains(sdnn), "\(label): SDNN \(sdnn) ms") }
            if let pnn50 = projection.heart.metric(.pNN50)?.numericValue { XCTAssertTrue((0...100).contains(pnn50), "\(label): pNN50 \(pnn50)%") }
            if let breaths = projection.heart.metric(.respiration)?.numericValue {
                XCTAssertTrue((8...25).contains(breaths), "\(label): respiratory rate \(breaths)/min")
            }
        }
        let text = report.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "real-night-audit"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = ProcessInfo.processInfo.environment["LOOPR_AUDIT_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(nightsWithSleep, 0, "the database holds no night at all")
    }

    override func setUp() async throws {
        try XCTSkipIf(Self.databasePath == nil, "No real strap database available")
    }
}
