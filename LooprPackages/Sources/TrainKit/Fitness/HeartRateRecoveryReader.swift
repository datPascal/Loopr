import AnalyticsKit
import Foundation

/// A completed workout with the heart rate samples around its end.
public struct WorkoutRecoveryInput: Sendable {
    public let workoutID: UUID
    public let startedAt: Date
    public let endedAt: Date
    /// Timestamps are Unix seconds, the same epoch as `startedAt` and `endedAt`.
    public let samples: [WorkoutHRPoint]
    /// The person's maximum heart rate, or nil when unknown. Without it the calculation gives no result.
    public let maximumHR: Double?
    public let timeZoneIdentifier: String

    public init(workoutID: UUID, startedAt: Date, endedAt: Date, samples: [WorkoutHRPoint],
                maximumHR: Double?, timeZoneIdentifier: String) {
        self.workoutID = workoutID; self.startedAt = startedAt; self.endedAt = endedAt
        self.samples = samples; self.maximumHR = maximumHR; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Heart rate recovery for the capacity list. It does not calculate anything itself: it calls the existing
/// `WorkoutAnalytics.timedHeartRateRecovery` (`loopr.workout-hrr.1`) and takes the drop one minute after the
/// workout's end. A workout the calculation cannot score gives no result, and a negative drop is not stored.
public enum HeartRateRecoveryReader {
    public static func result(from workout: WorkoutRecoveryInput) -> CapacityResult? {
        let recovery = WorkoutAnalytics.timedHeartRateRecovery(samples: workout.samples,
            start: workout.startedAt.timeIntervalSince1970, end: workout.endedAt.timeIntervalSince1970,
            maximumHR: workout.maximumHR)
        guard let minute = recovery.firstMinute, minute.dropBPM.isFinite, minute.dropBPM >= 0 else { return nil }
        // The workout's id is the result's id, so reading the same workout twice gives the same result.
        return try? CapacityResult(id: workout.workoutID, kind: .heartRateRecovery, value: minute.dropBPM,
            recordedAt: workout.endedAt, timeZoneIdentifier: workout.timeZoneIdentifier, source: .workout,
            workoutID: workout.workoutID, algorithmVersion: minute.algorithmVersion, createdAt: workout.endedAt)
    }

    public static func results(from workouts: [WorkoutRecoveryInput]) -> [CapacityResult] {
        workouts.compactMap(result(from:))
    }
}
