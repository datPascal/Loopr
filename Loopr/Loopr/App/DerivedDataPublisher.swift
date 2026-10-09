import AnalyticsKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import Foundation
import HeartKit
import RecordsKit
import SettingsKit
import SharedSurfaceKit
import SleepKit
import TodayKit
import WidgetKit
import WorkoutKit

// MARK: - Seams

/// Where a finished snapshot goes. Production writes the App Group file,
/// reloads the widget timelines, and hands the same bytes to the Watch.
nonisolated protocol LooprSurfaceSnapshotSink: Sendable {
    func publish(_ snapshot: SurfaceSnapshot) async
}

/// Reads the four surface privacy switches from Settings. The widgets and the
/// Watch run in other processes and can only see what this writer puts in the
/// App Group file, so the switches have to be applied here, before the write.
nonisolated protocol LooprSurfacePrivacyReading: Sendable {
    func currentSurfacePrivacy() async -> SurfacePrivacySettings
}

struct LooprSettingsSurfacePrivacyReader: LooprSurfacePrivacyReading {
    let repository: any SettingsRepository

    func currentSurfacePrivacy() async -> SurfacePrivacySettings {
        await repository.snapshot().surfacePrivacy
    }
}

/// Used when no settings repository exists yet. Publishing nothing is the safe
/// default: a missing preference must not be read as permission.
struct LooprDeniedSurfacePrivacyReader: LooprSurfacePrivacyReading {
    func currentSurfacePrivacy() async -> SurfacePrivacySettings {
        SurfacePrivacySettings(todayWidget: false, batteryWidget: false, watchSnapshot: false, liveActivity: false)
    }
}

struct LooprSurfaceSnapshotWriter: LooprSurfaceSnapshotSink {
    let url: URL?
    let privacy: any LooprSurfacePrivacyReading

    init(
        url: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SurfaceConfiguration.appGroupIdentifier
        )?.appendingPathComponent("surface.json"),
        privacy: any LooprSurfacePrivacyReading = LooprDeniedSurfacePrivacyReader()
    ) {
        self.url = url
        self.privacy = privacy
    }

    func publish(_ snapshot: SurfaceSnapshot) async {
        let settings = await privacy.currentSurfacePrivacy()
        let published = Self.applying(settings, to: snapshot)
        if let url {
            try? await AtomicSurfaceSnapshotStore(url: url).write(published)
        }
        // Reload the iPhone widgets first. The Watch bridge waits on a WCSession
        // activation callback that may never arrive, and the widgets have no
        // reason to wait for it.
        if settings.todayWidget || settings.batteryWidget {
            WidgetCenter.shared.reloadAllTimelines()
        }
        guard settings.watchSnapshot else { return }
        Task.detached(priority: .utility) {
            await LooprWatchSnapshotBridge.shared.publish(snapshot)
        }
    }

    /// A switched-off surface reads an empty field rather than a stale number.
    /// The file keeps its identity and timestamps so a widget can still tell
    /// the difference between "turned off" and "never synced".
    nonisolated static func applying(
        _ settings: SurfacePrivacySettings,
        to snapshot: SurfaceSnapshot
    ) -> SurfaceSnapshot {
        guard !settings.todayWidget || !settings.batteryWidget else { return snapshot }
        return SurfaceSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generation: snapshot.generation,
            createdAt: snapshot.createdAt,
            sourceDay: snapshot.sourceDay,
            syncDate: snapshot.syncDate,
            metrics: settings.todayWidget ? snapshot.metrics : SurfaceMetrics(),
            battery: settings.batteryWidget ? snapshot.battery : nil,
            activeWorkout: settings.todayWidget ? snapshot.activeWorkout : nil,
            staleReasons: snapshot.staleReasons,
            insight: settings.todayWidget ? snapshot.insight : nil
        )
    }
}

nonisolated protocol LooprDetectedWorkoutNotifying: Sendable {
    func detected(detectionID: String, at date: Date) async
}

struct LooprDetectedWorkoutNotifier: LooprDetectedWorkoutNotifying {
    func detected(detectionID: String, at date: Date) async {
        #if canImport(UserNotifications)
        await LooprNotificationRuntime.shared.detectedWorkout(detectionID: detectionID, at: date)
        #endif
    }
}

/// Detected bouts the person has already answered. A confirmed or dismissed
/// detection is removed from the store, so without this ledger the next
/// derivation would hand it straight back.
nonisolated protocol LooprDetectedWorkoutLedger: Sendable {
    func save(_ detection: WorkoutKit.DetectedWorkout) async throws
    func detection(id: String) async -> WorkoutKit.DetectedWorkout?
    func resolvedDetectionIDs() async -> Set<String>
    func markDetectionResolved(id: String) async
    func savedWorkouts() async -> [WorkoutRecord]
}

extension LooprDetectedWorkoutLedger {
    func savedWorkouts() async -> [WorkoutRecord] { [] }
}

// MARK: - Publisher

/// Runs everything that depends on a derived day but that analytics must not
/// do itself: saving detected workouts for review, writing the record rows the
/// Records, streaks, timeline and recap screens read, and publishing the
/// snapshot behind the widgets, the Watch app and the complications.
///
/// Calls are coalesced. A history commit, a battery change and a scene
/// activation arriving together produce one pass, not three.
actor LooprDerivedDataPublisher {
    /// Matches Edge's derive scheduler. Long enough that a burst of committed
    /// batches does not re-derive per batch, short enough that a person who
    /// opens Loopr after a sync sees the new day without waiting.
    static let debounceSeconds: TimeInterval = 8
    /// A bout that ended longer ago than this is saved for review but does not
    /// interrupt anyone. Backfilled history is almost entirely old bouts.
    static let notificationFreshnessSeconds: TimeInterval = 2 * 60 * 60
    /// Past this, the snapshot on a widget or watch face is not today's news.
    static let staleSyncSeconds: TimeInterval = 6 * 60 * 60

    private let analytics: CanonicalDailyAnalytics
    private let records: any RecordsStore
    private let workouts: any LooprDetectedWorkoutLedger
    private let device: (any DeviceCenterRepository)?
    private let sink: any LooprSurfaceSnapshotSink
    private let notifier: any LooprDetectedWorkoutNotifying
    private let dateProvider: any DateProviding
    private let timeZoneProvider: any TimeZoneProviding
    private let debounce: TimeInterval
    private let budget: LooprDerivationBudget
    private let corrections: (any SleepCorrectionRepository)?

    private var scheduled: Task<Void, Never>?
    private var lastRunAt: Date?
    private var stopped = false
    private let morningRecap: (any LooprMorningRecapNotifying)?
    /// The night length last published per day, so a re-derivation that
    /// changes it can be written to the sleep audit trail.
    private var publishedSleepMinutes: [DayIdentity: Int] = [:]

    init(
        analytics: CanonicalDailyAnalytics,
        records: any RecordsStore,
        workouts: any LooprDetectedWorkoutLedger,
        device: (any DeviceCenterRepository)?,
        sink: any LooprSurfaceSnapshotSink,
        notifier: any LooprDetectedWorkoutNotifying,
        dateProvider: any DateProviding,
        timeZoneProvider: any TimeZoneProviding,
        debounce: TimeInterval = LooprDerivedDataPublisher.debounceSeconds,
        budget: LooprDerivationBudget = .shared,
        corrections: (any SleepCorrectionRepository)? = nil,
        morningRecap: (any LooprMorningRecapNotifying)? = nil
    ) {
        self.analytics = analytics
        self.records = records
        self.workouts = workouts
        self.device = device
        self.sink = sink
        self.notifier = notifier
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
        self.debounce = debounce
        self.budget = budget
        self.corrections = corrections
        self.morningRecap = morningRecap
    }

    /// Coalescing entry point. Safe to call on every history commit, battery
    /// reading and scene activation.
    ///
    /// The pass is budgeted rather than merely debounced. Off screen it runs
    /// at most once per band top-up and no more often than every half hour,
    /// which is what stops a night of fifteen-minute syncs from adding up to a
    /// CPU kill.
    func request() {
        guard !stopped, scheduled == nil else { return }
        let now = dateProvider.now()
        let delay = lastRunAt.map { max(0, debounce - now.timeIntervalSince($0)) } ?? 0
        scheduled = Task(priority: .utility) { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduled()
        }
    }

    func stop() {
        stopped = true
        scheduled?.cancel()
        scheduled = nil
    }

    private func runScheduled() async {
        scheduled = nil
        guard await budget.claim(.surfaceSnapshot) != nil else { return }
        await publishNow()
    }

    /// One pass over the current local day. Exposed so tests do not wait on
    /// the debounce timer.
    func publishNow() async {
        guard !stopped else { return }
        lastRunAt = dateProvider.now()
        let today = currentDay()
        let projection = try? await analytics.read(day: today, reason: "surface")
        await saveRecords(projection, day: today)
        await recordSleepCorrection(projection, day: today)
        // The day was just derived, so its detected bouts are already in hand.
        // Asking analytics again re-derived the same day whenever a second had
        // landed in between, which off screen it always has.
        await saveDetectedWorkouts(projection?.detectedWorkouts ?? [])
        // A bout that ended before midnight belongs to yesterday. Without this
        // the first sync of the morning never offers last night's ride.
        // Yesterday is only consulted when there is headroom to look at it.
        if let yesterday = day(offsetByDays: -1), await budget.canDerive() {
            let sessions = (try? await analytics.readDetectedWorkouts(day: yesterday, reason: "surface")) ?? []
            await saveDetectedWorkouts(sessions)
        }
        // Publishing an empty snapshot over a good one, because the CPU
        // ceiling refused the derivation, would blank the widgets and the
        // watch face for no reason.
        if projection == nil, await budget.shouldHoldBackSnapshot() { return }
        await publishSurface(projection, day: today)
        if let morningRecap, let projection, let status = try? await device?.readStatus(),
           status.connection != .synchronizing {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZoneProvider.timeZone
            await morningRecap.morning(summary: projection.today, sleep: projection.sleep.mainSleep,
                syncedAt: status.completedSyncAt, now: dateProvider.now(), calendar: calendar)
        }
    }

    // MARK: Records

    private func saveRecords(_ projection: CanonicalDailyProjection?, day: DayIdentity) async {
        guard let projection else { return }
        let label = Self.dayLabel(day)
        let version = Self.recordAlgorithmVersion(projection.algorithmVersion)
        for row in Self.metricSnapshots(projection, day: label, algorithmVersion: version) {
            await records.save(row)
        }
        if let event = Self.timelineEvent(for: projection.sleep.mainSleep, day: label) {
            await records.save(event)
        }
    }

    /// Writes the sleep audit trail.
    ///
    /// A re-derivation that changes a night Loopr had already published is a
    /// correction, with a real before and after. Nothing wrote these entries
    /// before, so the Corrections row read "0 audit entries" on every phone.
    /// The first night seen after launch only records the value; it is not a
    /// change until Loopr has published it once.
    private func recordSleepCorrection(_ projection: CanonicalDailyProjection?, day: DayIdentity) async {
        guard let corrections, let projection,
              let minutes = projection.sleep.mainSleep?.durationMinutes else { return }
        // The `??` right-hand side is a non-async autoclosure, so the history
        // read cannot sit inside it. The fallback still only runs when this
        // process has not published the night yet.
        var previous = publishedSleepMinutes[day]
        if previous == nil {
            let history = try? await corrections.history(for: day)
            previous = Int(history?.last?.after ?? "")
        }
        publishedSleepMinutes[day] = minutes
        guard let correction = Self.sleepCorrection(
            previousMinutes: previous, minutes: minutes, day: day,
            algorithmVersion: projection.sleep.algorithmVersion, now: dateProvider.now()
        ) else { return }
        try? await corrections.append(correction)
    }

    /// The audit entry for a night whose length moved, or nil when there is
    /// nothing to correct. Kept apart from the storage so the rule is testable
    /// without a database behind it.
    nonisolated static func sleepCorrection(previousMinutes: Int?, minutes: Int, day: DayIdentity,
                                            algorithmVersion: String?, now: Date) -> SleepCorrection? {
        guard let previousMinutes, previousMinutes != minutes else { return nil }
        return SleepCorrection(
            day: day,
            target: "sleep.duration.minutes",
            before: String(previousMinutes),
            after: String(minutes),
            reason: "A later sync changed this night after Loopr had already saved it.",
            source: "derivation",
            algorithmVersion: algorithmVersion,
            createdAt: now
        )
    }

    /// One event per finished night. A night still in progress has no final
    /// duration, so the timeline waits rather than logging a number that will
    /// change. The identity is the day, so re-deriving corrects the row.
    nonisolated static func timelineEvent(for sleep: SleepSessionSummary?, day: String) -> TimelineEvent? {
        guard let sleep, !sleep.isPartial, sleep.durationMinutes > 0 else { return nil }
        return TimelineEvent(
            kind: .sleep,
            day: day,
            title: "Slept \(sleep.durationMinutes / 60)h \(sleep.durationMinutes % 60)m",
            sourceID: "sleep.\(day)"
        )
    }

    /// Saving replaces any row with the same day and metric, so re-deriving a
    /// day corrects its rows instead of adding duplicates.
    nonisolated static func metricSnapshots(
        _ projection: CanonicalDailyProjection,
        day: String,
        algorithmVersion: Int
    ) -> [MetricSnapshot] {
        var rows: [MetricSnapshot] = []
        func append(_ metric: String, _ value: Double?, _ state: MetricState?) {
            guard let value, value.isFinite, let state, state != .absent else { return }
            rows.append(MetricSnapshot(day: day, metric: metric, value: value, algorithmVersion: algorithmVersion))
        }
        func today(_ id: TodayMetricID) -> (Double?, MetricState?) {
            let metric = projection.today.metric(id)
            return (metric?.numericValue, metric?.state)
        }
        // Recovery leads: the Records screen picks the first saved metric for
        // its streak, and a readiness streak is the one people look for.
        let recovery = today(.recovery)
        append("recovery", recovery.0, recovery.1)
        let strain = today(.strain)
        append("strain", strain.0, strain.1)
        let steps = today(.steps)
        append("steps", steps.0, steps.1)
        if let sleep = projection.sleep.metrics.first(where: { $0.id == "duration" }) {
            append("sleep hours", sleep.numericValue.map { $0 / 60 }, sleep.state)
        }
        for (id, name) in [(HeartMetricID.rmssd, "hrv"), (.restingHeartRate, "resting heart rate")] {
            let metric = projection.heart.metric(id)
            append(name, metric?.numericValue, metric?.state)
        }
        return rows
    }

    /// The canonical version string ends in a generation number. Records needs
    /// an integer to flag an algorithm change inside a recap window.
    nonisolated static func recordAlgorithmVersion(_ value: String) -> Int {
        let digits = value.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 1
    }

    // MARK: Detected workouts

    private func saveDetectedWorkouts(_ sessions: [ExerciseSession]) async {
        guard !sessions.isEmpty else { return }
        let resolved = await workouts.resolvedDetectionIDs()
        let saved = await workouts.savedWorkouts()
        let now = dateProvider.now()
        for detection in Self.detectionsToSave(sessions, answered: resolved, saved: saved) {
            // The latest sample is not proof a bout has ended. Waiting also
            // lets the next day's pass extend a session across midnight.
            guard now.timeIntervalSince(detection.endedAt) >= 300 else { continue }
            if let existing = await workouts.detection(id: detection.detectionID) {
                if detection.endedAt > existing.endedAt { try? await workouts.save(detection) }
                continue
            }
            do { try await workouts.save(detection) } catch { continue }
            guard Self.deservesNotification(detection, now: now) else { continue }
            await notifier.detected(detectionID: detection.detectionID, at: detection.endedAt)
        }
    }

    /// Bouts worth offering for review. A bout the person already confirmed or
    /// dismissed never comes back, however often the day is re-derived.
    nonisolated static func detectionsToSave(
        _ sessions: [ExerciseSession],
        answered: Set<String>,
        saved: [WorkoutRecord] = []
    ) -> [WorkoutKit.DetectedWorkout] {
        sessions.map(detectedWorkout).filter {
            !WorkoutDetectionDeduplication.wasAnswered($0, answered: answered)
                && !WorkoutDetectionDeduplication.overlapsSavedWorkout($0, workouts: saved)
        }
    }

    /// Importing weeks of backfilled history would otherwise fire a
    /// notification for every old bout in it.
    nonisolated static func deservesNotification(_ detection: WorkoutKit.DetectedWorkout, now: Date) -> Bool {
        let age = now.timeIntervalSince(detection.endedAt)
        return age >= 0 && age <= notificationFreshnessSeconds
    }

    /// The identity is the bout's start second, so re-deriving the same day
    /// produces the same row rather than a second copy of the same workout.
    /// `DetectedWorkout` carries only the identity, the activity and the
    /// window; the heart-rate, zone, strain and energy detail stays in the
    /// derivation until the person confirms the bout and it becomes a record.
    nonisolated static func detectedWorkout(_ session: ExerciseSession) -> WorkoutKit.DetectedWorkout {
        WorkoutKit.DetectedWorkout(
            detectionID: "loopr.detected.\(Int(session.start.rounded()))",
            activity: activity(for: session.sport),
            startedAt: Date(timeIntervalSince1970: session.start),
            endedAt: Date(timeIntervalSince1970: max(session.start, session.end))
        )
    }

    /// The detector reports a generic bout, not a sport. Anything it cannot
    /// name stays "other" so the review screen asks rather than guesses.
    nonisolated static func activity(for sport: String) -> ActivityType {
        ActivityType(rawValue: sport.lowercased()) ?? .other
    }

    // MARK: Snapshot

    private func publishSurface(_ projection: CanonicalDailyProjection?, day: DayIdentity) async {
        let now = dateProvider.now()
        let status = try? await device?.readStatus()
        let snapshot = Self.snapshot(
            projection,
            day: day,
            status: status,
            now: now
        )
        await sink.publish(snapshot)
    }

    nonisolated static func snapshot(
        _ projection: CanonicalDailyProjection?,
        day: DayIdentity,
        status: DeviceStatusSnapshot?,
        now: Date
    ) -> SurfaceSnapshot {
        func today(_ id: TodayMetricID) -> Double? {
            let metric = projection?.today.metric(id)
            return metric?.state == .absent ? nil : metric?.numericValue
        }
        let summary = projection?.today
        let sleep = summary?.metric(.sleep)
        let hero = summary.map { TodayDashboard(summary: $0, context: nil, pinned: [], isToday: true).hero }
        var have: Int?
        var need: Int?
        if case .learning(let recorded, let required, _) = hero { have = recorded; need = required }
        let metrics = SurfaceMetrics(
            recovery: today(.recovery),
            sleep: nil,
            strain: today(.strain),
            heartRate: today(.restingHeartRate),
            hrv: today(.hrv),
            steps: today(.steps),
            sleepMinutes: sleep?.state == .absent ? nil : sleep?.numericValue
        )
        let battery: SurfaceBatteryObservation? = {
            guard let status, case .measured(let percent) = status.batteryPercent else { return nil }
            return SurfaceBatteryObservation(
                level: Double(percent) / 100,
                observedAt: status.historyCommitAt ?? status.storedAt ?? now,
                charging: status.charging
            )
        }()
        var stale: Set<SurfaceStaleReason> = []
        let latest = projection?.latestRecord
        if latest == nil || now.timeIntervalSince(latest!) > staleSyncSeconds {
            stale.insert(.noRecentSync)
        }
        if let status, status.connection != .connected, status.connection != .synchronizing {
            stale.insert(.disconnected)
        }
        return SurfaceSnapshot(
            generation: UInt64(max(0, now.timeIntervalSince1970 * 1_000)),
            createdAt: now,
            sourceDay: dayLabel(day),
            syncDate: latest,
            metrics: metrics,
            battery: battery,
            activeWorkout: nil,
            staleReasons: stale,
            insight: projection.map { _ in SurfaceDayInsight(
                headline: summary?.headline,
                recoveryStyle: recoveryStyle(score: today(.recovery)),
                recoveryUnavailableReason: summary?.metric(.recovery)?.confidence,
                nightsRecorded: have, nightsNeeded: need,
                sleepNeedMinutes: projection?.sleep.needHours.map { $0 * 60 },
                sleepUnavailableReason: today(.sleep) == nil ? "Wear your band overnight, then sync." : nil,
                strainUnavailableReason: today(.strain) == nil ? summary?.metric(.strain)?.confidence : nil
            ) }
        )
    }

    nonisolated static func recoveryStyle(score: Double?) -> SurfaceRecoveryStyle? {
        guard let band = LooprRecoveryBand(score: score) else { return nil }
        let palette = band.token.rgbPalette
        return SurfaceRecoveryStyle(verdict: band.verdict, lightRGB: palette.light, darkRGB: palette.dark,
            highContrastLightRGB: palette.highLight, highContrastDarkRGB: palette.highDark)
    }

    // MARK: Days

    private func currentDay() -> DayIdentity {
        day(offsetByDays: 0) ?? DayIdentity(year: 1970, month: 1, day: 1)
    }

    private func day(offsetByDays offset: Int) -> DayIdentity? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        guard let date = calendar.date(byAdding: .day, value: offset, to: dateProvider.now()) else { return nil }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        return DayIdentity(era: parts.era ?? 1, year: year, month: month, day: dayOfMonth)
    }

    nonisolated static func dayLabel(_ day: DayIdentity) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
}
