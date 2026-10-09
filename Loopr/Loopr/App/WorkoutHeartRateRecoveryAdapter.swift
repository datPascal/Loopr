import AnalyticsKit
import DomainKit
import Foundation
import ProfileKit
import StorageKit
import WorkoutKit

/// Reads the actual post-workout tail. Workout samples stop at finish, so
/// using only the saved session could never measure the following minutes.
nonisolated struct StoredWorkoutRecoveryProvider: WorkoutHeartRateRecoveryProviding {
    let history: StorageDatabase
    let workouts: any WorkoutStore
    let profile: any ProfileRepository
    var zoneSettings: HeartRateZoneSettings? = nil

    func recovery(for workout: WorkoutRecord) async -> WorkoutRecoveryPresentation {
        let user = try? await profile.readProfile()
        let year = workout.endedAt.map { Calendar.current.component(.year, from: $0) }
        let age = user?.birthYear.flatMap { birth in year.map { $0 - birth } }
        let settings = if let zoneSettings { zoneSettings } else { await HeartZonePreferences.shared.load() }
        let maximum = settings.resolved(age: age)?.maximum
        let current = await assessment(workout, maximum: maximum)
        let rows = await workouts.all()
        let prior = rows.filter { $0.id != workout.id && $0.activity == workout.activity && $0.state == .completed &&
            ($0.endedAt ?? .distantFuture) < (workout.endedAt ?? .distantPast) }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }.prefix(20)
        var drops: [Double] = []
        for record in prior {
            let result = await assessment(record, maximum: maximum)
            if let value = result.firstMinute?.dropBPM { drops.append(value) }
        }
        let sorted = drops.sorted()
        let usual: Double? = sorted.count >= 5
            ? (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2 : nil
        return WorkoutRecoveryPresentation(assessment: current, usualDrop: usual, eligibleWorkouts: drops.count)
    }

    private func assessment(_ workout: WorkoutRecord, maximum: Double?) async -> TimedHeartRateRecovery {
        if let saved = workout.heartRateRecovery,
           saved.firstMinute?.algorithmVersion == TimedHeartRateRecovery.algorithmVersion, saved.maximumHR == maximum, saved.secondMinute != nil { return saved }
        guard let start = workout.startedAt, let end = workout.endedAt,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              end > start, abs(start.timeIntervalSince1970) < 1e12, abs(end.timeIntervalSince1970) < 1e12 else {
            return TimedHeartRateRecovery(firstMinute: nil, secondMinute: nil, reason: "A recorded workout end is needed.")
        }
        let snapshot = try? history.historicalAnalyticsSnapshot(from: Int64(max(start.timeIntervalSince1970, end.timeIntervalSince1970 - 300)),
                                                                to: Int64(end.timeIntervalSince1970 + 124))
        let samples = snapshot?.records.map {
            WorkoutHRPoint(timestamp: Double($0.absoluteTimestamp), bpm: Double($0.heartRate ?? 0),
                           valid: ($0.heartRate ?? 0) > 0 && $0.skinContact != 0)
        } ?? []
        let measured = WorkoutAnalytics.timedHeartRateRecovery(samples: samples, start: start.timeIntervalSince1970,
                                                           end: end.timeIntervalSince1970, maximumHR: maximum)
        let result: TimedHeartRateRecovery
        if measured.firstMinute == nil, let saved = workout.heartRateRecovery,
           saved.maximumHR == maximum, saved.firstMinute?.algorithmVersion == TimedHeartRateRecovery.algorithmVersion {
            result = saved
        } else { result = measured }
        // Cache observations. Missing tails can become available
        // after a sync. Refresh the record first so unrelated edits survive.
        if result.firstMinute != nil, var latest = await workouts.workout(id: workout.id),
           latest.startedAt == start, latest.endedAt == end {
            latest.heartRateRecovery = result
            try? await workouts.save(latest)
        }
        return result
    }
}
