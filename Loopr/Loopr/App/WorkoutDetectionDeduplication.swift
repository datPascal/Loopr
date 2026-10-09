import Foundation
import WorkoutKit

nonisolated enum WorkoutDetectionDeduplication {
    static func wasAnswered(_ detection: WorkoutKit.DetectedWorkout,
                            answered: Set<String>) -> Bool {
        if answered.contains(detection.detectionID) { return true }
        return answered.contains { identifier in
            guard identifier.hasPrefix("loopr.detected."),
                  let start = TimeInterval(identifier.dropFirst("loopr.detected.".count)) else { return false }
            return detection.startedAt.timeIntervalSince1970 <= start
                && start <= detection.endedAt.timeIntervalSince1970
        }
    }

    static func overlapsSavedWorkout(_ detection: WorkoutKit.DetectedWorkout,
                                     workouts: [WorkoutRecord]) -> Bool {
        workouts.contains { workout in
            guard let start = workout.startedAt else { return false }
            let coversDetection: Bool
            if workout.state == .completed {
                coversDetection = true
            } else {
                coversDetection = workout.source == .live && [
                    .preparing, .active, .paused, .finishing,
                    .interruptedAndRecoverable, .discarded
                ].contains(workout.state)
            }
            guard coversDetection else { return false }
            let end = workout.endedAt ?? .distantFuture
            return detection.startedAt <= end && start <= detection.endedAt
        }
    }
}
