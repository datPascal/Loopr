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

    /// A completed workout of any source answers a band detection that overlaps it. That includes an Apple Health
    /// import: a Garmin ride already says what the band saw, so the band does not ask about it again.
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

/// Apple Health workouts against Loopr's own records and against each other (R1-VET-01).
///
/// Two records are one session when their activities are in the same family and they overlap by more than half of
/// the shorter one. The richer record is kept, ranked by `rank(_:)`:
///
/// 3. Loopr's live and detected records: the band's heart rate every second, strain and zones.
/// 2. A record with heart rate from elsewhere: an Apple Health workout with heart rate, a WHOOP account export.
/// 1. An Apple Health workout without heart rate: a device still measured its time and usually its distance.
/// 0. A workout typed in by hand.
///
/// On a tie Loopr's own record wins, because it is the one the person made and the band's minutes for that time
/// already count. So a Garmin ride the band also recorded stays Loopr's, and a ride typed in by hand gives way to
/// the Garmin copy that has heart rate. A record that gives way is hidden, never deleted: it shows again when the
/// import is gone.
nonisolated enum HealthWorkoutDeduplication {
    /// Activities that can be the same session under two names.
    enum Family: Equatable {
        case onFoot, ride, swim, row, gym, mindAndBody, cardio, climb
        /// "Other" says nothing about the kind, so it matches every family.
        case any
    }

    static func family(_ activity: ActivityType) -> Family {
        switch activity {
        case .run, .walk, .hike: .onFoot
        case .cycle: .ride
        case .swim: .swim
        case .rowing: .row
        case .strength, .crossfit, .hiit: .gym
        case .yoga, .pilates, .mobility: .mindAndBody
        case .cardio, .dance, .sport: .cardio
        case .climbing: .climb
        case .other: .any
        }
    }

    static func sameFamily(_ lhs: ActivityType, _ rhs: ActivityType) -> Bool {
        let a = family(lhs), b = family(rhs)
        return a == .any || b == .any || a == b
    }

    /// The overlap as a share of the shorter record. Zero when either has no times.
    static func overlapShare(_ lhs: WorkoutRecord, _ rhs: WorkoutRecord) -> Double {
        guard let a = lhs.startedAt, let b = lhs.endedAt, let c = rhs.startedAt, let d = rhs.endedAt else { return 0 }
        let shorter = min(b.timeIntervalSince(a), d.timeIntervalSince(c))
        guard shorter > 0 else { return 0 }
        return max(0, min(b, d).timeIntervalSince(max(a, c))) / shorter
    }

    static func isSameSession(_ lhs: WorkoutRecord, _ rhs: WorkoutRecord) -> Bool {
        lhs.id != rhs.id && sameFamily(lhs.activity, rhs.activity) && overlapShare(lhs, rhs) > 0.5
    }

    /// See the type's comment. Reads only what a list row keeps, so rows and full records rank the same.
    static func rank(_ record: WorkoutRecord) -> Int {
        let hasHeartRate = record.importedSummary?.averageHeartRate != nil || record.samples.contains { $0.heartRate != nil }
        switch record.source {
        case .live, .detected: return 3
        case .healthKit, .imported: return hasHeartRate ? 2 : 1
        case .manual: return hasHeartRate ? 2 : 0
        }
    }

    /// The Apple Health workouts to store. One that ties with or loses to a Loopr record of the same session is
    /// dropped. Of two Apple Health copies of one session, as when a Garmin and an Apple Watch both recorded a ride,
    /// the higher rank is kept, then the longer, then the lower id, so the answer never depends on read order.
    static func importsToKeep(_ imports: [WorkoutRecord], natives: [WorkoutRecord]) -> [WorkoutRecord] {
        let completed = natives.filter { $0.state == .completed && $0.source != .healthKit }
        let survivors = imports.filter { candidate in
            !completed.contains { isSameSession(candidate, $0) && rank(candidate) <= rank($0) }
        }
        let ordered = survivors.sorted { lhs, rhs in
            let left = (rank(lhs), lhs.duration ?? 0), right = (rank(rhs), rhs.duration ?? 0)
            if left != right { return left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var kept: [WorkoutRecord] = []
        for candidate in ordered where !kept.contains(where: { isSameSession(candidate, $0) }) { kept.append(candidate) }
        return kept
    }

    /// Every record except a Loopr record that gives way to a stored Apple Health copy of the same session. Apple
    /// Health records are never hidden here: `importsToKeep` already left out the ones that lose.
    static func visible(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        let imports = records.filter { $0.source == .healthKit && $0.state == .completed }
        guard !imports.isEmpty else { return records }
        return records.filter { record in
            guard record.source != .healthKit, record.state == .completed else { return true }
            return !imports.contains { isSameSession(record, $0) && rank($0) > rank(record) }
        }
    }
}
