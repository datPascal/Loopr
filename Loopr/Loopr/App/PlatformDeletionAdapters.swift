import Foundation
import CycleKit

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(Security)
import Security
#endif

#if canImport(UserNotifications)
import UserNotifications
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Identifiers owned by the Loopr application outside the product database.
/// Keep this list explicit: APP-16 must never remove another application's
/// keychain records, notifications, files, or live activities.
nonisolated enum LooprPlatformOwnedArtifacts {
    static let keychainService = "com.loopr.ios.loopr-owned"
    static let aiKeychainService = "com.loopr.ios.ai-provider"
    static let keychainServices = [keychainService, aiKeychainService]
    static let appGroupIdentifier = "group.com.loopr.shared"

    static let appGroupFileNames = [
        "loopr.export.json",
        "loopr.pending-import.json",
        "loopr.live-activity.json",
        "surface.json"
    ]

    static let appGroupDirectoryNames = [
        "LooprExports",
        "LooprSnapshots"
    ]

    static let cycleReminderIdentifier = "com.loopr.cycle.reminder.daily.v1"
    static let notificationIdentifiers = [cycleReminderIdentifier]

    /// Export files remain in the app sandbox until shared or purged by iOS.
    /// Account deletion owns only these namespaced prefixes.
    static let temporaryExportPrefixes = [
        "loopr-export-",
        "loopr-cycle-",
        "loopr-journal-"
    ]
}

/// A small, deterministic notification boundary shared by Cycle reminders
/// and destructive deletion. The production implementation below is the only
/// type that talks to UNUserNotificationCenter; tests can inject an actor fake.
enum LooprNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unavailable
}

nonisolated protocol LooprNotificationCenterClient: Sendable {
    func authorizationStatus() async -> LooprNotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func addDailyRequest(identifier: String, hour: Int) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
    func removeAllPendingNotificationRequests() async
    func removeAllDeliveredNotifications() async
}

#if canImport(UserNotifications)

private final class LiveLooprNotificationCenterClient: @unchecked Sendable, LooprNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> LooprNotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.map(settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func addDailyRequest(identifier: String, hour: Int) async throws {
        var date = DateComponents()
        date.hour = hour
        let content = UNMutableNotificationContent()
        content.title = "Loopr cycle check-in"
        content.body = "Log how you feel today when it works for you."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllPendingNotificationRequests() async { center.removeAllPendingNotificationRequests() }
    func removeAllDeliveredNotifications() async { center.removeAllDeliveredNotifications() }

    private static func map(_ status: UNAuthorizationStatus) -> LooprNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .unavailable
        }
    }
}

#endif

/// Production Cycle reminder scheduling. It requests authorization only when
/// a user enables reminders, and never treats denied or unavailable delivery
/// as a successful persisted setting.
struct UserNotificationCycleReminderScheduler: CycleReminderScheduler {
    private let client: any LooprNotificationCenterClient

    init(client: (any LooprNotificationCenterClient)? = nil) {
        #if canImport(UserNotifications)
        self.client = client ?? LiveLooprNotificationCenterClient()
        #else
        self.client = client ?? UnavailableLooprNotificationCenterClient()
        #endif
    }

    init(client: any LooprNotificationCenterClient) {
        self.client = client
    }

    func schedule(settings: CycleSettings) async throws {
        guard settings.remindersEnabled, let hour = settings.reminderHour else {
            try await cancel()
            return
        }
        guard (0...23).contains(hour) else {
            throw CycleError.invalidReminderHour
        }

        switch await client.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            throw CycleError.reminderDenied
        case .notDetermined:
            do {
                guard try await client.requestAuthorization() else {
                    throw CycleError.reminderDenied
                }
            } catch let error as CycleError {
                throw error
            } catch {
                throw CycleError.reminderUnavailable
            }
        case .unavailable:
            throw CycleError.reminderUnavailable
        }

        // Replacing the stable identifier is intentional: one enabled Cycle
        // reminder exists at a time, and stale schedules cannot accumulate.
        await client.removePendingNotificationRequests(
            withIdentifiers: LooprPlatformOwnedArtifacts.notificationIdentifiers
        )
        try await client.addDailyRequest(
            identifier: LooprPlatformOwnedArtifacts.cycleReminderIdentifier,
            hour: hour
        )
    }

    func cancel() async throws {
        await client.removePendingNotificationRequests(
            withIdentifiers: LooprPlatformOwnedArtifacts.notificationIdentifiers
        )
        await client.removeDeliveredNotifications(
            withIdentifiers: LooprPlatformOwnedArtifacts.notificationIdentifiers
        )
    }
}

/// Removes only notifications whose identifiers are registered in the Loopr
/// ownership table. Notification authorization is not required to remove an
/// already pending or delivered local notification.
struct LooprNotificationDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "notifications.loopr-owned"
    private let client: any LooprNotificationCenterClient

    init(client: any LooprNotificationCenterClient) {
        self.client = client
    }

    #if canImport(UserNotifications)
    init(center: UNUserNotificationCenter = .current()) {
        self.client = LiveLooprNotificationCenterClient(center: center)
    }
    #endif

    func deleteAll() async throws {
        // UNUserNotificationCenter is namespaced to this application. Clearing all here
        // covers dynamic family/object/day identifiers as well as the legacy cycle ID.
        await client.removeAllPendingNotificationRequests()
        await client.removeAllDeliveredNotifications()
    }
}

private struct UnavailableLooprNotificationCenterClient: LooprNotificationCenterClient {
    func authorizationStatus() async -> LooprNotificationAuthorizationStatus { .unavailable }
    func requestAuthorization() async throws -> Bool { throw CycleError.reminderUnavailable }
    func addDailyRequest(identifier: String, hour: Int) async throws { throw CycleError.reminderUnavailable }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}
    func removeAllPendingNotificationRequests() async {}
    func removeAllDeliveredNotifications() async {}
}

#if canImport(Security)

/// Deletes generic-password records under Loopr's exact service namespace.
/// The query does not use `kSecMatchLimitAll` or a wildcard account, so an
/// unrelated service/account cannot be touched.
struct LooprKeychainDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "keychain.loopr-owned"

    func deleteAll() async throws {
        for service in LooprPlatformOwnedArtifacts.keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }
}

#else

struct LooprKeychainDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "keychain.loopr-owned"

    func deleteAll() async throws {
        throw PersistentDataDeletionError.unavailableExternalStore(storeName)
    }
}

#endif

/// Deletes known Loopr files and the Loopr-owned shared defaults suite from
/// the application group. It never recursively removes the group container.
struct LooprAppGroupDataDeletionDeleter: PersistentDataDeletionDeleter, @unchecked Sendable {
    nonisolated let storeName = "app-group.loopr-owned"
    private let containerURL: URL?

    init(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: LooprPlatformOwnedArtifacts.appGroupIdentifier
    )) {
        self.containerURL = containerURL
    }

    func deleteAll() async throws {
        guard let containerURL else {
            throw PersistentDataDeletionError.unavailableExternalStore(storeName)
        }
        let fileManager = FileManager.default
        for name in LooprPlatformOwnedArtifacts.appGroupFileNames {
            try removeIfPresent(containerURL.appendingPathComponent(name, isDirectory: false), fileManager: fileManager)
        }
        for name in LooprPlatformOwnedArtifacts.appGroupDirectoryNames {
            try removeIfPresent(containerURL.appendingPathComponent(name, isDirectory: true), fileManager: fileManager)
        }
        UserDefaults(suiteName: LooprPlatformOwnedArtifacts.appGroupIdentifier)?
            .removePersistentDomain(forName: LooprPlatformOwnedArtifacts.appGroupIdentifier)
        // The snapshot publisher is stopped before this runs, so nothing else
        // will ask the widgets to redraw. Without this the Home and Lock
        // screen keep showing deleted numbers until the timeline expires.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func removeIfPresent(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

/// Removes durable integration ledgers stored in Application Support. These directories
/// contain no SQLite schema and are therefore outside StorageDatabase.deleteAllData().
struct LooprIntegrationLedgerDeletionDeleter: PersistentDataDeletionDeleter, @unchecked Sendable {
    nonisolated let storeName = "application-support.integration-ledgers"
    private let applicationSupportURL: URL
    private let directoryNames = ["NotificationKit", "HealthKitBridge", "AIKit"]

    init(applicationSupportURL: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]) {
        self.applicationSupportURL = applicationSupportURL
    }

    func deleteAll() async throws {
        let manager = FileManager.default
        for name in directoryNames {
            let url = applicationSupportURL.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
    }
}

/// Removes locally prepared export files while leaving unrelated temporary
/// files alone. Copies the user has shared outside Loopr's sandbox remain
/// under the destination app's control.
struct LooprTemporaryExportDataDeletionDeleter: PersistentDataDeletionDeleter, @unchecked Sendable {
    nonisolated let storeName = "temporary-exports.loopr-owned"
    private let directoryURL: URL

    init(directoryURL: URL = FileManager.default.temporaryDirectory) {
        self.directoryURL = directoryURL
    }

    func deleteAll() async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directoryURL.path) else { return }
        let entries = try manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for url in entries where LooprPlatformOwnedArtifacts.temporaryExportPrefixes.contains(
            where: { url.lastPathComponent.hasPrefix($0) }
        ) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try manager.removeItem(at: url)
        }
    }
}

protocol LooprWatchSnapshotDeletionClient: Sendable {
    func clearSnapshot() async throws
}

extension LooprWatchSnapshotBridge: LooprWatchSnapshotDeletionClient {
    func clearSnapshot() async throws {
        try await clear()
    }
}

/// Revokes the durable application context already delivered to the paired
/// Watch. The Watch clears its local App Group snapshot when it receives the
/// empty context.
struct LooprWatchSnapshotDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "watch-connectivity.snapshot"
    private let client: any LooprWatchSnapshotDeletionClient

    init(client: any LooprWatchSnapshotDeletionClient = LooprWatchSnapshotBridge.shared) {
        self.client = client
    }

    func deleteAll() async throws {
        try await client.clearSnapshot()
    }
}

#if canImport(ActivityKit)

protocol LooprLiveActivityDeletionClient: Sendable {
    func endWorkoutActivities() async
    func endBreathingActivities() async
}

private struct LiveLooprActivityDeletionClient: LooprLiveActivityDeletionClient {
    func endWorkoutActivities() async {
        await LooprIntervalRuntime.shared.endAll()
        await LooprLiveActivityRuntime.shared.recover(canonicalWorkout: nil)
    }

    func endBreathingActivities() async {
        await LooprHandsFreeRuntime.shared.stopBreathingForDeletion()
        await LooprBreathingLiveActivityHook.shared.endOrphans()
    }
}

/// Ends Loopr workout, interval and breathing Live Activities and clears the breathing
/// runtime's in-memory session registry.
@available(iOS 16.1, *)
struct LooprLiveActivityDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "live-activities.loopr-owned"
    private let client: any LooprLiveActivityDeletionClient

    init(client: any LooprLiveActivityDeletionClient = LiveLooprActivityDeletionClient()) {
        self.client = client
    }

    func deleteAll() async throws {
        await client.endWorkoutActivities()
        await client.endBreathingActivities()
    }
}

#else

struct LooprLiveActivityDataDeletionDeleter: PersistentDataDeletionDeleter {
    nonisolated let storeName = "live-activities.loopr-owned"

    func deleteAll() async throws {
        throw PersistentDataDeletionError.unavailableExternalStore(storeName)
    }
}

#endif
