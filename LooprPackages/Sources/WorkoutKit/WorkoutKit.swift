import AnalyticsKit
import Foundation

/// The one activity catalogue used by workout logging, detection review, and
/// live-session entry points.  Keep this list deliberately small: an activity
/// that is not explicitly supported must remain an honest `other` rather than
/// being guessed from a metric.
public enum ActivityType: String, CaseIterable, Codable, Sendable {
    case run
    case cycle
    case walk
    case hike
    case strength
    case swim
    case cardio
    case yoga
    case hiit
    case pilates
    /// Stretching and mobility work.
    case mobility
    /// CrossFit-style sessions: a WOD with a format and a score.
    case crossfit
    case rowing
    case climbing
    /// Team and racket sports.
    case sport
    case dance
    case other

    public var displayName: String {
        switch self {
        case .run: "Running"
        case .cycle: "Cycling"
        case .walk: "Walking"
        case .hike: "Hiking"
        case .strength: "Strength training"
        case .swim: "Swimming"
        case .cardio: "Cardio"
        case .yoga: "Yoga"
        case .hiit: "HIIT"
        case .pilates: "Pilates"
        case .mobility: "Stretching and mobility"
        case .crossfit: "CrossFit"
        case .rowing: "Rowing"
        case .climbing: "Climbing"
        case .sport: "Sport"
        case .dance: "Dance"
        case .other: "Other"
        }
    }
}

public extension ActivityType {
    /// The activities the start screen records. Strength is missing on purpose: a gym workout starts
    /// from Train, where it logs sets, reps and weight instead of recording heart rate alone.
    static let recordable: [ActivityType] = [.run, .cycle, .walk, .hike, .swim, .rowing, .hiit, .crossfit, .cardio,
                                              .yoga, .pilates, .mobility, .climbing, .sport, .dance, .other]

    /// "Run", "Ride", for tiles and buttons.
    var shortName: String {
        switch self {
        case .run: "Run"
        case .cycle: "Ride"
        case .walk: "Walk"
        case .hike: "Hike"
        case .strength: "Gym"
        case .swim: "Swim"
        case .cardio: "Cardio"
        case .yoga: "Yoga"
        case .hiit: "HIIT"
        case .pilates: "Pilates"
        case .mobility: "Mobility"
        case .crossfit: "WOD"
        case .rowing: "Row"
        case .climbing: "Climb"
        case .sport: "Sport"
        case .dance: "Dance"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .run: "figure.run"
        case .cycle: "figure.outdoor.cycle"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .strength: "dumbbell.fill"
        case .swim: "figure.pool.swim"
        case .cardio: "figure.mixed.cardio"
        case .yoga: "figure.yoga"
        case .hiit: "figure.highintensity.intervaltraining"
        case .pilates: "figure.pilates"
        case .mobility: "figure.flexibility"
        case .crossfit: "figure.cross.training"
        case .rowing: "figure.rower"
        case .climbing: "figure.climbing"
        case .sport: "figure.basketball"
        case .dance: "figure.dance"
        case .other: "figure.stand"
        }
    }

    /// What Loopr records for it, in a few words.
    var recordsCaption: String {
        switch self {
        case .run, .cycle, .walk, .hike: "Route, pace and heart rate"
        case .swim: "Time and heart rate. Add your lengths after."
        case .strength: "Sets, reps and weight"
        default: "Heart rate and strain"
        }
    }
}

public enum WorkoutSource: String, Codable, Sendable {
    case live
    case manual
    case detected
    case imported
    case healthKit
}

/// The durable state machine.  `interruptedAndRecoverable` is intentionally a
/// user-decision state; recovery never silently resumes a workout.
public enum WorkoutLifecycleState: String, CaseIterable, Codable, Sendable {
    case selectedActivity
    case preparing
    case active
    case paused
    case finishing
    case completed
    case interruptedAndRecoverable
    case discarded

    public var displayName: String {
        switch self {
        case .selectedActivity: "Ready"
        case .preparing: "Preparing"
        case .active: "Active"
        case .paused: "Paused"
        case .finishing: "Finishing"
        case .completed: "Completed"
        case .interruptedAndRecoverable: "Needs attention"
        case .discarded: "Discarded"
        }
    }
}

public enum WorkoutTransitionError: Error, Equatable, Sendable, LocalizedError {
    case missingWorkout
    case illegalTransition(from: WorkoutLifecycleState, to: WorkoutLifecycleState)
    case invalidTimeRange
    case cannotEditFinalizedWorkout
    case finalizationInProgress
    case liveSamplesUnavailable
    case staleLiveGeneration
    case anotherWorkoutActive

    public var errorDescription: String? {
        if self == .anotherWorkoutActive {
            return "Finish or discard your current workout before starting another."
        }
        return nil
    }
}

public enum WorkoutRecoveryAction: String, CaseIterable, Sendable {
    case resume
    case discard
}

public struct WorkoutIdentity: Hashable, Codable, Sendable {
    public let canonicalKey: String

    public init(canonicalKey: String) {
        self.canonicalKey = canonicalKey
    }

    /// Callers pass the source's stable session id when one exists.  For
    /// imported/detected records without one, the bounded start/end bucket is
    /// enough to reconcile the same underlying session without using a fuzzy
    /// metric-derived identity.
    public static func make(
        activity: ActivityType,
        sourceKey: String?,
        startedAt: Date,
        endedAt: Date?
    ) -> Self {
        if let sourceKey, !sourceKey.isEmpty {
            return Self(canonicalKey: "source:\(sourceKey)")
        }
        let start = Int(startedAt.timeIntervalSince1970.rounded())
        let end = endedAt.map { Int($0.timeIntervalSince1970.rounded()) } ?? 0
        return Self(canonicalKey: "window:\(activity.rawValue):\(start):\(end)")
    }
}

public struct WorkoutSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let heartRate: Int?
    public let zone: Int?
    public let strain: Double?
    public let energyKcal: Double?
    public let distanceMeters: Double?

    public init(
        timestamp: Date,
        heartRate: Int? = nil,
        zone: Int? = nil,
        strain: Double? = nil,
        energyKcal: Double? = nil,
        distanceMeters: Double? = nil
    ) {
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.zone = zone
        self.strain = strain
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
    }
}

/// The app composition supplies the one verified live cardiac stream. Fixture
/// compositions may omit it, but production must not turn an unavailable
/// stream into fabricated samples.
public protocol WorkoutLiveSampleSource: Sendable {
    func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease
}

public final class WorkoutLiveSampleLease: @unchecked Sendable {
    public let generation: UUID
    public let stream: AsyncStream<WorkoutSample>

    private let lock = NSLock()
    private var cancelled = false
    private let cancelAction: @Sendable () async -> Void

    public init(
        generation: UUID,
        stream: AsyncStream<WorkoutSample>,
        cancelAction: @escaping @Sendable () async -> Void
    ) {
        self.generation = generation
        self.stream = stream
        self.cancelAction = cancelAction
    }

    public func cancel() async {
        let shouldCancel = lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        await cancelAction()
    }
}

public struct UnavailableWorkoutLiveSampleSource: WorkoutLiveSampleSource {
    public init() {}

    public func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease {
        throw WorkoutTransitionError.liveSamplesUnavailable
    }
}

/// Account-export totals. These are session summaries, never invented live
/// samples. Each absent field remains nil.
public struct WorkoutImportedSummary: Codable, Equatable, Sendable {
    public let source: String
    public let activityName: String?
    public let strain: Double?
    public let energyKcal: Double?
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let zonePercentages: [Int: Double]
    public init(source: String, activityName: String? = nil, strain: Double? = nil, energyKcal: Double? = nil,
                averageHeartRate: Double? = nil, maximumHeartRate: Double? = nil, zonePercentages: [Int: Double] = [:]) {
        self.source = source; self.activityName = activityName; self.strain = strain; self.energyKcal = energyKcal
        self.averageHeartRate = averageHeartRate; self.maximumHeartRate = maximumHeartRate
        self.zonePercentages = zonePercentages
    }
}

public struct WorkoutRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identity: WorkoutIdentity
    public var activity: ActivityType
    public var source: WorkoutSource
    public var state: WorkoutLifecycleState
    public let createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var samples: [WorkoutSample]
    public var checkpointNumber: Int
    public var lastCheckpointAt: Date?
    public var finalizationStage: FinalizationStage
    public var importedSummary: WorkoutImportedSummary?
    public var heartRateRecovery: TimedHeartRateRecovery?
    public var pauses: [WorkoutPause]?
    public var zoneAlertPreference: WorkoutZoneAlertPreference?
    public var zoneTargetChanges: [WorkoutZoneTargetChange]?

    // What the person logged by hand (Fitness round 1). Every field is optional, so records saved
    // before these existed decode unchanged.
    /// A name for the session, as "Spin class" or "Bouldering".
    public var title: String?
    /// How hard it felt, 1 to 10, in the person's words.
    public var effort: Int?
    /// A distance the person typed. A measured distance stays in `samples`.
    public var loggedDistanceMeters: Double?
    /// An average heart rate the person typed. It is never counted as zone minutes.
    public var typedAverageHeartRate: Int?
    public var notes: String?
    /// The format, movements and score of a CrossFit session.
    public var wod: WODResult?
    /// Pool lengths the person counted. A swim has no other way to know its distance.
    public var lengths: Int?
    public var poolLengthMeters: Int?
    /// Calories read off a machine's display. Never mixed with the band's estimates.
    public var loggedCalories: Int?
    /// The work phases of an interval timer session.
    public var effortWindows: [WorkoutEffortWindow]?

    public init(
        id: UUID,
        identity: WorkoutIdentity,
        activity: ActivityType,
        source: WorkoutSource,
        state: WorkoutLifecycleState = .selectedActivity,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        samples: [WorkoutSample] = [],
        checkpointNumber: Int = 0,
        lastCheckpointAt: Date? = nil,
        finalizationStage: FinalizationStage = .none,
        importedSummary: WorkoutImportedSummary? = nil,
        heartRateRecovery: TimedHeartRateRecovery? = nil,
        pauses: [WorkoutPause]? = nil,
        zoneAlertPreference: WorkoutZoneAlertPreference? = nil,
        zoneTargetChanges: [WorkoutZoneTargetChange]? = nil,
        title: String? = nil,
        effort: Int? = nil,
        loggedDistanceMeters: Double? = nil,
        typedAverageHeartRate: Int? = nil,
        notes: String? = nil,
        wod: WODResult? = nil,
        lengths: Int? = nil,
        poolLengthMeters: Int? = nil,
        loggedCalories: Int? = nil,
        effortWindows: [WorkoutEffortWindow]? = nil
    ) {
        self.lengths = lengths
        self.poolLengthMeters = poolLengthMeters
        self.loggedCalories = loggedCalories
        self.effortWindows = effortWindows
        self.id = id
        self.identity = identity
        self.activity = activity
        self.source = source
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.checkpointNumber = checkpointNumber
        self.lastCheckpointAt = lastCheckpointAt
        self.finalizationStage = finalizationStage
        self.importedSummary = importedSummary
        self.heartRateRecovery = heartRateRecovery
        self.pauses = pauses; self.zoneAlertPreference = zoneAlertPreference
        self.zoneTargetChanges = zoneTargetChanges
        self.title = title
        self.effort = effort
        self.loggedDistanceMeters = loggedDistanceMeters
        self.typedAverageHeartRate = typedAverageHeartRate
        self.notes = notes
        self.wod = wod
    }

    public var duration: TimeInterval? {
        guard startedAt != nil, let end = endedAt else { return nil }
        return activeElapsed(at: end)
    }

    public var isActive: Bool {
        [.preparing, .active, .paused, .finishing].contains(state)
    }
}

public enum FinalizationStage: String, Codable, CaseIterable, Sendable {
    case none
    case localCommit
    case healthKitEnqueued
    case snapshotPublished
    case liveActivityUpdated
    case activeStateCleared
}

public struct WorkoutFinalizationHooks: Sendable {
    public var enqueueHealthKit: @Sendable (WorkoutRecord) async throws -> Void
    public var publishSnapshot: @Sendable (WorkoutRecord) async throws -> Void
    public var updateLiveActivity: @Sendable (WorkoutRecord) async throws -> Void

    public init(
        enqueueHealthKit: @escaping @Sendable (WorkoutRecord) async throws -> Void = { _ in },
        publishSnapshot: @escaping @Sendable (WorkoutRecord) async throws -> Void = { _ in },
        updateLiveActivity: @escaping @Sendable (WorkoutRecord) async throws -> Void = { _ in }
    ) {
        self.enqueueHealthKit = enqueueHealthKit
        self.publishSnapshot = publishSnapshot
        self.updateLiveActivity = updateLiveActivity
    }
}

/// The explicit privacy choices made before a workout share preview is built.
/// Route and location are opt-in and remain separate so a caller cannot
/// accidentally broaden one selection when enabling the other.
public struct WorkoutShareRequest: Codable, Equatable, Sendable {
    public let workoutID: UUID
    public let includeRoute: Bool
    public let includeLocation: Bool

    public init(workoutID: UUID, includeRoute: Bool = false, includeLocation: Bool = false) {
        self.workoutID = workoutID
        self.includeRoute = includeRoute
        self.includeLocation = includeLocation
    }
}

/// A local, redacted preview contract.  The preview contains only the fields
/// a share renderer explicitly opted into; it is not an implicit export of the
/// complete workout record.
public struct WorkoutSharePreview: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let activity: ActivityType
    public let duration: TimeInterval?
    public let includesRoute: Bool
    public let includesLocation: Bool
    public let summary: String

    public init(
        id: UUID,
        activity: ActivityType,
        duration: TimeInterval?,
        includesRoute: Bool,
        includesLocation: Bool,
        summary: String
    ) {
        self.id = id
        self.activity = activity
        self.duration = duration
        self.includesRoute = includesRoute
        self.includesLocation = includesLocation
        self.summary = summary
    }
}

public enum WorkoutShareError: Error, Equatable, Sendable {
    case missingWorkout
    case finalizedPreviewUnavailable
}

public protocol WorkoutShareExporter: Sendable {
    func makePreview(workout: WorkoutRecord, request: WorkoutShareRequest) async throws -> WorkoutSharePreview
}

/// Safe default used by package-owned screens and fixtures.  It produces a
/// deterministic local preview and never pretends to send or persist a share.
public struct LocalWorkoutShareExporter: WorkoutShareExporter {
    public init() {}

    public func makePreview(workout: WorkoutRecord, request: WorkoutShareRequest) async throws -> WorkoutSharePreview {
        guard workout.id == request.workoutID else { throw WorkoutShareError.missingWorkout }
        guard workout.state == .completed else { throw WorkoutShareError.finalizedPreviewUnavailable }
        let activity = workout.activity.rawValue.capitalized
        let summary = "\(activity) workout preview, \(Int((workout.duration ?? 0).rounded())) seconds"
        return WorkoutSharePreview(
            id: workout.id,
            activity: workout.activity,
            duration: workout.duration,
            includesRoute: request.includeRoute,
            includesLocation: request.includeLocation,
            summary: summary
        )
    }
}

public protocol WorkoutStore: Sendable {
    func save(_ workout: WorkoutRecord) async throws
    func workout(id: UUID) async -> WorkoutRecord?
    func workout(identity: WorkoutIdentity) async -> WorkoutRecord?
    func all() async -> [WorkoutRecord]
    func remove(id: UUID) async
    func removeChecked(id: UUID) async throws
    func cacheHeartRateRecovery(_ value: TimedHeartRateRecovery, workoutID: UUID, startedAt: Date, endedAt: Date) async throws
    /// The workouts `query` covers, as list rows: see `WorkoutRecord.listingRow`.
    /// A store that keeps full records on disk can decode rows without
    /// building every sample.
    func listingRows(_ query: WorkoutLogQuery) async -> [WorkoutRecord]
}

public extension WorkoutStore {
    func removeChecked(id: UUID) async throws { await remove(id: id) }
    // Caching is optional. Durable stores override this with a conditional
    // update; a default read/await/save could resurrect a deleted workout.
    func cacheHeartRateRecovery(_ value: TimedHeartRateRecovery, workoutID: UUID, startedAt: Date, endedAt: Date) async throws {}
    func listingRows(_ query: WorkoutLogQuery) async -> [WorkoutRecord] {
        await all().filter { query.contains($0.startedAt ?? $0.createdAt) }.map(\.listingRow)
    }
}

/// How much of each record a workout list load reads.
public enum WorkoutListDetail: Sendable, Equatable {
    /// Every sample. Detail, recovery and share screens need these.
    case full
    /// `WorkoutRecord.listingRow`: what a list row shows, without the samples.
    case listing
}

public extension WorkoutRecord {
    /// This record as the workout list shows it. Every field is kept except
    /// `samples`, which is cut to the time and distance of the newest sample
    /// that carries a distance, the only sample a row reads. Open the record
    /// by `id` for the rest.
    var listingRow: WorkoutRecord {
        var row = self
        row.samples = latestDistanceSample.map {
            [WorkoutSample(timestamp: $0.timestamp, distanceMeters: $0.distanceMeters)]
        } ?? []
        return row
    }

    /// The newest sample with a distance, if any.
    var latestDistanceSample: WorkoutSample? {
        samples.filter { $0.distanceMeters != nil }.max { $0.timestamp < $1.timestamp }
    }
}

/// Decodes a stored `WorkoutRecord` straight into its `listingRow`.
///
/// A completed workout stores one sample per second, so a three-month list
/// used to build hundreds of thousands of samples to show one distance per
/// row. This reads the same JSON but keeps only each sample's time and
/// distance while scanning, so the rows cost what they show.
public struct WorkoutListingRowDocument: Decodable, Sendable {
    public let row: WorkoutRecord

    private enum CodingKeys: String, CodingKey {
        case id, identity, activity, source, state, createdAt, startedAt, endedAt
        case samples, checkpointNumber, lastCheckpointAt, finalizationStage, importedSummary, heartRateRecovery, pauses, zoneAlertPreference, zoneTargetChanges
        case title, effort, loggedDistanceMeters, typedAverageHeartRate, notes, wod
        case lengths, poolLengthMeters, loggedCalories, effortWindows
    }

    private struct DistanceProbe: Decodable {
        let timestamp: Date
        let distanceMeters: Double?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let probes = try container.decode([DistanceProbe].self, forKey: .samples)
        let latest = probes.filter { $0.distanceMeters != nil }.max { $0.timestamp < $1.timestamp }
        row = WorkoutRecord(
            id: try container.decode(UUID.self, forKey: .id),
            identity: try container.decode(WorkoutIdentity.self, forKey: .identity),
            activity: try container.decode(ActivityType.self, forKey: .activity),
            source: try container.decode(WorkoutSource.self, forKey: .source),
            state: try container.decode(WorkoutLifecycleState.self, forKey: .state),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            endedAt: try container.decodeIfPresent(Date.self, forKey: .endedAt),
            samples: latest.map { [WorkoutSample(timestamp: $0.timestamp, distanceMeters: $0.distanceMeters)] } ?? [],
            checkpointNumber: try container.decode(Int.self, forKey: .checkpointNumber),
            lastCheckpointAt: try container.decodeIfPresent(Date.self, forKey: .lastCheckpointAt),
            finalizationStage: try container.decode(FinalizationStage.self, forKey: .finalizationStage),
            importedSummary: try container.decodeIfPresent(WorkoutImportedSummary.self, forKey: .importedSummary),
            heartRateRecovery: try container.decodeIfPresent(TimedHeartRateRecovery.self, forKey: .heartRateRecovery),
            pauses: try container.decodeIfPresent([WorkoutPause].self, forKey: .pauses),
            zoneAlertPreference: try container.decodeIfPresent(WorkoutZoneAlertPreference.self, forKey: .zoneAlertPreference),
            zoneTargetChanges: try container.decodeIfPresent([WorkoutZoneTargetChange].self, forKey: .zoneTargetChanges),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            effort: try container.decodeIfPresent(Int.self, forKey: .effort),
            loggedDistanceMeters: try container.decodeIfPresent(Double.self, forKey: .loggedDistanceMeters),
            typedAverageHeartRate: try container.decodeIfPresent(Int.self, forKey: .typedAverageHeartRate),
            notes: try container.decodeIfPresent(String.self, forKey: .notes),
            wod: try container.decodeIfPresent(WODResult.self, forKey: .wod),
            lengths: try container.decodeIfPresent(Int.self, forKey: .lengths),
            poolLengthMeters: try container.decodeIfPresent(Int.self, forKey: .poolLengthMeters),
            loggedCalories: try container.decodeIfPresent(Int.self, forKey: .loggedCalories),
            effortWindows: try container.decodeIfPresent([WorkoutEffortWindow].self, forKey: .effortWindows)
        )
    }
}

/// A deterministic actor-backed store.  The app's StorageKit adapter can
/// conform to WorkoutStore without changing any state-machine or screen code.
public actor InMemoryWorkoutStore: WorkoutStore {
    private var rowsByID: [UUID: WorkoutRecord] = [:]
    private var idByIdentity: [WorkoutIdentity: UUID] = [:]

    public init(workouts: [WorkoutRecord] = []) {
        for workout in workouts {
            rowsByID[workout.id] = workout
            idByIdentity[workout.identity] = workout.id
        }
    }

    public func save(_ workout: WorkoutRecord) {
        rowsByID[workout.id] = workout
        idByIdentity[workout.identity] = workout.id
    }

    public func cacheHeartRateRecovery(_ value: TimedHeartRateRecovery, workoutID: UUID, startedAt: Date, endedAt: Date) async throws {
        guard var current = rowsByID[workoutID], current.state == .completed,
              current.startedAt == startedAt, current.endedAt == endedAt else { return }
        current.heartRateRecovery = value
        rowsByID[workoutID] = current
    }

    public func workout(id: UUID) -> WorkoutRecord? { rowsByID[id] }

    public func workout(identity: WorkoutIdentity) -> WorkoutRecord? {
        guard let id = idByIdentity[identity] else { return nil }
        return rowsByID[id]
    }

    public func all() -> [WorkoutRecord] {
        rowsByID.values.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
    }

    public func remove(id: UUID) {
        if let row = rowsByID.removeValue(forKey: id) {
            idByIdentity.removeValue(forKey: row.identity)
        }
    }
}

public struct WorkoutLogQuery: Sendable, Equatable {
    public enum Range: String, CaseIterable, Sendable { case today, week, month, threeMonths, all }
    public var range: Range
    public var now: Date
    public var calendar: Calendar

    public init(range: Range, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.range = range
        self.now = now
        self.calendar = calendar
    }

    public func contains(_ date: Date) -> Bool {
        var calendar = calendar
        calendar.timeZone = self.calendar.timeZone
        let start: Date?
        switch range {
        case .today: start = calendar.startOfDay(for: now)
        case .week: start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: start = calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: now)
        case .all: start = .distantPast
        }
        return date >= (start ?? now) && date <= now
    }
}

/// Coordinates durable checkpoints and all five finalization steps.  A
/// failed side effect leaves the record in `finishing` with its stage intact,
/// allowing the next launch to retry without clearing active state early.
public actor WorkoutSessionController {
    private enum FinalizationEntry {
        case transition(WorkoutLifecycleState)
        case finish
        case discard
    }

    public let store: any WorkoutStore
    private let now: @Sendable () -> Date
    private let liveSource: (any WorkoutLiveSampleSource)?
    private var activeID: UUID?
    private var selectedID: UUID?
    private var liveLease: WorkoutLiveSampleLease?
    private var liveTask: Task<Void, Never>?
    /// Asks for the live stream again while the band refuses it. See `acquireLiveSamplesIfNeeded`.
    private var liveRetryTask: Task<Void, Never>?
    private let liveRetryInterval: Duration
    private var updateContinuations: [UUID: (workoutID: UUID, continuation: AsyncStream<WorkoutRecord>.Continuation)] = [:]
    private var finalizationsInProgress: Set<UUID> = []
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    // Actor isolation does not protect a read/modify/save transaction across
    // store and integration awaits. Keep mutations in order; reads stay free.
    private func acquireMutation() async throws {
        try Task.checkCancellation()
        if mutationActive {
            await withCheckedContinuation { mutationWaiters.append($0) }
        } else {
            mutationActive = true
        }
        do { try Task.checkCancellation() }
        catch { releaseMutation(); throw error }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationActive = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    public init(
        store: any WorkoutStore,
        now: @escaping @Sendable () -> Date = Date.init,
        liveSource: (any WorkoutLiveSampleSource)? = nil,
        liveRetryInterval: Duration = .seconds(5)
    ) {
        self.store = store
        self.now = now
        self.liveSource = liveSource
        self.liveRetryInterval = liveRetryInterval
    }

    /// A typed update stream keeps the live screen bound to the durable record
    /// without polling or manufacturing a display-only timer value.
    public func updates(for id: UUID) async -> AsyncStream<WorkoutRecord> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<WorkoutRecord>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        updateContinuations[token] = (id, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(token) }
        }
        if let row = await store.workout(id: id) {
            continuation.yield(row)
        }
        return stream
    }

    private func removeUpdateContinuation(_ token: UUID) {
        updateContinuations.removeValue(forKey: token)
    }

    private func broadcast(_ row: WorkoutRecord) {
        for subscriber in updateContinuations.values where subscriber.workoutID == row.id {
            _ = subscriber.continuation.yield(row)
        }
    }

    private func releaseLiveSamples() async {
        liveRetryTask?.cancel()
        liveRetryTask = nil
        liveTask?.cancel()
        liveTask = nil
        let lease = liveLease
        liveLease = nil
        await lease?.cancel()
    }

    /// Attaches the live heart-rate stream. The workout never fails because of it: right after a reconnect
    /// the band offloads its history and refuses live data for a while, and a run or a gym session has to
    /// record anyway. Until the band accepts, the session records time without heart rate and asks again
    /// every `liveRetryInterval`. A composition with no live source at all is not asked again.
    private func acquireLiveSamplesIfNeeded() async {
        guard liveLease == nil, liveRetryTask == nil, let liveSource else { return }
        do {
            try await attachLiveSamples(from: liveSource)
        } catch WorkoutTransitionError.liveSamplesUnavailable {
            return
        } catch {
            scheduleLiveRetry()
        }
    }

    private func attachLiveSamples(from liveSource: any WorkoutLiveSampleSource) async throws {
        let generation = UUID()
        let lease = try await liveSource.acquire(generation: generation)
        liveLease = lease
        liveTask = Task { [weak self] in
            for await sample in lease.stream {
                guard !Task.isCancelled else { break }
                try? await self?.append(sample, generation: generation)
            }
        }
    }

    private func scheduleLiveRetry() {
        let interval = liveRetryInterval
        liveRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, await self.retryLiveSamples() else { continue }
                return
            }
        }
    }

    /// One retry. True when there is nothing left to retry: the stream attached, or the session is no longer
    /// an active live recording.
    private func retryLiveSamples() async -> Bool {
        do { try await acquireMutation() } catch { return true }
        defer { releaseMutation() }
        guard !Task.isCancelled else { return true }
        guard liveLease == nil, let liveSource, let id = activeID,
              let row = await store.workout(id: id), row.source == .live, row.state == .active else {
            liveRetryTask = nil
            return true
        }
        do {
            try await attachLiveSamples(from: liveSource)
            liveRetryTask = nil
            return true
        } catch {
            return false
        }
    }

    /// True while an active live session is still waiting for the band to allow heart rate.
    public var isWaitingForLiveSamples: Bool { liveRetryTask != nil }

    /// Reattaches an active persisted session to the verified live source after
    /// a relaunch. While the band refuses live data it keeps asking in the background.
    public func reattachLiveSamples() async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        guard let id = activeID ?? selectedID,
              let row = await store.workout(id: id),
              row.source == .live,
              row.isActive else { return }
        await acquireLiveSamplesIfNeeded()
    }

    private func append(_ sample: WorkoutSample, generation: UUID) async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        guard liveLease?.generation == generation else {
            throw WorkoutTransitionError.staleLiveGeneration
        }
        try await appendLocked(sample)
    }

    public func activeWorkout() async -> WorkoutRecord? {
        guard let activeID else { return nil }
        return await store.workout(id: activeID)
    }

    public func workout(id: UUID) async -> WorkoutRecord? {
        await store.workout(id: id)
    }

    /// The row currently selected by a package-owned detail/recovery route.
    /// Selection survives finalization so the detail screen can render the
    /// exact record that was just completed instead of looking up the first
    /// matching row.
    public func selectedWorkout() async -> WorkoutRecord? {
        guard let selectedID else { return nil }
        return await store.workout(id: selectedID)
    }

    public func selectedWorkoutID() -> UUID? { selectedID }

    @discardableResult
    public func select(id: UUID) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard let row = await store.workout(id: id) else { throw WorkoutTransitionError.missingWorkout }
        if row.isActive { try await requireNoOtherActiveWorkout(id: id) }
        selectedID = id
        if row.isActive { activeID = id }
        return row
    }

    @discardableResult
    public func start(
        activity: ActivityType,
        source: WorkoutSource = .live,
        sourceKey: String? = nil,
        id: UUID? = nil
    ) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        let created = now()
        let identity = WorkoutIdentity.make(activity: activity, sourceKey: sourceKey, startedAt: created, endedAt: nil)
        if let activeID, let current = await store.workout(id: activeID),
           current.isActive || current.state == .selectedActivity {
            guard current.identity == identity else { throw WorkoutTransitionError.anotherWorkoutActive }
            selectedID = current.id
            return current
        }
        if let existing = await store.workout(identity: identity) {
            if existing.isActive { activeID = existing.id }
            selectedID = existing.id
            return existing
        }
        let row = WorkoutRecord(
            id: id ?? UUID(), identity: identity, activity: activity, source: source,
            createdAt: created
        )
        try await store.save(row)
        activeID = row.id
        selectedID = row.id
        return row
    }

    @discardableResult
    public func transition(to target: WorkoutLifecycleState, hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        guard let id = activeID ?? selectedID else { throw WorkoutTransitionError.missingWorkout }
        if target == .completed || target == .discarded {
            return try await finalizeWithLease(id: id, entry: .transition(target), hooks: hooks)
        }
        try await acquireMutation()
        defer { releaseMutation() }
        return try await transitionLocked(id: id, to: target)
    }

    private func transitionLocked(id: UUID, to target: WorkoutLifecycleState) async throws -> WorkoutRecord {
        guard var row = await store.workout(id: id) else { throw WorkoutTransitionError.missingWorkout }
        guard Self.isLegal(from: row.state, to: target) else {
            throw WorkoutTransitionError.illegalTransition(from: row.state, to: target)
        }
        if target != .paused, target != .interruptedAndRecoverable,
           let index = row.pauses?.lastIndex(where: { $0.end == nil }) { row.pauses?[index].end = now() }
        if target == .paused { row.pauses = (row.pauses ?? []) + [.init(start: now())] }
        row.state = target
        if row.isActive { activeID = row.id }
        if target == .preparing || target == .active, row.startedAt == nil { row.startedAt = now() }
        if target == .interruptedAndRecoverable { row.lastCheckpointAt = now() }
        try await store.save(row)
        broadcast(row)
        if target == .active, row.source == .live {
            await acquireLiveSamplesIfNeeded()
        }
        if target == .paused || target == .interruptedAndRecoverable {
            await releaseLiveSamples()
        }
        return row
    }

    /// Persists the exact target used, so later profile changes cannot rewrite
    /// a completed workout's target time. Configuration changes start a new span.
    @discardableResult public func configureZoneAlerts(id: UUID, preference: WorkoutZoneAlertPreference,
                                                       target: WorkoutZoneTarget?) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard activeID == id, var row = await store.workout(id: id), [.active, .paused].contains(row.state) else {
            throw WorkoutTransitionError.missingWorkout
        }
        row.zoneAlertPreference = preference
        if row.zoneTargetChanges == nil || row.currentZoneTarget != target {
            let at = row.zoneTargetChanges == nil ? row.startedAt ?? now() : now()
            row.zoneTargetChanges = (row.zoneTargetChanges ?? []) + [.init(at: at, target: target)]
        }
        try await store.save(row)
        broadcast(row)
        return row
    }

    public func append(_ sample: WorkoutSample) async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        try await appendLocked(sample)
    }

    private func appendLocked(_ sample: WorkoutSample) async throws {
        guard let activeID, var row = await store.workout(id: activeID) else { throw WorkoutTransitionError.missingWorkout }
        guard [.active, .paused].contains(row.state) else { throw WorkoutTransitionError.illegalTransition(from: row.state, to: .active) }
        row.samples.append(sample)
        try await store.save(row)
        broadcast(row)
    }

    @discardableResult
    public func checkpoint() async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard let activeID, var row = await store.workout(id: activeID) else { throw WorkoutTransitionError.missingWorkout }
        guard row.isActive else { throw WorkoutTransitionError.illegalTransition(from: row.state, to: .active) }
        row.checkpointNumber += 1
        row.lastCheckpointAt = now()
        try await store.save(row)
        broadcast(row)
        return row
    }

    /// Marks any in-flight row recoverable after a process/lifecycle boundary.
    /// It does not resume it and returns rows for the confirmation UI.
    @discardableResult
    public func recoverInterrupted() async throws -> [WorkoutRecord] {
        try await acquireMutation()
        defer { releaseMutation() }
        await releaseLiveSamples()
        var recovered: [WorkoutRecord] = []
        for var row in await store.all() where row.isActive {
            if row.pauses?.last?.end != nil || row.pauses?.isEmpty != false {
                let lastActive = [row.lastCheckpointAt, row.samples.last?.timestamp].compactMap { $0 }.max() ?? now()
                row.pauses = (row.pauses ?? []) + [.init(start: lastActive)]
            }
            row.state = .interruptedAndRecoverable
            row.lastCheckpointAt = now()
            try await store.save(row)
            broadcast(row)
            recovered.append(row)
        }
        activeID = nil
        if recovered.count == 1 { selectedID = recovered[0].id }
        return recovered
    }

    public func resumeRecovered(id: UUID) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard let row = await store.workout(id: id), row.state == .interruptedAndRecoverable else {
            throw WorkoutTransitionError.missingWorkout
        }
        try await requireNoOtherActiveWorkout(id: id)
        activeID = id; selectedID = id
        return try await transitionLocked(id: id, to: .active)
    }

    private func requireNoOtherActiveWorkout(id: UUID) async throws {
        if let activeID, activeID != id, let current = await store.workout(id: activeID),
           current.isActive || current.state == .selectedActivity {
            throw WorkoutTransitionError.anotherWorkoutActive
        }
    }

    @discardableResult
    public func discard(id: UUID, hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        try await finalizeWithLease(id: id, entry: .discard, hooks: hooks)
    }

    /// Finish is idempotent after `activeStateCleared`. A concurrent attempt
    /// for the same UUID fails with `finalizationInProgress`, preventing actor
    /// reentrancy at hook suspension points. The durable local save is always
    /// first; the three integration hooks then run in order; only after all
    /// hooks succeed is the active pointer cleared.
    @discardableResult
    public func finish(id: UUID? = nil, hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        guard let id = id ?? activeID ?? selectedID else { throw WorkoutTransitionError.missingWorkout }
        return try await finalizeWithLease(id: id, entry: .finish, hooks: hooks)
    }

    /// Every public finalization path claims this lease before its first
    /// suspension. This prevents stale pre-await rows from entering the hook
    /// pipeline after a concurrent finish, discard, or terminal transition.
    private func finalizeWithLease(
        id: UUID,
        entry: FinalizationEntry,
        hooks: WorkoutFinalizationHooks
    ) async throws -> WorkoutRecord {
        guard !finalizationsInProgress.contains(id) else {
            throw WorkoutTransitionError.finalizationInProgress
        }
        finalizationsInProgress.insert(id)
        defer { finalizationsInProgress.remove(id) }
        try await acquireMutation()
        defer { releaseMutation() }

        guard var row = await store.workout(id: id) else {
            throw WorkoutTransitionError.missingWorkout
        }
        switch entry {
        case .transition(let target):
            guard Self.isLegal(from: row.state, to: target) else {
                throw WorkoutTransitionError.illegalTransition(from: row.state, to: target)
            }
            row.endedAt = row.endedAt ?? now()
            if target == .discarded { row.state = .discarded }
        case .finish:
            if row.state == .completed { return row }
            guard [.active, .paused, .finishing, .interruptedAndRecoverable].contains(row.state) else {
                throw WorkoutTransitionError.illegalTransition(from: row.state, to: .finishing)
            }
            if row.state != .finishing {
                row.state = .finishing
                row.endedAt = row.endedAt ?? now()
            }
        case .discard:
            guard row.state == .interruptedAndRecoverable || row.state == .selectedActivity || row.state == .discarded else {
                throw WorkoutTransitionError.missingWorkout
            }
            row.state = .discarded
            row.endedAt = row.endedAt ?? now()
            selectedID = id
        }
        return try await executeFinalization(row: row, hooks: hooks)
    }

    /// Executes the durable five-step finalization contract.  The local row
    /// and each integration stage are committed before advancing, so a
    /// relaunch can retry the first incomplete side effect without clearing
    /// the active pointer early.
    private func executeFinalization(row initial: WorkoutRecord, hooks: WorkoutFinalizationHooks) async throws -> WorkoutRecord {
        var row = initial
        if row.finalizationStage == .none || row.finalizationStage == .localCommit {
            row.finalizationStage = .localCommit
            try await store.save(row)
            broadcast(row)
        }
        if row.finalizationStage == .localCommit {
            try await hooks.enqueueHealthKit(row)
            row.finalizationStage = .healthKitEnqueued
            try await store.save(row)
            broadcast(row)
        }
        if row.finalizationStage == .healthKitEnqueued {
            try await hooks.publishSnapshot(row)
            row.finalizationStage = .snapshotPublished
            try await store.save(row)
            broadcast(row)
        }
        if row.finalizationStage == .snapshotPublished {
            try await hooks.updateLiveActivity(row)
            row.finalizationStage = .liveActivityUpdated
            try await store.save(row)
            broadcast(row)
        }
        row.state = row.state == .discarded ? .discarded : .completed
        row.finalizationStage = .activeStateCleared
        try await store.save(row)
        broadcast(row)
        if activeID == row.id {
            await releaseLiveSamples()
            activeID = nil
        }
        selectedID = row.id
        return row
    }

    public func edit(id: UUID, activity: ActivityType? = nil, startedAt: Date? = nil, endedAt: Date? = nil) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard var row = await store.workout(id: id) else { throw WorkoutTransitionError.missingWorkout }
        guard [.selectedActivity, .interruptedAndRecoverable, .completed].contains(row.state) else {
            throw WorkoutTransitionError.cannotEditFinalizedWorkout
        }
        if (startedAt != nil && startedAt != row.startedAt) || (endedAt != nil && endedAt != row.endedAt) {
            row.heartRateRecovery = nil
        }
        if let activity { row.activity = activity }
        if let startedAt { row.startedAt = startedAt }
        if let endedAt { row.endedAt = endedAt }
        if let start = row.startedAt, let end = row.endedAt, end < start { throw WorkoutTransitionError.invalidTimeRange }
        try await store.save(row)
        broadcast(row)
        selectedID = id
        return row
    }

    public func delete(id: UUID) async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        guard await store.workout(id: id) != nil else { throw WorkoutTransitionError.missingWorkout }
        try await store.removeChecked(id: id)
        if activeID == id { await releaseLiveSamples() }
        if activeID == id { activeID = nil }
        if selectedID == id { selectedID = nil }
    }

    public func logManual(activity: ActivityType, startedAt: Date, endedAt: Date, id: UUID? = nil,
                          hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard endedAt >= startedAt else { throw WorkoutTransitionError.invalidTimeRange }
        let identity = WorkoutIdentity.make(activity: activity, sourceKey: nil, startedAt: startedAt, endedAt: endedAt)
        if let existing = await store.workout(identity: identity) {
            if existing.state == .finishing { return try await executeFinalization(row: existing, hooks: hooks) }
            return existing
        }
        let row = WorkoutRecord(id: id ?? UUID(), identity: identity, activity: activity, source: .manual,
                                state: .finishing, createdAt: now(), startedAt: startedAt, endedAt: endedAt,
                                finalizationStage: .none)
        selectedID = row.id
        return try await executeFinalization(row: row, hooks: hooks)
    }

    /// Saves a session the person typed in, with its title, effort, distance, typed heart rate, notes
    /// or WOD score. The entry is checked first (`WorkoutLogEntry.validated`).
    public func logManual(_ entry: WorkoutLogEntry, id: UUID? = nil,
                          hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        let entry = try entry.validated(now: now())
        try await acquireMutation()
        defer { releaseMutation() }
        let identity = WorkoutIdentity.make(activity: entry.activity, sourceKey: nil,
                                            startedAt: entry.startedAt, endedAt: entry.endedAt)
        if let existing = await store.workout(identity: identity) {
            if existing.state == .finishing { return try await executeFinalization(row: existing, hooks: hooks) }
            return existing
        }
        var row = WorkoutRecord(id: id ?? UUID(), identity: identity, activity: entry.activity, source: .manual,
                                state: .finishing, createdAt: now(), startedAt: entry.startedAt, endedAt: entry.endedAt,
                                finalizationStage: .none)
        entry.apply(to: &row)
        selectedID = row.id
        return try await executeFinalization(row: row, hooks: hooks)
    }

    /// Replaces what was logged on a saved or recoverable record: activity, times and the typed details.
    /// Measured samples stay as they are.
    public func edit(id: UUID, entry: WorkoutLogEntry) async throws -> WorkoutRecord {
        let entry = try entry.validated(allowingFuture: true)
        try await acquireMutation()
        defer { releaseMutation() }
        guard var row = await store.workout(id: id) else { throw WorkoutTransitionError.missingWorkout }
        guard [.selectedActivity, .interruptedAndRecoverable, .completed].contains(row.state) else {
            throw WorkoutTransitionError.cannotEditFinalizedWorkout
        }
        if entry.startedAt != row.startedAt || entry.endedAt != row.endedAt { row.heartRateRecovery = nil }
        row.activity = entry.activity
        row.startedAt = entry.startedAt
        row.endedAt = entry.endedAt
        entry.apply(to: &row)
        try await store.save(row)
        broadcast(row)
        selectedID = id
        return row
    }

    /// Sets or clears how hard a finished workout felt. Nothing else on the record changes.
    @discardableResult
    public func setEffort(id: UUID, effort: Int?) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        guard var row = await store.workout(id: id) else { throw WorkoutTransitionError.missingWorkout }
        guard row.state == .completed else { throw WorkoutTransitionError.cannotEditFinalizedWorkout }
        if let effort, !WorkoutLogEntry.effortRange.contains(effort) { throw WorkoutLogError.effortOutOfRange }
        row.effort = effort
        try await store.save(row)
        broadcast(row)
        return row
    }

    public func reconcile(_ candidate: WorkoutRecord,
                          hooks: WorkoutFinalizationHooks = .init()) async throws -> WorkoutRecord {
        try await acquireMutation()
        defer { releaseMutation() }
        if let existing = await store.workout(identity: candidate.identity) {
            var merged = existing
            if merged.samples.isEmpty { merged.samples = candidate.samples }
            if merged.startedAt == nil { merged.startedAt = candidate.startedAt }
            if merged.endedAt == nil { merged.endedAt = candidate.endedAt }
            if existing.source != .live && candidate.source == .live { merged.source = .live }
            try await store.save(merged)
            broadcast(merged)
            selectedID = merged.id
            if merged.state == .finishing { return try await executeFinalization(row: merged, hooks: hooks) }
            return merged
        }
        var pending = candidate
        if pending.state == .completed && pending.finalizationStage == .activeStateCleared {
            pending.state = .finishing
            pending.finalizationStage = .none
        }
        selectedID = pending.id
        return try await executeFinalization(row: pending, hooks: hooks)
    }

    public func list(_ query: WorkoutLogQuery, detail: WorkoutListDetail = .full) async -> [WorkoutRecord] {
        switch detail {
        case .full: await store.all().filter { query.contains($0.startedAt ?? $0.createdAt) }
        case .listing: await store.listingRows(query)
        }
    }

    public static func isLegal(from: WorkoutLifecycleState, to: WorkoutLifecycleState) -> Bool {
        switch (from, to) {
        case (.selectedActivity, .preparing), (.selectedActivity, .discarded),
             (.preparing, .active), (.preparing, .discarded), (.preparing, .interruptedAndRecoverable),
             (.active, .paused), (.active, .finishing), (.active, .interruptedAndRecoverable),
             (.paused, .active), (.paused, .finishing), (.paused, .interruptedAndRecoverable),
             (.finishing, .completed), (.finishing, .interruptedAndRecoverable),
             (.interruptedAndRecoverable, .active), (.interruptedAndRecoverable, .discarded),
             (.completed, .completed), (.discarded, .discarded): return true
        default: return false
        }
    }
}

public struct WorkoutMiniPlayer: Equatable, Sendable {
    public let workoutID: UUID
    public let activity: ActivityType
    public let state: WorkoutLifecycleState
    public let elapsed: TimeInterval?
    public let heartRate: Int?

    public init(workout: WorkoutRecord, now: Date) {
        workoutID = workout.id; activity = workout.activity; state = workout.state
        elapsed = workout.activeElapsed(at: now)
        heartRate = WorkoutLiveMetrics(workout: workout, zones: nil, now: now).heartRate
    }
}

public struct DetectedWorkout: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let detectionID: String
    public let activity: ActivityType
    public let startedAt: Date
    public let endedAt: Date
    /// The band's average heart rate over the bout, when the detector had one (R2-WOD-05). Rows saved before it
    /// existed decode with nil.
    public let averageHeartRate: Int?
    public var id: String { detectionID }
    public init(detectionID: String, activity: ActivityType, startedAt: Date, endedAt: Date, averageHeartRate: Int? = nil) {
        self.detectionID = detectionID; self.activity = activity; self.startedAt = startedAt; self.endedAt = endedAt
        self.averageHeartRate = averageHeartRate.flatMap { $0 > 0 ? $0 : nil }
    }
}

public protocol DetectedWorkoutRepository: Sendable {
    func save(_ detection: DetectedWorkout) async throws
    func allDetections() async -> [DetectedWorkout]
    func detection(id: String) async -> DetectedWorkout?
    func remove(id: String) async throws
}

public enum DetectedWorkoutRepositoryError: Error, Equatable, Sendable {
    case missingDetection
}

public actor InMemoryDetectedWorkoutRepository: DetectedWorkoutRepository {
    private var rows: [String: DetectedWorkout]

    public init(detections: [DetectedWorkout] = []) {
        rows = Dictionary(uniqueKeysWithValues: detections.map { ($0.detectionID, $0) })
    }

    public func save(_ detection: DetectedWorkout) { rows[detection.detectionID] = detection }

    public func allDetections() -> [DetectedWorkout] {
        rows.values.sorted { ($0.startedAt, $0.detectionID) < ($1.startedAt, $1.detectionID) }
    }

    public func detection(id: String) -> DetectedWorkout? { rows[id] }

    public func remove(id: String) throws {
        guard rows.removeValue(forKey: id) != nil else {
            throw DetectedWorkoutRepositoryError.missingDetection
        }
    }
}

public enum DetectedWorkoutCandidate {
    public static func record(
        from detection: DetectedWorkout,
        activity: ActivityType? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        title: String? = nil,
        id: UUID = UUID()
    ) throws -> WorkoutRecord {
        let activity = activity ?? detection.activity
        let startedAt = startedAt ?? detection.startedAt
        let endedAt = endedAt ?? detection.endedAt
        guard endedAt >= startedAt else { throw WorkoutTransitionError.invalidTimeRange }
        return WorkoutRecord(
            id: id,
            identity: WorkoutIdentity.make(
                activity: activity,
                sourceKey: detection.detectionID,
                startedAt: startedAt,
                endedAt: endedAt
            ),
            activity: activity,
            source: .detected,
            state: .completed,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            finalizationStage: .activeStateCleared,
            title: WorkoutLogEntry.cleaned(title)
        )
    }
}

public struct WorkoutScreenSnapshot<Value: Sendable & Equatable>: Sendable, Equatable {
    public enum State: String, CaseIterable, Sendable { case loading, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure, ready }
    public let state: State
    public let value: Value?
    public let accessibilitySummary: String
    public init(state: State, value: Value? = nil, accessibilitySummary: String) {
        self.state = state; self.value = value; self.accessibilitySummary = accessibilitySummary
    }
}
