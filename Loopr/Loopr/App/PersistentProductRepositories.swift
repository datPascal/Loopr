import AnalyticsKit
import DeviceCenterKit
import DomainKit
import DesignSystem
import Foundation
import OnboardingKit
import ProfileKit
import BodyKit
import BluetoothKit
import CoachKit
import DataKit
import HeartKit
import HealthKitBridge
import JournalKit
import CycleKit
import RecordsKit
import RouteKit
import SettingsKit
import SleepKit
import StorageKit
import StressKit
import TodayKit
import WorkoutKit
import ImportKit

nonisolated enum ProductRepositoryKeys {
    static let onboarding = "loopr.product.onboarding.v1"
    static let profile = "loopr.product.profile.v1"
    static let device = "loopr.product.device.v1"

    /// Every key the shipping app owns in its standard defaults domain. Full
    /// account deletion clears this registry instead of relying on each
    /// feature to remember its own key.
    static let allOwnedDefaultsKeys: [String] = [
        onboarding,
        profile,
        device,
        UserDefaultsAccessoryProvisioningStore.key,
        UserDefaultsGen5KillSwitchStore.key,
        UserDefaultsGen5ProductKillSwitchStore.key(for: .whoop5),
        UserDefaultsGen5ProductKillSwitchStore.key(for: .whoopMG),
        UserDefaultsBetaConsentStore.key,
        LooprAISettingsRuntime.endpointKey,
        LooprAISettingsRuntime.modelKey,
        LaunchOnboardingFlagStore.key,
        TodayLaunchSnapshotStore.key,
        LooprDayHintStore.key,
        TodayPreferencesStore.key
    ]
}

/// A deletion boundary for a store that lives outside the canonical product
/// database.  Platform-backed stores (Keychain, App Group, notifications,
/// Live Activities) can be injected when their concrete adapters are
/// available; an unavailable adapter is reported in the deletion receipt
/// instead of being treated as successfully cleared.
nonisolated protocol PersistentDataDeletionDeleter: Sendable {
    nonisolated var storeName: String { get }
    func deleteAll() async throws
}

struct UnavailablePersistentDataDeletionDeleter: PersistentDataDeletionDeleter {
    let storeName: String

    func deleteAll() async throws {
        throw PersistentDataDeletionError.unavailableExternalStore(storeName)
    }
}

struct SQLiteFileDataDeletionDeleter: PersistentDataDeletionDeleter {
    let storeName: String
    let databaseURL: URL
    let applicationVersion: String

    func deleteAll() async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else { return }
        // The production history file is already open in this process; use
        // that pool so the delete goes through the same writer as sync.
        let database = try LooprProductionDatabases.shared.database(at: databaseURL, applicationVersion: applicationVersion)
        try database.deleteAllAccountData()
        // The Bluetooth history file normally contains only StorageKit's
        // ledger. Clear any product-document rows too if an older build used
        // this file for a product namespace; deletion must not leave an
        // orphaned document behind after a migration.
        try database.write { db in
            guard try db.tableExists("loopr_product_document") else { return }
            try db.execute(sql: "DELETE FROM loopr_product_document")
        }
    }
}

nonisolated struct PersistentDataDeletionFailure: Codable, Equatable, Sendable {
    let storeName: String
    let reason: String
}

nonisolated struct PersistentDataDeletionReceipt: Codable, Equatable, Sendable {
    let clearedStores: [String]
    let failures: [PersistentDataDeletionFailure]

    var isComplete: Bool { failures.isEmpty }
}

nonisolated struct PersistentDataDeletionError: Error, Equatable, Sendable, LocalizedError {
    let receipt: PersistentDataDeletionReceipt

    static func unavailableExternalStore(_ name: String) -> Self {
        Self(receipt: PersistentDataDeletionReceipt(
            clearedStores: [],
            failures: [PersistentDataDeletionFailure(storeName: name, reason: "No concrete deletion adapter is configured.")]
        ))
    }

    var errorDescription: String? {
        "Loopr deleted \(receipt.clearedStores.count) local stores, but \(receipt.failures.count) store(s) could not be confirmed."
    }
}

struct NamedProductStore: Sendable {
    let name: String
    let store: StorageDocumentStore
}

actor PersistentOnboardingRepository: OnboardingRepository {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> OnboardingSnapshot? {
        guard let data = defaults.data(forKey: ProductRepositoryKeys.onboarding) else { return nil }
        return try JSONDecoder().decode(OnboardingSnapshot.self, from: data)
    }

    func save(_ snapshot: OnboardingSnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: ProductRepositoryKeys.onboarding)
    }

    func clear() { defaults.removeObject(forKey: ProductRepositoryKeys.onboarding) }
}

actor PersistentProfileRepository: ProfileRepository, GoalsRepository {
    private let defaults: UserDefaults
    private let dateProvider: any DateProviding
    private let uuidProvider: any UUIDProviding

    init(
        defaults: UserDefaults = .standard,
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        self.defaults = defaults
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
    }

    func readProfile() throws -> Profile? { try load().profile }

    func saveProfile(_ draft: ProfileDraft) async throws -> Profile {
        let current = try load()
        let now = dateProvider.now()
        let id = if let existing = current.profile?.id { existing } else { await uuidProvider.nextUUID() }
        let profile = try ProfileValidator.makeProfile(
            from: draft,
            id: id,
            now: now
        )
        let value = Profile(
            id: profile.id,
            displayName: profile.displayName,
            birthYear: profile.birthYear,
            biologicalSex: profile.biologicalSex,
            heightCentimeters: profile.heightCentimeters,
            weightKilograms: profile.weightKilograms,
            timezoneIdentifier: profile.timezoneIdentifier,
            unitSystem: profile.unitSystem,
            createdAt: current.profile?.createdAt ?? now,
            updatedAt: now
        )
        try persist(ProfileStoreSnapshot(schemaVersion: ProfileSchemaMigration.currentVersion, profile: value, goals: current.goals))
        return value
    }

    func resetProfile() throws { try persist(ProfileStoreSnapshot(schemaVersion: ProfileSchemaMigration.currentVersion, profile: nil, goals: [])) }
    func deleteAllData() throws { defaults.removeObject(forKey: ProductRepositoryKeys.profile) }
    func exportSnapshot() throws -> ProfileStoreSnapshot { try load() }
    func restoreSnapshot(_ snapshot: ProfileStoreSnapshot) throws { try persist(ProfileSchemaMigration.migrate(snapshot)) }
    func readGoals() throws -> [Goal] { try load().goals.sorted { $0.type.rawValue < $1.type.rawValue } }

    func saveGoal(type: GoalType, target: Double, unit: String, isEnabled: Bool) async throws -> Goal {
        try GoalValidator.validate(target: target, unit: unit)
        var snapshot = try load()
        let goal = Goal(id: await uuidProvider.nextUUID(), type: type, target: target, unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), isEnabled: isEnabled, updatedAt: dateProvider.now())
        let goals = snapshot.goals.filter { $0.type != type } + [goal]
        snapshot = ProfileStoreSnapshot(schemaVersion: ProfileSchemaMigration.currentVersion, profile: snapshot.profile, goals: goals)
        try persist(snapshot)
        return goal
    }

    func deleteGoals() throws {
        let snapshot = try load()
        try persist(ProfileStoreSnapshot(schemaVersion: ProfileSchemaMigration.currentVersion, profile: snapshot.profile, goals: []))
    }

    private func load() throws -> ProfileStoreSnapshot {
        guard let data = defaults.data(forKey: ProductRepositoryKeys.profile) else {
            return ProfileStoreSnapshot(schemaVersion: ProfileSchemaMigration.currentVersion, profile: nil, goals: [])
        }
        return try ProfileSchemaMigration.migrate(JSONDecoder().decode(ProfileStoreSnapshot.self, from: data))
    }

    private func persist(_ snapshot: ProfileStoreSnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: ProductRepositoryKeys.profile)
    }
}

private nonisolated struct PersistentDeviceSnapshot: Codable {
    var identity: DeviceIdentity? = nil
    var status: DeviceStatusSnapshot? = nil
}

actor PersistentDeviceCenterRepository: DeviceCenterRepository {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func readIdentity() throws -> DeviceIdentity? { try load().identity }
    func readStatus() throws -> DeviceStatusSnapshot? { try load().status }
    func saveIdentity(_ identity: DeviceIdentity) throws { var value = try load(); value.identity = identity; try persist(value) }
    func saveStatus(_ status: DeviceStatusSnapshot) throws { var value = try load(); value.status = status; try persist(value) }
    func forgetBand() { defaults.removeObject(forKey: ProductRepositoryKeys.device) }
    func deprovision() { defaults.removeObject(forKey: ProductRepositoryKeys.device) }

    private func load() throws -> PersistentDeviceSnapshot {
        guard let data = defaults.data(forKey: ProductRepositoryKeys.device) else { return PersistentDeviceSnapshot() }
        return try JSONDecoder().decode(PersistentDeviceSnapshot.self, from: data)
    }

    private func persist(_ snapshot: PersistentDeviceSnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: ProductRepositoryKeys.device)
    }
}

// MARK: - Production Storage Composition

/// These adapters are deliberately app-composed.  Feature packages define
/// their repository seams and value types; the app owns the one concrete
/// StorageKit database and injects it into every product slice.  DEBUG launch
/// modes continue to use the package fixture actors in ProductFeatureRoots.

actor SQLiteOnboardingRepository: OnboardingRepository {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "onboarding")
    }

    func load() throws -> OnboardingSnapshot? { try store.read(OnboardingSnapshot.self, key: "snapshot") }
    func save(_ snapshot: OnboardingSnapshot) throws { try store.write(snapshot, key: "snapshot") }
    func clear() throws { try store.remove(key: "snapshot") }
    func removeAll() throws { try store.removeAll() }
}

actor SQLiteDeviceCenterRepository: DeviceCenterRepository, StrapAlarmConfigurationRepository {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "device-center")
    }

    func readIdentity() throws -> DeviceIdentity? { try store.read(DeviceIdentity.self, key: "identity") }
    func readStatus() throws -> DeviceStatusSnapshot? { try store.read(DeviceStatusSnapshot.self, key: "status") }
    func saveIdentity(_ identity: DeviceIdentity) throws { try store.write(identity, key: "identity") }
    func saveStatus(_ status: DeviceStatusSnapshot) throws { try store.write(status, key: "status") }
    func readAlarmConfiguration() throws -> StrapAlarmConfiguration? { try store.read(StrapAlarmConfiguration.self, key: "alarm") }
    func saveAlarmConfiguration(_ configuration: StrapAlarmConfiguration) throws { try store.write(configuration.validated(), key: "alarm") }
    func forgetBand() throws { try store.removeAll() }
    func deprovision() throws { try store.removeAll() }
}

/// A bounded rolling log of band battery readings. The runtime reports only
/// the current percentage, so without this the drain forecast has no history
/// to fit a rate to.
///
/// Charging is reported by band events. A command-only battery reading keeps
/// charging unknown. Old samples with assumed discharging are not reused.
actor SQLiteBatterySampleLog: LooprBatterySampleLog {
    /// One reading every five minutes is enough for a rate over hours and
    /// keeps a day of history in a few hundred bytes.
    static let minimumIntervalSeconds: TimeInterval = 5 * 60
    static let retentionSeconds: TimeInterval = 48 * 60 * 60
    static let maximumSamples = 600

    private let store: StorageDocumentStore
    private let key = "battery-samples-v2"

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "device-center")
    }

    func samples(through now: Date) -> [BatterySample] {
        let second = Int(now.timeIntervalSince1970.rounded(.down))
        return stored().filter { $0.tsSec <= second }
    }

    func record(percent: Double, charging: Bool?, at date: Date) {
        guard percent.isFinite, (0...100).contains(percent) else { return }
        var values = stored()
        let second = Int(date.timeIntervalSince1970.rounded(.down))
        if let last = values.last {
            guard Double(second - last.tsSec) >= Self.minimumIntervalSeconds || last.pct != percent || last.charging != charging else { return }
            guard second > last.tsSec else { return }
        }
        values.append(BatterySample(tsSec: second, pct: percent, charging: charging))
        let oldest = second - Int(Self.retentionSeconds)
        values = values.filter { $0.tsSec >= oldest }.suffix(Self.maximumSamples).map { $0 }
        try? store.write(values, key: key)
    }

    private func stored() -> [BatterySample] {
        ((try? store.read([BatterySample].self, key: key)) ?? []).sorted { $0.tsSec < $1.tsSec }
    }
}

actor SQLiteTodayRepository: TodayRepository, TodayGoalsRepository, TodayCoachPlanRepository {
    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?

    init(database: StorageDatabase, analytics: CanonicalDailyAnalytics? = nil) throws {
        self.analytics = analytics
        store = try StorageDocumentStore(database: database, namespace: "today")
    }

    func readSummary(for day: DayIdentity) async throws -> TodaySummary? {
        if let analytics, let display = try await analytics.readDisplay(day: day) {
            return display.today
        }
        return try store.read(TodaySummary.self, key: "summary.\(Self.key(day))")
    }

    func readGoals(for day: DayIdentity) throws -> [TodayGoalProgress] {
        try store.read([TodayGoalProgress].self, key: "goals.\(Self.key(day))") ?? []
    }

    func readPlan(for day: DayIdentity) throws -> TodayCoachPlanSummary? {
        try store.read(TodayCoachPlanSummary.self, key: "coach.\(Self.key(day))")
    }

    func saveSummary(_ summary: TodaySummary) throws {
        try store.write(summary, key: "summary.\(Self.key(summary.day))")
    }

    func saveGoals(_ goals: [TodayGoalProgress], for day: DayIdentity) throws {
        try store.write(goals, key: "goals.\(Self.key(day))")
    }

    func savePlan(_ plan: TodayCoachPlanSummary, for day: DayIdentity) throws {
        try store.write(plan, key: "coach.\(Self.key(day))")
    }

    func removeAll() throws { try store.removeAll() }

    private static func key(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }
}

/// Joins the canonical ProfileKit goal configuration with the already
/// derived Today progress. It only changes the configured target/label and
/// leaves values and progress absent while ANA-08 recomputes; no metric math
/// is performed in this adapter.
actor ProfileBackedTodayGoalsRepository: TodayGoalsRepository {
    private let today: any TodayGoalsRepository
    private let profile: any GoalsRepository

    init(today: any TodayGoalsRepository, profile: any GoalsRepository) {
        self.today = today
        self.profile = profile
    }

    func readGoals(for day: DayIdentity) async throws -> [TodayGoalProgress] {
        var progress = try await today.readGoals(for: day)
        let configured = try await profile.readGoals().filter(\.isEnabled)
        // Older projections may carry a sleep target that is no longer the
        // saved personal need. The canonical profile goal is the only source.
        progress.removeAll { $0.id == "sleep" }
        let summary = try await (today as? any TodayRepository)?.readSummary(for: day)
        for goal in configured {
            let id = goal.type.rawValue
            let target = displayTarget(goal.target)
            let title = displayTitle(goal.type)
            let unit = goal.unit
            let metricID: TodayMetricID? = switch goal.type {
            case .recovery: .recovery
            case .sleep: .sleep
            case .strain: .strain
            case .steps: .steps
            case .workouts: nil
            }
            if let metricID, let metric = summary?.metric(metricID), let numeric = metric.numericValue {
                let normalizedUnit = unit.lowercased()
                let value: Double? = switch goal.type {
                case .sleep: ["h", "hours", "hour"].contains(normalizedUnit) ? numeric / 60 : ["min", "minutes"].contains(normalizedUnit) ? numeric : nil
                case .steps: ["steps", "count"].contains(normalizedUnit) ? numeric : nil
                case .strain: ["strain", "points", "/21"].contains(normalizedUnit) ? numeric : nil
                case .recovery: ["%", "percent", "points"].contains(normalizedUnit) ? numeric : nil
                case .workouts: nil
                }
                if let value, goal.target > 0 {
                    progress.removeAll { $0.id == id }
                    progress.append(TodayGoalProgress(id: id, title: title, value: displayTarget(value), target: target,
                        unit: unit, state: metric.state, progressFraction: min(1, max(0, value / goal.target))))
                    continue
                }
            }
            if let index = progress.firstIndex(where: { $0.id == id || $0.title.localizedCaseInsensitiveContains(title) }) {
                let current = progress[index]
                progress[index] = TodayGoalProgress(
                    id: current.id,
                    title: title,
                    value: current.value,
                    target: target,
                    unit: unit,
                    state: current.target == target ? current.state : .settling,
                    progressFraction: current.target == target ? current.progressFraction : nil
                )
            } else {
                progress.append(TodayGoalProgress(
                    id: id,
                    title: title,
                    value: nil,
                    target: target,
                    unit: unit,
                    state: .settling,
                    progressFraction: nil
                ))
            }
        }
        return progress
    }

    private func displayTitle(_ type: GoalType) -> String {
        switch type {
        case .recovery: "Recovery"
        case .sleep: "Sleep"
        case .strain: "Strain"
        case .steps: "Estimated steps"
        case .workouts: "Workouts"
        }
    }

    private func displayTarget(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

actor SQLiteCoachRepository: CoachInputRepository, CoachRecommendationHistoryRepository, TodayCoachPlanRepository {
    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?
    /// The evidence the saved plan was built from, per day. Today reloads every
    /// few seconds while history lands, and re-running the rule engine over
    /// identical evidence only rewrote two documents to say the same thing.
    private var evaluatedEvidence: [DayIdentity: [CoachEvidence]] = [:]

    init(database: StorageDatabase, analytics: CanonicalDailyAnalytics? = nil) throws {
        self.analytics = analytics
        store = try StorageDocumentStore(database: database, namespace: "coach")
    }

    func readInput(for day: DayIdentity) async throws -> CoachInput? {
        if let analytics, let input = try await analytics.readCoachInput(day: day) { return input }
        return try store.read(CoachInput.self, key: "input.\(Self.key(day))")
    }

    func saveInput(_ input: CoachInput) throws {
        try store.write(input, key: "input.\(Self.key(input.day))")
    }

    func save(_ decision: CoachDecision, for day: DayIdentity) async throws {
        if let analytics { try await analytics.saveCoachDecision(decision, day: day); return }
        try store.write(decision, key: "decision.\(Self.key(day))")
        if let plan = decision.plan {
            try store.write(plan.summary, key: "plan.\(Self.key(day))")
        } else if case .abstain(let abstention) = decision {
            let summary = TodayCoachPlanSummary(
                title: "No plan yet",
                detail: abstention.reason,
                recommendationCount: 0,
                evidenceSummary: abstention.missingEvidence.map(\.rawValue).joined(separator: ", "),
                state: .absent
            )
            try store.write(summary, key: "plan.\(Self.key(day))")
        }
    }

    func read(for day: DayIdentity) throws -> CoachDecision? {
        try store.read(CoachDecision.self, key: "decision.\(Self.key(day))")
    }

    func readRecent(limit: Int) throws -> [CoachDecision] {
        guard limit > 0 else { return [] }
        return try store.keys()
            .filter { $0.hasPrefix("decision.") }
            .sorted(by: >)
            .prefix(limit)
            .compactMap { try store.read(CoachDecision.self, key: $0) }
    }

    func deleteAll() throws {
        evaluatedEvidence.removeAll()
        try store.removeAll()
    }

    func readPlan(for day: DayIdentity) async throws -> TodayCoachPlanSummary? {
        if let analytics, let input = try await analytics.readCoachInput(day: day),
           evaluatedEvidence[day] != input.evidence {
            let decision = CoachRuleEngine().evaluate(input)
            try await save(decision, for: day)
            evaluatedEvidence[day] = input.evidence
        }
        return try store.read(TodayCoachPlanSummary.self, key: "plan.\(Self.key(day))")
    }

    private static func key(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }
}

actor SQLiteSleepRepository: SleepRepository, SleepCorrectionRepository {
    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?

    init(database: StorageDatabase, analytics: CanonicalDailyAnalytics? = nil) throws {
        self.analytics = analytics
        store = try StorageDocumentStore(database: database, namespace: "sleep")
    }

    func readSleepDay(for day: DayIdentity) async throws -> SleepDaySnapshot? {
        if let analytics, let display = try await analytics.readDisplay(day: day) { return display.projection.sleep }
        return try store.read(SleepDaySnapshot.self, key: "day.\(Self.key(day))")
    }

    func save(_ snapshot: SleepDaySnapshot) throws {
        try store.write(snapshot, key: "day.\(Self.key(snapshot.day))")
    }

    func append(_ correction: SleepCorrection) throws {
        var values = try store.read([SleepCorrection].self, key: "corrections.\(Self.key(correction.day))") ?? []
        values.append(correction)
        try store.write(values, key: "corrections.\(Self.key(correction.day))")
    }

    func history(for day: DayIdentity) throws -> [SleepCorrection] {
        try store.read([SleepCorrection].self, key: "corrections.\(Self.key(day))") ?? []
    }

    func deleteAll() throws { try store.removeAll() }

    private static func key(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }
}

actor SQLiteHeartRepository: HeartRepository, HeartSpotCheckRepository {
    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?

    init(database: StorageDatabase, analytics: CanonicalDailyAnalytics? = nil) throws {
        self.analytics = analytics
        store = try StorageDocumentStore(database: database, namespace: "heart")
    }

    func readHeartDay(for day: DayIdentity) async throws -> HeartDaySnapshot? {
        if let analytics, let display = try await analytics.readDisplay(day: day) { return display.projection.heart }
        return try store.read(HeartDaySnapshot.self, key: "day.\(Self.key(day))")
    }

    func save(_ snapshot: HeartDaySnapshot) throws {
        try store.write(snapshot, key: "day.\(Self.key(snapshot.day))")
    }

    func runSpotCheck() throws -> HeartSpotCheckResult {
        try store.read(HeartSpotCheckResult.self, key: "spot-check") ?? HeartSpotCheckResult(state: .absent, heartRateBPM: nil, rmssdMilliseconds: nil, sdnnMilliseconds: nil, durationSeconds: 0, source: "BLE-07.spot-check")
    }

    func saveSpotCheck(_ result: HeartSpotCheckResult) async throws {
        try store.write(result, key: "spot-check")
    }

    func deleteAll() throws { try store.removeAll() }

    private static func key(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }
}

actor SQLiteBodyRepository: BodyRepository {
    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?

    init(database: StorageDatabase, analytics: CanonicalDailyAnalytics? = nil) throws {
        self.analytics = analytics
        store = try StorageDocumentStore(database: database, namespace: "body")
    }

    func readBodyDay(for day: DayIdentity) async throws -> BodyDaySnapshot? {
        if let analytics, let display = try await analytics.readDisplay(day: day) { return display.projection.body }
        return try store.read(BodyDaySnapshot.self, key: "day.\(Self.key(day))")
    }

    func save(_ snapshot: BodyDaySnapshot) throws {
        try store.write(snapshot, key: "day.\(Self.key(snapshot.day))")
    }

    func deleteAll() throws { try store.removeAll() }

    private static func key(_ day: DayIdentity) -> String {
        "\(day.era)-\(day.year)-\(day.month)-\(day.day)"
    }
}

actor SQLiteSettingsRepository: SettingsRepository {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "settings")
    }

    func snapshot() -> SettingsSnapshot {
        (try? store.read(SettingsSnapshot.self, key: "snapshot")) ?? SettingsSnapshot()
    }

    func update(_ snapshot: SettingsSnapshot) throws {
        if let goal = snapshot.goals.stepGoal, goal <= 0 { throw SettingsError.invalidGoal }
        if let age = snapshot.profile.age, !(0...130).contains(age) { throw SettingsError.invalidProfile }
        try store.write(snapshot, key: "snapshot")
    }

    func resetProfile() async {
        var value = snapshot()
        value.profile = ProfileSettings()
        value.goals = GoalSettings()
        try? store.write(value, key: "snapshot")
    }

    func resetAll() async { try? store.removeAll() }
    func resetProfileChecked() throws {
        var value = try store.read(SettingsSnapshot.self, key: "snapshot") ?? SettingsSnapshot()
        value.profile = ProfileSettings()
        value.goals = GoalSettings()
        try store.write(value, key: "snapshot")
    }

    func resetAllChecked() throws { try store.removeAll() }
    func deleteAll() throws { try store.removeAll() }
}

actor SQLiteDataRepository: CheckedDataStore {
    private let store: StorageDocumentStore
    private let healthSampleDeletionClient: (any HealthSampleDeletionClient)?

    init(
        database: StorageDatabase,
        healthSampleDeletionClient: (any HealthSampleDeletionClient)? = nil
    ) throws {
        store = try StorageDocumentStore(database: database, namespace: "data")
        self.healthSampleDeletionClient = healthSampleDeletionClient
    }

    func records() -> [DataRecord] {
        (try? store.read(DataBackup.self, key: "records"))?.records ?? []
    }

    func recordsChecked() throws -> [DataRecord] {
        try store.read(DataBackup.self, key: "records")?.records ?? []
    }

    func insert(_ record: DataRecord) throws {
        guard Self.isValidDay(record.day) else { throw DataError.invalidDay }
        var values = Dictionary(uniqueKeysWithValues: records().map { ($0.id, $0) })
        values[record.id] = record
        try saveRecords(values.values)
    }

    func exportBackup() -> DataBackup { DataBackup(records: records()) }

    func exportBackupChecked() throws -> DataBackup { DataBackup(records: try recordsChecked()) }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(exportBackup())
    }

    func exportJSONChecked() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try exportBackupChecked())
    }

    func validatedPreviewChecked(source: ImportSource, incoming: [DataRecord]) throws -> ImportPreview {
        try Self.validateImport(source: source, incoming: incoming)
        let existing = Dictionary(uniqueKeysWithValues: try recordsChecked().map { ($0.id, $0) })
        var additions: [DataRecord] = []
        var updates: [DataRecord] = []
        var conflicts: [ImportConflict] = []
        for record in incoming {
            let normalized = Self.withProvenance(record, source: source)
            guard let current = existing[record.id] else {
                additions.append(normalized)
                continue
            }
            if current == normalized { continue }
            if current.provenance == .looprComputed && normalized.provenance != .looprComputed {
                conflicts.append(ImportConflict(recordID: record.id, existing: current, incoming: normalized))
            } else {
                updates.append(normalized)
            }
        }
        return ImportPreview(source: source, additions: additions, updates: updates, conflicts: conflicts)
    }

    func restoreChecked(_ backup: DataBackup) throws {
        guard backup.schemaVersion == 1 else { throw DataError.invalidBackup }
        try saveRecords(backup.records)
    }

    func preview(source: ImportSource, incoming: [DataRecord]) -> ImportPreview {
        var additions: [DataRecord] = []
        var updates: [DataRecord] = []
        var conflicts: [ImportConflict] = []
        let existing = Dictionary(uniqueKeysWithValues: records().map { ($0.id, $0) })
        for record in incoming {
            let normalized = Self.withProvenance(record, source: source)
            guard let current = existing[record.id] else {
                additions.append(normalized)
                continue
            }
            if current == normalized { continue }
            if current.provenance == .looprComputed && normalized.provenance != .looprComputed {
                conflicts.append(ImportConflict(recordID: record.id, existing: current, incoming: normalized))
            } else {
                updates.append(normalized)
            }
        }
        return ImportPreview(source: source, additions: additions, updates: updates, conflicts: conflicts)
    }

    func validatedPreview(source: ImportSource, incoming: [DataRecord]) throws -> ImportPreview {
        try Self.validateImport(source: source, incoming: incoming)
        return preview(source: source, incoming: incoming)
    }

    func beginImport(_ preview: ImportPreview) throws -> ImportReceipt {
        guard preview.conflicts.isEmpty else { throw DataError.conflictRequiresResolution }
        let receipt = ImportReceipt(preview: preview)
        try store.write(try exportBackupChecked(), key: "receipt.\(receipt.token.uuidString)")
        var values = Dictionary(uniqueKeysWithValues: try recordsChecked().map { ($0.id, $0) })
        for record in preview.additions + preview.updates { values[record.id] = record }
        try saveRecords(values.values)
        return receipt
    }

    func rollback(_ receipt: ImportReceipt) throws {
        guard let backup = try store.read(DataBackup.self, key: "receipt.\(receipt.token.uuidString)") else {
            throw DataError.unknownReceipt
        }
        try saveRecords(backup.records)
        try store.remove(key: "receipt.\(receipt.token.uuidString)")
    }

    func restore(_ backup: DataBackup) throws {
        guard backup.schemaVersion == 1 else { throw DataError.invalidBackup }
        try saveRecords(backup.records)
    }

    func exportDay(_ day: String) -> DataBackup {
        DataBackup(records: records().filter { $0.day == day })
    }

    func exportDayChecked(_ day: String) throws -> DataBackup {
        DataBackup(records: try recordsChecked().filter { $0.day == day })
    }

    func deleteDay(_ day: String) {
        try? deleteDayChecked(day)
    }

    func deleteDayChecked(_ day: String) throws {
        let values = try recordsChecked().filter { $0.day != day }
        try saveRecords(values)
        let statuses = try store.read([ReanalysisStatus].self, key: "reanalysis") ?? []
        try store.write(statuses.filter { $0.day != day }, key: "reanalysis")
    }

    func reanalyze(day: String, algorithmVersion: Int) async -> ReanalysisStatus {
        (try? await reanalyzeChecked(day: day, algorithmVersion: algorithmVersion))
            ?? ReanalysisStatus(day: day, algorithmVersion: algorithmVersion, state: "failed")
    }

    func reanalyzeChecked(day: String, algorithmVersion: Int) async throws -> ReanalysisStatus {
        var values = try await recordsChecked()
        for index in values.indices where values[index].day == day {
            values[index].algorithmVersion = algorithmVersion
        }
        try saveRecords(values)
        let status = ReanalysisStatus(day: day, algorithmVersion: algorithmVersion, state: "completed")
        var statuses = try store.read([ReanalysisStatus].self, key: "reanalysis") ?? []
        statuses.removeAll { $0.day == day }
        statuses.append(status)
        try store.write(statuses, key: "reanalysis")
        return status
    }

    func reanalyzeAll(algorithmVersion: Int) async -> [ReanalysisStatus] {
        (try? await reanalyzeAllChecked(algorithmVersion: algorithmVersion)) ?? []
    }

    func reanalyzeAllChecked(algorithmVersion: Int) async throws -> [ReanalysisStatus] {
        var values = try await recordsChecked()
        for index in values.indices { values[index].algorithmVersion = algorithmVersion }
        try saveRecords(values)
        let statuses = Array(Set(values.map(\.day))).sorted().map {
            ReanalysisStatus(day: $0, algorithmVersion: algorithmVersion, state: "completed")
        }
        try store.write(statuses, key: "reanalysis")
        return statuses
    }

    func reanalysisStatus() -> [ReanalysisStatus] {
        ((try? store.read([ReanalysisStatus].self, key: "reanalysis")) ?? []).sorted { $0.day < $1.day }
    }

    func reanalysisStatusChecked() throws -> [ReanalysisStatus] {
        try (store.read([ReanalysisStatus].self, key: "reanalysis") ?? []).sorted { $0.day < $1.day }
    }

    func setInventory(_ value: DataStoreInventory) async {
        try? await setInventoryChecked(value)
    }

    func setInventoryChecked(_ value: DataStoreInventory) async throws {
        var updated = value
        updated.sqliteRows = records().count
        try store.write(updated, key: "inventory")
    }

    func inventorySnapshot() -> DataStoreInventory {
        var value = (try? store.read(DataStoreInventory.self, key: "inventory")) ?? DataStoreInventory()
        value.sqliteRows = records().count
        return value
    }

    func inventorySnapshotChecked() throws -> DataStoreInventory {
        var value = try store.read(DataStoreInventory.self, key: "inventory") ?? DataStoreInventory()
        value.sqliteRows = try recordsChecked().count
        return value
    }

    func completeDeletion() async {
        try? await completeDeletionChecked()
    }

    func completeDeletionChecked() async throws {
        try store.removeAll()
    }

    /// Set when the non-throwing `removeHealthKitSamples()` fails, so the
    /// deletion summary can tell a failed Health wipe from a clean one.
    private(set) var lastHealthKitRemovalFailure: String?

    func removeHealthKitSamples() async {
        do {
            _ = try await removeHealthKitSamplesReportingCount()
        } catch {
            lastHealthKitRemovalFailure = String(describing: error)
        }
    }

    func removeHealthKitSamplesChecked() async throws {
        _ = try await removeHealthKitSamplesReportingCount()
    }

    /// Returns the number of samples Health actually removed, so the caller can
    /// report a real number instead of assuming the store is now empty.
    @discardableResult
    func removeHealthKitSamplesReportingCount() async throws -> Int {
        guard let healthSampleDeletionClient else {
            throw DataError.healthKitUnavailable
        }
        let removed = try await healthSampleDeletionClient.deleteLooprCreatedSamples()
        var value = try await inventorySnapshotChecked()
        value.healthKitSamples = 0
        try store.write(value, key: "inventory")
        lastHealthKitRemovalFailure = nil
        return removed
    }

    func setLegacyMigrationAvailable() async {
        try? store.write(LegacyMigrationState.ready, key: "legacy-state")
    }

    func legacyMigrationState() async -> LegacyMigrationState {
        (try? store.read(LegacyMigrationState.self, key: "legacy-state")) ?? .notAvailable
    }

    func runLegacyMigration(records imported: [DataRecord]) throws -> [DataRecord] {
        let state = awaitState()
        guard state == .ready else {
            if state == .completed { throw DataError.alreadyMigrated }
            throw DataError.legacyUnavailable
        }
        try Self.validateImport(source: .legacyCloud, incoming: imported)
        let migrated = imported.map { Self.withProvenance($0, source: .legacyCloud) }
        var values = Dictionary(uniqueKeysWithValues: records().map { ($0.id, $0) })
        for value in migrated { values[value.id] = value }
        try saveRecords(values.values)
        try store.write(LegacyMigrationState.completed, key: "legacy-state")
        return migrated
    }

    func diagnostics(capture: String = "unknown", storage: String = "ready", frame: String = "ready", compute: String = "idle") -> DiagnosticSnapshot {
        DiagnosticSnapshot(capture: capture, storage: storage, frame: frame, compute: compute, reanalysis: reanalysisStatus())
    }

    private func saveRecords<S: Sequence>(_ values: S) throws where S.Element == DataRecord {
        try store.write(DataBackup(records: Array(values)), key: "records")
    }

    private func awaitState() -> LegacyMigrationState {
        (try? store.read(LegacyMigrationState.self, key: "legacy-state")) ?? .notAvailable
    }

    private static func withProvenance(_ record: DataRecord, source: ImportSource) -> DataRecord {
        var result = record
        result.provenance = switch source {
        case .looprBackup: .looprComputed
        case .edgeMerge: .edgeMerged
        case .whoopCSV: .whoopCSV
        case .noopRaw: .noopRaw
        case .legacyCloud: .imported
        }
        if result.provenance != .looprComputed { result.algorithmVersion = nil }
        return result
    }

    private static func validateImport(source: ImportSource, incoming: [DataRecord]) throws {
        guard !incoming.isEmpty else { throw DataError.invalidImport }
        for row in incoming {
            guard isValidDay(row.day) else { throw DataError.invalidDay }
            if source == .noopRaw && row.payload.isEmpty { throw DataError.invalidImport }
        }
    }

    private static func isValidDay(_ day: String) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == pieces[0] && components.month == pieces[1] && components.day == pieces[2]
    }
}

actor SQLiteJournalRepository: JournalStore {
    private let store: StorageDocumentStore
    private let accountImport: WHOOPImportStore?
    private var reviewedProposals: Set<JournalProposal> = []
    /// Set when the non-throwing `deleteAll()` fails, so a caller that wiped the
    /// journal before restoring an archive can tell a failed wipe from a clean one.
    private(set) var lastDeleteAllFailure: String?

    init(database: StorageDatabase, accountImport: WHOOPImportStore? = nil) throws {
        self.accountImport = accountImport
        store = try StorageDocumentStore(database: database, namespace: "journal")
    }

    func save(_ entry: JournalEntry) throws -> JournalEntry {
        guard !entry.day.isEmpty else { throw JournalError.emptyDay }
        try store.write(entry, key: "entry.\(entry.id.uuidString)")
        return entry
    }

    func create(day: String, behaviors: Set<String> = [], tags: Set<String> = [], note: String? = nil, id: UUID? = nil, now: Date = Date()) throws -> JournalEntry {
        try save(JournalEntry(id: id ?? UUID(), day: day, behaviors: behaviors, tags: tags, note: note, createdAt: now))
    }

    func edit(id: UUID, behaviors: Set<String>? = nil, tags: Set<String>? = nil, note: String?? = nil, now: Date = Date()) throws -> JournalEntry {
        guard var entry = entry(id: id) else { throw JournalError.missingEntry }
        if let behaviors { entry.behaviors = behaviors }
        if let tags { entry.tags = tags }
        if let note { entry.note = note }
        entry.updatedAt = now
        return try save(entry)
    }

    func entry(id: UUID) -> JournalEntry? {
        (try? store.read(JournalEntry.self, key: "entry.\(id.uuidString)")) ?? (try? accountImport?.journals().first { $0.id == id })
    }

    func history(descending: Bool = true) -> [JournalEntry] {
        let values = (try? store.keys().filter { $0.hasPrefix("entry.") }.compactMap { try store.read(JournalEntry.self, key: $0) }) ?? []
        let merged = WHOOPImportResolution.journals(native: values, imported: (try? accountImport?.journals()) ?? [])
        return merged.sorted {
            let lhs = ($0.day, $0.updatedAt)
            let rhs = ($1.day, $1.updatedAt)
            return descending ? lhs > rhs : lhs < rhs
        }
    }

    func search(_ query: JournalSearchQuery) -> [JournalEntry] {
        let needle = query.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history().filter { entry in
            if let day = query.day, entry.day != day { return false }
            if let tag = query.tag, !entry.tags.contains(tag) && !entry.behaviors.contains(tag) { return false }
            if let needle, !needle.isEmpty {
                let haystack = ([entry.day] + Array(entry.tags) + Array(entry.behaviors) + [entry.note ?? ""]).joined(separator: " ").lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    func delete(id: UUID) throws {
        guard entry(id: id) != nil else { throw JournalError.missingEntry }
        try store.remove(key: "entry.\(id.uuidString)")
        try accountImport?.removeJournal(id: id)
    }

    func export(includeContent: Bool) -> JournalExport {
        let values = history(descending: false)
        let output = includeContent ? values : values.map {
            JournalEntry(id: $0.id, day: $0.day, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        return JournalExport(entries: output, includesJournalContent: includeContent)
    }

    func approve(_ proposal: JournalProposal) async {
        reviewedProposals.insert(proposal)
    }

    func saveProposal(_ proposal: JournalProposal, accepted: Bool, now: Date = Date()) throws -> JournalEntry? {
        guard accepted else { return nil }
        guard reviewedProposals.contains(proposal) else { throw JournalError.proposalNotReviewed }
        return try create(day: proposal.day, tags: proposal.tags, note: proposal.note, now: now)
    }

    func redactedSnapshot() -> JournalPrivacyPayload { JournalPrivacyPayload() }

    /// Throwing counterpart of `deleteAll()`. Use it wherever a failed wipe must
    /// stop the caller, such as before restoring an archive over the journal.
    func deleteAllChecked() throws {
        try store.removeAll()
        try accountImport?.deleteJournals()
        lastDeleteAllFailure = nil
    }

    func deleteAll() async {
        do {
            try deleteAllChecked()
        } catch {
            lastDeleteAllFailure = String(describing: error)
        }
    }
}

actor SQLiteHabitRepository: HabitStore {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "journal")
    }

    func definitions(includeArchived: Bool = true) throws -> [HabitDefinition] {
        try keys(withPrefix: "habit.definition.")
            .compactMap { try store.read(HabitDefinition.self, key: $0) }
            .filter { includeArchived || !$0.isArchived }
            .sorted {
                if $0.isArchived != $1.isArchived { return !$0.isArchived }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.id < $1.id
            }
    }

    func definition(id: HabitID) throws -> HabitDefinition? {
        try store.read(HabitDefinition.self, key: definitionKey(id))
    }

    func saveDefinition(_ definition: HabitDefinition) throws {
        try HabitStoreValidator.validate(definition: definition, existing: definitions())
        try store.write(definition, key: definitionKey(definition.id))
    }

    func setArchived(_ archived: Bool, habitID: HabitID, at date: Date) throws {
        guard var definition = try definition(id: habitID) else { throw HabitStoreError.missingHabit }
        if !archived && definition.isArchived {
            guard try definitions(includeArchived: false).count < HabitStoreValidator.activeLimit else {
                throw HabitStoreError.activeLimitReached
            }
        }
        definition.archivedAt = archived ? date : nil
        definition.updatedAt = date
        try store.write(definition, key: definitionKey(habitID))
    }

    func deleteHabit(id: HabitID) throws {
        guard try definition(id: id) != nil else { throw HabitStoreError.missingHabit }
        var mutations: [StorageDocumentMutation] = [
            .remove(key: definitionKey(id)),
            .remove(key: insightKey(id)),
            .remove(key: "habit.today-selection"),
            .remove(key: "habit.reminder.\(id.rawValue.uuidString.lowercased())")
        ]
        for key in try keys(withPrefix: "habit.day.") {
            guard var record = try store.read(HabitDayRecord.self, key: key) else { continue }
            let oldCount = record.responses.count
            record.responses.removeAll { $0.habitID == id }
            guard record.responses.count != oldCount else { continue }
            mutations.append(try .write(record, key: key))
        }
        try store.mutate(mutations)
    }

    func dayRecord(for day: DayIdentity) throws -> HabitDayRecord? {
        try store.read(HabitDayRecord.self, key: dayKey(day))
    }

    func dayRecords() throws -> [HabitDayRecord] {
        try keys(withPrefix: "habit.day.")
            .compactMap { try store.read(HabitDayRecord.self, key: $0) }
            .sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    func saveDayRecord(_ record: HabitDayRecord) throws {
        let definitionsByID = Dictionary(uniqueKeysWithValues: try definitions().map { ($0.id, $0) })
        try HabitStoreValidator.validate(record: record, definitions: definitionsByID)
        try store.write(record, key: dayKey(record.behaviorDay))
    }

    func outcome(for day: DayIdentity) throws -> HabitOutcomeSnapshot? {
        try store.read(HabitOutcomeSnapshot.self, key: outcomeKey(day))
    }

    func outcomes() throws -> [HabitOutcomeSnapshot] {
        try keys(withPrefix: "habit.outcome.")
            .compactMap { try store.read(HabitOutcomeSnapshot.self, key: $0) }
            .sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    func saveOutcome(_ outcome: HabitOutcomeSnapshot) throws {
        try store.write(outcome, key: outcomeKey(outcome.behaviorDay))
    }

    func removeOutcome(for day: DayIdentity) throws { try store.remove(key: outcomeKey(day)) }

    func outcomeExclusion(for day: DayIdentity) throws -> HabitOutcomeExclusionRecord? {
        try store.read(HabitOutcomeExclusionRecord.self, key: outcomeExclusionKey(day))
    }

    func outcomeExclusions() throws -> [HabitOutcomeExclusionRecord] {
        try keys(withPrefix: "habit.outcome-exclusion.")
            .compactMap { try store.read(HabitOutcomeExclusionRecord.self, key: $0) }
            .sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    func saveOutcomeExclusion(_ exclusion: HabitOutcomeExclusionRecord) throws {
        try store.write(exclusion, key: outcomeExclusionKey(exclusion.behaviorDay))
    }

    func removeOutcomeExclusion(for day: DayIdentity) throws { try store.remove(key: outcomeExclusionKey(day)) }

    func estimate(for habitID: HabitID) throws -> HabitImpactEstimate? {
        try store.read(HabitImpactEstimate.self, key: insightKey(habitID))
    }

    func estimates() throws -> [HabitImpactEstimate] {
        try keys(withPrefix: "habit.insight.")
            .compactMap { try store.read(HabitImpactEstimate.self, key: $0) }
            .sorted { $0.habitID < $1.habitID }
    }

    func saveEstimate(_ estimate: HabitImpactEstimate) throws {
        try store.write(estimate, key: insightKey(estimate.habitID))
    }

    func settings() throws -> HabitSettings {
        try store.read(HabitSettings.self, key: "habit.settings") ?? HabitSettings()
    }

    func saveSettings(_ settings: HabitSettings) throws {
        try store.write(settings, key: "habit.settings")
    }

    func todaySelection() throws -> HabitTodaySelection? {
        try store.read(HabitTodaySelection.self, key: "habit.today-selection")
    }

    func saveTodaySelection(_ selection: HabitTodaySelection?) throws {
        if let selection {
            try store.write(selection, key: "habit.today-selection")
        } else {
            try store.remove(key: "habit.today-selection")
        }
    }

    func migrationReceipt() throws -> HabitMigrationReceipt? {
        try store.read(HabitMigrationReceipt.self, key: "habit.migration.v1")
    }

    func completeMigration(definitions: [HabitDefinition], dayRecords: [HabitDayRecord], receipt: HabitMigrationReceipt) throws {
        try HabitStoreValidator.validateRestore(definitions: definitions, records: dayRecords)
        var mutations = try definitions.map { try StorageDocumentMutation.write($0, key: definitionKey($0.id)) }
        mutations += try dayRecords.map { try StorageDocumentMutation.write($0, key: dayKey($0.behaviorDay)) }
        mutations.append(try StorageDocumentMutation.write(receipt, key: "habit.migration.v1"))
        try store.mutate(mutations)
    }

    func replaceSourceRecords(definitions: [HabitDefinition], dayRecords: [HabitDayRecord]) throws {
        try HabitStoreValidator.validateRestore(definitions: definitions, records: dayRecords)
        var mutations = try keys(withPrefix: "habit.definition.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.day.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.outcome.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.outcome-exclusion.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.insight.").map(StorageDocumentMutation.remove(key:))
        mutations += try definitions.map { try .write($0, key: definitionKey($0.id)) }
        mutations += try dayRecords.map { try .write($0, key: dayKey($0.behaviorDay)) }
        try store.mutate(mutations)
    }

    func deleteDerivedData() throws {
        var mutations = try keys(withPrefix: "habit.outcome.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.outcome-exclusion.").map(StorageDocumentMutation.remove(key:))
        mutations += try keys(withPrefix: "habit.insight.").map(StorageDocumentMutation.remove(key:))
        mutations.append(.remove(key: "habit.today-selection"))
        try store.mutate(mutations)
    }

    func deleteAllHabitData() throws {
        try store.removeAll(whereKeyPrefix: "habit.")
    }

    private func keys(withPrefix prefix: String) throws -> [String] {
        try store.keys().filter { $0.hasPrefix(prefix) }
    }

    private func definitionKey(_ id: HabitID) -> String {
        "habit.definition.\(id.rawValue.uuidString.lowercased())"
    }

    private func dayKey(_ day: DayIdentity) -> String { "habit.day.\(day.habitKey)" }
    private func outcomeKey(_ day: DayIdentity) -> String { "habit.outcome.\(day.habitKey)" }
    private func outcomeExclusionKey(_ day: DayIdentity) -> String { "habit.outcome-exclusion.\(day.habitKey)" }
    private func insightKey(_ id: HabitID) -> String { "habit.insight.\(id.rawValue.uuidString.lowercased())" }
}

actor SQLiteStressRepository: StressStore {
    /// How many days back the read-through walks before it gives up. A night
    /// is assigned to the day you wake on, so before the first sync of the day
    /// the most recent real reading is yesterday's.
    static let lookbackDays = 3

    private let store: StorageDocumentStore
    private let analytics: CanonicalDailyAnalytics?
    private let dateProvider: any DateProviding
    private let timeZoneProvider: any TimeZoneProviding

    init(
        database: StorageDatabase,
        analytics: CanonicalDailyAnalytics? = nil,
        dateProvider: any DateProviding = SystemDateProvider(),
        timeZoneProvider: any TimeZoneProviding = SystemTimeZoneProvider()
    ) throws {
        store = try StorageDocumentStore(database: database, namespace: "stress")
        self.analytics = analytics
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
    }

    /// Stress is derived, never stored by the derivation. Read it back through
    /// the same canonical generation every other screen uses, and only fall
    /// back to a saved row when the derivation has nothing for these days.
    func latestObservation() async -> StressObservation? {
        (try? await latestObservationChecked()) ?? storedObservation()
    }

    /// A day with no derivation yet returns nil. A storage failure throws, so
    /// the screen can say the read broke instead of showing an empty day.
    func latestObservationChecked() async throws -> StressObservation? {
        if let analytics {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZoneProvider.timeZone
            let now = dateProvider.now()
            for offset in 0..<Self.lookbackDays {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { break }
                let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
                guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
                let day = DayIdentity(era: parts.era ?? 1, year: year, month: month, day: dayOfMonth)
                guard let reading = try await analytics.readStress(day: day) else { continue }
                return StressObservation(
                    day: String(format: "%04d-%02d-%02d", year, month, dayOfMonth),
                    value: reading.score,
                    coverage: reading.coverage,
                    confidence: reading.confidence
                )
            }
        }
        return storedObservation()
    }

    func hourlyStress() async throws -> HourlyStressDay? {
        guard let analytics else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: dateProvider.now())
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return try await analytics.readHourlyStress(day: DayIdentity(year: year, month: month, day: day))
    }

    private func storedObservation() -> StressObservation? {
        let keys = (try? store.keys().filter { $0.hasPrefix("observation.") }.sorted()) ?? []
        guard let key = keys.last else { return nil }
        return try? store.read(StressObservation.self, key: key)
    }

    func saveObservation(_ observation: StressObservation) async throws {
        try store.write(observation, key: "observation.\(observation.day)")
    }

    func spotChecks() async -> [SpotCheckResult] {
        ((try? store.read([SpotCheckResult].self, key: "spot-checks")) ?? [])
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    func saveSpotCheck(_ result: SpotCheckResult) async throws {
        var values = try store.read([SpotCheckResult].self, key: "spot-checks") ?? []
        values.removeAll { $0.id == result.id }
        values.append(result)
        try store.write(values, key: "spot-checks")
    }

    func breathingHistory() async -> [BreathingResult] {
        ((try? store.read([BreathingResult].self, key: "breathing-history")) ?? [])
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    func saveBreathingResult(_ result: BreathingResult) async throws {
        var values = try store.read([BreathingResult].self, key: "breathing-history") ?? []
        values.removeAll { $0.id == result.id }
        values.append(result)
        try store.write(values, key: "breathing-history")
    }

    func deleteAll() async { try? store.removeAll() }
}

private struct PersistedCycleState: Codable, Sendable {
    var enabled = false
    var disabled = false
    var entries: [CycleEntry] = []
    var settings = CycleSettings()

    nonisolated init(enabled: Bool = false, disabled: Bool = false, entries: [CycleEntry] = [], settings: CycleSettings = .init()) {
        self.enabled = enabled
        self.disabled = disabled
        self.entries = entries
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case enabled, disabled, entries, settings }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        entries = try container.decodeIfPresent([CycleEntry].self, forKey: .entries) ?? []
        settings = try container.decodeIfPresent(CycleSettings.self, forKey: .settings) ?? .init()
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(disabled, forKey: .disabled)
        try container.encode(entries, forKey: .entries)
        try container.encode(settings, forKey: .settings)
    }
}

actor SQLiteCycleRepository: CycleStore {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "cycle")
    }

    func state() async throws -> CycleState { try materializedState().state }
    func isOptedIn() async throws -> Bool { let value = try materializedState(); return value.enabled && !value.disabled }

    func optIn() async throws { var value = try loadChecked(); value.enabled = true; value.disabled = false; try save(value) }
    func disable() async throws { var value = try loadChecked(); if value.enabled { value.disabled = true }; try save(value) }
    func enableAfterDisable() throws { var value = try loadChecked(); guard value.enabled else { throw CycleError.optedOut }; value.disabled = false; try save(value) }
    func deleteAll() async throws { try store.removeAll() }

    func log(_ entry: CycleEntry) throws -> CycleEntry {
        var value = try loadChecked()
        guard value.enabled && !value.disabled else { throw CycleError.optedOut }
        guard CycleDate.parse(entry.day) != nil else { throw CycleError.invalidDay }
        value.entries.removeAll { $0.id == entry.id }
        value.entries.append(entry)
        try save(value)
        return entry
    }

    func history() async throws -> [CycleEntry] { try loadChecked().entries.sorted { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) } }
    func delete(id: UUID) throws { var value = try loadChecked(); guard value.entries.contains(where: { $0.id == id }) else { throw CycleError.missingEntry }; value.entries.removeAll { $0.id == id }; try save(value) }
    func updateSettings(_ newValue: CycleSettings) throws { var value = try loadChecked(); guard value.enabled && !value.disabled else { throw CycleError.optedOut }; value.settings = newValue; try save(value) }
    func currentSettings() async throws -> CycleSettings { try loadChecked().settings }

    func estimate(today: String? = nil) async throws -> CycleEstimate {
        let value = try loadChecked()
        return calculateEstimate(value, today: today)
    }

    func export() async throws -> CycleExport { let value = try loadChecked(); return CycleExport(entries: value.entries.sorted { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) }, settings: value.settings) }

    private func loadChecked() throws -> PersistedCycleState { try store.read(PersistedCycleState.self, key: "state") ?? PersistedCycleState() }
    private func save(_ value: PersistedCycleState) throws { try store.write(value, key: "state") }
    private func materializedState() throws -> (state: CycleState, enabled: Bool, disabled: Bool) {
        let value = try loadChecked()
        let state: CycleState = value.enabled ? (value.disabled ? .disabled : (value.entries.isEmpty ? .optedIn : .populated)) : .optedOut
        return (state, value.enabled, value.disabled)
    }

    private func calculateEstimate(_ value: PersistedCycleState, today: String?) -> CycleEstimate {
        guard value.enabled, !value.disabled else { return CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Cycle tracking is not enabled.", sampleSize: 0) }
        let starts = value.entries.filter { $0.kind == .periodStart }.map(\.day).compactMap(CycleDate.parse).sorted()
        guard let latest = starts.last else { return CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Log a period start to begin; no phase is inferred.", sampleSize: 0) }
        let lengths = zip(starts, starts.dropFirst()).map { CycleDate.days(from: $0, to: $1) }.filter { $0 > 0 }
        let typical = lengths.isEmpty ? 28.0 : Double(lengths.sorted()[lengths.count / 2])
        let variation = lengths.isEmpty ? 0 : lengths.map { abs(Double($0) - typical) }.reduce(0, +) / Double(lengths.count)
        let irregular = variation > 5 || lengths.contains(where: { $0 < 15 || $0 > 60 })
        let sampleSize = starts.count
        let confidence = (irregular ? 0.45 : 1) * min(1, Double(sampleSize) / 3)
        let reference = today.flatMap(CycleDate.parse) ?? latest
        let cycleDay = max(0, CycleDate.days(from: latest, to: reference)) + 1
        let phase: CyclePhase = switch cycleDay { case 1...5: .menstrual; case 6...13: .follicular; case 14...16: .ovulatory; default: .luteal }
        let length = Int(typical.rounded())
        let next = CycleDate.adding(days: length, to: latest)
        let ovulation = CycleDate.adding(days: max(1, length - 14), to: latest)
        let fertileStart = CycleDate.adding(days: max(1, length - 18), to: latest)
        let fertileEnd = CycleDate.adding(days: max(1, length - 12), to: latest)
        return CycleEstimate(phase: phase, nextPeriodDay: next, fertileWindow: fertileStart...fertileEnd, ovulationDay: ovulation, confidence: confidence, uncertainty: irregular ? "Irregular history; dates are broad estimates, not a medical prediction." : "Estimate from logged period starts; dates may vary.", sampleSize: sampleSize)
    }
}

actor SQLiteRecordsRepository: RecordsStore {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: "records")
    }

    func save(_ metric: MetricSnapshot) async { var values = await metrics(); values.removeAll { $0.day == metric.day && $0.metric == metric.metric }; values.append(metric); try? store.write(values, key: "metrics") }
    func save(_ event: TimelineEvent) async { var values = await timeline(); values.removeAll { $0.id == event.id }; values.append(event); try? store.write(values, key: "timeline") }
    func metrics() async -> [MetricSnapshot] { (try? store.read([MetricSnapshot].self, key: "metrics")) ?? [] }
    func timeline() async -> [TimelineEvent] { (try? store.read([TimelineEvent].self, key: "timeline")) ?? [] }
    func personalRecords() async -> [PersonalRecord] {
        Dictionary(grouping: await metrics(), by: \.metric).compactMap { metric, rows in
            guard let best = rows.max(by: { $0.value != $1.value ? $0.value < $1.value : ($0.day != $1.day ? $0.day < $1.day : $0.algorithmVersion < $1.algorithmVersion) }) else { return nil }
            return PersonalRecord(metric: metric, value: best.value, day: best.day, algorithmVersion: best.algorithmVersion)
        }.sorted { $0.metric < $1.metric }
    }
    func streak(metric: String, qualifying: @escaping @Sendable (MetricSnapshot) -> Bool, calendar: Calendar, now: Date) async -> Streak {
        let qualifyingDays = Set((await metrics()).filter { $0.metric == metric && qualifying($0) }.map(\.day))
        var cursor = calendar.startOfDay(for: now), count = 0
        while qualifyingDays.contains(LocalDayNavigator.dayString(for: cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Streak(metric: metric, qualifyingDays: qualifyingDays, length: count, current: count > 0)
    }
    func mergedTimeline(_ candidates: [TimelineEvent]) async -> [TimelineEvent] { for event in candidates { await save(event) }; return await timeline() }
    func recap(period: Recap.Period, startDay: String, endDay: String) async -> Recap {
        let rows = (await metrics()).filter { $0.day >= startDay && $0.day <= endDay }.sorted { ($0.day, $0.metric) < ($1.day, $1.metric) }
        let versions = Set(rows.map(\.algorithmVersion)).sorted()
        let corrections = (await timeline()).filter { $0.day >= startDay && $0.day <= endDay && $0.correctionProvenance != nil }.map(\.day)
        return Recap(period: period, startDay: startDay, endDay: endDay, metrics: rows, algorithmDiscontinuities: versions.count > 1 ? Array(versions.dropFirst()) : [], correctionDays: Array(Set(corrections)).sorted())
    }
    func journey(startDay: String, endDay: String) async -> JourneySummary {
        let values = (await timeline()).filter { $0.day >= startDay && $0.day <= endDay }
        let days = Set(values.map(\.day)).sorted()
        return JourneySummary(startDay: days.first, endDay: days.last, activeDays: days.count, eventCount: values.count)
    }
    func shareCard(period: Recap.Period, startDay: String, endDay: String, options: RecordsShareOptions = .init()) async -> RecordsShareCard { RecordsShareCard(recap: await recap(period: period, startDay: startDay, endDay: endDay), options: options) }
    func deleteAll() async { try? store.removeAll() }
}

actor SQLiteWorkoutStore: WorkoutStore, DetectedWorkoutRepository, LooprDetectedWorkoutLedger {
    /// Deliberately outside the `detected.` prefix: `allDetections()` decodes
    /// every key under it as a `DetectedWorkout`.
    private static let resolvedKey = "resolved-detections"

    private let store: StorageDocumentStore
    private let accountImport: WHOOPImportStore?

    init(database: StorageDatabase, accountImport: WHOOPImportStore? = nil) throws { self.accountImport = accountImport; store = try StorageDocumentStore(database: database, namespace: "workouts") }
    func save(_ workout: WorkoutRecord) throws {
        let key = "workout.\(workout.id.uuidString)"
        let previous = try store.read(HourlyStressWorkoutMask.Header.self, key: key)
        let next = HourlyStressWorkoutMask.Header(startedAt: workout.startedAt, endedAt: workout.endedAt, state: workout.state.rawValue)
        try store.write(workout, key: key)
        if previous != next, previous?.interval != nil || next.interval != nil { HourlyStressWorkoutMask.changed() }
    }
    func workout(id: UUID) async -> WorkoutRecord? {
        if let stored = try? store.read(WorkoutRecord.self, key: "workout.\(id.uuidString)") { return stored }
        return await all().first { $0.id == id }
    }
    func workout(identity: WorkoutIdentity) async -> WorkoutRecord? { await all().first { $0.identity == identity } }
    func all() async -> [WorkoutRecord] {
        let native = (try? store.keys().filter { $0.hasPrefix("workout.") }.compactMap { try store.read(WorkoutRecord.self, key: $0) }) ?? []
        return WHOOPImportResolution.workouts(native: native, imported: (try? accountImport?.workouts()) ?? [])
    }
    func savedWorkouts() async -> [WorkoutRecord] { await all() }
    /// List rows without the per-second samples. See `WorkoutListingRowDocument`.
    func listingRows(_ query: WorkoutLogQuery) async -> [WorkoutRecord] {
        let lower = query.range == .all ? nil : query.calendar.date(byAdding: .month, value: -3, to: query.now)
        let imported = (try? accountImport?.workouts(from: lower, through: query.now)) ?? []
        return WHOOPImportResolution.workouts(native: allListingRows(), imported: imported).filter { query.contains($0.startedAt ?? $0.createdAt) }
    }
    private func allListingRows() -> [WorkoutRecord] {
        let keys = (try? store.keys().filter { $0.hasPrefix("workout.") }) ?? []
        return keys.compactMap { key in
            guard let payload = try? store.readData(key: key) else { return nil }
            return try? JSONDecoder().decode(WorkoutListingRowDocument.self, from: payload).row
        }
    }
    func remove(id: UUID) async {
        do {
            try store.remove(key: "workout.\(id.uuidString)")
            HourlyStressWorkoutMask.changed()
        } catch { /* The existing store API has no throwing removal seam. */ }
        try? accountImport?.removeWorkout(id: id)
    }
    func save(_ detection: WorkoutKit.DetectedWorkout) throws { try store.write(detection, key: "detected.\(detection.detectionID)") }
    func allDetections() async -> [WorkoutKit.DetectedWorkout] {
        let rows = (try? store.keys().filter { $0.hasPrefix("detected.") }.compactMap { try store.read(WorkoutKit.DetectedWorkout.self, key: $0) }) ?? []
        // The overlap check reads only times, state and source.
        let saved = allListingRows()
        let answered = resolvedDetectionIDs()
        return rows.filter {
            !WorkoutDetectionDeduplication.wasAnswered($0, answered: answered)
                && !WorkoutDetectionDeduplication.overlapsSavedWorkout($0, workouts: saved)
        }
    }
    func detection(id: String) async -> WorkoutKit.DetectedWorkout? {
        guard let row = try? store.read(WorkoutKit.DetectedWorkout.self, key: "detected.\(id)") else { return nil }
        guard !WorkoutDetectionDeduplication.wasAnswered(row, answered: resolvedDetectionIDs()) else { return nil }
        return WorkoutDetectionDeduplication.overlapsSavedWorkout(row, workouts: allListingRows()) ? nil : row
    }
    func remove(id: String) throws {
        guard (try? store.read(WorkoutKit.DetectedWorkout.self, key: "detected.\(id)")) != nil else {
            throw DetectedWorkoutRepositoryError.missingDetection
        }
        try store.remove(key: "detected.\(id)")
        markResolved(id)
    }

    /// Confirming or dismissing a detection removes its row. Re-deriving the
    /// same day would otherwise hand the bout back, so the answer is recorded
    /// separately and outlives the row.
    func resolvedDetectionIDs() -> Set<String> {
        (try? store.read(Set<String>.self, key: Self.resolvedKey)) ?? []
    }

    func markDetectionResolved(id: String) { markResolved(id) }

    private func markResolved(_ id: String) {
        var values = resolvedDetectionIDs()
        values.insert(id)
        try? store.write(values, key: Self.resolvedKey)
    }

    func deleteAll() async {
        do {
            try store.removeAll()
            HourlyStressWorkoutMask.changed()
        } catch { /* Keep the existing nonthrowing store contract. */ }
        try? accountImport?.deleteWorkouts()
    }
}

actor SQLiteRouteStore: RouteStore {
    private let store: StorageDocumentStore

    init(database: StorageDatabase) throws { store = try StorageDocumentStore(database: database, namespace: "route") }
    func route(workoutID: String) async throws -> RouteRecord? { try store.read(RouteRecord.self, key: "route.\(workoutID)") }
    func all() async throws -> [RouteRecord] { try store.keys().filter { $0.hasPrefix("route.") }.compactMap { try store.read(RouteRecord.self, key: $0) } }
    func save(_ route: RouteRecord) async throws { try store.write(route, key: "route.\(route.workoutID)") }
    func delete(workoutID: String) async throws { try store.remove(key: "route.\(workoutID)") }
    func count() async throws -> Int { try store.keys().filter { $0.hasPrefix("route.") }.count }
    func deleteAll() async throws { try store.removeAll() }
}

/// Destructive onboarding actions are kept separate from screen repositories.
/// Each action has a narrow effect, while delete-all composes every local
/// namespace and the canonical StorageKit ledger in one explicit operation.
struct PersistentOnboardingDataEffects: @unchecked Sendable, OnboardingDataEffects {
    let profile: any ProfileRepository
    let device: any DeviceCenterRepository
    let onboarding: SQLiteOnboardingRepository
    let database: StorageDatabase
    let defaults: UserDefaults
    let accessoryProvisioningStore: any AccessoryProvisioningStore
    let productStores: [NamedProductStore]
    /// The Bluetooth application model owns runtime stop/release. This phase
    /// must finish before any SQLite/history deletion can begin, otherwise an
    /// in-flight commit can repopulate a file after it was cleared.
    let derivationDataDeleter: (any PersistentDataDeletionDeleter)?
    let runtimeDataDeleter: (any PersistentDataDeletionDeleter)?
    let externalDeleters: [any PersistentDataDeletionDeleter]

    init(
        profile: any ProfileRepository,
        device: any DeviceCenterRepository,
        onboarding: SQLiteOnboardingRepository,
        database: StorageDatabase,
        defaults: UserDefaults = .standard,
        accessoryProvisioningStore: (any AccessoryProvisioningStore)? = nil,
        productStores: [NamedProductStore],
        runtimeDataDeleter: (any PersistentDataDeletionDeleter)? = nil,
        derivationDataDeleter: (any PersistentDataDeletionDeleter)? = nil,
        externalDeleters: [any PersistentDataDeletionDeleter] = []
    ) {
        self.profile = profile
        self.device = device
        self.onboarding = onboarding
        self.database = database
        self.defaults = defaults
        self.accessoryProvisioningStore = accessoryProvisioningStore
            ?? UserDefaultsAccessoryProvisioningStore(defaults: defaults)
        self.productStores = productStores
        self.runtimeDataDeleter = runtimeDataDeleter
        self.derivationDataDeleter = derivationDataDeleter
        self.externalDeleters = externalDeleters
    }

    func resetProfile() async throws {
        try await profile.resetProfile()
    }

    func forgetBand() async throws {
        try await device.forgetBand()
    }

    func deleteAllData() async throws {
        let receipt = await deleteAllDataWithReceipt()
        guard receipt.isComplete else {
            throw PersistentDataDeletionError(receipt: receipt)
        }
    }

    /// Runs every local deletion boundary and continues after an individual
    /// failure so callers receive a truthful inventory of what was cleared.
    /// The throwing protocol method above only reports success when every
    /// injected store has confirmed deletion.
    func deleteAllDataWithReceipt() async -> PersistentDataDeletionReceipt {
        var clearedStores: [String] = []
        var failures: [PersistentDataDeletionFailure] = []

        if let runtimeDataDeleter {
            await record(
                name: runtimeDataDeleter.storeName,
                operation: { try await runtimeDataDeleter.deleteAll() },
                clearedStores: &clearedStores,
                failures: &failures
            )
            // Fail closed before touching product/history files. If the model
            // could not prove that its runtime stopped, durable deletion must
            // not race a late commit or ACK.
            if !failures.isEmpty {
                return PersistentDataDeletionReceipt(clearedStores: clearedStores, failures: failures)
            }
        }

        if let derivationDataDeleter {
            await record(name: derivationDataDeleter.storeName,
                operation: { try await derivationDataDeleter.deleteAll() },
                clearedStores: &clearedStores, failures: &failures)
            if !failures.isEmpty { return PersistentDataDeletionReceipt(clearedStores: clearedStores, failures: failures) }
        }

        let firstPartyOperations: [(String, @Sendable () async throws -> Void)] = [
            ("product.profile", { try await self.profile.deleteAllData() }),
            ("product.device-center", { try await self.device.deprovision() }),
            ("product.onboarding", { try await self.onboarding.clear() }),
            ("product.sqlite-ledger", { try self.database.deleteAllAccountData() })
        ]
        for (name, operation) in firstPartyOperations {
            await record(name: name, operation: operation, clearedStores: &clearedStores, failures: &failures)
        }

        for namedStore in productStores {
            await record(
                name: "product.namespace.\(namedStore.name)",
                operation: { try namedStore.store.removeAll() },
                clearedStores: &clearedStores,
                failures: &failures
            )
        }

        await record(
            name: "userDefaults.product-identifiers",
            operation: {
                for key in ProductRepositoryKeys.allOwnedDefaultsKeys {
                    self.defaults.removeObject(forKey: key)
                }
            },
            clearedStores: &clearedStores,
            failures: &failures
        )
        await record(
            name: "bluetooth.provisioning-identifier",
            operation: { try await self.accessoryProvisioningStore.removeBluetoothIdentifier() },
            clearedStores: &clearedStores,
            failures: &failures
        )

        for deleter in externalDeleters {
            await record(
                name: deleter.storeName,
                operation: { try await deleter.deleteAll() },
                clearedStores: &clearedStores,
                failures: &failures
            )
        }

        return PersistentDataDeletionReceipt(clearedStores: clearedStores, failures: failures)
    }

    private func record(
        name: String,
        operation: @escaping @Sendable () async throws -> Void,
        clearedStores: inout [String],
        failures: inout [PersistentDataDeletionFailure]
    ) async {
        do {
            try await operation()
            clearedStores.append(name)
        } catch {
            failures.append(PersistentDataDeletionFailure(storeName: name, reason: String(describing: error)))
        }
    }
}

/// Owns the one database and all durable package seams needed by production
/// composition.  It is intentionally not used for DEBUG fixture launch modes.
struct PersistentProductRepositories {
    let database: StorageDatabase
    /// The one derivation boundary. Held so the app can publish everything
    /// that depends on a freshly derived day: detected workouts, record rows,
    /// and the snapshot the widgets, Watch and complications read.
    let analytics: CanonicalDailyAnalytics
    let derivedData: LooprDerivedDataPublisher
    let onboarding: SQLiteOnboardingRepository
    let profile: SQLiteProfileRepository
    let device: any DeviceCenterRepository
    let deviceCommandWriter: any DeviceCommandWriter
    let today: SQLiteTodayRepository
    let todayGoals: any TodayGoalsRepository
    let coach: SQLiteCoachRepository
    let sleep: SQLiteSleepRepository
    let heart: SQLiteHeartRepository
    let body: SQLiteBodyRepository
    let stress: SQLiteStressRepository
    /// The shared live adapters remain fail-closed when no Bluetooth runtime
    /// has been installed. With a runtime, this mechanism is the bounded
    /// canonical service and persists Heart + Stress atomically.
    let stressLiveConsumer: any LiveConsumer
    let breathingSession: BreathingSessionController
    let stressSpotCheckMechanism: any SpotCheckMechanism
    let spotCheckService: CanonicalLiveSpotCheckService?
    /// Optional because production launch may complete before the shared
    /// Bluetooth runtime has been installed. When nil, HeartKit fails closed.
    let heartLiveClient: (any HeartLiveStreamClient)?
    /// Generation-stamped live events for Heart/Stress consumers. This is a
    /// separate typed seam so feature code cannot fall back to opaque bytes.
    let heartLiveEventClient: (any HeartLiveEventStreamClient)?
    let settings: SQLiteSettingsRepository
    let healthSync: LooprHealthSyncRuntime
    let data: SQLiteDataRepository
    let accountImport: WHOOPImportStore
    let journal: SQLiteJournalRepository
    let habits: SQLiteHabitRepository
    let habitReminderScheduler: any HabitReminderScheduling
    let cycle: SQLiteCycleRepository
    /// Production scheduling is backed by UserNotifications; fixture
    /// compositions intentionally keep the unavailable scheduler so they do
    /// not request permission or mutate device notification state.
    let cycleReminderScheduler: any CycleReminderScheduler
    let records: SQLiteRecordsRepository
    let workouts: SQLiteWorkoutStore
    let routes: SQLiteRouteStore
    /// Core Location is created lazily and only requests permission after an
    /// eligible route recorder explicitly calls `start()`.
    let routeLocation: CoreLocationRouteAdapter
    let destructiveEffects: PersistentOnboardingDataEffects
    /// The per-second history database, read by the Heart tab's day timeline.
    let historyDatabase: StorageDatabase

    init(
        environment: AppEnvironment,
        heartLiveRuntime: (any LooprHeartLiveRuntime)? = nil,
        deviceCenterRuntime: (any LooprDeviceCenterRuntime)? = nil,
        runtimeDataDeleter: (any PersistentDataDeletionDeleter)? = nil,
        routeLocationDriverFactory: CoreLocationRouteDriverFactory? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        guard environment.composition == .production,
              let storageURL = environment.storageURL else {
            throw ProductRepositoryCompositionError.productionStorageUnavailable
        }
        let resolvedDeviceCenterRuntime: (any LooprDeviceCenterRuntime)? = deviceCenterRuntime
            ?? (heartLiveRuntime as? any LooprDeviceCenterRuntime)
        // Production files are shared and usually already open: launch
        // prewarms them off the main thread (see LooprProductionDatabases).
        let databases = LooprProductionDatabases.shared
        let database = try databases.database(at: storageURL, applicationVersion: environment.applicationVersion)
        let onboarding = try SQLiteOnboardingRepository(database: database)
        let profile = try SQLiteProfileRepository(
            database: database,
            dateProvider: environment.dateProvider,
            uuidProvider: environment.uuidProvider
        )
        let device = try SQLiteDeviceCenterRepository(database: database)
        let deviceRepository: any DeviceCenterRepository
        if let resolvedDeviceCenterRuntime {
            deviceRepository = RuntimeDeviceCenterRepository(
                base: device,
                alarmRepository: device,
                runtime: resolvedDeviceCenterRuntime,
                dateProvider: environment.dateProvider,
                batteryLog: try SQLiteBatterySampleLog(database: database)
            )
        } else {
            deviceRepository = device
        }
        let historyURL = storageURL.deletingLastPathComponent().appendingPathComponent("Loopr/loopr.sqlite")
        let historyDatabase = try databases.database(at: historyURL, applicationVersion: environment.applicationVersion)
        let analytics = try CanonicalDailyAnalytics(history: historyDatabase, products: database, profile: profile,
            dateProvider: environment.dateProvider, timeZoneProvider: environment.timeZoneProvider)
        let today = try SQLiteTodayRepository(database: database, analytics: analytics)
        let coach = try SQLiteCoachRepository(database: database, analytics: analytics)
        let sleep = try SQLiteSleepRepository(database: database, analytics: analytics)
        let heart = try SQLiteHeartRepository(database: database, analytics: analytics)
        let body = try SQLiteBodyRepository(database: database, analytics: analytics)
        let stress = try SQLiteStressRepository(database: database, analytics: analytics,
            dateProvider: environment.dateProvider, timeZoneProvider: environment.timeZoneProvider)
        let settings = try SQLiteSettingsRepository(database: database)
        let data = try SQLiteDataRepository(
            database: database,
            healthSampleDeletionClient: LiveHealthKitClient()
        )
        let journal = try SQLiteJournalRepository(database: database, accountImport: try WHOOPImportStore(database: historyDatabase))
        let habits = try SQLiteHabitRepository(database: database)
        let cycle = try SQLiteCycleRepository(database: database)
        let records = try SQLiteRecordsRepository(database: database)
        let workouts = try SQLiteWorkoutStore(database: database, accountImport: try WHOOPImportStore(database: historyDatabase))
        let healthSyncStore = try SQLiteHealthSyncStore(database: database, timeZone: environment.timeZoneProvider.timeZone.identifier)
        let exportTimeZone = try healthSyncStore.preferences().timeZoneIdentifier
        let healthAnalytics = try CanonicalDailyAnalytics(history: historyDatabase, products: database, profile: profile,
            dateProvider: environment.dateProvider,
            timeZoneProvider: HealthExportTimeZone(timeZone: TimeZone(identifier: exportTimeZone) ?? .gmt),
            namespace: "health-export-analytics")
        let healthSync = try LooprHealthSyncRuntime(history: historyDatabase, analytics: healthAnalytics, workouts: workouts,
            store: healthSyncStore, dates: environment.dateProvider)
        self.healthSync = healthSync
        let routes = try SQLiteRouteStore(database: database)
        let stores = [
            NamedProductStore(name: "daily-analytics", store: try StorageDocumentStore(database: database, namespace: "daily-analytics")),
            NamedProductStore(name: "onboarding", store: try StorageDocumentStore(database: database, namespace: "onboarding")),
            NamedProductStore(name: "device-center", store: try StorageDocumentStore(database: database, namespace: "device-center")),
            NamedProductStore(name: "today", store: try StorageDocumentStore(database: database, namespace: "today")),
            NamedProductStore(name: "coach", store: try StorageDocumentStore(database: database, namespace: "coach")),
            NamedProductStore(name: "sleep", store: try StorageDocumentStore(database: database, namespace: "sleep")),
            NamedProductStore(name: "heart", store: try StorageDocumentStore(database: database, namespace: "heart")),
            NamedProductStore(name: "body", store: try StorageDocumentStore(database: database, namespace: "body")),
            NamedProductStore(name: "stress", store: try StorageDocumentStore(database: database, namespace: "stress")),
            NamedProductStore(name: "settings", store: try StorageDocumentStore(database: database, namespace: "settings")),
            NamedProductStore(name: "data", store: try StorageDocumentStore(database: database, namespace: "data")),
            NamedProductStore(name: "journal", store: try StorageDocumentStore(database: database, namespace: "journal")),
            NamedProductStore(name: "cycle", store: try StorageDocumentStore(database: database, namespace: "cycle")),
            NamedProductStore(name: "records", store: try StorageDocumentStore(database: database, namespace: "records")),
            NamedProductStore(name: "route", store: try StorageDocumentStore(database: database, namespace: "route")),
            NamedProductStore(name: "workouts", store: try StorageDocumentStore(database: database, namespace: "workouts"))
        ]
        let derivedData = LooprDerivedDataPublisher(
            analytics: analytics,
            records: records,
            workouts: workouts,
            device: deviceRepository,
            sink: LooprSurfaceSnapshotWriter(
                privacy: LooprSettingsSurfacePrivacyReader(repository: settings)
            ),
            notifier: LooprDetectedWorkoutNotifier(),
            dateProvider: environment.dateProvider,
            timeZoneProvider: environment.timeZoneProvider,
            corrections: sleep,
            morningRecap: LooprMorningRecapNotifier()
        )
        self.database = database
        self.analytics = analytics
        self.derivedData = derivedData
        self.onboarding = onboarding
        self.profile = profile
        self.device = deviceRepository
        if let resolvedDeviceCenterRuntime {
            self.deviceCommandWriter = SharedBluetoothDeviceCommandWriter(runtime: resolvedDeviceCenterRuntime)
        } else {
            self.deviceCommandWriter = UnavailableDeviceCommandWriter()
        }
        self.today = today
        self.todayGoals = ProfileBackedTodayGoalsRepository(today: today, profile: profile)
        self.coach = coach
        self.sleep = sleep
        self.heart = heart
        self.body = body
        self.stress = stress
        let resolvedHeartLiveRuntime: (any LooprHeartLiveRuntime)? = heartLiveRuntime ?? resolvedDeviceCenterRuntime
        let stressConsumer = StressLiveAdapter.liveConsumer(runtime: resolvedHeartLiveRuntime)
        self.stressLiveConsumer = stressConsumer
        let bandCueDelivery = BandCueDelivery(runtime: resolvedDeviceCenterRuntime)
        self.breathingSession = BreathingSessionController(
            consumer: stressConsumer,
            hook: LooprBreathingLiveActivityHook.shared,
            bandCue: { @Sendable [bandCueDelivery] phase, sessionID in
                await bandCueDelivery.send(effect: BandCuePattern.breathing(phase), sessionID: sessionID)
            }
        )
        if let resolvedHeartLiveRuntime {
            let spotCheckPersistence = try SQLiteCanonicalSpotCheckPersistence(database: database)
            let spotCheckService = CanonicalLiveSpotCheckService(
                runtime: resolvedHeartLiveRuntime,
                persistence: spotCheckPersistence
            )
            self.spotCheckService = spotCheckService
            self.stressSpotCheckMechanism = spotCheckService
            let liveClient = SyncKitHeartLiveStreamClient(runtime: resolvedHeartLiveRuntime)
            self.heartLiveClient = liveClient
            self.heartLiveEventClient = liveClient
        } else {
            self.spotCheckService = nil
            self.stressSpotCheckMechanism = StressLiveAdapter.spotCheckMechanism(runtime: nil)
            self.heartLiveClient = nil
            self.heartLiveEventClient = nil
        }
        self.settings = settings
        self.data = data
        self.journal = journal
        self.habits = habits
        self.habitReminderScheduler = CentralNotificationHabitReminderScheduler()
        self.cycle = cycle
        self.cycleReminderScheduler = CentralNotificationCycleReminderScheduler()
        self.records = records
        self.workouts = workouts
        self.historyDatabase = historyDatabase
        self.accountImport = try WHOOPImportStore(database: historyDatabase)
        self.routes = routes
        self.routeLocation = CoreLocationRouteAdapter(
            driverFactory: routeLocationDriverFactory ?? { CoreLocationManagerRouteDriver() }
        )
        var externalDeleters: [any PersistentDataDeletionDeleter] = []
        // Stops the metric history work before the history file is wiped.
        externalDeleters.append(LooprMetricHistoryDeletion(history: .shared))
        externalDeleters.append(SQLiteFileDataDeletionDeleter(
            storeName: "bluetooth.history.sqlite", databaseURL: historyURL,
            applicationVersion: environment.applicationVersion
        ))
        externalDeleters.append(contentsOf: [
            LooprKeychainDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprIntegrationLedgerDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprTemporaryExportDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprAppGroupDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprWatchSnapshotDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprNotificationDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprLiveActivityDataDeletionDeleter() as any PersistentDataDeletionDeleter,
            LooprHeartAlertsDataDeletionDeleter() as any PersistentDataDeletionDeleter
        ])
        self.destructiveEffects = PersistentOnboardingDataEffects(
            profile: profile,
            device: deviceRepository,
            onboarding: onboarding,
            database: database,
            defaults: defaults,
            accessoryProvisioningStore: UserDefaultsAccessoryProvisioningStore(defaults: defaults),
            productStores: stores,
            runtimeDataDeleter: runtimeDataDeleter,
            derivationDataDeleter: ProductDerivationDeletionGroup(
                analytics: analytics, healthSync: healthSync, derivedData: derivedData
            ),
            externalDeleters: externalDeleters
        )
        // The Live Activity runtime is a singleton with no owner, so the
        // composition hands it the surface privacy switches here.
        let liveActivityPrivacy = LooprSettingsSurfacePrivacyReader(repository: settings)
        Task { await LooprLiveActivityRuntime.shared.setPrivacyReader(liveActivityPrivacy) }
        // Metric history: band write-through, backfill and the Apple Health
        // import, all kept in the history database. Background work runs only
        // against the real on-device store, never a test composition's.
        LooprMetricHistory.shared.attach(history: historyDatabase, analytics: analytics,
            timeZoneProvider: environment.timeZoneProvider, dateProvider: environment.dateProvider,
            healthPreferences: healthSyncStore,
            scheduleWork: historyURL.standardizedFileURL.path
                == (try? ProductionBluetoothAdoptionStore.historyDatabaseURL())?.standardizedFileURL.path)
    }
}

enum ProductRepositoryCompositionError: Error, Equatable, Sendable, LocalizedError {
    case productionStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .productionStorageUnavailable:
            "Loopr could not open its local production database."
        }
    }
}
