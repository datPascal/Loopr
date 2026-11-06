#if DEBUG
import DomainKit
import Foundation
import HealthKitBridge
import WorkoutKit

/// Two Apple Health workouts in Alex's week of the Train fixture (`--loopr-train-fixture`), built through the same
/// mapping the import uses (R1-VET-01, R1-VET-02):
///
/// - Tuesday 14 November, 06:05 to 06:57 in Perth: a 52 minute ride from Garmin Connect with heart rate every
///   10 seconds, 4 minutes warming up in zone 1 and 48 in zone 2. The band has no data on Tuesday, so these are the
///   day's zone minutes, labelled Apple Health.
/// - Monday 13 November, 06:30 to 07:05: a 35 minute run from Apple Watch with its average and maximum heart rate.
///   The band covered Monday, so the run adds no minutes of its own.
///
/// Both stay in memory with the rest of the fixture.
nonisolated enum HealthWorkoutFixtures {
    static let rideID = UUID(uuidString: "7A0460FE-0000-4000-8000-0000000000A1") ?? UUID()
    static let runID = UUID(uuidString: "7A0460FE-0000-4000-8000-0000000000A2") ?? UUID()

    private static func perth(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        AppTrainFixtures.calendar.date(from: DateComponents(year: 2023, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static let rideStart = perth(14, 6, 5)
    static let rideEnd = rideStart.addingTimeInterval(52 * 60)
    static let runStart = perth(13, 6, 30)
    static let runEnd = runStart.addingTimeInterval(35 * 60)

    /// Zone 1 for Alex runs from 91 to 108 bpm and zone 2 from 109 to 126 (age 38, no resting heart rate).
    static var rideHeartRate: [AppleHealthHeartRateSample] {
        (0..<312).map { index in
            let bpm: Double = index < 24 ? 98 + Double(index % 4) : 117 + Double([0, 2, 4, 3, 1, -1, -2, 0][index % 8])
            return AppleHealthHeartRateSample(time: rideStart.addingTimeInterval(Double(index) * 10), bpm: bpm)
        }
    }

    static var ride: AppleHealthWorkout {
        let heartRate = rideHeartRate
        return AppleHealthWorkout(
            id: rideID, activity: .cycle, activityName: "Cycling", start: rideStart, end: rideEnd,
            distanceMeters: 24_600, energyKcal: 512,
            averageHeartRate: heartRate.reduce(0) { $0 + $1.bpm } / Double(heartRate.count),
            maximumHeartRate: heartRate.map(\.bpm).max(), heartRate: heartRate,
            provenance: AppleHealthProvenance(sourceName: "Garmin Connect", sourceBundleIdentifier: "com.garmin.connect.mobile"))
    }

    static var run: AppleHealthWorkout {
        AppleHealthWorkout(
            id: runID, activity: .run, activityName: "Running", start: runStart, end: runEnd,
            distanceMeters: 6_100, energyKcal: 402, averageHeartRate: 148, maximumHeartRate: 166,
            provenance: AppleHealthProvenance(sourceName: "Alex's Apple Watch", sourceBundleIdentifier: "com.apple.health.81C9A3F2",
                                              deviceName: "Apple Watch", deviceModel: "Watch"))
    }

    /// The records the fixture workout store holds beside the Train fixture's own.
    static var records: [WorkoutRecord] { [HealthWorkoutMapping.record(ride), HealthWorkoutMapping.record(run)] }

    /// Alex's zones on the fixture's days: the default zone settings at age 38.
    static let zones: HeartRateZones? = HeartRateZoneSettings().resolved(age: 38)

    /// The fixture's Apple Health records that overlap a window.
    static func records(from start: Date, to end: Date) -> [WorkoutRecord] {
        records.filter { record in
            guard let recordStart = record.startedAt, let recordEnd = record.endedAt else { return false }
            return recordStart < end && recordEnd > start
        }
    }
}
#endif
