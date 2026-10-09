import Foundation
import AnalyticsKit
import WorkoutKit

/// Decisions are independent of ActivityKit so launch and transition behavior
/// can be checked without asking iOS to create an activity.
nonisolated enum LooprActivityLifecycle {
    struct Existing: Equatable {
        let id: String
        let sessionID: UUID
        let isStale: Bool
    }

    enum Session: Equatable {
        case none
        case running(UUID)
        case finished(UUID)
        case discarded(UUID)
    }

    enum EndReason: Equatable {
        case orphan
        case duplicate
        case stale
        case finished
        case discarded
    }

    struct End: Equatable {
        let id: String
        let reason: EndReason
    }

    struct Decision: Equatable {
        let ends: [End]
        let updateID: String?
        let shouldStart: Bool
    }

    static func session(for workout: WorkoutRecord, allowed: Bool) -> Session {
        guard allowed else { return .none }
        switch workout.state {
        case .finishing where workout.endedAt != nil:
            return .finished(workout.id)
        case .completed:
            return .finished(workout.id)
        case .active, .preparing, .paused, .finishing:
            return .running(workout.id)
        case .discarded:
            return .discarded(workout.id)
        default:
            return .none
        }
    }

    static func decide(existing: [Existing], session: Session) -> Decision {
        let matchingID: UUID?
        if case let .running(id) = session { matchingID = id }
        else { matchingID = nil }

        let keeper = existing
            .filter { $0.sessionID == matchingID && !$0.isStale }
            .map(\.id)
            .sorted()
            .first
        let ends = existing.map { activity -> End? in
            if activity.id == keeper { return nil }
            if case let .finished(id) = session, activity.sessionID != id { return nil }
            if case let .discarded(id) = session, activity.sessionID != id { return nil }
            let reason: EndReason
            switch session {
            case let .finished(id) where activity.sessionID == id: reason = .finished
            case let .discarded(id) where activity.sessionID == id: reason = .discarded
            default:
                if activity.sessionID == matchingID {
                    reason = activity.isStale ? .stale : .duplicate
                } else {
                    reason = .orphan
                }
            }
            return End(id: activity.id, reason: reason)
        }.compactMap { $0 }
        return Decision(ends: ends, updateID: keeper,
                        shouldStart: matchingID != nil && keeper == nil)
    }
}

nonisolated enum LooprWorkoutActivityProjection {
    static func state(for workout: WorkoutRecord, zones: HeartRateZoneSet?, now: Date) -> LooprWorkoutActivityAttributes.ContentState {
        let startedAt = workout.startedAt ?? workout.createdAt
        let elapsed = max(0, Int(workout.activeElapsed(at: now) ?? 0))
        let live = WorkoutLiveMetrics(workout: workout, zones: zones, now: now)
        let heartRate = workout.endedAt == nil ? live.heartRate : nil
        let heartRateObservedAt = heartRate == nil ? nil : workout.samples.last?.timestamp
        let distanceSample = workout.source == .live && [.run, .cycle, .walk].contains(workout.activity)
            ? workout.samples.last(where: {
                guard let meters = $0.distanceMeters else { return false }
                return meters.isFinite && meters >= 0
            })
            : nil
        let pace = distanceSample.flatMap { sample -> Double? in
            guard let meters = sample.distanceMeters, meters > 0 else { return nil }
            let measuredSeconds = sample.timestamp.timeIntervalSince(startedAt)
            guard measuredSeconds > 0 else { return nil }
            return measuredSeconds * 1_000 / meters
        }
        let lifecycle = LooprActivityLifecycle.session(for: workout, allowed: true)
        let status: String
        if case .finished = lifecycle { status = "Complete" }
        else { status = workout.state.displayName }
        return .init(
            elapsedSeconds: elapsed,
            heartRate: heartRate,
            status: status,
            startedAt: workout.state == .active ? now.addingTimeInterval(-Double(elapsed)) : nil,
            heartRateObservedAt: heartRateObservedAt,
            zone: heartRate == nil ? nil : live.zone?.number,
            distanceMeters: distanceSample?.distanceMeters,
            paceSecondsPerKilometer: pace,
            targetName: workout.currentZoneTarget?.title,
            targetStatus: workout.targetStatus(bpm: heartRate, at: now)
        )
    }
}
