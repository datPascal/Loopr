import Foundation
import AnalyticsKit
import NotificationKit
import StorageKit
import HeartKit
import SleepKit
import DomainKit
import ProfileKit

/// Reads the per-second rows the heart rate alert detector needs straight from
/// the history database. Only heart rate, gravity and RR: the full
/// `historicalAnalyticsSnapshot` read also pulls optical and ADC columns the
/// detector never looks at.
nonisolated enum HeartAlertHistoryReader {
    static func latestTimestamp(_ database: StorageDatabase) throws -> Int64? {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second")
        }
    }

    /// Half-open absolute range.
    static func seconds(_ database: StorageDatabase, from start: Int64, to end: Int64) throws -> [HeartRateMonitorSecond] {
        try database.read { db in
            var beats: [Int64: [Int]] = [:]
            let rr = try Row.fetchCursor(db, sql: """
                SELECT r.decoded_second_id, r.rr_milliseconds
                FROM rr_beat r JOIN decoded_second d ON r.decoded_second_id = d.id
                WHERE d.absolute_timestamp >= ? AND d.absolute_timestamp < ?
                ORDER BY d.absolute_timestamp, r.beat_index
                """, arguments: [start, end])
            while let row = try rr.next() {
                beats[row["decoded_second_id"], default: []].append(row["rr_milliseconds"])
            }
            var output: [HeartRateMonitorSecond] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, absolute_timestamp, heart_rate, gravity_x, gravity_y, gravity_z
                FROM decoded_second WHERE absolute_timestamp >= ? AND absolute_timestamp < ?
                ORDER BY absolute_timestamp
                """, arguments: [start, end])
            while let row = try rows.next() {
                let id: Int64 = row["id"]
                let rate: Int64? = row["heart_rate"]
                output.append(HeartRateMonitorSecond(
                    timestamp: row["absolute_timestamp"],
                    heartRate: rate.flatMap { $0 > 0 ? Double($0) : nil },
                    gravityX: row["gravity_x"], gravityY: row["gravity_y"], gravityZ: row["gravity_z"],
                    rrIntervalsMilliseconds: beats[id] ?? []
                ))
            }
            return output
        }
    }
}

/// Where the overnight check gets its nights and the runtime its sleep windows.
nonisolated protocol HeartAlertsOvernightSource: Sendable {
    /// Nights whose wake day falls in the `days` days ending on `endingOn`.
    func nights(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsNight]
    /// Main sleeps that ended in the `days` days ending on `endingOn`.
    func mainSleeps(endingOn: Date, days: Int, calendar: Calendar) async -> [DateInterval]
    func assessments(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsAssessment]
}

nonisolated extension HeartAlertsOvernightSource {
    func assessments(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsAssessment] {
        let input = await nights(endingOn: endingOn, days: days + 30, calendar: calendar).sorted { $0.night < $1.night }
        let recent = Set(input.suffix(days).map(\.night))
        return input.indices.compactMap { index in
            guard recent.contains(input[index].night) else { return nil }
            return OvernightVitalsCheck.assessment(nights: Array(input.prefix(index + 1)), calendar: calendar)
        }
    }
}

nonisolated enum HeartAlertsDay {
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Refreshes recent canonical days, then reads their saved display assessments.
nonisolated struct ProjectionOvernightSource: HeartAlertsOvernightSource {
    let database: StorageDatabase
    var analytics: CanonicalDailyAnalytics? = nil

    /// A Bluetooth relaunch can have history before any scene builds repositories.
    static func production(history: StorageDatabase) -> Self? {
        let registry = LooprProductionDatabases.shared
        let historyURL = URL(fileURLWithPath: history.path)
        guard registry.isShared(historyURL),
              let productURL = LooprProductionDatabases.defaultProductionURLs().first(where: {
                  $0.standardizedFileURL.path != historyURL.standardizedFileURL.path
              }),
              let products = try? registry.database(at: productURL, applicationVersion: history.applicationVersion),
              let profile = try? SQLiteProfileRepository(database: products, dateProvider: SystemDateProvider(), uuidProvider: SystemUUIDProvider()),
              let analytics = try? CanonicalDailyAnalytics(history: history, products: products, profile: profile,
                  dateProvider: SystemDateProvider(), timeZoneProvider: SystemTimeZoneProvider()) else { return nil }
        return Self(database: products, analytics: analytics)
    }

    func nights(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsNight] {
        projections(endingOn: endingOn, days: days, calendar: calendar).map { _, projection in
            CanonicalDailyAnalytics.overnightNight(projection)
        }
    }

    func assessments(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsAssessment] {
        let end = calendar.startOfDay(for: endingOn)
        // Refresh the last two canonical days before reading the episode history.
        // This shares the screen generation instead of deriving alert-only ranges.
        if let analytics {
            for offset in [1, 0] {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
                let parts = calendar.dateComponents([.era, .year, .month, .day], from: day)
                let identity = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
                _ = try? await analytics.read(day: identity, reason: "overnight-alerts")
            }
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: day)
            let identity = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
            return CanonicalDailyAnalytics.cachedDisplay(database: database, day: identity)?.projection.heart.vitals?.assessment
        }
    }

    func mainSleeps(endingOn: Date, days: Int, calendar: Calendar) async -> [DateInterval] {
        projections(endingOn: endingOn, days: days, calendar: calendar).compactMap { _, projection in
            guard let sleep = projection.sleep.mainSleep, sleep.end > sleep.start else { return nil }
            return DateInterval(start: sleep.start, end: sleep.end)
        }
    }

    private func projections(endingOn: Date, days: Int, calendar: Calendar) -> [(Date, CanonicalDailyProjection)] {
        guard let store = try? StorageDocumentStore(database: database, namespace: "daily-analytics") else { return [] }
        let end = calendar.startOfDay(for: endingOn)
        return (0..<days).reversed().compactMap { offset -> (Date, CanonicalDailyProjection)? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let parts = calendar.dateComponents([.era, .year, .month, .day], from: day)
            // Same key `CanonicalDailyAnalytics.documentKey` writes.
            let key = "\(parts.era ?? 1)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            guard let projection = try? store.read(CanonicalDailyProjection.self, key: key) else { return nil }
            return (day, projection)
        }
    }
}

/// Fallback overnight metrics included in the check.
nonisolated struct MetricHistoryOvernightSource: HeartAlertsOvernightSource {
    let provider: any MetricHistoryProviding
    let fallback: (any HeartAlertsOvernightSource)?

    private static let keys: [(MetricKey, OvernightVitalMetric)] = [
        (.restingHeartRate, .restingHeartRate),
        (.rmssd, .heartRateVariability),
        (.respiratoryRate, .respiratoryRate)
    ]

    func nights(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsNight] {
        var merged: [String: [OvernightVitalMetric: Double]] = [:]
        if let fallback {
            for night in await fallback.nights(endingOn: endingOn, days: days, calendar: calendar) {
                merged[night.night] = night.values.filter {
                    OvernightVitalMetric.monitored.contains($0.key)
                }
            }
        }
        for (key, metric) in Self.keys {
            let points = (try? await provider.series(for: key, days: days, endingOn: endingOn)) ?? []
            for point in points where point.value.isFinite {
                merged[HeartAlertsDay.key(point.day, calendar: calendar), default: [:]][metric] = point.value
            }
        }
        return merged.map { OvernightVitalsNight(night: $0.key, values: $0.value) }
    }

    func assessments(endingOn: Date, days: Int, calendar: Calendar) async -> [OvernightVitalsAssessment] {
        if let fallback { return await fallback.assessments(endingOn: endingOn, days: days, calendar: calendar) }
        let input = await nights(endingOn: endingOn, days: days + 30, calendar: calendar).sorted { $0.night < $1.night }
        return input.indices.suffix(days).compactMap {
            OvernightVitalsCheck.assessment(nights: Array(input.prefix($0 + 1)), calendar: calendar)
        }
    }

    func mainSleeps(endingOn: Date, days: Int, calendar: Calendar) async -> [DateInterval] {
        await fallback?.mainSleeps(endingOn: endingOn, days: days, calendar: calendar) ?? []
    }
}

/// Runs the heart rate alerts and the overnight check after every committed
/// history batch, including when iOS relaunches Loopr headless for its
/// Bluetooth central and no scene exists.
///
/// The hook sits in `ProductionBluetoothAdoptionStore.markAcknowledged`, which
/// runs for every committed batch whether or not a scene is connected. Work is
/// coalesced per burst and only reads seconds after the persisted watermark.
actor LooprHeartAlertsRuntime {
    static let shared = LooprHeartAlertsRuntime()

    /// A backlog offload commits about one batch a second. One pass after the
    /// burst settles is enough.
    static let debounce: Duration = .seconds(3)

    let store: HeartAlertsStore
    private let parameters: HeartRateAlertParameters
    private let calendarProvider: @Sendable () -> Calendar
    private let clock: @Sendable () -> Date
    private let publisher: any HeartAlertsPublishing
    private var history: StorageDatabase?
    private var overnightSource: (any HeartAlertsOvernightSource)?
    private var metricHistory: (any MetricHistoryProviding)?
    private var pending: Task<Void, Never>?
    private var evaluating = false
    private var rerunRequested = false
    private var cachedSleep: (fetchedAt: Date, windows: [Range<Int64>])?

    init(
        store: HeartAlertsStore = HeartAlertsStore(),
        parameters: HeartRateAlertParameters = .standard,
        calendar: @escaping @Sendable () -> Calendar = { Calendar.autoupdatingCurrent },
        clock: @escaping @Sendable () -> Date = { Date() },
        publisher: any HeartAlertsPublishing = LooprHeartAlertsNotificationPublisher()
    ) {
        self.store = store
        self.parameters = parameters
        self.calendarProvider = calendar
        self.clock = clock
        self.publisher = publisher
    }

    // MARK: - Wiring

    /// Called by the post-commit hook. Remembers the history database the
    /// Bluetooth store writes to and schedules one evaluation per burst.
    func historyCommitted(database: StorageDatabase) {
        history = database
        if overnightSource == nil { overnightSource = ProjectionOvernightSource.production(history: database) }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.evaluateNow()
        }
    }

    func attach(history database: StorageDatabase) { history = database }

    /// The app attaches the product database once it has one.
    func attach(overnightSource source: any HeartAlertsOvernightSource) {
        overnightSource = source
        cachedSleep = nil
    }

    /// The metric history provider supplies the three overnight readings.
    func attach(metricHistory provider: any MetricHistoryProviding) {
        metricHistory = provider
    }

    private var effectiveOvernightSource: (any HeartAlertsOvernightSource)? {
        if let overnightSource { return overnightSource }
        if let metricHistory { return MetricHistoryOvernightSource(provider: metricHistory, fallback: nil) }
        return nil
    }

    /// Called when the app becomes active: the morning check often has its
    /// night derived only once a scene is up.
    func appBecameActive() async {
        await evaluateNow()
    }

    // MARK: - Workouts

    func noteWorkout(id: String, start: Date?, end: Date?) async {
        guard let start else { return }
        var state = await store.state()
        state.workouts.removeAll { $0.id == id }
        state.workouts.append(HeartAlertsWorkoutSpan(id: id, start: start, end: end))
        let horizon = clock().addingTimeInterval(-2 * 86_400)
        state.workouts.removeAll { ($0.end ?? $0.start) < horizon }
        try? await store.saveState(state)
    }

    /// An open workout is treated as running for at most six hours, so a lost
    /// finish never silences alerts for good.
    private func workoutRanges(_ spans: [HeartAlertsWorkoutSpan], now: Date) -> [Range<Int64>] {
        spans.compactMap { span in
            let start = Int64(span.start.timeIntervalSince1970)
            let end = Int64((span.end ?? min(now, span.start.addingTimeInterval(6 * 3600))).timeIntervalSince1970)
            return end > start ? start..<end : nil
        }
    }

    // MARK: - Settings

    func preferences() async -> HeartAlertsPreferences { await store.preferences() }

    func history() async -> [HeartAlertRecord] { await store.history() }

    /// Saves the choice and keeps the notification families in step, so the
    /// central policy and this screen never disagree.
    func update(_ preferences: HeartAlertsPreferences) async throws {
        let previous = await store.preferences()
        try await store.savePreferences(preferences)
        try await publisher.setFamilies([
            .highHeartRate: preferences.rates.highEnabled,
            .lowHeartRate: preferences.rates.lowEnabled,
            .overnightCheck: preferences.overnightCheckEnabled,
            .cardioFitness: preferences.cardioFitnessEnabled
        ])
        // Turning an alert on starts from now: history already on the phone
        // is never scanned for old episodes.
        let turnedOn = (!previous.rates.highEnabled && preferences.rates.highEnabled)
            || (!previous.rates.lowEnabled && preferences.rates.lowEnabled)
        if turnedOn, let history, let latest = try? HeartAlertHistoryReader.latestTimestamp(history) {
            var state = await store.state()
            state.rates.watermark = max(state.rates.watermark ?? latest, latest)
            try? await store.saveState(state)
        }
    }

    /// "Pause for today" from a heart alert notification.
    func pauseForToday(_ family: NotificationFamily) async {
        let kind: HeartRateAlertKind
        switch family {
        case .highHeartRate: kind = .high
        case .lowHeartRate: kind = .low
        default: return
        }
        let calendar = calendarProvider()
        let now = clock()
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        var preferences = await store.preferences()
        preferences.pausedUntil[kind.rawValue] = midnight
        try? await store.savePreferences(preferences)
    }

    // MARK: - Evaluation

    /// One pass at a time. The actor is reentrant at every `await`, so a
    /// commit landing mid-pass would otherwise start a second pass on the same
    /// watermark; it asks for one more pass instead.
    func evaluateNow() async {
        guard !evaluating else {
            rerunRequested = true
            return
        }
        evaluating = true
        repeat {
            rerunRequested = false
            await evaluateHeartRate()
            await evaluateOvernight()
        } while rerunRequested
        evaluating = false
    }

    /// One pass of the heart rate alerts over the seconds after the watermark.
    func evaluateHeartRate() async {
        guard let history else { return }
        let preferences = await store.preferences()
        var state = await store.state()
        guard let latest = try? HeartAlertHistoryReader.latestTimestamp(history) else { return }

        // Nothing on: only move the watermark, so turning an alert on later
        // does not scan everything recorded in the meantime.
        guard preferences.rates.highEnabled || preferences.rates.lowEnabled else {
            state.rates.watermark = latest
            try? await store.saveState(state)
            return
        }

        let now = clock()
        let lookback = parameters.requiredLookbackSeconds
        // Windows older than the freshness limit can never alert, so a long
        // backlog is skipped instead of read. After such a gap both kinds
        // re-arm: nobody saw the stretch in between.
        let oldestUseful = Int64(now.timeIntervalSince1970) - parameters.freshnessSeconds - parameters.windowSeconds
        var watermark = state.rates.watermark ?? (latest - parameters.windowSeconds)
        if watermark < oldestUseful {
            watermark = oldestUseful
            for kind in HeartRateAlertKind.allCases {
                state.rates[kind] = HeartRateAlertState.KindState(alertTimes: state.rates[kind].alertTimes)
            }
        }
        state.rates.watermark = watermark
        guard latest > watermark,
              let seconds = try? HeartAlertHistoryReader.seconds(history, from: watermark - lookback, to: latest + 1)
        else {
            try? await store.saveState(state)
            return
        }

        let openIDs = HeartRateAlertKind.allCases.compactMap { state.rates[$0].openEpisodeID }
        let open = await store.episodes(ids: openIDs)
        let context = HeartRateAlertContext(
            now: Int64(now.timeIntervalSince1970),
            calendar: calendarProvider(),
            workouts: workoutRanges(state.workouts, now: now),
            sleep: await sleepWindows(now: now)
        )
        let result = HeartRateAlertDetector.evaluate(
            seconds: seconds, settings: preferences.rates, state: state.rates,
            context: context, openEpisodes: open, parameters: parameters
        )
        state.rates = result.nextState
        try? await store.saveState(state)

        for episode in result.updatedEpisodes {
            try? await store.updateEpisode(episode)
        }
        for episode in result.alerts {
            let family: NotificationFamily = episode.kind == .high ? .highHeartRate : .lowHeartRate
            let delivery: HeartAlertDelivery
            if preferences.isPaused(episode.kind, at: now) {
                delivery = .paused
            } else {
                delivery = await publisher.publish(
                    HeartAlertsCopy.request(for: episode, family: family, now: now,
                                            calendar: calendarProvider(),
                                            allowDuringQuietHours: preferences.allowDuringQuietHours)
                )
            }
            try? await store.record(HeartAlertRecord(
                id: episode.id,
                kind: episode.kind == .high ? .highHeartRate : .lowHeartRate,
                date: Date(timeIntervalSince1970: TimeInterval(episode.detectedAt)),
                episode: episode,
                delivery: delivery
            ))
        }
    }

    private func sleepWindows(now: Date) async -> [Range<Int64>] {
        if let cachedSleep, now.timeIntervalSince(cachedSleep.fetchedAt) < 30 * 60 { return cachedSleep.windows }
        guard let source = effectiveOvernightSource else { return [] }
        let windows = await source.mainSleeps(endingOn: now, days: 2, calendar: calendarProvider()).map {
            Int64($0.start.timeIntervalSince1970)..<Int64($0.end.timeIntervalSince1970)
        }
        cachedSleep = (now, windows)
        return windows
    }

    /// The morning check reads the same cached daily assessment as Today.
    /// A completed sync may update a night already seen earlier this morning.
    func evaluateOvernight() async {
        let preferences = await store.preferences()
        guard preferences.overnightCheckEnabled, let source = effectiveOvernightSource else { return }
        let calendar = calendarProvider()
        let now = clock()
        let today = HeartAlertsDay.key(now, calendar: calendar)
        var state = await store.state()
        if let evaluated = state.overnight.lastEvaluatedNight, evaluated > today { return }

        let assessments = await source.assessments(endingOn: now, days: 31, calendar: calendar)
        guard assessments.last?.night == today,
              let result = OvernightVitalsCheck.evaluate(assessments: assessments, state: state.overnight, calendar: calendar) else { return }
        guard state.overnight != result.nextState else { return }
        state.overnight = result.nextState
        // Fail closed if the episode edge cannot be persisted. A relaunch must
        // not publish the same episode again after a failed file write.
        do { try await store.saveState(state) } catch { return }
        guard result.shouldNotify else { return }

        let sleeps = await source.mainSleeps(endingOn: now, days: 14, calendar: calendar)
        let usualWake = OvernightVitalsCheck.usualWakeMinute(wakeTimes: sleeps.map(\.end), calendar: calendar)
        let quiet = await publisher.deliverySettings()
        let earliest = quiet.quietHoursEnabled ? quiet.quietHours.endMinute : 0
        let fireDate = OvernightVitalsCheck.deliveryDate(now: now, usualWakeMinute: usualWake,
                                                         earliestMinute: earliest, calendar: calendar)
        let id = "overnight-\(result.night)"
        let delivery = await publisher.publish(
            HeartAlertsCopy.overnightRequest(id: id, night: result.night, outliers: result.outliers,
                                             fireDate: fireDate, calendar: calendar)
        )
        try? await store.record(HeartAlertRecord(
            id: id, kind: .overnightCheck, date: fireDate, overnightNight: result.night,
            overnightMetrics: result.outliers.map {
                HeartAlertOvernightMetric(metric: $0.metric, value: $0.value, low: $0.range.low,
                                          high: $0.range.high, direction: $0.direction)
            },
            delivery: delivery
        ))
    }

    // MARK: - Cardio fitness

    /// For the vitals work: call when a new cardio fitness estimate lands in
    /// the low range for the person's age and sex. Loopr does not compute the
    /// estimate here. Sends at most one notice every four months, and only
    /// when the person switched the notice on.
    @discardableResult
    func cardioFitnessLowRange(estimateID: String, measuredAt: Date) async -> Bool {
        let preferences = await store.preferences()
        guard preferences.cardioFitnessEnabled else { return false }
        var state = await store.state()
        let now = clock()
        guard CardioFitnessNoticeGate.mayNotify(lastNotifiedAt: state.cardioFitnessLastNotifiedAt, now: now,
                                                calendar: calendarProvider()) else { return false }
        let id = "cardio-\(estimateID)"
        let delivery = await publisher.publish(HeartAlertsCopy.cardioFitnessRequest(id: id, now: now,
                                                                                     calendar: calendarProvider()))
        state.cardioFitnessLastNotifiedAt = now
        try? await store.saveState(state)
        try? await store.record(HeartAlertRecord(id: id, kind: .cardioFitness, date: measuredAt, delivery: delivery))
        return true
    }

    func deleteAll() async throws {
        pending?.cancel()
        cachedSleep = nil
        try await store.deleteAll()
    }
}

/// The notification side, behind a protocol so tests use a fake center.
nonisolated protocol HeartAlertsPublishing: Sendable {
    func publish(_ request: NotificationRequest) async -> HeartAlertDelivery
    func setFamilies(_ families: [NotificationFamily: Bool]) async throws
    func deliverySettings() async -> NotificationDeliverySettings
}

nonisolated struct LooprHeartAlertsNotificationPublisher: HeartAlertsPublishing {
    func publish(_ request: NotificationRequest) async -> HeartAlertDelivery {
        #if canImport(UserNotifications)
        switch await LooprNotificationRuntime.shared.schedule(request) {
        case .scheduled?, .duplicate?: return .sent
        case .deferred?: return .heldForQuietHours
        case .queued?: return .waitingForPermission
        case .disabled?, .denied?: return .notificationsOff
        case .quietHours?, .expired?, nil: return .notSent
        }
        #else
        return .notificationsOff
        #endif
    }

    func setFamilies(_ families: [NotificationFamily: Bool]) async throws {
        #if canImport(UserNotifications)
        for (family, enabled) in families {
            try await LooprNotificationRuntime.shared.policy.setEnabled(enabled, for: family)
        }
        #endif
    }

    func deliverySettings() async -> NotificationDeliverySettings {
        #if canImport(UserNotifications)
        await LooprNotificationRuntime.shared.deliverySettings()
        #else
        .standard
        #endif
    }
}

/// Removes the alert history and preferences with "Delete all Loopr data".
nonisolated struct LooprHeartAlertsDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "heart-alerts"

    func deleteAll() async throws {
        try await LooprHeartAlertsRuntime.shared.deleteAll()
    }
}
