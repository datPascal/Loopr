import Foundation
import Testing
import CycleKit

@testable import Loopr

@MainActor
struct PlatformDeletionTests {
    @Test
    func ownershipRegistryIsExplicitAndDoesNotUseWildcards() {
        #expect(LooprPlatformOwnedArtifacts.keychainService == "com.loopr.ios.loopr-owned")
        #expect(LooprPlatformOwnedArtifacts.keychainServices == [
            "com.loopr.ios.loopr-owned", "com.loopr.ios.ai-provider"
        ])
        #expect(LooprPlatformOwnedArtifacts.appGroupIdentifier == "group.com.loopr.shared")
        #expect(LooprPlatformOwnedArtifacts.notificationIdentifiers == [
            LooprPlatformOwnedArtifacts.cycleReminderIdentifier
        ])
        #expect(!LooprPlatformOwnedArtifacts.appGroupFileNames.contains { $0 == "*" })
        #expect(!LooprPlatformOwnedArtifacts.appGroupDirectoryNames.contains { $0 == "" })
    }

    @Test
    func notificationDeletionUsesOnlyLooprIdentifiers() async throws {
        let client = RecordingNotificationCenterClient(status: .denied)
        let deleter = LooprNotificationDataDeletionDeleter(client: client)

        try await deleter.deleteAll()

        #expect(await client.removeAllPendingCount() == 1)
        #expect(await client.removeAllDeliveredCount() == 1)
    }

    @Test
    func cycleSchedulerRequestsAuthorizationBeforeScheduling() async throws {
        let client = RecordingNotificationCenterClient(status: .notDetermined, requestResult: true)
        let scheduler = UserNotificationCycleReminderScheduler(client: client)

        try await scheduler.schedule(settings: CycleSettings(remindersEnabled: true, reminderHour: 6))

        #expect(await client.authorizationRequests() == 1)
        #expect(await client.scheduledIdentifiers() == [LooprPlatformOwnedArtifacts.cycleReminderIdentifier])
        #expect(await client.scheduledHours() == [6])
    }

    @Test
    func cycleSchedulerFailsClosedWhenNotificationsAreDenied() async throws {
        let client = RecordingNotificationCenterClient(status: .denied)
        let scheduler = UserNotificationCycleReminderScheduler(client: client)

        do {
            try await scheduler.schedule(settings: CycleSettings(remindersEnabled: true, reminderHour: 6))
            Issue.record("denied notifications must not persist a scheduled reminder")
        } catch let error as CycleError {
            #expect(error == .reminderDenied)
        }
        #expect(await client.scheduledRequests().isEmpty)
    }

    @Test
    func appGroupDeletionRemovesOwnedArtifactsButLeavesUnknownFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-platform-deletion-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in LooprPlatformOwnedArtifacts.appGroupFileNames {
            try Data("owned".utf8).write(to: root.appendingPathComponent(name))
        }
        for name in LooprPlatformOwnedArtifacts.appGroupDirectoryNames {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("owned".utf8).write(to: directory.appendingPathComponent("payload"))
        }
        let unrelated = root.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: unrelated)

        try await LooprAppGroupDataDeletionDeleter(containerURL: root).deleteAll()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("loopr.export.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("LooprExports").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func integrationLedgerDeletionCoversEveryRegisteredDirectoryOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-integration-ledgers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["NotificationKit", "HealthKitBridge", "AIKit", "Unrelated"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("ledger.json"))
        }
        try await LooprIntegrationLedgerDeletionDeleter(applicationSupportURL: root).deleteAll()
        for name in ["NotificationKit", "HealthKitBridge", "AIKit"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unrelated").path))
    }

    @Test
    func temporaryExportDeletionRemovesEveryOwnedPrefixAndLeavesOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-export-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let owned = [
            "loopr-export-fixture.sqlite",
            "loopr-cycle-fixture.json",
            "loopr-journal-fixture.json"
        ]
        for name in owned {
            try Data("private".utf8).write(to: root.appendingPathComponent(name))
        }
        let unrelated = root.appendingPathComponent("other-app-export.json")
        try Data("keep".utf8).write(to: unrelated)

        try await LooprTemporaryExportDataDeletionDeleter(directoryURL: root).deleteAll()

        for name in owned {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    #if canImport(ActivityKit)
    @Test
    func liveActivityDeletionEndsWorkoutAndBreathingActivities() async throws {
        let client = RecordingLiveActivityDeletionClient()

        try await LooprLiveActivityDataDeletionDeleter(client: client).deleteAll()

        #expect(await client.workoutEndCount() == 1)
        #expect(await client.breathingEndCount() == 1)
    }
    #endif

    @Test
    func watchSnapshotDeletionRevokesTheDeliveredApplicationContext() async throws {
        let client = RecordingWatchSnapshotDeletionClient()

        try await LooprWatchSnapshotDataDeletionDeleter(client: client).deleteAll()

        #expect(await client.clearCount() == 1)
    }
}

private actor RecordingWatchSnapshotDeletionClient: LooprWatchSnapshotDeletionClient {
    private var count = 0
    func clearSnapshot() { count += 1 }
    func clearCount() -> Int { count }
}

#if canImport(ActivityKit)
private actor RecordingLiveActivityDeletionClient: LooprLiveActivityDeletionClient {
    private var workoutCount = 0
    private var breathingCount = 0

    func endWorkoutActivities() { workoutCount += 1 }
    func endBreathingActivities() { breathingCount += 1 }
    func workoutEndCount() -> Int { workoutCount }
    func breathingEndCount() -> Int { breathingCount }
}
#endif

private actor RecordingNotificationCenterClient: LooprNotificationCenterClient {
    private var status: LooprNotificationAuthorizationStatus
    private let requestResult: Bool
    private var authorizationRequestCount = 0
    private var scheduled: [(String, Int)] = []
    private var pending: [String] = []
    private var delivered: [String] = []
    private var allPendingRemovalCount = 0
    private var allDeliveredRemovalCount = 0

    init(
        status: LooprNotificationAuthorizationStatus,
        requestResult: Bool = false
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() async -> LooprNotificationAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        if requestResult {
            status = .authorized
        }
        return requestResult
    }

    func addDailyRequest(identifier: String, hour: Int) async throws {
        scheduled.append((identifier, hour))
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        pending = identifiers
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        delivered = identifiers
    }
    func removeAllPendingNotificationRequests() async { allPendingRemovalCount += 1 }
    func removeAllDeliveredNotifications() async { allDeliveredRemovalCount += 1 }

    func authorizationRequests() -> Int { authorizationRequestCount }
    func scheduledRequests() -> [(String, Int)] { scheduled }
    func scheduledIdentifiers() -> [String] { scheduled.map { $0.0 } }
    func scheduledHours() -> [Int] { scheduled.map { $0.1 } }
    func pendingIDs() -> [String] { pending }
    func deliveredIDs() -> [String] { delivered }
    func removeAllPendingCount() -> Int { allPendingRemovalCount }
    func removeAllDeliveredCount() -> Int { allDeliveredRemovalCount }
}
