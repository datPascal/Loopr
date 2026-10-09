import ActivityKit
import Foundation

nonisolated struct LooprWorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let elapsedSeconds: Int
        let heartRate: Int?
        let status: String
        let startedAt: Date?
        let heartRateObservedAt: Date?
        let zone: Int?
        let distanceMeters: Double?
        let paceSecondsPerKilometer: Double?
        var targetName: String? = nil
        var targetStatus: String? = nil
    }

    let sessionID: UUID
    let activityName: String
}

nonisolated struct LooprBreathingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let completedCycles: Int
        let status: String
        let startedAt: Date?
    }

    let sessionID: UUID
}

nonisolated struct LooprIntervalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let phase: String
        let round: Int
        let phaseStartedAt: Date
        let phaseEndsAt: Date
    }
    let sessionID: UUID
    let rounds: Int
    let endsAt: Date
}
