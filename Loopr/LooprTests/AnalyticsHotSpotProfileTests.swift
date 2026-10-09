import XCTest
import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
@testable import Loopr

/// Times the individual analytics primitives over a real day so the cost of one
/// derivation can be attributed instead of guessed. Skips itself without a
/// database copy. Nothing asserts a budget; the numbers are printed.
final class AnalyticsHotSpotProfileTests: XCTestCase {
    private static var sourcePath: String {
        ProcessInfo.processInfo.environment["LOOPR_REAL_DB"] ?? "/tmp/loopr-night/analytics/loopr.sqlite"
    }

    private static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "[hot] %@: %.1f ms", label, elapsed))
        return value
    }

    func testPrimitiveTimings() throws {
        try XCTSkipIf(!FileManager.default.isReadableFile(atPath: Self.sourcePath), "No real strap database available")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.sqlite")
        try FileManager.default.copyItem(atPath: Self.sourcePath, toPath: destination.path)
        let history = try StorageDatabase(url: destination, applicationVersion: "profile")

        let zone = TimeZone(secondsFromGMT: 8 * 3_600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = DayIdentity(year: 2026, month: 9, day: 21)
        let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let sleepStart = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: -1, to: start)!)!

        let raw = try Self.time("historicalAnalyticsSnapshot") {
            try history.historicalAnalyticsSnapshot(from: Int64(sleepStart.timeIntervalSince1970), to: Int64(end.timeIntervalSince1970))
        }
        print("[hot] records \(raw.records.count)")

        func hr(_ record: StoredHistoricalRecord) -> Double? {
            guard let value = record.heartRate, (25...230).contains(Int(value)) else { return nil }
            return Double(value)
        }
        let nightHR = raw.records.compactMap { record in hr(record).map { SleepHeartRateSample(timestamp: Double(record.absoluteTimestamp), bpm: $0) } }
        let motion = raw.records.compactMap { record -> SleepAccelerationSample? in
            guard let x = record.gravityX, let y = record.gravityY, let z = record.gravityZ else { return nil }
            return SleepAccelerationSample(timestamp: Double(record.absoluteTimestamp), x: x, y: y, z: z)
        }
        let rr = raw.records.flatMap { record in
            record.rrBeats.compactMap { beat -> SleepRRInterval? in
                guard let timestamp = beat.timestampMilliseconds else { return nil }
                return SleepRRInterval(timestamp: Double(timestamp) / 1_000, milliseconds: Double(beat.intervalMilliseconds))
            }
        }
        print("[hot] hr \(nightHR.count) motion \(motion.count) rr \(rr.count)")

        _ = Self.time("SleepAdvancedWindowDetector.detect") {
            SleepAdvancedWindowDetector.detect(acceleration: motion, heartRate: nightHR, timeZoneIdentifier: zone.identifier, daytimeHeartRate: [])
        }
        let firstSecond = Double(raw.records.first?.absoluteTimestamp ?? 0)
        let lastSecond = Double(raw.records.last?.absoluteTimestamp ?? 0)
        _ = Self.time("SleepCardioStager.stage over the whole span") {
            SleepCardioStager.stage(acceleration: motion, heartRate: nightHR, rr: rr, onset: firstSecond, offset: lastSecond)
        }
        let sleep = try Self.time("SleepAnalytics.derive") {
            try awaitSync { try await SleepAnalytics.derive(SleepInputSnapshot(acceleration: motion, heartRate: nightHR, rr: rr, daytimeHeartRate: [], timeZoneIdentifier: zone.identifier, mainSleepWakeDay: day)) }
        }
        print("[hot] sleep window \(String(describing: sleep.segmentation.window?.sptSeconds))")

        let gated = Self.time("RRQuality.gated over the whole day") {
            RRQuality.gated(rr.map(\.milliseconds), beatTimestampsMilliseconds: rr.map { $0.timestamp * 1_000 })
        }
        if let cleaned = gated.value {
            print("[hot] clean beats \(cleaned.normalIntervalsMilliseconds.count) fraction \(cleaned.cleanFraction)")
            _ = Self.time("HRVTime.derive") {
                HRVTime.derive(cleaned.normalIntervalsMilliseconds, beatTimesMilliseconds: cleaned.normalTimesMilliseconds)
            }
            _ = Self.time("HRVTime.nocturnalRMSSD") {
                HRVTime.nocturnalRMSSD(cleaned.normalIntervalsMilliseconds, beatTimesMilliseconds: cleaned.normalTimesMilliseconds)
            }
            _ = Self.time("Respiration.rsaRate") {
                Respiration.rsaRate(intervals: cleaned.normalIntervalsMilliseconds,
                    beatTimesMilliseconds: cleaned.normalTimesMilliseconds,
                    artifactFraction: 1 - cleaned.cleanFraction)
            }
            _ = Self.time("WellnessAnalytics.baevskyStressIndex") {
                WellnessAnalytics.baevskyStressIndex(cleaned.normalIntervalsMilliseconds)
            }
        }
        let activityHR = raw.records.compactMap { record in hr(record).map { ActivityHeartRateSample(timestamp: Double(record.absoluteTimestamp), bpm: $0) } }
        let activityMotion = raw.records.compactMap { record -> ActivityAccelerationSample? in
            guard let x = record.gravityX, let y = record.gravityY, let z = record.gravityZ else { return nil }
            return ActivityAccelerationSample(timestamp: Double(record.absoluteTimestamp), x: x, y: y, z: z)
        }
        _ = try Self.time("ActivityAnalytics.derive") {
            try awaitSync { try await ActivityAnalytics.derive(ActivityInputSnapshot(heartRate: activityHR, acceleration: activityMotion, restingHR: 75, age: 33, sex: .male, personalDynamicFloor: nil, pooledMotionMinutes: 0, timeZoneIdentifier: zone.identifier, personalDynamicFloorRequirement: 5)) }
        }
        let workoutMotion = (ActivityAnalytics.enmoSeries(activityMotion).value?.minutes ?? []).map {
            WorkoutMotionPoint(timestamp: $0.start, intensity: $0.dynamicAmplitude)
        }
        _ = Self.time("WorkoutAnalytics.detect") {
            WorkoutAnalytics.detect(activityHR.map { WorkoutHRPoint(timestamp: $0.timestamp, bpm: $0.bpm) },
                motion: workoutMotion, restingHR: 75, maxHR: 184.9, age: 33, profile: nil)
        }
    }
}

/// Runs an async body from a synchronous timing closure.
private func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<Result<T, Error>?>(nil)
    Task.detached {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.value!.get()
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
