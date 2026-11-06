import AnalyticsKit
import DataKit
import DomainKit
import Foundation
import NotificationKit
import ProfileKit
import RoutineKit
import SettingsKit
import StorageKit
import TrainKit

// LV-08b step 2: what the blood test screens read and write. This file only maps the app's repositories onto the
// stores that hold the data and decides nothing: ranges and flags stay the lab's own, and no value is judged.

/// The stores behind the blood test screens.
nonisolated struct LabsServices: Sendable {
    let labs: LabStore
    let routine: RoutineStore
    let capacity: CapacityStore
    /// The profile's birth year, for the blood age check. Nil when none is saved.
    let birthYear: @Sendable () async -> Int?

    init(database: StorageDatabase, birthYear: @escaping @Sendable () async -> Int?) {
        labs = LabStore(database: database)
        routine = RoutineStore(database: database)
        capacity = CapacityStore(database: database)
        self.birthYear = birthYear
    }
}

@MainActor
enum LabsServicesProvider {
    /// Production reads the one database. A fixture launch uses a scratch database of its own, so a DEBUG run never
    /// touches a durable store. Nil when storage could not open.
    static func services(for repositories: ProductRepositoryContainer) -> LabsServices? {
        if let persistent = repositories.persistent {
            let profile = persistent.profile
            return LabsServices(database: persistent.database, birthYear: { try? await profile.readProfile()?.birthYear })
        }
        #if DEBUG
        if repositories.isFixtureComposition { return fixture }
        #endif
        return nil
    }

    #if DEBUG
    private static let fixture: LabsServices? = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LooprLabsFixture-\(UUID().uuidString)")
        guard let database = try? StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "labs-fixture") else {
            return nil
        }
        return LabsServices(database: database, birthYear: { nil })
    }()
    #endif
}

nonisolated enum LabsReader {
    @concurrent
    static func list(_ services: LabsServices, now: Date, calendar: Calendar, reminded: Set<RuleKey>) async throws -> LabsListSnapshot {
        let tests = try LabTestsDueBuilder.load(routine: services.routine, labs: services.labs, capacity: services.capacity,
                                                now: now, calendar: calendar)
        return try services.labs.listSnapshot(tests: tests, remindedTests: reminded, now: now, calendar: calendar)
    }

    @concurrent
    static func detail(_ services: LabsServices, reportID: UUID) async throws -> LabReportDetail? {
        try services.labs.detail(reportID: reportID, birthYear: await services.birthYear())
    }

    /// Saves a report with its values and returns once they are stored.
    @concurrent
    static func save(_ services: LabsServices, report: LabReport, values: [LabValue]) async throws {
        try services.labs.saveReport(report, values: values)
    }

    @concurrent
    static func save(_ services: LabsServices, clock: LabClockResult) async throws {
        try services.labs.saveClockResult(clock)
    }

    @concurrent
    static func update(_ services: LabsServices, value: LabValue) async throws {
        try services.labs.updateValue(value)
    }

    @concurrent
    static func delete(_ services: LabsServices, reportID: UUID) async throws {
        try services.labs.deleteReport(id: reportID)
    }

    @concurrent
    static func delete(_ services: LabsServices, clockID: UUID) async throws {
        try services.labs.deleteClockResult(id: clockID)
    }

    @concurrent
    static func markDone(_ services: LabsServices, ruleKey: RuleKey, now: Date, calendar: Calendar) async throws {
        try LabTestsDueBuilder.markDone(ruleKey: ruleKey, routine: services.routine, now: now, calendar: calendar)
    }
}

#if canImport(UserNotifications)
extension LooprNotificationRuntime {
    /// The tests that have a waiting reminder.
    func testReminderKeys() async -> Set<RuleKey> {
        Set(await userReminders().filter(LabTestReminder.isTestReminder).map {
            RuleKey(rawValue: String($0.identity.objectID.dropFirst("tests.".count)))
        })
    }

    /// Sets or moves the reminder for one test, after the person confirmed its words. Asks for permission here, on
    /// that confirmation, and never before.
    func scheduleTestReminder(_ test: LabTestDue, now: Date, calendar: Calendar) async -> UserReminderOutcome {
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined: guard await requestPermission() == .available else { return .notAllowed }
        case .denied: return .notAllowed
        }
        switch LabTestReminder.build(test: test, now: now, calendar: calendar, pending: await userReminders()) {
        case .refused(.full): return .full
        case .refused(.invalidTime): return .failed
        case .request(let request, let replacesPending):
            if replacesPending {
                try? await policy.remove(family: .userReminders, objectID: request.identity.objectID)
            }
            do {
                switch try await policy.schedule(request) {
                case .scheduled, .deferred, .duplicate: return .set
                case .disabled: return .familyOff
                case .denied, .queued: return .notAllowed
                case .limitReached: return .full
                case .quietHours, .expired: return .failed
                }
            } catch { return .failed }
        }
    }

    func cancelTestReminder(_ key: RuleKey) async {
        try? await policy.remove(family: .userReminders, objectID: LabTestReminder.objectID(key))
    }
}

nonisolated enum LabsReminderCopy {
    static func message(for outcome: UserReminderOutcome) -> String? {
        switch outcome {
        case .set: nil
        case .notAllowed: "Notifications are off for Loopr, so the reminder was not set. You can turn them on in Settings."
        case .full: "\(NotificationFamily.userReminderLimit) reminders are already waiting. Cancel one in Settings, then try again."
        case .familyOff: "Reminders you set are off in Settings. Turn them on to set this one."
        case .failed: "Loopr could not set the reminder. Try again."
        }
    }
}
#endif
