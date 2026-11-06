import Foundation

// Workouts other apps saved to Apple Health (R1-VET-01).
//
// A Garmin, an Apple Watch or Strava saves its sessions to Apple Health, and
// Loopr reads them back with the name of the app or device that saved them.
// Loopr's own workouts, which it exports to Apple Health, are left out, so a
// session is never read back as outside data.
//
// HealthKit stays behind `AppleHealthWorkoutStore`, so the filtering, the
// value checks and the heart rate fill-in here run against a fake store in
// tests. The live store is in `AppleHealthWorkoutsHealthKit.swift`.
//
// Missing stays missing: a workout with no heart rate has no heart rate, and
// a read that finds nothing says why. It never returns zero.

/// The activity Loopr files an Apple Health workout under. Raw values match
/// WorkoutKit's `ActivityType`, so the app maps one onto the other by name.
public enum AppleHealthWorkoutActivity: String, CaseIterable, Codable, Hashable, Sendable {
    case run, cycle, walk, hike, strength, swim, cardio, yoga, hiit, pilates, mobility, crossfit
    case rowing, climbing, sport, dance, other
}

/// One heart rate reading in beats per minute.
public struct AppleHealthHeartRateSample: Equatable, Hashable, Codable, Sendable {
    public let time: Date
    public let bpm: Double
    public init(time: Date, bpm: Double) { self.time = time; self.bpm = bpm }
}

/// A workout as the store read it, before Loopr's checks.
public struct AppleHealthRawWorkout: Equatable, Sendable {
    /// `HKWorkout.uuid`. Stable for the life of the workout in Apple Health.
    public let id: UUID
    public let activity: AppleHealthWorkoutActivity
    /// Apple Health's name for the activity, for example "Functional strength training".
    public let activityName: String
    public let start: Date
    public let end: Date
    public let distanceMeters: Double?
    public let energyKcal: Double?
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let provenance: AppleHealthProvenance
    /// `HKMetadataKeySyncIdentifier`, when the writing app set one.
    public let syncIdentifier: String?
    /// The metadata keys on the workout. Loopr's exports carry `com.loopr.*` keys.
    public let metadataKeys: Set<String>

    public init(id: UUID, activity: AppleHealthWorkoutActivity, activityName: String, start: Date, end: Date,
                distanceMeters: Double? = nil, energyKcal: Double? = nil, averageHeartRate: Double? = nil,
                maximumHeartRate: Double? = nil, provenance: AppleHealthProvenance, syncIdentifier: String? = nil,
                metadataKeys: Set<String> = []) {
        self.id = id; self.activity = activity; self.activityName = activityName
        self.start = start; self.end = end; self.distanceMeters = distanceMeters; self.energyKcal = energyKcal
        self.averageHeartRate = averageHeartRate; self.maximumHeartRate = maximumHeartRate
        self.provenance = provenance; self.syncIdentifier = syncIdentifier; self.metadataKeys = metadataKeys
    }
}

/// A heart rate reading as the store read it, with who wrote it.
public struct AppleHealthRawHeartRate: Equatable, Sendable {
    public let time: Date
    public let bpm: Double
    public let sourceBundleIdentifier: String?
    public init(time: Date, bpm: Double, sourceBundleIdentifier: String?) {
        self.time = time; self.bpm = bpm; self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

/// A checked workout from another app, with its source.
public struct AppleHealthWorkout: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let activity: AppleHealthWorkoutActivity
    public let activityName: String
    public let start: Date
    public let end: Date
    /// Nil when Apple Health has no distance, or a distance of zero.
    public let distanceMeters: Double?
    public let energyKcal: Double?
    public var averageHeartRate: Double?
    public var maximumHeartRate: Double?
    /// The readings inside the workout, oldest first. Empty until
    /// `AppleHealthWorkoutReader.withHeartRate(_:)` fills them, and empty for a
    /// workout recorded without heart rate.
    public var heartRate: [AppleHealthHeartRateSample]
    public let provenance: AppleHealthProvenance

    public init(id: UUID, activity: AppleHealthWorkoutActivity, activityName: String, start: Date, end: Date,
                distanceMeters: Double? = nil, energyKcal: Double? = nil, averageHeartRate: Double? = nil,
                maximumHeartRate: Double? = nil, heartRate: [AppleHealthHeartRateSample] = [],
                provenance: AppleHealthProvenance) {
        self.id = id; self.activity = activity; self.activityName = activityName
        self.start = start; self.end = end; self.distanceMeters = distanceMeters; self.energyKcal = energyKcal
        self.averageHeartRate = averageHeartRate; self.maximumHeartRate = maximumHeartRate
        self.heartRate = heartRate; self.provenance = provenance
    }

    /// "Apple Watch", "Garmin Connect", "Strava". "Apple Health" when nothing names the source.
    public var sourceLabel: String { provenance.label ?? "Apple Health" }
}

public enum AppleHealthWorkoutReadResult: Equatable, Sendable {
    /// Apple Health has workouts from another app. These are the ones in the
    /// window, newest first, and may be none.
    case workouts([AppleHealthWorkout])
    /// Nothing to read. `.noSamples` means no app other than Loopr saved a
    /// workout, which is also what Apple Health shows when the person declined
    /// read access.
    case absent(AppleHealthAbsence)
}

// MARK: - Store boundary

/// Reads workouts and heart rate. The live implementation is `LiveAppleHealthWorkoutStore`.
/// Implementations leave out Loopr's own source and every source whose bundle
/// identifier starts with one of `excludingBundlePrefixes`.
public protocol AppleHealthWorkoutStore: Sendable {
    func access() async -> AppleHealthStoreAccess

    /// The newest `limit` workouts that start in the window. Nil when no
    /// included source has saved a workout at all.
    func workouts(from start: Date, to end: Date, limit: Int,
                  excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawWorkout]?

    /// Heart rate readings that overlap the window, from every included source.
    func heartRate(from start: Date, to end: Date, limit: Int,
                   excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawHeartRate]
}

/// The store for a build or device without Apple Health.
public struct UnavailableAppleHealthWorkoutStore: AppleHealthWorkoutStore {
    public init() {}
    public func access() async -> AppleHealthStoreAccess { .unavailable }
    public func workouts(from start: Date, to end: Date, limit: Int,
                         excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawWorkout]? {
        throw AppleHealthStoreError.unavailable
    }
    public func heartRate(from start: Date, to end: Date, limit: Int,
                          excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawHeartRate] {
        throw AppleHealthStoreError.unavailable
    }
}

// MARK: - Reader

/// What the app asks.
public protocol AppleHealthWorkoutReading: Sendable {
    /// Workouts that start in the window. Never throws: a denial, an empty
    /// result and a failed query each come back as `.absent`.
    func read(from start: Date, to end: Date) async -> AppleHealthWorkoutReadResult
    /// The same workout with its heart rate readings, and its average and
    /// maximum filled from them when Apple Health had none. A failed read
    /// returns the workout unchanged.
    func withHeartRate(_ workout: AppleHealthWorkout) async -> AppleHealthWorkout
}

public struct AppleHealthWorkoutReader: AppleHealthWorkoutReading {
    /// Eight weeks of training is well under this.
    public static let defaultWorkoutLimit = 500
    /// One reading every second for over two hours.
    public static let defaultHeartRateLimit = 10_000

    private let store: any AppleHealthWorkoutStore
    private let excludedBundlePrefixes: [String]
    private let readsHeartRate: Bool

    /// `readsHeartRate` false leaves every workout without heart rate, as when
    /// the person switched heart rate reads off.
    public init(store: any AppleHealthWorkoutStore, excludingBundlePrefixes: [String] = [], readsHeartRate: Bool = true) {
        self.store = store
        self.excludedBundlePrefixes = excludingBundlePrefixes.filter { !$0.isEmpty }
        self.readsHeartRate = readsHeartRate
    }

    public func read(from start: Date, to end: Date) async -> AppleHealthWorkoutReadResult {
        switch await store.access() {
        case .unavailable: return .absent(.unavailable)
        case .notRequested: return .absent(.notAuthorized)
        case .requested: break
        }
        guard start < end else { return .workouts([]) }
        do {
            guard let raw = try await store.workouts(from: start, to: end, limit: Self.defaultWorkoutLimit,
                                                     excludingBundlePrefixes: excludedBundlePrefixes) else {
                return .absent(.noSamples)
            }
            return .workouts(Self.checked(raw, window: start..<end, excludingBundlePrefixes: excludedBundlePrefixes))
        } catch let error as AppleHealthStoreError {
            switch error {
            case .authorizationDenied: return .absent(.notAuthorized)
            case .unavailable: return .absent(.unavailable)
            case .failed(let message): return .absent(.queryFailed(message))
            }
        } catch {
            return .absent(.queryFailed(String(describing: error)))
        }
    }

    public func withHeartRate(_ workout: AppleHealthWorkout) async -> AppleHealthWorkout {
        guard readsHeartRate,
              let raw = try? await store.heartRate(from: workout.start, to: workout.end, limit: Self.defaultHeartRateLimit,
                                                   excludingBundlePrefixes: excludedBundlePrefixes) else { return workout }
        return Self.filling(workout, with: raw)
    }

    // MARK: Rules, pure so tests pin them

    /// True for a workout Loopr saved itself: its source is Loopr, or it
    /// carries the sync identifier or provenance key Loopr's export writes.
    public static func isLooprOwn(_ workout: AppleHealthRawWorkout, excludingBundlePrefixes prefixes: [String]) -> Bool {
        if HealthHistorySourceFilter.isExcluded(workout.provenance.sourceBundleIdentifier, prefixes: prefixes) { return true }
        if workout.syncIdentifier?.hasPrefix("com.loopr.") == true { return true }
        return workout.metadataKeys.contains { $0.hasPrefix("com.loopr.") }
    }

    /// Drops Loopr's own workouts, workouts outside the window, and workouts
    /// that end before they start. Values that cannot be real become nil.
    static func checked(_ raw: [AppleHealthRawWorkout], window: Range<Date>,
                        excludingBundlePrefixes prefixes: [String]) -> [AppleHealthWorkout] {
        var seen = Set<UUID>()
        return raw.compactMap { workout -> AppleHealthWorkout? in
            guard !isLooprOwn(workout, excludingBundlePrefixes: prefixes), workout.start < workout.end,
                  window.contains(workout.start), seen.insert(workout.id).inserted else { return nil }
            return AppleHealthWorkout(
                id: workout.id, activity: workout.activity, activityName: workout.activityName,
                start: workout.start, end: workout.end,
                distanceMeters: positive(workout.distanceMeters), energyKcal: positive(workout.energyKcal),
                averageHeartRate: heartRate(workout.averageHeartRate), maximumHeartRate: heartRate(workout.maximumHeartRate),
                provenance: workout.provenance)
        }
        .sorted { ($0.start, $0.id.uuidString) > ($1.start, $1.id.uuidString) }
    }

    /// The readings inside the workout. The workout's own source wins: a
    /// Garmin ride reads the Garmin's heart rate even when an Apple Watch was
    /// also worn. Other sources count only when the workout's source saved no
    /// heart rate at all, as Strava often does not.
    static func filling(_ workout: AppleHealthWorkout, with raw: [AppleHealthRawHeartRate]) -> AppleHealthWorkout {
        let inside = raw.filter {
            $0.time >= workout.start && $0.time <= workout.end && heartRate($0.bpm) != nil
        }
        let own = workout.provenance.sourceBundleIdentifier.map { bundle in inside.filter { $0.sourceBundleIdentifier == bundle } } ?? []
        let chosen = own.isEmpty ? inside : own
        var byTime: [Date: Double] = [:]
        for sample in chosen where byTime[sample.time] == nil { byTime[sample.time] = sample.bpm }
        var result = workout
        result.heartRate = byTime.keys.sorted().map { AppleHealthHeartRateSample(time: $0, bpm: byTime[$0]!) }
        if result.averageHeartRate == nil, !result.heartRate.isEmpty {
            result.averageHeartRate = result.heartRate.reduce(0) { $0 + $1.bpm } / Double(result.heartRate.count)
        }
        if result.maximumHeartRate == nil { result.maximumHeartRate = result.heartRate.map(\.bpm).max() }
        return result
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// 25 to 250 bpm, the range a heart rate reading can be.
    private static func heartRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (25...250).contains(value) else { return nil }
        return value
    }
}
