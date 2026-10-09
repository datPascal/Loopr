import Foundation
import AnalyticsKit
import StorageKit
import DomainKit
import DesignSystem
import ProfileKit
import TodayKit
import HeartKit
import SleepKit
import BodyKit
import CoachKit
import ImportKit

/// One day's resting autonomic tension, derived from the night's clean RR
/// intervals. This is heart-rate variability, not a mood reading.
nonisolated struct CanonicalStressReading: Codable, Sendable, Equatable {
    let score: Double
    let stressIndex: Double
    let level: String
    /// Share of the night's beats that survived artifact rejection. The Stress
    /// screen's quality gate reads this.
    let coverage: Double
    let confidence: Double
    let algorithmVersion: String
}

nonisolated struct CanonicalDailyProjection: Codable, Sendable {
    let revision: Int64
    let movementBaselineRevision: Int64
    let profile: Profile?
    let timeZoneIdentifier: String
    let algorithmVersion: String
    let latestRecord: Date?
    let today: TodaySummary
    let sleep: SleepDaySnapshot
    let heart: HeartDaySnapshot
    let body: BodyDaySnapshot
    let strainConfidence: Double
    /// Workouts the detector found in this day, ready for a caller that owns
    /// the workout store to persist. Nothing here is written by analytics.
    let detectedWorkouts: [ExerciseSession]
    let stress: CanonicalStressReading?
    let stressHours: [StressHourFeature]?

    private enum CodingKeys: String, CodingKey {
        case revision, movementBaselineRevision, profile, timeZoneIdentifier, algorithmVersion
        case latestRecord, today, sleep, heart, body, strainConfidence, detectedWorkouts, stress, stressHours
    }

    init(revision: Int64, movementBaselineRevision: Int64, profile: Profile?, timeZoneIdentifier: String,
         algorithmVersion: String, latestRecord: Date?, today: TodaySummary, sleep: SleepDaySnapshot,
         heart: HeartDaySnapshot, body: BodyDaySnapshot, strainConfidence: Double,
         detectedWorkouts: [ExerciseSession] = [], stress: CanonicalStressReading? = nil, stressHours: [StressHourFeature]? = nil) {
        self.revision = revision
        self.movementBaselineRevision = movementBaselineRevision
        self.profile = profile
        self.timeZoneIdentifier = timeZoneIdentifier
        self.algorithmVersion = algorithmVersion
        self.latestRecord = latestRecord
        self.today = today
        self.sleep = sleep
        self.heart = heart
        self.body = body
        self.strainConfidence = strainConfidence
        self.detectedWorkouts = detectedWorkouts
        self.stress = stress
        self.stressHours = stressHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        movementBaselineRevision = try container.decode(Int64.self, forKey: .movementBaselineRevision)
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile)
        timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
        latestRecord = try container.decodeIfPresent(Date.self, forKey: .latestRecord)
        today = try container.decode(TodaySummary.self, forKey: .today)
        sleep = try container.decode(SleepDaySnapshot.self, forKey: .sleep)
        heart = try container.decode(HeartDaySnapshot.self, forKey: .heart)
        body = try container.decode(BodyDaySnapshot.self, forKey: .body)
        strainConfidence = try container.decode(Double.self, forKey: .strainConfidence)
        detectedWorkouts = try container.decodeIfPresent([ExerciseSession].self, forKey: .detectedWorkouts) ?? []
        stress = try container.decodeIfPresent(CanonicalStressReading.self, forKey: .stress)
        stressHours = try container.decodeIfPresent([StressHourFeature].self, forKey: .stressHours)
    }

    func replacingToday(_ today: TodaySummary) -> CanonicalDailyProjection {
        CanonicalDailyProjection(revision: revision, movementBaselineRevision: movementBaselineRevision,
            profile: profile, timeZoneIdentifier: timeZoneIdentifier, algorithmVersion: algorithmVersion,
            latestRecord: latestRecord, today: today, sleep: sleep, heart: heart, body: body,
            strainConfidence: strainConfidence, detectedWorkouts: detectedWorkouts, stress: stress, stressHours: stressHours)
    }

    func replacingSleep(_ sleep: SleepDaySnapshot) -> CanonicalDailyProjection {
        CanonicalDailyProjection(revision: revision, movementBaselineRevision: movementBaselineRevision,
            profile: profile, timeZoneIdentifier: timeZoneIdentifier, algorithmVersion: algorithmVersion,
            latestRecord: latestRecord, today: today, sleep: sleep, heart: heart, body: body,
            strainConfidence: strainConfidence, detectedWorkouts: detectedWorkouts, stress: stress, stressHours: stressHours)
    }

    func replacingHeart(_ heart: HeartDaySnapshot) -> CanonicalDailyProjection {
        CanonicalDailyProjection(revision: revision, movementBaselineRevision: movementBaselineRevision,
            profile: profile, timeZoneIdentifier: timeZoneIdentifier, algorithmVersion: algorithmVersion,
            latestRecord: latestRecord, today: today, sleep: sleep, heart: heart, body: body,
            strainConfidence: strainConfidence, detectedWorkouts: detectedWorkouts, stress: stress, stressHours: stressHours)
    }

    func replacingBody(_ body: BodyDaySnapshot) -> CanonicalDailyProjection {
        CanonicalDailyProjection(revision: revision, movementBaselineRevision: movementBaselineRevision,
            profile: profile, timeZoneIdentifier: timeZoneIdentifier, algorithmVersion: algorithmVersion,
            latestRecord: latestRecord, today: today, sleep: sleep, heart: heart, body: body,
            strainConfidence: strainConfidence, detectedWorkouts: detectedWorkouts, stress: stress, stressHours: stressHours)
    }
}

/// One finished day exactly as the screens read it: the projection with its
/// trailing sleep history folded in, and the Today summary with the readiness
/// metric that only a walk over the trailing nights can produce.
///
/// Today, Sleep, Heart and Body all read this one value, so opening four tabs
/// derives the day once rather than four times.
nonisolated struct CanonicalDayDisplay: Codable, Sendable {
    let projection: CanonicalDailyProjection
    let today: TodaySummary
    var hourlyStress: HourlyStressDay? = nil
}

/// Posted after a background pass produces a day generation that differs from
/// the one already on screen. The visible feature root reloads rather than
/// waiting out its poll.
nonisolated let looprDerivedGenerationUpdated = Notification.Name("com.loopr.analytics.generation-updated")

nonisolated private struct DailyMotionCache: Codable {
    let revision: Int64
    let algorithmVersion: String
    let amplitudes: [Double]
    /// This day's own contribution to the personal movement floor. Nil for a
    /// day too thin to summarise.
    let dailyP90: Double?

    private enum CodingKeys: String, CodingKey { case revision, algorithmVersion, amplitudes, dailyP90 }

    init(revision: Int64, algorithmVersion: String, amplitudes: [Double], dailyP90: Double?) {
        self.revision = revision; self.algorithmVersion = algorithmVersion
        self.amplitudes = amplitudes; self.dailyP90 = dailyP90
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int64.self, forKey: .revision)
        algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
        amplitudes = try container.decode([Double].self, forKey: .amplitudes)
        dailyP90 = try container.decodeIfPresent(Double.self, forKey: .dailyP90)
    }
}

nonisolated private struct MovementBaseline {
    let pooledAmplitudes: [Double]
    let dailyP90: [Double]
}

/// The production read-through derivation boundary. Every feature reads the
/// same versioned generation, built from a consistent history snapshot. Raw
/// commits never wait for analytics and retain their commit-before-ACK rule.
actor CanonicalDailyAnalytics: PersistentDataDeletionDeleter {
    nonisolated let storeName = "analytics.daily-generations"
    private var stopped = false
    private var inFlight: [DayIdentity: Task<CanonicalDailyProjection?, Error>] = [:]

    /// In-memory extension of the projection cache. A cold Today or Sleep read
    /// walks 28 prior days; without this each of those days was decoded, and
    /// on a cold cache fully re-derived, once per screen refresh. The memo is
    /// keyed by the same revision and profile predicate the document cache
    /// uses, so a newly synced day still invalidates it.
    private struct MemoEntry {
        let revision: Int64
        let baselineRevision: Int64
        let profile: Profile?
        let timeZoneIdentifier: String
        let projection: CanonicalDailyProjection?
    }
    private var memo: [DayIdentity: MemoEntry] = [:]
    /// The day with its trailing sleep history and readiness folded in, keyed
    /// by the revisions it was built from. Held separately so a 30-day export
    /// loop walks each day's history once rather than once per day it touches,
    /// and written through to the document store so a cold launch paints the
    /// screen from it instead of deriving the day again.
    private struct DisplayGeneration: Codable {
        let revision: Int64
        let baselineRevision: Int64
        let profile: Profile?
        let timeZoneIdentifier: String
        let algorithmVersion: String
        let display: CanonicalDayDisplay
        /// How far the readiness composite trusts its own answer. The local
        /// coach is the only reader, and without it here the coach had to walk
        /// the trailing nights again for a number this pass already produced.
        /// Optional so a generation saved by an older build still decodes.
        let readinessConfidence: Double?
    }
    private var displayMemo: [DayIdentity: DisplayGeneration] = [:]
    private var displayInFlight: [DayIdentity: Task<DisplayGeneration?, Error>] = [:]
    /// Days with a background pass already running. A stale generation is
    /// handed to every screen that asks while one pass catches up.
    private var refreshing: Set<DayIdentity> = []
    private var refreshTasks: [DayIdentity: Task<Void, Never>] = [:]
    private var lastCatchUpAt: [DayIdentity: Date] = [:]
    /// When this actor last actually derived each day. Used only while history
    /// is landing, to hold the foreground consumers to one derivation per day
    /// per coalescing window.
    private var lastDerivedAt: [DayIdentity: Date] = [:]
    /// Readiness confidence rebuilt for a generation saved before that field
    /// existed, kept against the revision it belongs to.
    private var recoveredReadinessConfidence: [DayIdentity: (revision: Int64, confidence: Double)] = [:]
    /// Days this actor actually derived, as opposed to read back from a cache.
    /// This is the number the CPU budget exists to hold down, so it is kept
    /// where a test can assert on it.
    private(set) var derivationCount = 0
    /// The soonest a screen may start another catch-up for the same day. A
    /// pass over a worn day costs seconds of CPU, and the screen has a
    /// finished generation to paint in the meantime. The band streams a second
    /// at a time while the app is open, so anything shorter than a minute
    /// re-derives the day for a second that cannot move a number.
    static let catchUpIntervalSeconds: TimeInterval = 60
    /// How long a day stays derived-enough while the band is offloading a
    /// backlog.
    ///
    /// A history offload moves the day's revision every second, so every
    /// foreground consumer that wakes on a commit sees a revision nothing has
    /// derived yet and asks for its own pass. On the phone that was a quarter
    /// of a second of main-thread-blocking arithmetic several times a second.
    /// Inside this window a consumer is handed the last finished generation
    /// instead, exactly as the screens already are. It applies only while
    /// commits are still arriving, so the pass that finishes the offload is
    /// never delayed.
    static let foregroundCoalesceSeconds: TimeInterval = 20

    func deleteAll() throws {
        stopped = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        for task in displayInFlight.values { task.cancel() }
        displayInFlight.removeAll()
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
        lastCatchUpAt.removeAll()
        lastDerivedAt.removeAll()
        recoveredReadinessConfidence.removeAll()
        memo.removeAll()
        displayMemo.removeAll()
        let generations = sharedGenerations
        Task { await generations.removeAll() }
        try projections.removeAll()
    }
    /// Reads the finished generation without deriving a second assessment in alerts.
    nonisolated static func cachedDisplay(database: StorageDatabase, day: DayIdentity) -> CanonicalDayDisplay? {
        guard let store = try? StorageDocumentStore(database: database, namespace: "daily-analytics"),
              let saved = try? store.read(DisplayGeneration.self, key: displayKey(day)),
              saved.algorithmVersion == zoneVersion else { return nil }
        return saved.display
    }

    /// v7 added overnight vitals (skin temperature, oxygen channels,
    /// beat-to-beat) and cardio fitness. v8 fixed sleep accounting: nights
    /// stored before it counted 0 minutes of deep sleep. v9 added per-night
    /// bed and wake times and stage numbers to the sleep trend. v10 changed
    /// workout detection (gap bridging, sustained moderate effort). Bumping
    /// it re-derives every cached day.
    // v16 combines byte-72 vitals, the published Today summary, sleep/day
    // heart metrics and Body's shared training load.
    static let version = "loopr.daily.17.morning"
    // A zone edit changes Body's strain and zone minutes even when no new
    // band record arrives. Keep the saved generation keyed to that edit.
    static var zoneVersion: String {
        "\(version).zones.\(UserDefaults.standard.integer(forKey: HeartZonePreferences.revisionKey)).workouts.\(UserDefaults.standard.integer(forKey: HourlyStressWorkoutMask.revisionKey))"
    }
    private let history: StorageDatabase
    // Decode only times and state, once per workout edit. The trailing-day
    // walk must not reread every saved workout for each of its 28 days.
    private var workoutMaskCache: (revision: Int, intervals: [DateInterval])?
    private let workoutDocuments: StorageDocumentStore
    private let coachDocuments: StorageDocumentStore
    private let projections: StorageDocumentStore
    private let accountImport: WHOOPImportStore
    private let profileRepository: any ProfileRepository
    private let dateProvider: any DateProviding
    private let timeZoneProvider: any TimeZoneProviding
    /// The process-wide CPU budget. Two analytics actors exist (the screens
    /// use one, the Apple Health export owns another for its own time zone),
    /// so the lane that keeps derivations one at a time has to live outside
    /// both of them.
    private let budget: LooprDerivationBudget
    /// One derived day per revision for the whole process, shared with the
    /// other engine. Injectable so a test suite cannot leak generations
    /// between its own cases.
    private let sharedGenerations: LooprSharedGenerationCache
    /// Metric history write-through. Empty unless the composition installs a
    /// recorder, which it does for the screen engine only.
    nonisolated let metricHistory = MetricHistoryRecorderSlot()

    init(history: StorageDatabase, products: StorageDatabase, profile: any ProfileRepository,
         dateProvider: any DateProviding, timeZoneProvider: any TimeZoneProviding,
         namespace: String = "daily-analytics",
         budget: LooprDerivationBudget = .shared,
         sharedGenerations: LooprSharedGenerationCache = .shared) throws {
        self.history = history
        self.accountImport = try WHOOPImportStore(database: history)
        self.projections = try StorageDocumentStore(database: products, namespace: namespace)
        self.workoutDocuments = try StorageDocumentStore(database: products, namespace: "workouts")
        self.coachDocuments = try StorageDocumentStore(database: products, namespace: "coach")
        self.profileRepository = profile
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
        self.budget = budget
        self.sharedGenerations = sharedGenerations
    }

    func read(day: DayIdentity, reason: String = "read") async throws -> CanonicalDailyProjection? {
        guard let display = try await displayGeneration(day: day, reason: reason)?.display else { return nil }
        return display.projection.replacingToday(display.today)
    }

    /// What a screen paints when it opens.
    ///
    /// The last generation Loopr finished for this day comes back at once,
    /// even when newer seconds have landed since, and a single background pass
    /// catches it up behind the screen. Opening a tab therefore never waits on
    /// a derivation that has already been done once. The pass posts
    /// `looprDerivedGenerationUpdated` when the new generation differs, and the
    /// visible feature root reloads on it.
    func readDisplay(day: DayIdentity, reason: String = "display") async throws -> CanonicalDayDisplay? {
        let band = try await screenGeneration(day: day, reason: reason)?.display
        let label = WHOOPImportStore.label(day)
        let trend = try accountImport.sleepTrend(endingOn: label)
        if let band {
            let sleep = ImportedAccountProjection.withTrend(band.projection.sleep, imported: trend)
            return CanonicalDayDisplay(projection: band.projection.replacingSleep(sleep), today: band.today)
        }
        if let imported = try accountImport.day(label) {
            return ImportedAccountProjection.display(imported, trend: trend)
        }
        return band
    }

    /// The generation a screen paints, with the catch-up scheduled behind it.
    /// Every on-screen reader goes through here, the local coach included, so
    /// one finished day serves all of them.
    private func screenGeneration(day: DayIdentity, reason: String) async throws -> DisplayGeneration? {
        guard !stopped else { return nil }
        if let known = displayMemo[day] ?? (try? projections.read(DisplayGeneration.self, key: Self.displayKey(day))) {
            displayMemo[day] = known
            if try await isCurrent(known, day: day) { return known }
            // A wiped history has no revision to catch up to. Fall through so
            // the authoritative path reports the day as gone.
            if let revisions = try revisions(for: day), revisions.day != 0 {
                scheduleRefresh(day: day)
                return known
            }
        }
        return try await displayGeneration(day: day, reason: reason)
    }

    /// One generation per day and data revision, shared by every screen.
    private func displayGeneration(day: DayIdentity, reason: String) async throws -> DisplayGeneration? {
        guard !stopped else { return nil }
        if let existing = displayInFlight[day] { return try await existing.value }
        let task = Task(priority: derivationPriority) { try await self.buildDisplay(day: day, reason: reason) }
        displayInFlight[day] = task
        defer { displayInFlight.removeValue(forKey: day) }
        return try await task.value
    }

    /// Off screen, a derivation must never outrank anything the system wants
    /// to do. The kills came from a burst of default-priority work.
    private nonisolated var derivationPriority: TaskPriority {
        budget.isForegroundNow ? .userInitiated : .utility
    }

    private func buildDisplay(day: DayIdentity, reason: String) async throws -> DisplayGeneration? {
        guard let base = try await baseProjection(day: day, reason: reason) else { return nil }
        guard !stopped else { return nil }
        let timeZoneIdentifier = timeZoneProvider.timeZone.identifier
        func matches(_ candidate: DisplayGeneration) -> Bool {
            candidate.revision == base.revision
                && candidate.baselineRevision == base.movementBaselineRevision
                && candidate.profile == base.profile
                && candidate.timeZoneIdentifier == timeZoneIdentifier
                && candidate.algorithmVersion == Self.zoneVersion
        }
        if let memo = displayMemo[day], matches(memo) { return memo }
        if let saved = try? projections.read(DisplayGeneration.self, key: Self.displayKey(day)), matches(saved) {
            displayMemo[day] = saved
            return saved
        }
        // The trailing nights are walked once and handed to both consumers.
        // Sleep trends and the readiness composite read the same 28 days, and
        // deriving them twice per screen is what a person feels as a hang.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        let started = DispatchTime.now().uptimeNanoseconds
        let prior = try await priorDays(before: day, count: 30, calendar: calendar, reason: reason)
        guard let displayDay = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)),
              let earlierFloor = calendar.date(byAdding: .day, value: -28, to: displayDay) else { return nil }
        let earlierLabel = HeartAlertsDay.key(earlierFloor, calendar: calendar)
        let prior28 = prior.filter { Self.dayLabel($0.heart.day) >= earlierLabel }
        let withSleep = base.replacingSleep(try await sleepWithHistory(base, day: day, priorDays: prior28))
        // The same 28 days again, no extra read: the Heart trends screen and
        // the resting heart-rate hero line had no points at all without this.
        let withHeart = withSleep.replacingHeart(Self.heartWithHistory(withSleep, priorDays: prior))
        // Cardio fitness reads resting heart rate from the same trailing nights.
        let displayBody = withHeart.body.replacingZoneMinutes(try await displayZoneMinutes(withHeart, prior: prior28, calendar: calendar))
        let projection = withHeart.replacingBody(displayBody.replacingCardioFitness(
            Self.cardioFitness(withHeart, priorDays: prior, calendar: calendar)))
        // `base` is this day's own generation and `todayWithConfidence` needs
        // exactly that. Letting it fetch the day again re-derived it whenever a
        // history batch moved the revision mid-build, which is every second of
        // an offload.
        let hourlyStress = HourlyStress.resolve(base.stressHours ?? [], baseline: prior28.flatMap { $0.stressHours ?? [] }, calendar: calendar)
        guard let summary = try await todayWithConfidence(day: day, current: base, priorDays: prior28, hourlyStress: hourlyStress, reason: reason),
              !stopped else { return nil }
        Self.trace(day: day, reason: "\(reason)+history", started: started, foreground: budget.isForegroundNow)
        let generation = DisplayGeneration(
            revision: base.revision, baselineRevision: base.movementBaselineRevision,
            profile: base.profile, timeZoneIdentifier: timeZoneIdentifier, algorithmVersion: base.algorithmVersion,
            display: CanonicalDayDisplay(projection: projection.replacingToday(summary.0), today: summary.0,
                hourlyStress: hourlyStress),
            readinessConfidence: summary.1)
        displayMemo[day] = generation
        // The generation records the revisions it was built from, so a second
        // that landed while it was building leaves it detectably stale rather
        // than wrong. A deletion, however, must never be published over.
        if let revisions = try revisions(for: day), revisions.day != 0 {
            try? projections.write(generation, key: Self.displayKey(day))
            metricHistory.record(day: day, projection: projection, today: summary.0)
        }
        return generation
    }

    private func isCurrent(_ generation: DisplayGeneration, day: DayIdentity) async throws -> Bool {
        guard generation.algorithmVersion == Self.zoneVersion,
              generation.timeZoneIdentifier == timeZoneProvider.timeZone.identifier,
              let revisions = try revisions(for: day),
              generation.revision == revisions.day,
              generation.baselineRevision == revisions.baseline else { return false }
        return generation.profile == (try await profileRepository.readProfile())
    }

    private func scheduleRefresh(day: DayIdentity) {
        guard !stopped, !refreshing.contains(day) else { return }
        // Nobody is looking at this day while Loopr is off screen, so a
        // speculative catch-up is background CPU spent on a screen that is not
        // there. The Health export and the background processing window still
        // derive the day when they genuinely need it.
        guard budget.isForegroundNow else { return }
        if let last = lastCatchUpAt[day],
           dateProvider.now().timeIntervalSince(last) < Self.catchUpIntervalSeconds { return }
        refreshing.insert(day)
        // Claimed before the pass starts, so a burst of live seconds cannot
        // queue a second one behind the first.
        lastCatchUpAt[day] = dateProvider.now()
        refreshTasks[day] = Task(priority: .utility) { await self.runRefresh(day: day) }
    }

    /// Waits for a refresh already scheduled by a display read. The caller
    /// still checks whether a new generation was actually derived.
    func waitForScheduledRefresh(day: DayIdentity) async {
        await refreshTasks[day]?.value
    }

    private func runRefresh(day: DayIdentity) async {
        defer {
            refreshing.remove(day)
            refreshTasks.removeValue(forKey: day)
            if !stopped { lastCatchUpAt[day] = dateProvider.now() }
        }
        let previous = displayMemo[day]?.revision
        guard let generation = try? await displayGeneration(day: day, reason: "catch-up"),
              generation.revision != previous, !stopped else { return }
        NotificationCenter.default.post(name: looprDerivedGenerationUpdated, object: nil)
    }

    private nonisolated static func elapsedSeconds(since started: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
    }

    #if DEBUG
    /// One line per derivation, on stderr. The app delegate points stderr at a
    /// file in Caches, so an overnight run can be audited from the device
    /// afterwards without a console attached.
    private nonisolated static func trace(day: DayIdentity, reason: String, started: UInt64, foreground: Bool) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        let message = String(
            format: "[Loopr Analytics] %@ derive day=%@ reason=%@ ms=%.0f background=%@\n",
            Date().formatted(date: .omitted, time: .standard),
            dayLabel(day), reason, milliseconds, foreground ? "false" : "true"
        )
        fputs(message, stderr)
    }
    #else
    private nonisolated static func trace(day: DayIdentity, reason: String, started: UInt64, foreground: Bool) {}
    #endif

    private static func documentKey(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }

    private static func displayKey(_ day: DayIdentity) -> String { "display.\(documentKey(day))" }

    /// The absolute-time window one civil day is derived from: the previous
    /// noon through the day's end, plus the preceding 28 days used by the hourly stress
    /// reference. Movement still reads only its own seven-day window. Held as one value so the cache check and the
    /// derivation cannot drift apart.
    private struct DayWindow {
        let calendar: Calendar
        let start: Date
        let end: Date
        let sleepStart: Date
        let baselineStart: Date
    }

    private func window(for day: DayIdentity) -> DayWindow? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        guard let start = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)),
              let end = calendar.date(byAdding: .day, value: 1, to: start),
              let previousDay = calendar.date(byAdding: .day, value: -1, to: start),
              let sleepStart = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: previousDay),
              let baselineStart = calendar.date(byAdding: .day, value: -28, to: start) else { return nil }
        let resolved = calendar.dateComponents([.era, .year, .month, .day], from: start)
        guard resolved.era == day.era, resolved.year == day.year,
              resolved.month == day.month, resolved.day == day.day else { return nil }
        return DayWindow(calendar: calendar, start: start, end: end, sleepStart: sleepStart, baselineStart: baselineStart)
    }

    /// The two revisions a day's generation is keyed by. Reading them is two
    /// indexed lookups, which is what lets a screen decide whether the saved
    /// generation is still current without deriving anything.
    private func revisions(for day: DayIdentity) throws -> (day: Int64, baseline: Int64)? {
        guard let window = window(for: day) else { return nil }
        return (
            try history.historicalAnalyticsRevision(
                from: Int64(window.sleepStart.timeIntervalSince1970), to: Int64(window.end.timeIntervalSince1970)),
            try history.historicalAnalyticsRevision(
                from: Int64(window.baselineStart.timeIntervalSince1970), to: Int64(window.start.timeIntervalSince1970))
        )
    }

    /// A day's generation if one already exists, and nothing else.
    ///
    /// Off screen the prior-day walk uses this instead of deriving. A cold
    /// background launch used to chain today, twenty-eight nights and the
    /// history fold into one unbroken minute of CPU, which is exactly what iOS
    /// killed Loopr for.
    private func cachedProjection(day: DayIdentity) async throws -> CanonicalDailyProjection? {
        guard !stopped else { return nil }
        let profile = try await profileRepository.readProfile()
        let timeZone = timeZoneProvider.timeZone
        guard let revisions = try revisions(for: day) else { return nil }
        if let entry = memo[day], entry.revision == revisions.day, entry.baselineRevision == revisions.baseline,
           entry.profile == profile, entry.timeZoneIdentifier == timeZone.identifier,
           entry.projection?.algorithmVersion == Self.zoneVersion {
            return entry.projection
        }
        if revisions.day == 0 { return nil }
        if let saved = try? projections.read(CanonicalDailyProjection.self, key: Self.documentKey(day)),
           saved.revision == revisions.day, saved.movementBaselineRevision == revisions.baseline,
           saved.profile == profile, saved.timeZoneIdentifier == timeZone.identifier,
           saved.algorithmVersion == Self.zoneVersion {
            return saved
        }
        return await sharedGenerations.projection(
            for: sharedKey(day: day, revisions: revisions, timeZone: timeZone), profile: profile)
    }

    private func sharedKey(day: DayIdentity, revisions: (day: Int64, baseline: Int64),
                           timeZone: TimeZone) -> LooprSharedGenerationCache.Key {
        LooprSharedGenerationCache.Key(history: ObjectIdentifier(history), day: day,
            revision: revisions.day, baselineRevision: revisions.baseline,
            timeZoneIdentifier: timeZone.identifier, algorithmVersion: Self.zoneVersion)
    }

    /// The day's own generation, with no cross-day history folded in. Every
    /// prior-day walk uses this so a 28-day history never triggers 28 further
    /// 28-day histories.
    private func baseProjection(day: DayIdentity, reason: String = "read") async throws -> CanonicalDailyProjection? {
        guard !stopped else { return nil }
        if let existing = inFlight[day] { return try await existing.value }
        let task = Task(priority: derivationPriority) { try await self.compute(day: day, reason: reason) }
        inFlight[day] = task
        defer { inFlight.removeValue(forKey: day) }
        return try await task.value
    }

    func readStress(day: DayIdentity, reason: String = "stress") async throws -> CanonicalStressReading? {
        try await baseProjection(day: day, reason: reason)?.stress
    }

    func readHourlyStress(day: DayIdentity) async throws -> HourlyStressDay? {
        try await readDisplay(day: day, reason: "hourly-stress")?.hourlyStress
    }

    /// Workouts the detector found. The caller owns persistence; analytics
    /// never writes to the workout store.
    func readDetectedWorkouts(day: DayIdentity, reason: String = "workouts") async throws -> [ExerciseSession] {
        try await baseProjection(day: day, reason: reason)?.detectedWorkouts ?? []
    }

    private func compute(day: DayIdentity, reason: String = "read") async throws -> CanonicalDailyProjection? {
        guard !stopped else { return nil }
        let profile = try await profileRepository.readProfile()
        guard !stopped else { return nil }
        let timeZone = timeZoneProvider.timeZone
        guard let window = window(for: day), let revisions = try revisions(for: day) else { return nil }
        let calendar = window.calendar
        let start = window.start, end = window.end
        let sleepStart = window.sleepStart, baselineStart = window.baselineStart
        let revision = revisions.day
        let baselineRevision = revisions.baseline
        let key = Self.documentKey(day)
        if let entry = memo[day], entry.revision == revision, entry.baselineRevision == baselineRevision,
           entry.profile == profile, entry.timeZoneIdentifier == timeZone.identifier,
           entry.projection?.algorithmVersion == Self.zoneVersion {
            return entry.projection
        }
        func remember(_ projection: CanonicalDailyProjection?) -> CanonicalDailyProjection? {
            memo[day] = MemoEntry(revision: revision, baselineRevision: baselineRevision, profile: profile,
                timeZoneIdentifier: timeZone.identifier, projection: projection)
            return projection
        }
        // Revision 0 means no second was ever recorded in this window, so
        // there is nothing to read and nothing to derive. The 28-night walk
        // behind Today and Sleep is mostly such days on a new account.
        if revision == 0 { return remember(nil) }
        if let saved = try? projections.read(CanonicalDailyProjection.self, key: key),
           saved.revision == revision, saved.movementBaselineRevision == baselineRevision, saved.profile == profile,
           saved.timeZoneIdentifier == timeZone.identifier, saved.algorithmVersion == Self.zoneVersion {
            return remember(saved)
        }
        // The other engine may already have derived this exact day. Writing it
        // into this engine's namespace costs a file write instead of fifteen
        // seconds of arithmetic.
        let sharedKey = sharedKey(day: day, revisions: revisions, timeZone: timeZone)
        if let shared = await sharedGenerations.projection(for: sharedKey, profile: profile) {
            try? projections.write(shared, key: key)
            return remember(shared)
        }
        // While the band is offloading a backlog, one more second of history
        // cannot move a number the person can see, and every consumer that
        // wakes on the commit would otherwise buy its own pass over the day.
        // Hand back the last finished generation instead. Once commits stop
        // this stops applying, so the offload still ends in a real derivation.
        if let recent = try await coalescedProjection(day: day, profile: profile, timeZone: timeZone, key: key) {
            return recent
        }
        let raw = try history.historicalAnalyticsSnapshot(from: Int64(sleepStart.timeIntervalSince1970), to: Int64(end.timeIntervalSince1970))
        // A day with no records is remembered as such. Re-snapshotting an
        // empty day 28 times per screen refresh is the same hang as deriving
        // it 28 times, just quieter.
        guard !raw.records.isEmpty else { return remember(nil) }
        try Task.checkCancellation()
        // The single gate. One derivation at a time for the whole process, and
        // off screen never more than the rolling CPU ceiling, whichever path
        // asked: a screen, the export, a prior-day walk or a processing
        // window. A refusal is not an error; the caller keeps what it had.
        guard await budget.beginDerivation() else { return nil }
        // Waiting for the lane can take as long as a derivation, and whoever
        // held it may have been deriving this very day for this very revision:
        // the screens, the widget snapshot and the Health export all wake on
        // the same commit. Ask once more before spending the CPU.
        if let shared = await sharedGenerations.projection(for: sharedKey, profile: profile) {
            await budget.releaseLane()
            try? projections.write(shared, key: key)
            return remember(shared)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let projection: CanonicalDailyProjection
        do {
            let baseline = try await movementBaseline(start: calendar.date(byAdding: .day, value: -7, to: start) ?? baselineStart, end: start, calendar: calendar)
            let zoneVersion = Self.zoneVersion
            projection = try await Self.derive(day: day, raw: raw, profile: profile, timeZone: timeZone,
                dayStart: start.timeIntervalSince1970, dayEnd: end.timeIntervalSince1970,
                now: dateProvider.now(), movementBaseline: baseline, baselineRevision: baselineRevision,
                zoneVersion: zoneVersion, recordedWorkouts: try workoutIntervals(start: start, end: end))
        } catch {
            await budget.endDerivation(seconds: Self.elapsedSeconds(since: started))
            throw error
        }
        let cost = Self.elapsedSeconds(since: started)
        await budget.endDerivation(seconds: cost)
        await sharedGenerations.store(projection, for: sharedKey, profile: profile)
        derivationCount += 1
        lastDerivedAt[day] = dateProvider.now()
        Self.trace(day: day, reason: reason, started: started, foreground: budget.isForegroundNow)
        try Task.checkCancellation()
        _ = remember(projection)
        // A deletion or later sync makes this generation obsolete. The next
        // read derives the new revision; do not publish it over newer inputs.
        guard !stopped else { return nil }
        if (raw.records.last?.absoluteTimestamp ?? 0) <= Int64(dateProvider.now().timeIntervalSince1970),
           try history.historicalAnalyticsRevision(from: Int64(sleepStart.timeIntervalSince1970), to: Int64(end.timeIntervalSince1970)) == raw.revision {
            try projections.write(projection, key: key)
            metricHistory.record(day: day, projection: projection, today: nil)
        }
        return projection
    }

    /// The last finished generation for `day`, when a fresh one would be spent
    /// on history that is still arriving.
    ///
    /// Three conditions, all required: the band is still committing batches,
    /// this day was derived inside the coalescing window, and there is a
    /// finished generation to hand back. A first read, an idle band and a
    /// background pass all fall straight through to the real derivation.
    private func coalescedProjection(day: DayIdentity, profile: Profile?, timeZone: TimeZone,
                                     key: String) async throws -> CanonicalDailyProjection? {
        guard budget.isForegroundNow, let last = lastDerivedAt[day],
              dateProvider.now().timeIntervalSince(last) < Self.foregroundCoalesceSeconds,
              await budget.isHistoryLanding() else { return nil }
        if let entry = memo[day], let projection = entry.projection,
           entry.profile == profile, entry.timeZoneIdentifier == timeZone.identifier,
           projection.algorithmVersion == Self.zoneVersion {
            return projection
        }
        guard let saved = try? projections.read(CanonicalDailyProjection.self, key: key),
              saved.profile == profile, saved.timeZoneIdentifier == timeZone.identifier,
              saved.algorithmVersion == Self.zoneVersion else { return nil }
        return saved
    }

    private func workoutIntervals(start: Date, end: Date) throws -> [DateInterval] {
        let revision = UserDefaults.standard.integer(forKey: HourlyStressWorkoutMask.revisionKey)
        if workoutMaskCache?.revision != revision {
            workoutMaskCache = (revision, try HourlyStressWorkoutMask.intervals(in: workoutDocuments, start: .distantPast, end: .distantFuture))
        }
        return workoutMaskCache?.intervals.filter { $0.end > start && $0.start < end } ?? []
    }

    private func movementBaseline(start: Date, end: Date, calendar: Calendar) async throws -> MovementBaseline {
        var cursor = start
        var values: [Double] = []
        var dailyP90: [Double] = []
        while cursor < end {
            try Task.checkCancellation()
            // A day of acceleration at a time, with the actor released in
            // between, so a seven-day baseline cannot hold one core for as
            // long as it takes to finish all seven.
            await Task.yield()
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let lower = Int64(cursor.timeIntervalSince1970), upper = Int64(next.timeIntervalSince1970)
            let revision = try history.historicalAnalyticsRevision(from: lower, to: upper)
            // No second was ever recorded in this day, so it contributes no
            // amplitudes and no daily p90. Reading and caching that is work
            // for nothing, once per day in the window, on every cold read.
            if revision == 0 { cursor = next; continue }
            let key = "motion.\(lower).\(upper)"
            if let cached = try? projections.read(DailyMotionCache.self, key: key), cached.revision == revision,
               cached.algorithmVersion == ActivityAlgorithm.version {
                values.append(contentsOf: cached.amplitudes)
                if let p90 = cached.dailyP90 { dailyP90.append(p90) }
            } else {
                let samples = try history.historicalAcceleration(from: lower, to: upper).map {
                    ActivityAccelerationSample(timestamp: Double($0.timestamp), x: $0.x, y: $0.y, z: $0.z)
                }
                let motion = ActivityAnalytics.enmoSeries(samples)
                let minutes = motion.value?.minutes ?? []
                let amplitudes = minutes.filter { $0.sampleCount >= 30 }.map(\.dynamicAmplitude)
                let p90 = ActivityAnalytics.dailyDynamicAmplitudeSummary(minutes)
                if !stopped, try history.historicalAnalyticsRevision(from: lower, to: upper) == revision {
                    try projections.write(DailyMotionCache(revision: revision, algorithmVersion: ActivityAlgorithm.version, amplitudes: amplitudes, dailyP90: p90), key: key)
                }
                values.append(contentsOf: amplitudes)
                if let p90 { dailyP90.append(p90) }
            }
            cursor = next
        }
        return MovementBaseline(pooledAmplitudes: values, dailyP90: dailyP90)
    }

    func readToday(day: DayIdentity, reason: String = "today") async throws -> TodaySummary? {
        try await displayGeneration(day: day, reason: reason)?.display.today
    }

    func saveCoachDecision(_ decision: CoachDecision, day: DayIdentity) throws {
        guard !stopped else { throw CancellationError() }
        let key = "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
        var changes = [try StorageDocumentMutation.write(decision, key: "decision.\(key)")]
        if let plan = decision.plan {
            changes.append(try .write(plan.summary, key: "plan.\(key)"))
        } else if case .abstain(let reason) = decision {
            let summary = TodayCoachPlanSummary(title: "No plan yet", detail: reason.reason, recommendationCount: 0,
                evidenceSummary: reason.missingEvidence.map(\.rawValue).joined(separator: ", "), state: .absent)
            changes.append(try .write(summary, key: "plan.\(key)"))
        }
        try coachDocuments.mutate(changes)
    }

    /// Evidence for the local coach, read from the same finished generation the
    /// screens paint.
    ///
    /// This used to walk the trailing nights itself and derive both today and
    /// yesterday, uncached, every time Today reloaded: on the phone that was
    /// two derivations every few seconds for the whole of a history offload,
    /// and the single largest block of CPU in the 91% report. The coach asks a
    /// question about a finished day, so it reads the finished day.
    func readCoachInput(day: DayIdentity) async throws -> CoachInput? {
        guard let generation = try await screenGeneration(day: day, reason: "coach"), !stopped else { return nil }
        let summary = generation.display.today
        let current = generation.display.projection
        guard let readinessConfidence = try await readinessConfidence(for: generation, day: day) else { return nil }
        let inputs: [(CoachEvidenceID, TodayMetricID, Double)] = [
            (.readiness, .recovery, readinessConfidence),
            (.sleep, .sleep, current.sleep.mainSleep?.confidence ?? 0),
            (.strain, .strain, current.strainConfidence)
        ]
        let evidence = inputs.compactMap { id, metricID, confidence -> CoachEvidence? in
            guard let metric = summary.metric(metricID) else { return nil }
            return CoachEvidence(id: id, label: metric.title,
                value: metricID == .sleep ? metric.numericValue.map { $0 / 60 } : metric.numericValue,
                unit: metricID == .sleep ? "hours" : metric.unit,
                state: summary.freshness.state == .stale ? .stale : metric.state,
                confidence: summary.freshness.state == .stale ? 0 : confidence, source: metric.source, detail: "From your saved strap records")
        }
        return CoachInput(day: day, generatedAt: dateProvider.now(), evidence: evidence)
    }

    /// How far readiness trusts itself, for the generation the coach is reading.
    ///
    /// Generations written before this field existed do not carry it, and a
    /// missing number reads as no confidence, which makes the coach abstain on
    /// a day it has perfectly good evidence for. Those are recovered once by
    /// walking the trailing nights, and the answer is kept against the revision
    /// it was computed for so a screen reloading every few seconds cannot buy
    /// the walk again. Every generation written from here on carries it.
    private func readinessConfidence(for generation: DisplayGeneration,
                                     day: DayIdentity) async throws -> Double? {
        if let stored = generation.readinessConfidence { return stored }
        if let recovered = recoveredReadinessConfidence[day], recovered.revision == generation.revision {
            return recovered.confidence
        }
        guard let recomputed = try await todayWithConfidence(
            day: day, current: generation.display.projection, reason: "coach") else { return nil }
        recoveredReadinessConfidence[day] = (generation.revision, recomputed.1)
        return recomputed.1
    }

    /// The 28 nights before `day` that are complete enough to use as a
    /// baseline, newest first. Each day is derived at most once per revision.
    private func priorDays(before day: DayIdentity, count: Int = 28, calendar: Calendar,
                           reason: String = "read") async throws -> [CanonicalDailyProjection] {
        guard let date = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)) else { return [] }
        var prior: [CanonicalDailyProjection] = []
        for offset in 1...max(1, count) {
            try Task.checkCancellation()
            // The first launch after an install derives twenty-eight nights in
            // a row. Yielding between them keeps the walk chunked, so the run
            // loop, the Bluetooth callbacks and cancellation all still get in.
            await Task.yield()
            guard !stopped, let previous = calendar.date(byAdding: .day, value: -offset, to: date) else { break }
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: previous)
            let previousDay = DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
            // Off screen a night is used only if it is already derived. One
            // pass must never chain today, twenty-eight nights and the history
            // fold into one unbroken stretch of CPU, which is what the phone's
            // crash reports were made of.
            let mayDerive = await budget.canDerive()
            let value = mayDerive
                ? try await baseProjection(day: previousDay, reason: "\(reason)/prior")
                : try await cachedProjection(day: previousDay)
            if let value, value.sleep.mainSleep?.isPartial == false {
                prior.append(value)
            }
        }
        return prior
    }

    nonisolated static func dayLabel(_ day: DayIdentity) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    /// Folds the trailing nights into the day's sleep snapshot: the trend
    /// series, sleep need and debt, and the regularity score. Without this the
    /// Sleep trends screen has nothing to draw and the need and debt figures
    /// stay empty forever.
    private func sleepWithHistory(_ projection: CanonicalDailyProjection, day: DayIdentity,
                                  priorDays known: [CanonicalDailyProjection]? = nil) async throws -> SleepDaySnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        let prior: [CanonicalDailyProjection]
        if let known { prior = known } else { prior = try await priorDays(before: day, calendar: calendar) }
        guard !stopped else { return projection.sleep }
        let snapshot = projection.sleep
        let days = [projection] + prior
        // Each night also carries its bed and wake times and its stage,
        // efficiency and breathing numbers, so the Sleep tab can compare a
        // night with the usual ones without deriving anything on screen.
        let trend = days.map { value in
            let label = Self.dayLabel(value.sleep.day)
            return SleepTrendPoint(id: label, localDay: label,
                value: value.sleep.mainSleep.map { Double($0.durationMinutes) / 60 },
                state: value.sleep.state, unit: "hours",
                start: value.sleep.mainSleep?.start, end: value.sleep.mainSleep?.end,
                values: SleepTrendPoint.nightValues(value.sleep, breathingRate: value.heart.metric(.respiration)
                    .flatMap { $0.state == .absent ? nil : $0.numericValue }))
        }.sorted { $0.localDay < $1.localDay }

        func hours(_ value: CanonicalDailyProjection) -> Double? {
            value.sleep.mainSleep.map { Double($0.durationMinutes) / 60 }
        }
        // A free night is one you wake from without an alarm you had to set.
        // Loopr does not know your calendar, so it uses the weekend as the
        // proxy the sleep-need literature uses.
        func isFreeNight(_ value: CanonicalDailyProjection) -> Bool {
            guard let date = calendar.date(from: DateComponents(era: value.sleep.day.era, year: value.sleep.day.year,
                                                                month: value.sleep.day.month, day: value.sleep.day.day)) else { return false }
            let weekday = calendar.component(.weekday, from: date)
            return weekday == 1 || weekday == 7
        }
        let recent = prior.compactMap(hours)
        let free = prior.filter(isFreeNight).compactMap(hours)
        let debt = SleepAnalytics.sleepDebt(recentSleepHours: recent, freeNightSleepHours: free).value

        // Regularity compares each minute with the same minute a day later, so
        // it needs an unbroken run of nights. A missing night is not a night
        // spent awake and must not be scored as one.
        var consecutive: [CanonicalDailyProjection] = []
        let byLabel = Dictionary(days.map { (Self.dayLabel($0.sleep.day), $0) }, uniquingKeysWith: { first, _ in first })
        if let today = calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day)) {
            var offset = 0
            while offset < 29, let date = calendar.date(byAdding: .day, value: -offset, to: today) {
                let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
                let identity = DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
                guard let value = byLabel[Self.dayLabel(identity)], value.sleep.mainSleep != nil else { break }
                consecutive.append(value)
                offset += 1
            }
        }
        var regularity: SleepRegularity?
        if consecutive.count >= 2 {
            let nights = consecutive.reversed().compactMap { value in
                value.sleep.mainSleep.map { RegularityNight(day: value.sleep.day, start: $0.start.timeIntervalSince1970,
                                                            end: $0.end.timeIntervalSince1970) }
            }
            let asleep = Self.regularityMinutes(nights, calendar: calendar)
            regularity = SleepAnalytics.sleepRegularityIndex(asleep, epochsPerDay: 1_440).value
        }

        var metrics = snapshot.metrics
        if let debt {
            metrics.append(SleepMetricValue(id: "need", title: "Sleep need", value: debt.optimalSleepHours.map { String(format: "%.1f", $0) },
                unit: "hours", state: debt.optimalSleepHours == nil ? .settling : .partial,
                confidence: debt.hasFreeNight ? "From your free nights" : "Sleep in on a free day to set this",
                source: snapshot.source, algorithmVersion: SleepAlgorithm.version,
                numericValue: debt.optimalSleepHours, numericUnit: .hours))
            metrics.append(SleepMetricValue(id: "debt", title: "Sleep debt", value: debt.debtHours.map { String(format: "%.1f", $0) },
                unit: "hours", state: debt.debtHours == nil ? .settling : .partial,
                confidence: "Sleep need minus your recent nights",
                source: snapshot.source, algorithmVersion: SleepAlgorithm.version,
                numericValue: debt.debtHours, numericUnit: .hours))
        }
        if let regularity {
            metrics.append(SleepMetricValue(id: "regularity", title: "Sleep regularity", value: String(format: "%.0f", regularity.score),
                unit: "points", state: .partial, confidence: "Your last \(consecutive.count) nights were \(regularity.band)",
                source: snapshot.source, algorithmVersion: SleepAlgorithm.version,
                numericValue: regularity.score, numericUnit: .scorePoints))
        }
        // The Sleep screen has always been able to show a suggested alarm, and
        // analytics never produced one, so the row could not appear. The
        // suggestion is the hour you usually fall asleep plus the sleep you
        // need, and it stays absent until both are known.
        let alarm = Self.suggestedAlarm(need: debt?.optimalSleepHours, prior: prior, calendar: calendar)
        // The row to the local coach was never built, so the Sleep screen
        // could not reach the evidence for the night it was showing. It only
        // appears once there is a night to explain.
        let coach = snapshot.coachLink ?? snapshot.mainSleep.map { _ in
            SleepCoachLink(title: "Sleep coach",
                detail: "How last night affected today's readiness",
                state: snapshot.state)
        }
        return SleepDaySnapshot(day: snapshot.day, state: snapshot.state, mainSleep: snapshot.mainSleep,
            naps: snapshot.naps, metrics: metrics, hypnogram: snapshot.hypnogram, trend: trend,
            needHours: debt?.optimalSleepHours, debtHours: debt?.debtHours,
            source: snapshot.source, algorithmVersion: snapshot.algorithmVersion,
            coachLink: coach, suggestedAlarm: alarm ?? snapshot.suggestedAlarm)
    }

    /// Reclassify display time only. Scores keep their original anchors and weights.
    private func displayZoneMinutes(_ current: CanonicalDailyProjection, prior: [CanonicalDailyProjection],
                                    calendar: Calendar) async throws -> [BodyZoneMinutes] {
        guard let window = window(for: current.heart.day) else { return [] }
        let first = calendar.date(byAdding: .day, value: -13, to: window.start) ?? window.start
        let recent = ([current] + prior).filter { projection in
            guard let start = self.window(for: projection.heart.day)?.start else { return false }
            return start >= first && start <= window.start
        }.sorted { (self.window(for: $0.heart.day)?.start ?? .distantPast) < (self.window(for: $1.heart.day)?.start ?? .distantPast) }
        let resting = recent.compactMap { $0.heart.metric(.restingHeartRate)?.numericValue }
        let settings = await HeartZonePreferences.shared.load()
        let age = current.profile?.birthYear.map { current.heart.day.year - $0 }
        guard let resolved = settings.resolved(age: age, restingNights: resting),
              let zones = ActivityAnalytics.zones(resolved, source: resolved.source == .manual ? .manual : resolved.source == .observed ? .measured : .agePredicted).value else { return [] }
        let sleep = current.sleep.mainSleep
        let now = dateProvider.now().timeIntervalSince1970
        let samples = try HeartDayTimelineReader.samples(history, from: Int64(window.start.timeIntervalSince1970),
            to: Int64(window.end.timeIntervalSince1970), includingBeats: false).filter { sample in
                guard (25...230).contains(sample.bpm), sample.time <= now else { return false }
                // Keep the derivation's waking-day policy, including the half-open sleep window.
                return sleep.map { sample.time < $0.start.timeIntervalSince1970 || sample.time >= $0.end.timeIntervalSince1970 } ?? true
            }.map { ActivityHeartRateSample(timestamp: $0.time, bpm: $0.bpm) }
        return Self.zoneMinutes(ActivityAnalytics.timeInZone(samples, zoneSet: zones).value)
    }

    /// The day's time in heart-rate zones, in minutes, for the Body screen.
    ///
    /// The derivation has produced this on every day since zones existed and
    /// nothing read it. Below zone 1 is left out: it is mostly sleep and
    /// sitting, and it would flatten every other bar.
    nonisolated static func zoneMinutes(_ zones: TimeInHeartRateZones?) -> [BodyZoneMinutes] {
        guard let zones else { return [] }
        let names = ["Recovery", "Aerobic", "Tempo", "Threshold", "Peak"]
        let values = zones.seconds.enumerated().map { index, seconds in
            BodyZoneMinutes(id: index + 1,
                name: index < names.count ? names[index] : "Zone \(index + 1)",
                minutes: (seconds / 60).rounded())
        }
        // A day with no beats above zone 1 has nothing worth charting.
        return values.contains { $0.minutes > 0 } ? values : []
    }

    /// Folds the trailing days into the day's heart snapshot as trend points.
    ///
    /// It reads only generations the caller already walked, so the Heart trends
    /// screen costs nothing beyond the pass sleep and readiness already make.
    /// Resting heart rate and RMSSD are the two series the screen charts.
    nonisolated static func heartWithHistory(_ projection: CanonicalDailyProjection,
                                             priorDays prior: [CanonicalDailyProjection]) -> HeartDaySnapshot {
        let snapshot = projection.heart
        let charted: [HeartMetricID] = [.restingHeartRate, .rmssd]
        let trend: [HeartTrendPoint] = ([projection] + prior).flatMap { value -> [HeartTrendPoint] in
            let label = Self.dayLabel(value.heart.day)
            return charted.compactMap { id in
                guard let metric = value.heart.metric(id) else { return nil }
                return HeartTrendPoint(id: "\(label).\(id.rawValue)", metric: id, localDay: label,
                    value: metric.value, unit: metric.unit, state: metric.state,
                    source: value.heart.source, algorithmVersion: value.heart.algorithmVersion)
            }
        }.sorted { lhs, rhs in
            if lhs.localDay != rhs.localDay { return lhs.localDay < rhs.localDay }
            return lhs.id < rhs.id
        }
        return HeartDaySnapshot(day: snapshot.day, state: snapshot.state, metrics: snapshot.metrics,
            liveState: snapshot.liveState, source: snapshot.source,
            algorithmVersion: snapshot.algorithmVersion, trend: trend,
            vitals: heartVitalsWithHistory(projection, priorDays: prior))
    }

    /// Median recent sleep onset plus the sleep need, as a local clock label.
    /// Three nights is the same floor `sleepDebt` uses, so the alarm never
    /// appears before the need it is built on.
    nonisolated static func suggestedAlarm(need: Double?, prior: [CanonicalDailyProjection],
                                           calendar: Calendar, minimumNights: Int = 3) -> SleepSuggestedAlarm? {
        guard let need, need.isFinite, need > 0 else { return nil }
        // A bedtime before midnight is a large minute-of-day and one after
        // midnight is a small one, so a plain median of the two lands at noon.
        // Measure every onset from 18:00 instead and the run stays contiguous.
        let offsets = prior.compactMap { value -> Double? in
            guard let start = value.sleep.mainSleep?.start else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            guard let hour = parts.hour, let minute = parts.minute else { return nil }
            let minuteOfDay = Double(hour * 60 + minute)
            return minuteOfDay >= 1_080 ? minuteOfDay - 1_080 : minuteOfDay + 360
        }
        guard offsets.count >= minimumNights, let median = AnalyticsMath.median(offsets) else { return nil }
        let wakeMinute = Int((median + 1_080 + need * 60).rounded()) % 1_440
        let label = String(format: "%02d:%02d", wakeMinute / 60, wakeMinute % 60)
        return SleepSuggestedAlarm(localTime: label,
            reason: "Your usual bedtime plus the \(String(format: "%.1f", need)) hours you need",
            source: "Loopr · your recent nights", algorithmVersion: SleepAlgorithm.version)
    }

    private func todayWithConfidence(day: DayIdentity,
                                     current knownCurrent: CanonicalDailyProjection? = nil,
                                     priorDays known: [CanonicalDailyProjection]? = nil,
                                     hourlyStress knownHourlyStress: HourlyStressDay? = nil,
                                     reason: String = "today") async throws -> (TodaySummary, Double)? {
        let resolved: CanonicalDailyProjection?
        if let knownCurrent { resolved = knownCurrent }
        else { resolved = try await baseProjection(day: day, reason: reason) }
        guard let current = resolved else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        let prior: [CanonicalDailyProjection]
        if let known { prior = known } else { prior = try await priorDays(before: day, calendar: calendar, reason: reason) }
        guard !stopped else { return nil }
        // RMSSD is log-normal, so a raw mean and MAD read a good night as an
        // outlier. Compare ln(RMSSD) against a ln(RMSSD) baseline, as the
        // pinned composite does, and let respiration carry its own weight.
        func naturalLog(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return log(value)
        }
        // Without a recorded main sleep the heart values on the day are quiet
        // daytime stretches, display only. Scoring them against nightly
        // baselines reads a morning walk as a bad night, so with no night
        // there is nothing to score and the baselines stay untouched.
        let hasNight = current.sleep.mainSleep?.isPartial == false
        func nightly(_ value: Double?) -> Double? { hasNight ? value : nil }
        let readiness = WellnessAnalytics.readinessComposite([
            .hrv(nightly(naturalLog(current.heart.metric(.rmssd)?.numericValue)),
                 baseline: prior.compactMap { naturalLog($0.heart.metric(.rmssd)?.numericValue) }),
            .restingHeartRate(nightly(current.heart.metric(.restingHeartRate)?.numericValue),
                              baseline: prior.compactMap { $0.heart.metric(.restingHeartRate)?.numericValue }),
            .respiration(nightly(current.heart.metric(.respiration)?.numericValue),
                         baseline: prior.compactMap { $0.heart.metric(.respiration)?.numericValue })
        ])
        // Past the cap the logistic has railed and the number means nothing.
        let score = WellnessAnalytics.headlineReadinessScore(readiness)
        let remaining = baselineNightsRemaining(readiness.note)
        let building: String
        if !hasNight {
            building = "Wear your strap overnight to start this"
        } else if readiness.value != nil {
            building = "This night is too far from your recent readings to score reliably"
        } else {
            building = switch remaining {
            case .some(let nights) where nights > 0:
                LooprLearningText.progress(have: max(1, 4 - nights), need: 4) + ". "
                    + LooprLearningText.remaining(have: max(1, 4 - nights), need: 4) + " before recovery can start"
            default: "Recovery needs at least two usable overnight heart readings"
            }
        }
        let recovery = TodayMetricValue(id: .recovery, title: "Recovery", value: score.map { String(format: "%.0f", $0) }, unit: "%",
            confidence: score == nil ? building : {
                let counts = ["HRV": prior.compactMap { naturalLog($0.heart.metric(.rmssd)?.numericValue) }.count,
                              "RHR": prior.compactMap { $0.heart.metric(.restingHeartRate)?.numericValue }.count,
                              "RR": prior.compactMap { $0.heart.metric(.respiration)?.numericValue }.count]
                let nights = readiness.inputsUsed.compactMap { counts[$0] }.min().map { $0 + 1 } ?? 0
                return nights < 14 ? "Early estimate · " + LooprLearningText.progress(have: nights, need: 14) : "Based on your recent nights"
            }(),
            state: score == nil ? .settling : .partial, source: "Loopr · nightly heart trends",
            algorithmVersion: WellnessAlgorithm.readinessVersion, numericValue: score, numericUnit: .scorePoints)
        let age = current.latestRecord.map { max(0, Int(dateProvider.now().timeIntervalSince($0) / 60)) }
        let nowParts = calendar.dateComponents([.era, .year, .month, .day], from: dateProvider.now())
        let isToday = day == DayIdentity(era: nowParts.era ?? 1, year: nowParts.year!, month: nowParts.month!, day: nowParts.day!)
        let freshness: MetricState = isToday && (age ?? .max) > 30 ? .stale : .partial
        let summary = TodaySummary(day: day, overallState: current.today.overallState,
            freshness: TodayFreshness(state: freshness, updatedAt: current.latestRecord, ageMinutes: age, detail: "From saved strap records"),
            device: current.today.device, metrics: [recovery] + current.today.metrics,
            goals: current.today.goals, coachPlan: current.today.coachPlan,
            notableChanges: Self.notableChanges(current: current, prior: prior) +
                (isToday && (knownHourlyStress ?? HourlyStress.resolve(current.stressHours ?? [], baseline: prior.flatMap { $0.stressHours ?? [] }, calendar: calendar)).hasSustainedHigh
                    ? [TodayDayInsight.sustainedStressHint] : []), sleepNeedMinutes: current.sleep.needHours.map { $0 * 60 })
        // Reuse Today's sentence rules with the same trailing nights. No extra
        // database walk and no second recovery formula for external readers.
        let dayStart = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        var history: [TodayTrackedMetric: [LooprChartPoint]] = [:]
        for value in ([current] + prior).reversed() {
            let date = calendar.date(from: DateComponents(year: value.today.day.year, month: value.today.day.month, day: value.today.day.day))!
            for (tracked, heartID) in [(TodayTrackedMetric.hrv, HeartMetricID.rmssd), (.restingHeartRate, .restingHeartRate), (.respiratoryRate, .respiration)] {
                if let number = value.heart.metric(heartID)?.numericValue {
                    history[tracked, default: []].append(LooprChartPoint(date: date, value: number))
                }
            }
            if let number = value.today.metric(.sleep)?.numericValue {
                history[.sleep, default: []].append(LooprChartPoint(date: date, value: number))
            }
        }
        let context = TodayDayContext(day: day, dayStart: dayStart, history: history,
            recovery: LooprTodayContextSource.recoveryBreakdown(summary: summary, history: history, dayStart: dayStart, calendar: calendar))
        let hero = TodayDashboard(summary: summary, context: context, pinned: [], isToday: isToday, calendar: calendar).hero
        return (summary.withHeadline(hero.reading?.driver), readiness.confidence)
    }

    /// What moved today against the trailing days the same pass already read.
    ///
    /// Nothing ever filled this, so the "Notable changes" card on Today could
    /// not appear. A line is only produced when the day sits outside the
    /// trailing spread, so an ordinary day says nothing at all.
    nonisolated static func notableChanges(current: CanonicalDailyProjection,
                                           prior: [CanonicalDailyProjection],
                                           minimumDays: Int = 7) -> [String] {
        func line(_ label: String, _ today: Double?, _ baseline: [Double]) -> String? {
            guard let today, today.isFinite, baseline.count >= minimumDays,
                  let mean = AnalyticsMath.mean(baseline) else { return nil }
            let deviation = AnalyticsMath.standardDeviation(baseline)
            guard let deviation, deviation > 0 else { return nil }
            let z = (today - mean) / deviation
            guard abs(z) >= 1.5 else { return nil }
            let direction = z > 0 ? "above" : "below"
            let percent = abs(mean) > 0 ? abs(today - mean) / abs(mean) * 100 : 0
            return "\(label) is \(String(format: "%.0f", percent))% \(direction) your recent days."
        }
        var lines: [String] = []
        if let value = line("HRV", current.heart.metric(.rmssd)?.numericValue,
                            prior.compactMap { $0.heart.metric(.rmssd)?.numericValue }) {
            lines.append(value)
        }
        if let value = line("Resting heart rate", current.heart.metric(.restingHeartRate)?.numericValue,
                            prior.compactMap { $0.heart.metric(.restingHeartRate)?.numericValue }) {
            lines.append(value)
        }
        if let value = line("Sleep", current.sleep.mainSleep.map { Double($0.durationMinutes) },
                            prior.compactMap { $0.sleep.mainSleep.map { night in Double(night.durationMinutes) } }) {
            lines.append(value)
        }
        return lines
    }

    private static func derive(day: DayIdentity, raw: HistoricalAnalyticsSnapshot, profile: Profile?, timeZone: TimeZone,
                               dayStart: Double, dayEnd: Double, now: Date, movementBaseline: MovementBaseline, baselineRevision: Int64,
                               zoneVersion: String, recordedWorkouts: [DateInterval] = []) async throws -> CanonicalDailyProjection {
        let records = raw.records.filter { Double($0.absoluteTimestamp) <= now.timeIntervalSince1970 }
        let dayRecords = records.filter { Double($0.absoluteTimestamp) >= dayStart && Double($0.absoluteTimestamp) < dayEnd }
        let night = records
        func hr(_ record: StoredHistoricalRecord) -> Double? {
            guard let value = record.heartRate, (25...230).contains(Int(value)) else { return nil }
            return Double(value)
        }
        let nightHR = night.compactMap { record in hr(record).map { SleepHeartRateSample(timestamp: Double(record.absoluteTimestamp), bpm: $0) } }
        let nightMotion = night.compactMap { record -> SleepAccelerationSample? in
            guard let x = record.gravityX, let y = record.gravityY, let z = record.gravityZ,
                  x.isFinite, y.isFinite, z.isFinite else { return nil }
            return SleepAccelerationSample(timestamp: Double(record.absoluteTimestamp), x: x, y: y, z: z)
        }
        // Several beats share one packet timestamp, so a timestamp-only sort
        // leaves their order up to the sort's tie handling and the night's HRV
        // stops being reproducible. Break ties on arrival order.
        let rr = night.enumerated().flatMap { recordIndex, record in
            record.rrBeats.enumerated().compactMap { beatIndex, beat -> (Int, Int, SleepRRInterval)? in
                guard let timestamp = beat.timestampMilliseconds else { return nil }
                return (recordIndex, beatIndex, SleepRRInterval(timestamp: Double(timestamp) / 1_000, milliseconds: Double(beat.intervalMilliseconds)))
            }
        }.sorted { left, right in
            if left.2.timestamp != right.2.timestamp { return left.2.timestamp < right.2.timestamp }
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1 < right.1
        }.map(\.2)
        // The heart-rate baseline the sleep detector compares the night
        // against must come from waking hours outside that night. The evening
        // before the night is the last waking stretch available here.
        let preNightHR = records.filter { Double($0.absoluteTimestamp) < dayStart }.compactMap(hr)
        let sleep = try await SleepAnalytics.derive(SleepInputSnapshot(acceleration: nightMotion, heartRate: nightHR,
            rr: rr, daytimeHeartRate: preNightHR, timeZoneIdentifier: timeZone.identifier, mainSleepWakeDay: day))
        let segmentation = sleep.segmentation
        // Assign the overnight session to its wake day, never repeat the
        // preceding day's daytime nap as this day's main sleep.
        let window = segmentation.window.flatMap { $0.offset >= dayStart ? $0 : nil }
        // Strain, steps and energy describe the waking day. Leaving the night
        // in makes every day look like eight hours of very light activity.
        let daytime = dayRecords.filter { record in
            guard let window else { return true }
            let timestamp = Double(record.absoluteTimestamp)
            return timestamp < window.onset || timestamp >= window.offset
        }
        let sleepRR = rr.filter { beat in window.map { beat.timestamp >= $0.onset && beat.timestamp < $0.offset } ?? false }
        // Before the first night there are still real beats from the day. HRV
        // and stress come from those rather than from an empty tile, capped to
        // low confidence and captioned so nobody reads a walk as a night. They
        // never reach a baseline: a prior day only becomes a readiness
        // reference once it carries a complete night.
        let daytimeRR = window == nil ? rr.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd } : []
        let analysedRR = window == nil ? daytimeRR : sleepRR
        let isDaytimeHeartAnalysis = window == nil && !daytimeRR.isEmpty
        let daytimeHeartCaption = isDaytimeHeartAnalysis ? "From your quiet stretches today, not from sleep" : nil
        let daytimeHeartCeiling = 0.4
        func capped(_ confidence: Double) -> Double {
            isDaytimeHeartAnalysis ? min(daytimeHeartCeiling, confidence) : confidence
        }
        let quality = RRQuality.gated(analysedRR.map(\.milliseconds), beatTimestampsMilliseconds: analysedRR.map { $0.timestamp * 1_000 })
        let hrv = quality.value.map { HRVTime.derive($0.normalIntervalsMilliseconds, beatTimesMilliseconds: $0.normalTimesMilliseconds) }
        let respiration = quality.value.map { cleaned in
            Respiration.rsaRate(intervals: cleaned.normalIntervalsMilliseconds,
                beatTimesMilliseconds: cleaned.normalTimesMilliseconds,
                artifactFraction: 1 - cleaned.cleanFraction)
        }
        // The headline HRV is the median of clean five-minute windows inside
        // the sleep session. A whole-night RMSSD is the last resort, because a
        // single arousal moves it more than the night's autonomic tone does.
        let sessionRMSSD = window.map {
            HRVTime.sleepSessionWindowedRMSSD(rrMilliseconds: sleepRR.map(\.milliseconds),
                rrTimestampsMilliseconds: sleepRR.map { $0.timestamp * 1_000 },
                startSeconds: Int($0.onset), endSeconds: Int($0.offset))
        }
        let nocturnal = quality.value.map {
            HRVTime.nocturnalRMSSD($0.normalIntervalsMilliseconds, beatTimesMilliseconds: $0.normalTimesMilliseconds)
        }
        let rmssdMetric: (value: Double, confidence: Double)? = {
            if let session = sessionRMSSD?.value { return (session, sessionRMSSD!.confidence) }
            if let robust = nocturnal?.value { return (robust, capped(nocturnal!.confidence)) }
            if let whole = hrv?.value?.rmssdMilliseconds { return (whole, capped(hrv!.confidence)) }
            return nil
        }()
        let rmssd = rmssdMetric?.value
        var denseHR: [Double] = []
        if let window {
            denseHR = [Double](repeating: 0, count: max(0, Int(ceil(window.offset - window.onset))))
            for sample in nightHR {
                let index = Int(sample.timestamp - window.onset)
                if sample.timestamp >= window.onset, index >= 0, index < denseHR.count { denseHR[index] = sample.bpm }
            }
        }
        // The same main-sleep window as RHR. Compare with waking samples outside
        // the window, never with sleep samples or fabricated missing seconds.
        let sleepingHR = night.filter { record in
            guard let window, record.skinContact != 0 else { return false }
            let timestamp = Double(record.absoluteTimestamp)
            return timestamp >= window.onset && timestamp < window.offset
        }.compactMap(hr)
        let wakingHR = daytime.filter { record in
            let timestamp = Double(record.absoluteTimestamp)
            return record.skinContact != 0 && !segmentation.naps.contains { timestamp >= $0.onset && timestamp < $0.offset }
        }.compactMap(hr)
        let dip = NocturnalMetrics.heartRateDip(daySamples: wakingHR, nightSamples: sleepingHR)
        let sleepingMean = sleepingHR.count >= NocturnalMetrics.minimumDipSamples ? AnalyticsMath.mean(sleepingHR) : nil
        let observedMax = dayRecords.filter { $0.skinContact != 0 }.compactMap(hr).max()
        let rhr = NocturnalMetrics.restingHeartRate(denseHR)
        let nocturnalResting = rhr.value?.lowestThirtyMinuteMeanBPM
        // With no sleep window there is still a lowest quiet stretch in the
        // day worth showing. It is display only: baselines and the workout
        // gate keep using the sleep-gated value.
        let dayRestingMetric: AnalyticsMetric<NocturnalRHRValue>? = {
            guard nocturnalResting == nil, dayEnd > dayStart else { return nil }
            var series = [Double](repeating: 0, count: max(0, Int(dayEnd - dayStart)))
            for record in dayRecords {
                guard let bpm = hr(record) else { continue }
                let index = Int(Double(record.absoluteTimestamp) - dayStart)
                if index >= 0, index < series.count { series[index] = bpm }
            }
            return NocturnalMetrics.restingHeartRate(series)
        }()
        let resting = nocturnalResting ?? dayRestingMetric?.value?.lowestThirtyMinuteMeanBPM
        let restingConfidence = nocturnalResting != nil ? rhr.confidence : min(0.45, dayRestingMetric?.confidence ?? 0)
        let age = profile?.birthYear.flatMap { let age = day.year - $0; return (1...120).contains(age) ? Double(age) : nil }
        let sex: ActivitySex = profile?.biologicalSex == .male ? .male : profile?.biologicalSex == .female ? .female : .nonbinary
        // The personal movement floor is the median of the trailing daily p90
        // values. Pooling every minute of every day instead needs 2000 minutes
        // before it returns anything, which no new user ever reaches.
        let dynamicFloor = ActivityAnalytics.personalDynamicFloorFromDailySummaries(movementBaseline.dailyP90)
        let activityHeartRate = daytime.compactMap { record -> ActivityHeartRateSample? in
            guard let bpm = hr(record) else { return nil }
            let agreesWithBeats = record.rrBeats.contains { beat in
                let rr = Double(beat.intervalMilliseconds)
                return (300...2_000).contains(rr) && abs(60_000 / rr - bpm) <= max(5, bpm * 0.1)
            }
            return ActivityHeartRateSample(timestamp: Double(record.absoluteTimestamp), bpm: bpm,
                valid: record.skinContact != 0,
                goodSignal: agreesWithBeats && (record.skinContact == nil || record.skinContact != 0))
        }
        let currentZoneSettings = await HeartZonePreferences.shared.load()
        let activity = try await ActivityAnalytics.derive(ActivityInputSnapshot(
            heartRate: activityHeartRate,
            acceleration: daytime.compactMap { record in
                guard let x = record.gravityX, let y = record.gravityY, let z = record.gravityZ,
                      x.isFinite, y.isFinite, z.isFinite else { return nil }
                return ActivityAccelerationSample(timestamp: Double(record.absoluteTimestamp), x: x, y: y, z: z)
            }, restingHR: resting,
            zoneSettings: currentZoneSettings, age: age,
            sex: sex,
            personalDynamicFloor: dynamicFloor, pooledMotionMinutes: movementBaseline.dailyP90.count,
            timeZoneIdentifier: timeZone.identifier,
            personalDynamicFloorRequirement: 5))
        let source = "WHOOP 4.0 · Loopr"
        func state(_ value: Double?, confidence: Double = 1) -> MetricState {
            guard value != nil else { return .absent }
            return confidence < 0.5 ? .lowConfidence : .partial
        }
        func display(_ value: Double?) -> String? { value.flatMap { $0.isFinite ? String(format: "%.0f", $0) : nil } }
        let sleepMinutes = window == nil ? nil : segmentation.totalSleepSeconds.map { Double($0) / 60 }
        let sleepState = state(sleepMinutes, confidence: segmentation.confidence)
        let duration = sleepMinutes.map { "\(Int($0) / 60):\(String(format: "%02d", Int($0) % 60))" }
        let efficiency = window == nil ? nil : segmentation.efficiencyPercent
        let stageMetrics: [SleepMetricValue] = [
            ("deep", "Deep sleep", segmentation.deepSeconds),
            ("light", "Light sleep", segmentation.lightSeconds),
            ("rem", "REM sleep", segmentation.remSeconds),
            ("awake", "Awake", segmentation.wakeSeconds)
        ].map { id, title, seconds in
            let minutes = window == nil ? nil : seconds.map { Double($0) / 60 }
            return SleepMetricValue(id: id, title: title, value: display(minutes), unit: "minutes", state: state(minutes, confidence: segmentation.confidence),
                source: source, algorithmVersion: SleepAlgorithm.version, numericValue: minutes, numericUnit: .minutes)
        }
        // The derivation already counts cycles, latency and disturbances. They
        // were computed and then dropped, so the Sleep screen could only ever
        // show duration, efficiency and the four stage totals.
        let cycleCount = window == nil ? nil : sleep.cycles.map { Double($0.cycles.count) }
        let latencyMinutes = window == nil ? nil : sleep.hypnogram.map { Double($0.sleepOnsetLatencySeconds) / 60 }
        let remLatencyMinutes = window == nil ? nil : sleep.hypnogram?.remLatencySeconds.map { $0 / 60 }
        let disturbances = window == nil ? nil : sleep.hypnogram.map { Double($0.disturbances) }
        let hypnogramMetrics: [SleepMetricValue] = [
            ("cycles", "Sleep cycles", cycleCount, "cycles", SleepMetricUnitID.unknown),
            ("latency", "Time to fall asleep", latencyMinutes, "minutes", .minutes),
            ("remLatency", "Time to first REM", remLatencyMinutes, "minutes", .minutes),
            ("disturbances", "Wake-ups", disturbances, "times", .unknown)
        ].map { id, title, value, unit, numericUnit in
            SleepMetricValue(id: id, title: title, value: display(value), unit: unit,
                state: state(value, confidence: segmentation.confidence), source: source,
                algorithmVersion: SleepAlgorithm.version, numericValue: value, numericUnit: numericUnit)
        }
        let napSummaries = segmentation.naps.map { nap in
            SleepSessionSummary(id: "nap-\(Int(nap.onset))", start: Date(timeIntervalSince1970: nap.onset),
                end: Date(timeIntervalSince1970: nap.offset), durationMinutes: max(0, nap.sptSeconds / 60),
                isMainSleep: false, isPartial: true, confidence: min(0.4, segmentation.confidence),
                state: .lowConfidence)
        }
        let sleepSnapshot = SleepDaySnapshot(day: day, state: sleepState,
            mainSleep: window.map { SleepSessionSummary(id: "\(Int($0.onset))", start: Date(timeIntervalSince1970: $0.onset),
                end: Date(timeIntervalSince1970: $0.offset), durationMinutes: Int(sleepMinutes ?? 0), isMainSleep: true,
                isPartial: segmentation.isPartial || $0.offset >= Double(records.last?.absoluteTimestamp ?? 0) - 120,
                confidence: segmentation.confidence, state: sleepState) },
            naps: napSummaries,
            metrics: [
                SleepMetricValue(id: "duration", title: "Duration", value: duration, unit: "hours", state: sleepState,
                    confidence: segmentation.isHeartRateLed ? "Your strap recorded little movement, so this night came from your heart rate" : nil,
                    source: source, algorithmVersion: SleepAlgorithm.version, numericValue: sleepMinutes, numericUnit: .minutes),
                SleepMetricValue(id: "efficiency", title: "Efficiency", value: display(efficiency), unit: "%", state: state(efficiency),
                    source: source, algorithmVersion: SleepAlgorithm.version, numericValue: efficiency, numericUnit: .percentagePoints)
            ] + stageMetrics + hypnogramMetrics, hypnogram: window == nil ? [] : hypnogram(segmentation.stages4), source: source, algorithmVersion: SleepAlgorithm.version)
        func heartMetric(_ id: HeartMetricID, _ value: Double?, _ unit: String, _ numericUnit: HeartMetricUnitID, _ confidence: Double, caption: String? = nil) -> HeartMetricValue {
            HeartMetricValue(id: id, title: id.title, value: display(value), unit: unit, state: state(value, confidence: confidence),
                confidence: value == nil ? nil : caption,
                source: source, algorithmVersion: [.restingHeartRate, .heartRateDip, .sleepingHeartRate, .maxHeartRate].contains(id) ? AnalyticsAlgorithmVersion.nocturnal : id == .respiration ? AnalyticsAlgorithmVersion.respiration : AnalyticsAlgorithmVersion.hrv,
                numericValue: value, numericUnit: numericUnit)
        }
        let restingCaption = nocturnalResting == nil && resting != nil ? "From your quietest stretch today, not from sleep" : nil
        let heartSnapshot = HeartDaySnapshot(day: day, state: state(resting ?? rmssd), metrics: [
            heartMetric(.restingHeartRate, resting, "bpm", .beatsPerMinute, restingConfidence, caption: restingCaption),
            heartMetric(.rmssd, rmssd, "ms", .milliseconds, rmssdMetric?.confidence ?? 0, caption: daytimeHeartCaption),
            heartMetric(.sdnn, hrv?.value?.sdnnMilliseconds, "ms", .milliseconds, capped(hrv?.confidence ?? 0), caption: daytimeHeartCaption),
            heartMetric(.pNN50, hrv?.value?.pNN50Percent, "%", .percentagePoints, capped(hrv?.confidence ?? 0), caption: daytimeHeartCaption),
            heartMetric(.respiration, respiration?.value?.breathsPerMinute, "br/min", .breathsPerMinute, capped(respiration?.confidence ?? 0), caption: daytimeHeartCaption),
            heartMetric(.heartRateDip, dip.value?.dipPercent, "%", .percentagePoints, dip.confidence,
                caption: "Sleep compared with your waking day"),
            heartMetric(.sleepingHeartRate, sleepingMean, "bpm", .beatsPerMinute, rhr.confidence,
                caption: "Average during your main sleep"),
            heartMetric(.maxHeartRate, observedMax, "bpm", .beatsPerMinute, 1,
                caption: "Highest recorded today, not your maximum capacity")
        ], source: source, algorithmVersion: AnalyticsAlgorithmVersion.hrv,
            vitals: overnightVitals(records: records, sleepWindow: window.map { VitalsWindow(start: $0.onset, end: $0.offset) },
                cleanSleepBeats: window == nil ? nil : quality.value))
        // Product goals and Coach use the canonical 0...21 strain scale.
        // The activity family also exposes a distinct 0...100 load score.
        // Activity already resolved the same maximum and boundaries Heart
        // shows, including a manual value when the profile has no birth year.
        // Strain and Stress describe the day, so they wait for an hour of
        // on-wrist data. A band put on at midday after days off would
        // otherwise score its first minutes as the whole day.
        let wornMinutes = WearTime.wornMinutes(dayRecords.map {
            WearSample(timestamp: Double($0.absoluteTimestamp), bpm: hr($0), skinContact: $0.skinContact != 0)
        })
        let hasEnoughWear = WearTime.hasEnoughWear(wornMinutes)
        let isLiveDay = now.timeIntervalSince1970 < dayEnd
        let wearCaption: String? = hasEnoughWear ? nil
            : isLiveDay ? Self.wearSettlingCaption(wornMinutes: wornMinutes)
            : "Worn under \(WearTime.minimumWearMinutesForDayMetrics) min"
        let wearState: MetricState? = hasEnoughWear ? nil : (isLiveDay ? .settling : .absent)
        let strain = hasEnoughWear ? activity.strain.value.map { ActivityAnalytics.strainScore($0.trimp) } : nil
        // Settings calls this field "Age", so the caption names the field the
        // person will actually look for.
        let strainCaption = wearCaption ?? (strain == nil && currentZoneSettings.resolved(age: age.map(Int.init)) == nil
            ? "Add your age or set a maximum heart rate to see strain" : nil)
        let steps = activity.steps.value.map { Double($0.stepsMidpoint) }
        // Steps are always an estimate from wrist motion, never a count. The
        // honest label is "estimated", not "low confidence": the estimate is
        // usable, it just is not a pedometer.
        let stepState: MetricState = steps == nil ? .absent : .partial
        // An empty tile with no line of text reads as a bug. Steps wait on a
        // personal movement floor, which needs a few days of wear, so say that
        // instead of leaving the space blank.
        let stepCaption = activity.steps.value
            .map { $0.calibrated ? "Estimated from wrist motion and your walking pace" : "Estimated from wrist motion" }
            ?? "A few more days of wear and this is ready"

        // Energy. A relative index labelled "activity" told nobody anything
        // and could never be exported. Build the real profile and report
        // active kilocalories, or nothing at all.
        let workoutProfile: WorkoutProfile? = {
            guard let age, let weight = profile?.weightKilograms, weight.isFinite, weight > 0,
                  let height = profile?.heightCentimeters, height.isFinite, height > 0 else { return nil }
            return WorkoutProfile(weightKG: weight, heightCM: height, age: age, sex: sex)
        }()
        let configuredHRMax = currentZoneSettings.resolved(age: age.map(Int.init))?.maximum
        var hrByMinute: [Int: [Double]] = [:]
        for record in daytime {
            guard let bpm = hr(record) else { continue }
            hrByMinute[Int(Double(record.absoluteTimestamp) / 60), default: []].append(bpm)
        }
        let wakingHRPerMinute = hrByMinute.keys.sorted().compactMap { AnalyticsMath.mean(hrByMinute[$0] ?? []) }
        // Without a resting anchor the flex point is a flat half of the
        // configured maximum, and every minute a person spends sitting above
        // it is billed as exercise. Hand the estimator the same resting heart
        // rate the rest of the day uses.
        let energy = workoutProfile.map {
            WorkoutAnalytics.dailyEnergy(wakingHRPerMinute, profile: $0, hrMax: configuredHRMax, restingHR: resting,
                dayMinutes: max(0, Int((dayEnd - dayStart) / 60)))
        }
        let activeKcal = energy?.value?.activeKcal
        let usedDefaultAnchors = energy?.value?.usedDefaultHRmax ?? true
        let energyCaption: String? = {
            guard workoutProfile != nil else { return "Add your age, height and weight to your profile to see this" }
            return usedDefaultAnchors ? "Estimated with a default maximum heart rate" : "Estimated from your heart rate"
        }()
        let energyState: MetricState = activeKcal == nil ? .absent : (usedDefaultAnchors ? .lowConfidence : .partial)

        // Workout detection. The pinned pipeline only runs this with a real
        // nocturnal resting heart rate, because every zone in it is measured
        // from that anchor.
        // The raw snapshot reaches back into yesterday. Reuse a bounded part
        // of it so a bout crossing midnight has one continuous HR/motion span.
        let carryover = records.filter {
            let timestamp = Double($0.absoluteTimestamp)
            return timestamp >= dayStart - 2 * 3_600 && timestamp < dayStart
        }
        let carryoverAcceleration = carryover.compactMap { record -> ActivityAccelerationSample? in
            guard let x = record.gravityX, let y = record.gravityY, let z = record.gravityZ,
                  x.isFinite, y.isFinite, z.isFinite else { return nil }
            return ActivityAccelerationSample(timestamp: Double(record.absoluteTimestamp), x: x, y: y, z: z)
        }
        let carryoverMotion = ActivityAnalytics.enmoSeries(carryoverAcceleration).value?.minutes ?? []
        let workoutMotion = (carryoverMotion + (activity.motion.value?.minutes ?? [])).map {
            WorkoutMotionPoint(timestamp: $0.start, intensity: $0.dynamicAmplitude)
        }
        let workoutHR = (carryover + daytime).compactMap { record in
            hr(record).map { WorkoutHRPoint(timestamp: Double(record.absoluteTimestamp), bpm: $0) }
        }
        let detectedWorkouts: [ExerciseSession] = nocturnalResting.map { anchor in
            WorkoutAnalytics.detect(workoutHR, motion: workoutMotion, restingHR: anchor, maxHR: configuredHRMax,
                age: age, profile: workoutProfile, includeSustainedModerate: true).value?.filter {
                    $0.end >= dayStart - 300 && $0.end < dayEnd - 300
                } ?? []
        } ?? []
        // A peak can raise the automatic maximum only inside a workout that
        // passed the HR and motion detector, with agreeing RR and heart rate.
        let workoutPeakSamples = activityHeartRate.compactMap { sample -> ReliableHeartRateSample? in
            guard detectedWorkouts.contains(where: { sample.timestamp >= $0.start && sample.timestamp <= $0.end }) else { return nil }
            return ReliableHeartRateSample(time: sample.timestamp, bpm: sample.bpm, goodSignal: sample.goodSignal)
        }
        await HeartZonePreferences.shared.recordReliablePeak(workoutPeakSamples, age: age.map(Int.init))

        // Resting autonomic tension from the night's clean beats, or from the
        // day's own beats before the first night, at reduced confidence.
        let stress: CanonicalStressReading? = {
            guard hasEnoughWear, let gated = quality.value else { return nil }
            let index = WellnessAnalytics.baevskyStressIndex(gated.normalIntervalsMilliseconds)
            guard let value = index.value, let score = WellnessAnalytics.stressScore(stressIndex: value.si) else { return nil }
            return CanonicalStressReading(score: score, stressIndex: value.si, level: value.level,
                coverage: gated.cleanFraction, confidence: capped(index.confidence), algorithmVersion: WellnessAlgorithm.version)
        }()

        let stressHours = HourlyStress.features(samples: dayRecords.map { record in
            HourlyStressSample(time: Date(timeIntervalSince1970: Double(record.absoluteTimestamp)), heartRate: hr(record),
                rrMilliseconds: record.rrBeats.map { Double($0.intervalMilliseconds) })
        }, dayStart: Date(timeIntervalSince1970: dayStart), calendar: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; return calendar
        }(), sleep: (window.map { [DateInterval(start: Date(timeIntervalSince1970: $0.onset), end: Date(timeIntervalSince1970: $0.offset))] } ?? [])
            + segmentation.naps.map { DateInterval(start: Date(timeIntervalSince1970: $0.onset), end: Date(timeIntervalSince1970: $0.offset)) },
            workouts: recordedWorkouts + detectedWorkouts.map { DateInterval(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end)) },
            motion: activity.motion.value?.minutes ?? [], restingHR: resting, maximumHR: configuredHRMax)

        let bodySnapshot = BodyDaySnapshot(day: day, state: daytime.isEmpty ? .absent : .partial, metrics: [
            BodyMetricValue(id: .strain, title: "Strain", value: strain.map { String(format: "%.1f", $0) }, unit: "/21", state: wearState ?? state(strain, confidence: activity.strain.confidence), confidence: strainCaption, source: source, algorithmVersion: ActivityAlgorithm.version),
            BodyMetricValue(id: .steps, title: "Estimated steps", value: display(steps), unit: "steps", state: stepState, confidence: stepCaption, source: source, algorithmVersion: ActivityAlgorithm.version),
            BodyMetricValue(id: .energy, title: "Active energy", value: display(activeKcal), unit: "kcal", state: energyState, confidence: energyCaption, source: source, algorithmVersion: WorkoutAlgorithm.version)
        ], composition: BodyCompositionContext(weight: profile?.weightKilograms.map { String(format: "%.1f kg", $0) },
            height: profile?.heightCentimeters.map { String(format: "%.0f cm", $0) }, bodyFat: nil,
            state: profile == nil ? .absent : .partial, source: "Your profile"), cardioAge: nil, looprAge: nil, source: source, algorithmVersion: ActivityAlgorithm.version,
            zoneMinutes: Self.zoneMinutes(activity.zones.value))
        func todayMetric(_ id: TodayMetricID, _ title: String, _ value: Double?, _ unit: String, _ numericUnit: TodayMetricUnitID, _ version: String, confidence: Double = 1, formatted: String? = nil, caption: String? = nil, forcedState: MetricState? = nil) -> TodayMetricValue {
            TodayMetricValue(id: id, title: title, value: formatted ?? display(value), unit: unit, confidence: caption,
                state: forcedState ?? state(value, confidence: confidence), source: source,
                algorithmVersion: version, numericValue: value, numericUnit: numericUnit)
        }
        let latest = records.last.map { Date(timeIntervalSince1970: Double($0.absoluteTimestamp)) }
        let today = TodaySummary(day: day, overallState: .partial,
            freshness: TodayFreshness(state: .partial, updatedAt: latest, ageMinutes: latest.map { max(0, Int(now.timeIntervalSince($0) / 60)) }, detail: "From saved strap records"),
            // Stored history has no per-record model identity. The live
            // Bluetooth owner supplies the model shown in Today; a saved day
            // must not become "WHOOP 4.0" by default after an fd4b sync.
            device: TodayDeviceSnapshot(connection: .unknown, status: .partial),
            metrics: [
                todayMetric(.sleep, "Sleep", sleepMinutes, "hours", .minutes, SleepAlgorithm.version, confidence: segmentation.confidence, formatted: duration),
                todayMetric(.hrv, "HRV", rmssd, "ms", .milliseconds, AnalyticsAlgorithmVersion.hrv, confidence: rmssdMetric?.confidence ?? 0,
                    caption: rmssd == nil ? nil : daytimeHeartCaption),
                todayMetric(.restingHeartRate, "Resting heart rate", resting, "bpm", .beatsPerMinute, AnalyticsAlgorithmVersion.nocturnal, confidence: restingConfidence,
                    caption: restingCaption),
                todayMetric(.strain, "Strain", strain, "/21", .strainScore, ActivityAlgorithm.version, confidence: activity.strain.confidence, formatted: strain.map { String(format: "%.1f", $0) }, caption: strainCaption, forcedState: wearState),
                todayMetric(.steps, "Estimated steps", steps, "steps", .count, ActivityAlgorithm.version, confidence: activity.steps.confidence, caption: stepCaption, forcedState: stepState),
                // The same canonical stress reading the Stress screen shows.
                // Without this tile Today rendered a permanent dash next to a
                // number the derivation had already produced.
                todayMetric(.stress, "Stress", stress?.score, "/100", .scorePoints, WellnessAlgorithm.version,
                    confidence: stress?.confidence ?? 0,
                    formatted: stress.map { String(format: "%.0f", $0.score) },
                    caption: wearCaption ?? stress.map { $0.level } ?? "No clean heart data today",
                    forcedState: wearState)
            ])
        return CanonicalDailyProjection(revision: raw.revision, movementBaselineRevision: baselineRevision, profile: profile, timeZoneIdentifier: timeZone.identifier,
            algorithmVersion: zoneVersion, latestRecord: latest, today: today, sleep: sleepSnapshot, heart: heartSnapshot, body: bodySnapshot,
            strainConfidence: activity.strain.confidence, detectedWorkouts: detectedWorkouts, stress: stress, stressHours: stressHours)
    }

    /// "23 of 60 min worn", the caption under a Strain or Stress ring
    /// that is still waiting for an hour of wear.
    static func wearSettlingCaption(wornMinutes: Int) -> String {
        let minimum = WearTime.minimumWearMinutesForDayMetrics
        return "\(min(max(0, wornMinutes), minimum)) of \(minimum) min worn"
    }

    private static func hypnogram(_ stages: [AnalyticsKit.SleepStage]) -> [DesignSystem.SleepSegment] {
        // Quantize once into complete minutes, then group. Rounding every
        // short stage run independently would inflate the displayed night.
        var groups: [(DesignSystem.SleepStage, Int)] = []
        for start in stride(from: 0, to: stages.count - (stages.count % 60), by: 60) {
            var counts: [AnalyticsKit.SleepStage: Int] = [:]
            for stage in stages[start..<(start + 60)] { counts[stage, default: 0] += 1 }
            let chosen = AnalyticsKit.SleepStage.allCases.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .wake
            let stage: DesignSystem.SleepStage = switch chosen {
            case .wake: .awake
            case .rem: .rem
            case .deep: .deep
            case .light, .nrem: .light
            }
            if groups.last?.0 == stage { groups[groups.count - 1].1 += 1 }
            else { groups.append((stage, 1)) }
        }
        return groups.enumerated().map { DesignSystem.SleepSegment(id: $0.offset, stage: $0.element.0, durationMinutes: $0.element.1) }
    }
}

// MARK: Day selection

/// The reads behind the shared day selection (`DaySelection/`). They sit in
/// this file only because they need the engine's private history handle,
/// document store and day window; the policy lives in `LooprDayResolution`.
extension CanonicalDailyAnalytics {
    /// The longest history the day index walks. Older days stay reachable;
    /// their status is simply left unknown.
    static let dayIndexLimitDays = 800

    /// Which days hold data, from indexes only: the band rows in
    /// `metric_series` and one indexed existence check per civil day whose
    /// UTC bucket saw any second. Nothing is derived.
    func dayKnowledge(today: DayIdentity) throws -> LooprDayKnowledge {
        var knowledge = LooprDayKnowledge()
        guard !stopped else { return knowledge }
        let calendar = LooprDays.calendar(timeZoneProvider.timeZone)
        let bounds = try history.read { db -> (Int64?, Int64?) in
            (try Int64.fetchOne(db, sql: "SELECT MIN(absolute_timestamp) FROM decoded_second"),
             try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second"))
        }
        let limit = LooprDays.adding(-Self.dayIndexLimitDays, to: today, calendar: calendar) ?? today
        knowledge.coveredFrom = limit
        if let lower = bounds.0, let upper = bounds.1 {
            knowledge.lastRecordAt = Date(timeIntervalSince1970: TimeInterval(upper))
            let first = LooprDays.day(containing: Date(timeIntervalSince1970: TimeInterval(lower)), calendar: calendar)
            knowledge.earliestRecorded = first
            let last = LooprDays.day(containing: Date(timeIntervalSince1970: TimeInterval(upper)), calendar: calendar)
            var cursor = LooprDays.isEarlier(first, limit) ? limit : first
            let end = LooprDays.isEarlier(today, last) ? today : last
            if let span = LooprDays.bounds(of: cursor, calendar: calendar),
               let endSpan = LooprDays.bounds(of: end, calendar: calendar) {
                let lowBucket = Int64(span.start.timeIntervalSince1970) / 86_400
                let highBucket = (Int64(endSpan.end.timeIntervalSince1970) - 1) / 86_400
                let buckets = Set(try history.read { db in
                    try Int64.fetchAll(db, sql: "SELECT utc_day FROM analytics_range_revision WHERE utc_day >= ? AND utc_day <= ?",
                                       arguments: [lowBucket, highBucket])
                })
                while !LooprDays.isEarlier(end, cursor) {
                    guard let window = LooprDays.bounds(of: cursor, calendar: calendar) else { break }
                    let start = Int64(window.start.timeIntervalSince1970), stop = Int64(window.end.timeIntervalSince1970)
                    if buckets.contains(start / 86_400) || buckets.contains((stop - 1) / 86_400) {
                        let found = try history.read { db in
                            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decoded_second WHERE absolute_timestamp >= ? AND absolute_timestamp < ?)",
                                              arguments: [start, stop]) ?? false
                        }
                        if found { knowledge.recorded.insert(cursor) }
                    }
                    guard let next = LooprDays.adding(1, to: cursor, calendar: calendar) else { break }
                    cursor = next
                }
            }
        }
        // A recorded peak can come from a single second. Keep it on its
        // metric page, but apply the same rule as LooprDayDataPolicy to the
        // saved index so a peak alone never selects an otherwise empty day.
        let labels = try history.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT local_day FROM metric_series
                WHERE source = ? AND local_day >= ? AND local_day <= ?
                AND value IS NOT NULL AND metric_key != ?
                """, arguments: [StoredMetricSeriesSource.band.rawValue, LooprDays.label(limit),
                                   LooprDays.label(today), MetricKey.maxHeartRate.rawValue]))
        }
        let imported = try history.metricSeriesDays(source: .whoopExport, from: "0001-01-01", through: LooprDays.label(today))
        knowledge.withData = Set(labels.union(imported).compactMap(LooprDays.identity(label:)))
        return knowledge
    }

    /// Whether `day` has data, reading its display generation the way a
    /// screen would: a saved one comes straight back, a missing one is
    /// derived once through the shared budget.
    func dayHasData(day: DayIdentity) async throws -> Bool {
        guard let display = try await readDisplay(day: day, reason: "day-selection") else { return false }
        return LooprDayDataPolicy.hasData(display)
    }

    /// Whether a finished display generation for `day` exists, in memory or
    /// saved. Reads the stored bytes without decoding them.
    func hasSavedDisplay(day: DayIdentity) -> Bool {
        guard !stopped else { return false }
        if displayMemo[day] != nil { return true }
        if (try? accountImport.day(WHOOPImportStore.label(day))) != nil { return true }
        return ((try? projections.readData(key: Self.displayKey(day))) ?? nil) != nil
    }
}

// MARK: Overnight heart rate

/// The Sleep tab's overnight heart-rate line. It sits in this file only
/// because it needs the engine's private history handle; the folding lives in
/// `SleepHeartRateReading` (`SleepNightDetails.swift`).
extension CanonicalDailyAnalytics {
    /// Per-minute heart rate between `start` and `end`, from the per-second
    /// rows. Nothing is derived.
    func overnightHeartRate(from start: Date, to end: Date) throws -> [SleepHeartRateMinute] {
        guard !stopped, end > start, end.timeIntervalSince(start) <= SleepHeartRateReading.maximumSpan else { return [] }
        let lower = Int64(start.timeIntervalSince1970.rounded(.down))
        let upper = Int64(end.timeIntervalSince1970.rounded(.up))
        let rows = try history.read { db -> [(timestamp: Int64, bpm: Double)] in
            var result: [(timestamp: Int64, bpm: Double)] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT absolute_timestamp, heart_rate FROM decoded_second
                WHERE absolute_timestamp >= ? AND absolute_timestamp < ? AND heart_rate > 0
                ORDER BY absolute_timestamp
                """, arguments: [lower, upper])
            while let row = try cursor.next() {
                let rate: Int64 = row["heart_rate"]
                result.append((timestamp: row["absolute_timestamp"], bpm: Double(rate)))
            }
            return result
        }
        return SleepHeartRateReading.minutes(rows)
    }
}
