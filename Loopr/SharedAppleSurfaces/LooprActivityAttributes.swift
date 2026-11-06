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
        /// When a strength session's rest ends. Nil outside a rest. Optional with a default so an
        /// activity that was already running when the app updated still decodes.
        var restEndsAt: Date? = nil
        /// "Bench press · set 3 of 4" for a strength session. Nil for every other workout.
        var setSummary: String? = nil
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

/// The bedtime countdown (DEC-12.17). It counts down from 18:00 to the bedtime, and the evening rules are its steps.
/// Nothing here is a health reading: the steps are rule titles the person wrote, the times are the rules' own times,
/// and the bedtime is the person's in-bed rule or tonight's plan.
nonisolated struct LooprBedtimeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Step: Codable, Hashable, Identifiable {
            enum Status: String, Codable, Hashable { case done, pending }

            /// The rule key, so a step keeps its identity when the list changes.
            let id: String
            let title: String
            /// The rule's own time as minutes after local midnight, for display in the person's clock style.
            let minuteOfDay: Int?
            /// The same moment as a date on the evening, to place the step on the progress bar.
            let at: Date?
            let status: Status

            var isDone: Bool { status == .done }
        }

        /// Evening rules in time order. A rule the person has already missed is not listed.
        let steps: [Step]
        /// The first step still pending, if any.
        let nextStep: Step?
        /// 0 at 18:00 and 1 at bedtime. A clock-derived figure, never a measurement.
        let progress: Double

        /// What fits on the lock screen: the last finished step for context, then what is still ahead.
        func visibleSteps(limit: Int) -> [Step] {
            guard limit > 0, steps.count > limit else { return Array(steps.prefix(max(limit, 0))) }
            let firstPending = steps.firstIndex(where: { !$0.isDone }) ?? steps.count
            let start = min(max(firstPending - 1, 0), steps.count - limit)
            return Array(steps[start..<(start + limit)])
        }

        var doneCount: Int { steps.filter(\.isDone).count }
    }

    /// Bedtime as a date. The countdown reads it, so the activity ticks without updates.
    let bedtime: Date
    /// 18:00 on the evening the countdown belongs to.
    let windowStart: Date
    /// Bedtime as minutes after local midnight, for display.
    let bedtimeMinuteOfDay: Int
}
