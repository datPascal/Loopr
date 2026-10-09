import Foundation
import BodyKit
import HealthKitBridge
import StorageKit
import DomainKit
import DesignSystem
import HeartKit
import OnboardingKit
import SleepKit
import TodayKit
import WorkoutKit

nonisolated let looprHealthHistoryCommitted = Notification.Name("com.loopr.history.committed")
nonisolated let looprHealthReadPreferencesChanged = Notification.Name("com.loopr.health.readPreferencesChanged")

protocol LooprBackgroundHealthSynchronizing: AnyObject, Sendable {
    func synchronize() async
}

nonisolated struct HealthPartitionSummary: Codable, Sendable {
    let pending: Int
    let completedAt: Date?
    let error: String?
}

nonisolated private struct HealthPartitionProgress: Codable, Sendable {
    let version: Int
    let savedIndices: [Int]
    let obsolete: Set<String>
    let lastError: String?
    let completedAt: Date?
}

nonisolated final class SQLiteHealthSyncStore: HealthSyncStore, @unchecked Sendable {
    let documents: StorageDocumentStore
    private let initialTimeZone: String

    init(database: StorageDatabase, timeZone: String) throws {
        documents = try StorageDocumentStore(database: database, namespace: "health-sync")
        initialTimeZone = timeZone
    }

    func preferences() throws -> HealthSyncPreferences {
        try documents.read(HealthSyncPreferences.self, key: "preferences")
            ?? HealthSyncPreferences(timeZoneIdentifier: initialTimeZone)
    }
    func savePreferences(_ value: HealthSyncPreferences) throws { try documents.write(value, key: "preferences") }
    func partition(_ key: String) throws -> HealthSyncPartition? {
        guard let progress = try documents.read(HealthPartitionProgress.self, key: "partition.\(key)") else { return nil }
        guard let samples = try documents.read([HealthSyncSample].self, key: "samples.\(key)") else { throw HealthSyncError.invalidSamples }
        return HealthSyncPartition(samples: samples, version: progress.version,
            saved: Set(progress.savedIndices.compactMap { samples.indices.contains($0) ? samples[$0].identifier : nil }),
            obsolete: progress.obsolete, lastError: progress.lastError, completedAt: progress.completedAt)
    }
    func savePartition(_ value: HealthSyncPartition, key: String) throws {
        let previous = try documents.read(HealthPartitionProgress.self, key: "partition.\(key)")
        let progress = HealthPartitionProgress(version: value.version,
            savedIndices: value.samples.indices.filter { value.saved.contains(value.samples[$0].identifier) },
            obsolete: value.obsolete, lastError: value.lastError, completedAt: value.completedAt)
        var mutations: [StorageDocumentMutation] = try [
            .write(progress, key: "partition.\(key)"),
            .write(HealthPartitionSummary(pending: value.pendingCount, completedAt: value.completedAt, error: value.lastError), key: "summary.\(key)")
        ]
        if previous?.version != value.version { mutations.append(try .write(value.samples, key: "samples.\(key)")) }
        try documents.mutate(mutations)
    }
    func partitionKeys() throws -> [String] {
        try documents.keys().filter { $0.hasPrefix("partition.") }.map { String($0.dropFirst("partition.".count)) }
    }
}

nonisolated struct HealthExportTimeZone: TimeZoneProviding {
    let timeZone: TimeZone
}

nonisolated struct ProductDerivationDeletionGroup: PersistentDataDeletionDeleter {
    let storeName = "analytics.and-health-sync"
    let analytics: CanonicalDailyAnalytics
    let healthSync: LooprHealthSyncRuntime
    let derivedData: LooprDerivedDataPublisher?

    init(analytics: CanonicalDailyAnalytics, healthSync: LooprHealthSyncRuntime,
         derivedData: LooprDerivedDataPublisher? = nil) {
        self.analytics = analytics
        self.healthSync = healthSync
        self.derivedData = derivedData
    }

    func deleteAll() async throws {
        // The publisher goes first. A debounced pass that fires after deletion
        // would write a fresh snapshot over the revocation the Watch and the
        // widgets were just handed.
        await derivedData?.stop()
        try await healthSync.deleteAll()
        try await analytics.deleteAll()
    }
}

nonisolated struct LooprHealthSyncStatus: Sendable {
    var enabled = true
    var disabledRead: Set<HealthHistoryQuantity> = []
    var sleepReadEnabled = true
    var disabledWrite: Set<ExportMetricKind> = []
    var readPermissionNeeded = false
    var allowed: Set<ExportMetricKind> = []
    var undetermined: Set<ExportMetricKind> = []
    var unavailable = false
    var syncing = false
    var pendingCount = 0
    var lastSync: Date?
    var error: String?
}

actor LooprHealthSyncRuntime: PersistentDataDeletionDeleter, LooprBackgroundHealthSynchronizing {
    nonisolated let storeName = "health-sync.runtime"
    // These have production sources. Active energy joined the list once the
    // derivation started reporting real kilocalories from the person's
    // profile instead of a relative activity index.
    nonisolated static let metrics: Set<ExportMetricKind> = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
        .sleepStages, .steps, .activeEnergy, .completedWorkout
    ]
    private let history: StorageDatabase
    private let analytics: CanonicalDailyAnalytics
    private let workouts: any WorkoutStore
    private let store: SQLiteHealthSyncStore
    private let client: any HealthSyncClient
    private let engine: HealthSyncEngine
    private let dates: any DateProviding
    private let calendar: Calendar
    private let budget: LooprDerivationBudget
    private var syncing = false
    private var stopped = false
    private var lastError: String?

    init(history: StorageDatabase, analytics: CanonicalDailyAnalytics, workouts: any WorkoutStore,
         store: SQLiteHealthSyncStore, dates: any DateProviding, client: any HealthSyncClient = LiveHealthKitClient(),
         budget: LooprDerivationBudget = .shared) throws {
        self.history = history; self.analytics = analytics; self.workouts = workouts
        self.store = store; self.client = client; self.dates = dates; self.budget = budget
        self.engine = HealthSyncEngine(store: store, client: client)
        var calendar = Calendar(identifier: .gregorian)
        let preferences = try store.preferences()
        calendar.timeZone = TimeZone(identifier: preferences.timeZoneIdentifier) ?? .gmt
        self.calendar = calendar
        // Persist day assignment even before permission is requested.
        try store.savePreferences(preferences)
    }

    func status() async -> LooprHealthSyncStatus {
        var result = LooprHealthSyncStatus()
        result.syncing = syncing
        result.error = lastError
        do {
            let preferences = try store.preferences()
            result.enabled = preferences.enabled
            result.disabledRead = preferences.disabledRead
            result.sleepReadEnabled = preferences.sleepReadEnabled
            result.disabledWrite = preferences.disabledWrite
            for metric in Self.metrics.subtracting(preferences.disabledWrite) {
                switch await client.writeAuthorization(for: metric) {
                case .authorized: result.allowed.insert(metric)
                case .notDetermined: result.undetermined.insert(metric)
                case .unavailable: result.unavailable = true
                case .denied: break
                }
            }
            #if canImport(HealthKit)
            let reading = Set(HealthHistoryQuantity.allCases).subtracting(preferences.disabledRead)
            if !reading.isEmpty || preferences.sleepReadEnabled {
                result.readPermissionNeeded = !(await LiveHealthHistoryClient().historyReadAccessRequested(
                    reading: reading, readSleep: preferences.sleepReadEnabled))
            }
            #endif
            for key in try store.documents.keys() where key.hasPrefix("summary.") {
                guard let summary = try store.documents.read(HealthPartitionSummary.self, key: key) else { continue }
                result.pendingCount += summary.pending
                if let date = summary.completedAt { result.lastSync = max(result.lastSync ?? .distantPast, date) }
                if result.error == nil { result.error = summary.error }
            }
        } catch { result.enabled = false; result.error = error.localizedDescription }
        return result
    }

    func setEnabled(_ enabled: Bool) throws {
        guard !stopped else { throw CancellationError() }
        var preferences = try store.preferences()
        preferences.enabled = enabled
        try store.savePreferences(preferences)
        NotificationCenter.default.post(name: looprHealthReadPreferencesChanged, object: nil)
    }

    func setWriteEnabled(_ enabled: Bool, for metric: ExportMetricKind) async throws {
        guard !stopped else { throw CancellationError() }
        var preferences = try store.preferences()
        if enabled { preferences.disabledWrite.remove(metric) }
        else { preferences.disabledWrite.insert(metric) }
        try store.savePreferences(preferences)
        if enabled, preferences.enabled, await client.writeAuthorization(for: metric) == .notDetermined {
            try await client.requestWriteAuthorization(for: [metric])
        }
    }

    func setReadEnabled(_ enabled: Bool, for quantity: HealthHistoryQuantity?) async throws {
        guard !stopped else { throw CancellationError() }
        if let quantity, !HealthHistoryQuantity.allCases.contains(quantity) { return }
        var preferences = try store.preferences()
        if let quantity {
            if enabled { preferences.disabledRead.remove(quantity) }
            else { preferences.disabledRead.insert(quantity) }
        } else {
            preferences.sleepReadEnabled = enabled
        }
        try store.savePreferences(preferences)
        NotificationCenter.default.post(name: looprHealthReadPreferencesChanged, object: nil)
        if enabled, preferences.enabled {
            #if canImport(HealthKit)
            let reading = Set(quantity.map { [$0] } ?? [])
            if !(await LiveHealthHistoryClient().historyReadAccessRequested(
                reading: reading, readSleep: quantity == nil)),
               let authorizer = client as? any HealthHistoryAuthorizing {
                try await authorizer.requestAuthorization(sharing: [],
                    reading: reading, readSleep: quantity == nil)
            }
            #endif
            await LooprMetricHistory.shared.appleHealthConnected()
        }
    }

    func allowsRead(_ quantity: HealthHistoryQuantity) -> Bool {
        guard HealthHistoryQuantity.allCases.contains(quantity),
              let preferences = try? store.preferences() else { return false }
        return preferences.enabled && !preferences.disabledRead.contains(quantity)
    }

    /// Exactly what `requestPermission()` asks iOS for, given the saved
    /// choices. Onboarding lists these types before the sheet appears.
    nonisolated static func permissionRequest(for preferences: HealthSyncPreferences) -> OnboardingHealthRequest {
        OnboardingHealthRequest(
            writes: metrics.subtracting(preferences.disabledWrite),
            reads: Set(HealthHistoryQuantity.allCases).subtracting(preferences.disabledRead),
            readsSleep: preferences.sleepReadEnabled
        )
    }

    /// The request the next `requestPermission()` would make, or nil when
    /// Apple Health is switched off in Loopr and no sheet would appear.
    func permissionRequest() -> OnboardingHealthRequest? {
        guard let preferences = try? store.preferences(), preferences.enabled else { return nil }
        return Self.permissionRequest(for: preferences)
    }

    func requestPermission() async {
        guard !stopped else { return }
        do {
            let preferences = try store.preferences()
            guard preferences.enabled else { return }
            let request = Self.permissionRequest(for: preferences)
            // One sheet asks for both: write access for the export and read
            // access for the metric history import.
            if let history = client as? any HealthHistoryAuthorizing {
                try await history.requestAuthorization(sharing: request.writes, reading: request.reads,
                    readSleep: request.readsSleep)
            } else {
                try await client.requestWriteAuthorization(for: request.writes)
            }
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await LooprMetricHistory.shared.appleHealthConnected()
    }

    /// The automatic export. Every history commit used to call this, and the
    /// walk derives every day whose revision moved, so a night of top-ups was
    /// an unbounded background derivation loop. Off screen it now runs at most
    /// once per top-up and no more often than every half hour; a person who
    /// taps "Sync now" gets `synchronizeNow()` instead.
    func synchronize() async {
        guard await budget.claim(.healthExport) != nil else { return }
        await synchronizeNow()
    }

    func synchronizeNow() async {
        guard !syncing, !stopped else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard try store.preferences().enabled else { return }
            var allowed: Set<ExportMetricKind> = []
            let preferences = try store.preferences()
            for metric in Self.metrics.subtracting(preferences.disabledWrite)
                where await client.writeAuthorization(for: metric) == .authorized { allowed.insert(metric) }
            guard !allowed.isEmpty else { return }
            lastError = nil
            let now = dates.now()
            // Enumerate occupied UTC buckets, then resolve actual civil days.
            // Missing spans never cause an unbounded walk through empty years.
            let timestamps: [Int64] = try history.read { db in
                try Int64.fetchAll(db, sql: "SELECT DISTINCT (absolute_timestamp / 86400) * 86400 FROM decoded_second WHERE absolute_timestamp <= ? ORDER BY absolute_timestamp / 86400 DESC", arguments: [Int64(now.timeIntervalSince1970)])
            }
            var days = Set<Date>()
            for timestamp in timestamps {
                for offset: Int64 in [0, 86_399] {
                    let date = Date(timeIntervalSince1970: Double(timestamp + offset))
                    if date <= now { days.insert(calendar.startOfDay(for: date)) }
                    else { days.insert(calendar.startOfDay(for: now)) }
                }
            }
            // Finish workouts first, even while a large history import is pending.
            for workout in await workouts.all() {
                guard try canContinue() else { return }
                try await exportWorkout(workout, now: now)
            }
            for start in days.sorted(by: >) {
                guard try canContinue(), let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
                let day = dayIdentity(start)
                let dayKey = String(Int64(start.timeIntervalSince1970))
                // Local deletion does not authorize removal from Apple Health.
                let lower = Int64(start.timeIntervalSince1970), upper = Int64(min(end, now).timeIntervalSince1970)
                let hasRecords = try history.read { db in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decoded_second WHERE absolute_timestamp >= ? AND absolute_timestamp < ?)", arguments: [lower, upper]) ?? false
                }
                guard hasRecords else { continue }
                if allowed.contains(.heartRate) {
                    let revision = try history.historicalAnalyticsRevision(from: lower, to: upper)
                    let markerKey = "source.hr-minute-1.\(dayKey)"
                    let marker = "\(revision).\(min(Int64(end.timeIntervalSince1970), Int64(now.timeIntervalSince1970) / 60 * 60))"
                    let previousMarker = try store.documents.read(String.self, key: markerKey)
                    if previousMarker != marker {
                        let raw = try history.historicalAnalyticsSnapshot(from: lower, to: upper)
                        let samples = Self.heartRateSamples(raw.records, before: now, timeZone: calendar.timeZone.identifier)
                        let report = try await engine.synchronize(key: "hr.\(dayKey)", metric: .heartRate, samples: samples, now: now)
                        if let error = report.error { lastError = error }
                        if !stopped, report.pending == 0, try store.preferences().enabled {
                            try store.documents.write(marker, key: markerKey)
                        }
                    }
                }
                let dailyMetrics: [ExportMetricKind] = [
                    .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .sleepStages, .steps, .activeEnergy
                ]
                if !allowed.intersection(dailyMetrics).isEmpty {
                    guard try canContinue(), let projection = try await analytics.read(day: day, reason: "export") else { continue }
                    let samples = Self.dailySamples(projection, start: start, end: min(end, now), timeZone: calendar.timeZone.identifier)
                    for metric in dailyMetrics where allowed.contains(metric) {
                        guard try canContinue() else { return }
                        try await export(key: "\(metric.rawValue).\(dayKey)", metric: metric,
                            samples: samples.filter { $0.metric == metric }, now: now)
                    }
                }
            }
        } catch is CancellationError { }
        catch { if !stopped { lastError = error.localizedDescription } }
    }

    /// The local workout is already durable before this hook runs. Export
    /// failure remains retryable and must not prevent workout finalization.
    func workoutFinalized(_ workout: WorkoutRecord) async {
        guard !stopped else { return }
        do { try await exportWorkout(workout, now: dates.now()) }
        catch { if !stopped { lastError = error.localizedDescription } }
    }

    private func exportWorkout(_ workout: WorkoutRecord, now: Date) async throws {
        guard try canContinue(), !(try store.preferences()).disabledWrite.contains(.completedWorkout),
              let sample = Self.workoutSample(workout, before: now, timeZone: calendar.timeZone.identifier) else { return }
        try await export(key: "workout.\(workout.id.uuidString)", metric: .completedWorkout, samples: [sample], now: now)
    }

    private func export(key: String, metric: ExportMetricKind, samples: [HealthSyncSample], now: Date) async throws {
        guard try canContinue() else { return }
        let report = try await engine.synchronize(key: key, metric: metric, samples: samples, now: now)
        if let error = report.error { lastError = error }
    }

    private func canContinue() throws -> Bool {
        try Task.checkCancellation()
        guard !stopped else { return false }
        return try store.preferences().enabled
    }

    private func dayIdentity(_ date: Date) -> DayIdentity {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return DayIdentity(era: parts.era ?? 1, year: parts.year!, month: parts.month!, day: parts.day!)
    }

    func deleteAll() async throws {
        stopped = true
        await engine.stop()
        try await analytics.deleteAll()
        try store.documents.removeAll()
    }

    nonisolated static func heartRateSamples(_ records: [StoredHistoricalRecord], before now: Date, timeZone: String) -> [HealthSyncSample] {
        // One average per complete minute avoids flooding Health with a sample
        // every second. Require at least 30 distinct valid seconds per minute.
        var minutes: [Int64: [Int64: Double]] = [:]
        for record in records {
            guard let rate = record.heartRate, (25...230).contains(Int(rate)) else { continue }
            let minute = record.absoluteTimestamp / 60 * 60
            guard Double(minute + 60) <= now.timeIntervalSince1970 else { continue }
            minutes[minute, default: [:]][record.absoluteTimestamp] = Double(rate)
        }
        return minutes.keys.sorted().compactMap { minute in
            guard let values = minutes[minute], values.count >= 30 else { return nil }
            return HealthSyncSample(identifier: "com.loopr.hr.\(minute)", metric: .heartRate,
                value: values.values.reduce(0, +) / Double(values.count),
                start: Date(timeIntervalSince1970: Double(minute)), end: Date(timeIntervalSince1970: Double(minute + 60)),
                provenance: "Measured strap heart rate, one-minute mean", algorithm: "loopr.hr-minute.1", timeZone: timeZone)
        }
    }

    nonisolated static func dailySamples(_ projection: CanonicalDailyProjection, start: Date, end: Date, timeZone: String) -> [HealthSyncSample] {
        let key = "com.loopr.day.\(Int64(start.timeIntervalSince1970))"
        var result: [HealthSyncSample] = []
        func append(_ metric: ExportMetricKind, value: Double, from: Date, to: Date, suffix: String, algorithm: String) {
            guard value.isFinite, value >= 0, from < to else { return }
            result.append(HealthSyncSample(identifier: "\(key).\(suffix)", metric: metric, value: value,
                start: from, end: to, provenance: "Estimated by Loopr from strap records", algorithm: algorithm, timeZone: timeZone))
        }
        if let sleep = projection.sleep.mainSleep, !sleep.isPartial, sleep.confidence >= 0.5, sleep.end <= end {
            for (id, metric) in [(HeartMetricID.restingHeartRate, ExportMetricKind.restingHeartRate), (.sdnn, .heartRateVariabilitySDNN), (.respiration, .respiratoryRate)] {
                if let value = projection.heart.metric(id), value.state == .partial,
                   let number = value.numericValue, number > 0 {
                    append(metric, value: number, from: sleep.start, to: sleep.end, suffix: metric.rawValue, algorithm: value.algorithmVersion ?? projection.algorithmVersion)
                }
            }
            var cursor = sleep.start
            for (index, segment) in projection.sleep.hypnogram.enumerated() {
                let segmentEnd = min(sleep.end, cursor.addingTimeInterval(Double(segment.durationMinutes) * 60))
                let category: Double = switch segment.stage {
                case .awake: 2
                case .light: 3
                case .deep: 4
                case .rem: 5
                }
                append(.sleepStages, value: category, from: cursor, to: segmentEnd, suffix: "sleep.\(index)", algorithm: projection.sleep.algorithmVersion ?? projection.algorithmVersion)
                cursor = segmentEnd
            }
        }
        // Low-confidence estimates stay in Loopr.
        if let steps = projection.today.metric(.steps), steps.state == .partial,
           let value = steps.numericValue, value > 0 {
            append(.steps, value: value, from: start, to: end, suffix: "steps", algorithm: steps.algorithmVersion ?? projection.algorithmVersion)
        }
        // Active energy is real kilocalories, derived from the person's height,
        // weight and age. An estimate built on a textbook maximum heart rate
        // instead of theirs stays `.lowConfidence` and stays in Loopr.
        if let energy = projection.body.metric(.energy), energy.state == .partial,
           let value = energy.value.flatMap(Double.init), value > 0 {
            append(.activeEnergy, value: value, from: start, to: end, suffix: "activeEnergy",
                   algorithm: energy.algorithmVersion ?? projection.algorithmVersion)
        }
        return result
    }

    nonisolated static func workoutSample(_ workout: WorkoutRecord, before now: Date, timeZone: String) -> HealthSyncSample? {
        guard [.completed, .finishing].contains(workout.state), [.live, .manual, .detected].contains(workout.source),
              let start = workout.startedAt, let end = workout.endedAt, start < end, end <= now else { return nil }
        return HealthSyncSample(identifier: "com.loopr.workout.\(workout.id.uuidString)", metric: .completedWorkout,
            value: end.timeIntervalSince(start), start: start, end: end,
            provenance: "Loopr \(workout.source.rawValue) workout", algorithm: "loopr.workout.1", timeZone: timeZone,
            workoutActivity: workout.activity.rawValue)
    }
}
