import Foundation
import CycleKit
import DomainKit
import HealthKitBridge
import JournalKit
import NotificationKit
import SharedSurfaceKit
import SettingsKit
import WorkoutKit

actor LooprWorkoutIntegrationRuntime {
    static let shared = LooprWorkoutIntegrationRuntime()

    init() {}

    /// Only the Live Activity. Finishing a workout changes the whole day, so
    /// the widget and Watch snapshot is republished by the derived-data
    /// publisher, which has every metric. An earlier version of this hook
    /// wrote a snapshot carrying the workout's end time and nothing else,
    /// which blanked every widget and complication it reached.
    nonisolated func hooks() -> WorkoutFinalizationHooks {
        WorkoutFinalizationHooks(
            updateLiveActivity: { workout in
                await LooprLiveActivityRuntime.shared.synchronize(workout)
                // Heart rate alerts leave workouts and the ten minutes after
                // them alone.
                await LooprHeartAlertsRuntime.shared.noteWorkout(
                    id: workout.id.uuidString, start: workout.startedAt, end: workout.endedAt
                )
            }
        )
    }
}

#if canImport(HealthKit)
import HealthKit

actor LooprHealthKitSettingsEntryPoint: HealthKitSettingsEntryPoint {
    private let runtime: LooprHealthSyncRuntime?

    init(runtime: LooprHealthSyncRuntime?) { self.runtime = runtime }

    func state() async -> SettingsIntegrationState {
        guard let runtime else { return .unavailable }
        let status = await runtime.status()
        if status.unavailable { return .unsupported }
        if !status.allowed.isEmpty { return .available }
        return status.undetermined.isEmpty ? .denied : .permissionRequired
    }

    func requestPermission() async -> SettingsIntegrationState {
        guard let runtime else { return .unavailable }
        await runtime.requestPermission()
        Task { await runtime.synchronizeNow() }
        return await state()
    }

    func reset() async throws {
        // HealthKit authorization belongs to iOS. Local imported rows and anchors are
        // removed by the app's data-deletion coordinator; HealthKit samples remain a
        // separate explicitly confirmed action.
    }
}
#else
typealias LooprHealthKitSettingsEntryPoint = UnavailableHealthKitSettingsEntryPoint
#endif

#if canImport(UserNotifications)
import UserNotifications

private final class LooprNotificationSchedulingAdapter: @unchecked Sendable, NotificationSchedulingClient {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func schedule(_ request: NotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.lockScreenBody
        content.userInfo = try NotificationResponsePayload.userInfo(for: request)
        content.categoryIdentifier = request.categoryIdentifier
        content.threadIdentifier = request.categoryIdentifier
        content.sound = .default
        // A notification request carries one absolute instant, so the trigger
        // has to express that instant. A calendar trigger built from year to
        // minute drops the seconds and never fires once that minute has
        // passed, and every Loopr producer asks for "now", so every
        // notification was being scheduled for a moment already gone. A nil
        // trigger is the supported way to deliver immediately.
        let secondsFromNow = request.fireDate.timeIntervalSinceNow
        let trigger: UNNotificationTrigger? = secondsFromNow > 0.5
            ? UNTimeIntervalNotificationTrigger(timeInterval: secondsFromNow, repeats: false)
            : nil
        let identifier = Self.identifier(for: request.identity)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func remove(identities: Set<NotificationIdentity>) async {
        let identifiers = identities.map(Self.identifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func identifier(for identity: NotificationIdentity) -> String {
        ["com.loopr.notification.v1", identity.family.rawValue, identity.objectID, identity.day]
            .joined(separator: ".")
    }
}

actor LooprNotificationRuntime: NotificationSettingsEntryPoint {
    static let shared = LooprNotificationRuntime()
    let policy: NotificationPolicy
    let events: ProductNotificationEventSource
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current(), rootURL: URL? = nil) {
        self.center = center
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotificationKit", isDirectory: true)
        let policy = NotificationPolicy(
            client: LooprNotificationSchedulingAdapter(center: center),
            claims: NotificationClaimLedger(persistenceURL: root.appendingPathComponent("claims.json")),
            preferenceURL: root.appendingPathComponent("preferences.json"),
            deliveryURL: root.appendingPathComponent("delivery.json"),
            pendingURL: root.appendingPathComponent("pending.json")
        )
        self.policy = policy
        self.events = ProductNotificationEventSource(policy: policy)
    }

    func state() async -> SettingsIntegrationState {
        switch await authorizationState() {
        case .authorized: .available
        case .notDetermined: .permissionRequired
        case .denied: .denied
        }
    }

    func requestPermission() async -> SettingsIntegrationState {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await policy.setAuthorization(granted ? .authorized : .denied)
            return granted ? .available : .denied
        } catch { return .recoverableError(error.localizedDescription) }
    }

    func reset() async throws {
        try await policy.disableAll()
    }

    /// Every family that has a producer, in Settings order. Heart alerts have
    /// their own screen, and families nothing publishes are not offered.
    static let listedFamilies: [NotificationFamily] = [
        .recoveryReadiness, .detectedWorkouts, .workoutCompletion, .breathingCompletion,
        .battery, .chargeGuidance, .disconnect, .staleData,
        .journaling, .cycleReminders
    ]

    func preferences() async -> [NotificationPreferenceSetting] {
        var values: [NotificationPreferenceSetting] = []
        for family in Self.listedFamilies {
            values.append(.init(
                id: family.rawValue,
                title: Self.title(for: family),
                isEnabled: await policy.isEnabled(family)
            ))
        }
        return values
    }

    func setPreference(id: String, enabled: Bool) async throws {
        guard let family = NotificationFamily(rawValue: id) else { throw NotificationPayloadError.invalidDeepLink }
        try await policy.setEnabled(enabled, for: family)
    }

    func refreshAuthorization() async -> NotificationAuthorizationState {
        let value = await authorizationState()
        await policy.setAuthorization(value)
        return value
    }

    /// Called from `didFinishLaunching` on every launch, including the
    /// headless Bluetooth relaunch. Until this runs the policy believes
    /// permission is undetermined and only queues.
    func prepareAtLaunch() async {
        registerCategories()
        _ = await refreshAuthorization()
    }

    func registerCategories() {
        let categories = NotificationCategoryCatalog.all.map { descriptor in
            UNNotificationCategory(
                identifier: descriptor.identifier,
                actions: descriptor.actions.map { action in
                    UNNotificationAction(identifier: action.identifier, title: action.title,
                                         options: action.opensApp ? [.foreground] : [])
                },
                intentIdentifiers: [],
                options: []
            )
        }
        center.setNotificationCategories(Set(categories))
    }

    func deliverySettings() async -> NotificationDeliverySettings {
        await policy.deliverySettings()
    }

    func setDeliverySettings(_ value: NotificationDeliverySettings) async throws {
        try await policy.setDeliverySettings(value)
    }

    func isEnabled(_ family: NotificationFamily) async -> Bool {
        await policy.isEnabled(family)
    }

    /// Schedules a request the heart alerts runtime built.
    @discardableResult
    func schedule(_ request: NotificationRequest) async -> NotificationScheduleResult? {
        try? await policy.schedule(request)
    }

    private func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func workoutCompleted(id: UUID, at date: Date) async {
        try? await events.workoutCompleted(id: id.uuidString, day: Self.dayString(date), fireDate: date)
    }

    func detectedWorkout(id: UUID, at date: Date) async {
        await detectedWorkout(detectionID: id.uuidString, at: date)
    }

    /// A bout found by the derivation has a detection identity, not a workout
    /// identity: it has no record until the person confirms it.
    func detectedWorkout(detectionID: String, at date: Date) async {
        _ = try? await events.publish(
            .detectedWorkouts,
            targetID: detectionID,
            day: Self.dayString(date),
            fireDate: date,
            title: "Workout detected",
            detail: "Review the detected workout in Loopr."
        )
    }

    func breathingCompleted(id: UUID, at date: Date) async {
        try? await events.breathingCompleted(id: id.uuidString, day: Self.dayString(date), fireDate: date)
    }

    func deviceStateChanged(family: NotificationFamily, targetID: String, at date: Date = Date()) async {
        guard [.battery, .chargeGuidance, .disconnect, .staleData].contains(family) else { return }
        _ = try? await events.publish(
            family,
            targetID: targetID,
            day: Self.dayString(date),
            fireDate: date,
            title: "Strap update",
            detail: "Open Device Center for details."
        )
    }

    private static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func title(for family: NotificationFamily) -> String {
        switch family {
        case .recoveryReadiness: "Morning recap"
        case .validatedHealthChanges: "Health changes"
        case .goals: "Goals"
        case .detectedWorkouts: "Detected workouts"
        case .journaling: "Journal reminders"
        case .briefings: "Briefings"
        case .windDown: "Wind-down"
        case .hydration: "Hydration"
        case .battery: "Battery"
        case .chargeGuidance: "Charging guidance"
        case .disconnect: "Disconnections"
        case .staleData: "Stale data"
        case .workoutCompletion: "Workout completion"
        case .breathingCompletion: "Breathing completion"
        case .cycleReminders: "Cycle reminders"
        case .highHeartRate: "High heart rate"
        case .lowHeartRate: "Low heart rate"
        case .overnightCheck: "Overnight check"
        case .cardioFitness: "Cardio fitness"
        }
    }
}

struct CentralNotificationCycleReminderScheduler: CycleReminderScheduler {
    let runtime: LooprNotificationRuntime
    init(runtime: LooprNotificationRuntime = .shared) { self.runtime = runtime }

    func schedule(settings: CycleSettings) async throws {
        guard settings.remindersEnabled, let hour = settings.reminderHour else {
            try await cancel(); return
        }
        guard (0...23).contains(hour) else { throw CycleError.invalidReminderHour }
        switch await runtime.refreshAuthorization() {
        case .authorized: break
        case .notDetermined:
            guard await runtime.requestPermission() == .available else { throw CycleError.reminderDenied }
        case .denied: throw CycleError.reminderDenied
        }
        try await runtime.policy.setEnabled(true, for: .cycleReminders)
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        let fireDate = Calendar.current.nextDate(after: Date(), matching: components,
                                                 matchingPolicy: .nextTime) ?? Date()
        let context = NotificationFamilyContext(
            targetID: "daily", day: "recurring", fireDate: fireDate,
            title: "Loopr cycle check-in",
            detail: "Log how you feel today when it works for you.",
            cycleTrackingEnabled: true
        )
        guard let request = NotificationFamilyFactory.request(family: .cycleReminders, context: context) else {
            throw CycleError.reminderUnavailable
        }
        _ = try await runtime.policy.schedule(request)
    }

    func cancel() async throws {
        try await runtime.policy.remove(family: .cycleReminders)
        try await runtime.policy.setEnabled(false, for: .cycleReminders)
    }
}

struct CentralNotificationHabitReminderScheduler: HabitReminderScheduling {
    let runtime: LooprNotificationRuntime
    init(runtime: LooprNotificationRuntime = .shared) { self.runtime = runtime }

    func update(settings: HabitSettings, activeHabitCount: Int, behaviorDay: DayIdentity) async throws {
        guard settings.reminderEnabled, activeHabitCount > 0 else {
            try await cancel()
            return
        }
        switch await runtime.refreshAuthorization() {
        case .authorized: break
        case .notDetermined:
            guard await runtime.requestPermission() == .available else { throw HabitReminderError.permissionDenied }
        case .denied: throw HabitReminderError.permissionDenied
        }
        try await runtime.policy.setEnabled(true, for: .journaling)
        try await runtime.policy.remove(family: .journaling)
        var components = DateComponents()
        components.hour = settings.reminderHour
        components.minute = settings.reminderMinute
        let fireDate = Calendar.current.nextDate(
            after: Date(),
            matching: components,
            matchingPolicy: .nextTime
        ) ?? Date()
        let targetDay = Self.behaviorDay(
            before: fireDate,
            calendar: .current,
            fallback: behaviorDay
        )
        _ = try await runtime.policy.schedule(
            HabitReminderRequestFactory.request(
                behaviorDay: targetDay.habitKey,
                fireDate: fireDate
            )
        )
    }

    func cancel() async throws {
        try await runtime.policy.remove(family: .journaling)
        try await runtime.policy.setEnabled(false, for: .journaling)
    }

    static func behaviorDay(before fireDate: Date, calendar: Calendar, fallback: DayIdentity) -> DayIdentity {
        guard let date = calendar.date(byAdding: .day, value: -1, to: fireDate) else { return fallback }
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return fallback }
        return DayIdentity(era: components.era ?? 1, year: year, month: month, day: day)
    }
}

enum HabitReminderError: Error, LocalizedError {
    case permissionDenied
    var errorDescription: String? { "Allow notifications in Settings to use habit reminders." }
}
#else
typealias LooprNotificationRuntime = UnavailableNotificationSettingsEntryPoint
typealias CentralNotificationHabitReminderScheduler = NoOpHabitReminderScheduler
#endif
