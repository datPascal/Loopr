import Foundation
import HealthKitBridge
import WorkoutKit

// R1-VET-01: workouts a Garmin, an Apple Watch or Strava saved to Apple Health become workout records with
// source `.healthKit`, so they show in This week and count in the dose. The records mirror Apple Health over the
// last eight weeks: a workout deleted there, or read access taken away, leaves Loopr on the next refresh.

/// Maps an Apple Health workout onto a workout record.
nonisolated enum HealthWorkoutMapping {
    /// The identity key prefix, so a record names the Apple Health workout it came from.
    static let sourceKeyPrefix = "healthkit:"

    static func activity(_ value: AppleHealthWorkoutActivity) -> ActivityType {
        ActivityType(rawValue: value.rawValue) ?? .other
    }

    /// The record keeps Apple Health's id. Heart rate readings become samples, and the distance is one sample at the
    /// end, which is where list rows and the detail screen read a distance from. The source name ("Garmin Connect")
    /// is `importedSummary.source`.
    static func record(_ workout: AppleHealthWorkout) -> WorkoutRecord {
        var samples = workout.heartRate.map { WorkoutSample(timestamp: $0.time, heartRate: Int($0.bpm.rounded())) }
        if let distance = workout.distanceMeters { samples.append(WorkoutSample(timestamp: workout.end, distanceMeters: distance)) }
        let activity = activity(workout.activity)
        return WorkoutRecord(
            id: workout.id,
            identity: .make(activity: activity, sourceKey: sourceKeyPrefix + workout.id.uuidString,
                            startedAt: workout.start, endedAt: workout.end),
            activity: activity, source: .healthKit, state: .completed, createdAt: workout.start,
            startedAt: workout.start, endedAt: workout.end, samples: samples, finalizationStage: .activeStateCleared,
            importedSummary: WorkoutImportedSummary(
                source: workout.sourceLabel, activityName: workout.activityName, energyKcal: workout.energyKcal,
                averageHeartRate: workout.averageHeartRate, maximumHeartRate: workout.maximumHeartRate))
    }
}

/// What one refresh did.
nonisolated struct HealthWorkoutImportReport: Equatable, Sendable {
    var saved = 0
    var removed = 0
    /// True when the store changed, so the workout list should load again.
    var changed: Bool { saved > 0 || removed > 0 }
}

/// Keeps the workout store's Apple Health records in step with Apple Health.
nonisolated struct HealthWorkoutImporter: Sendable {
    /// How far back the import reads.
    static let windowWeeks = 8

    let reader: any AppleHealthWorkoutReading
    let store: any WorkoutStore
    /// False when Apple Health is off in Loopr or its heart rate read is switched off. Every imported record is
    /// then removed: the import fails closed.
    let mayRead: @Sendable () async -> Bool

    func refresh(now: Date, calendar: Calendar) async -> HealthWorkoutImportReport {
        let rows = await store.listingRows(WorkoutLogQuery(range: .all, now: now, calendar: calendar))
        let stored = rows.filter { $0.source == .healthKit }
        let natives = rows.filter { $0.source != .healthKit }
        guard await mayRead() else { return await remove(stored) }
        let windowStart = calendar.date(byAdding: .day, value: -7 * Self.windowWeeks, to: now) ?? now
        switch await reader.read(from: windowStart, to: now) {
        case .absent(.queryFailed):
            // Apple Health is locked or busy. What was read last time stays.
            return HealthWorkoutImportReport()
        case .absent:
            // No app other than Loopr saved a workout, which is also what a declined read looks like, or access was
            // never asked for: nothing from Apple Health may stay.
            return await remove(stored)
        case .workouts(let workouts):
            let storedByID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var candidates: [WorkoutRecord] = []
            var fresh = Set<UUID>()
            for workout in workouts {
                if let existing = storedByID[workout.id], existing.startedAt == workout.start, existing.endedAt == workout.end {
                    candidates.append(existing)
                } else {
                    candidates.append(HealthWorkoutMapping.record(await reader.withHeartRate(workout)))
                    fresh.insert(workout.id)
                }
            }
            let kept = HealthWorkoutDeduplication.importsToKeep(candidates, natives: natives)
            let keptIDs = Set(kept.map(\.id))
            var report = HealthWorkoutImportReport()
            for record in kept where fresh.contains(record.id) {
                guard (try? await store.save(record)) != nil else { continue }
                report.saved += 1
            }
            // A record from before the window is left alone: this read did not look at it.
            let gone = stored.filter { record in
                !keptIDs.contains(record.id) && (record.startedAt ?? record.createdAt) >= windowStart
            }
            report.removed = await remove(gone).removed
            return report
        }
    }

    private func remove(_ records: [WorkoutRecord]) async -> HealthWorkoutImportReport {
        var report = HealthWorkoutImportReport()
        for record in records {
            await store.remove(id: record.id)
            report.removed += 1
        }
        return report
    }
}

/// Lets one refresh run at a time and skips a refresh that follows the last one within a minute, since the Fitness
/// tab loads on every appearance.
actor HealthWorkoutImportGate {
    static let shared = HealthWorkoutImportGate()
    static let minimumInterval: TimeInterval = 60

    private var running = false
    private var lastRun: Date?

    func run(at now: Date, _ work: @Sendable () async -> HealthWorkoutImportReport) async -> HealthWorkoutImportReport {
        guard !running else { return HealthWorkoutImportReport() }
        if let lastRun, abs(now.timeIntervalSince(lastRun)) < Self.minimumInterval { return HealthWorkoutImportReport() }
        running = true
        defer { running = false; lastRun = now }
        return await work()
    }
}

nonisolated enum HealthWorkoutImport {
    /// Reads Apple Health on this device, leaving out Loopr's own workouts and heart rate.
    static func liveReader(readsHeartRate: Bool) -> any AppleHealthWorkoutReading {
        #if canImport(HealthKit)
        let store: any AppleHealthWorkoutStore = LiveAppleHealthWorkoutStore()
        #else
        let store: any AppleHealthWorkoutStore = UnavailableAppleHealthWorkoutStore()
        #endif
        return AppleHealthWorkoutReader(store: store, excludingBundlePrefixes: MetricHistoryHealth.ownBundlePrefixes,
                                        readsHeartRate: readsHeartRate)
    }

    /// One production refresh. Apple Health's heart rate switch in Loopr governs the workout read too, because the
    /// workouts are read for their heart rate.
    static func refresh(workouts: any WorkoutStore, healthSync: LooprHealthSyncRuntime, now: Date,
                        calendar: Calendar) async -> HealthWorkoutImportReport {
        await HealthWorkoutImportGate.shared.run(at: now) {
            let importer = HealthWorkoutImporter(reader: liveReader(readsHeartRate: true), store: workouts,
                                                 mayRead: { await healthSync.allowsRead(.heartRate) })
            return await importer.refresh(now: now, calendar: calendar)
        }
    }

    /// The stored Apple Health records that overlap the window, with their heart rate samples. List rows carry no
    /// samples, so each record is read in full.
    static func storedRecords(_ store: any WorkoutStore, from start: Date, to end: Date) async -> [WorkoutRecord] {
        let rows = await store.listingRows(WorkoutLogQuery(range: .all, now: end))
        var records: [WorkoutRecord] = []
        for row in rows where row.source == .healthKit {
            guard let rowStart = row.startedAt, let rowEnd = row.endedAt, rowStart < end, rowEnd > start,
                  let record = await store.workout(id: row.id) else { continue }
            records.append(record)
        }
        return records
    }
}
