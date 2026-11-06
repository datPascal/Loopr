import Foundation
import NotificationKit
import RoutineKit
import SettingsKit
#if canImport(UserNotifications)
import UserNotifications

/// Everything the app needs to schedule one reminder the person confirmed.
nonisolated struct UserReminderDraft: Equatable, Sendable {
    var source: UserReminderSource
    /// `ask.<proposal id>` or `patterns.<test id>`.
    var objectID: String
    var title: String
    var body: String
    var minuteOfDay: Int
    var repeatsDaily: Bool
    /// The first time it fires.
    var firstFire: Date
    /// A daily reminder that stops being useful, such as the reminder of a 14-day test.
    var expiresAt: Date?
}

nonisolated enum UserReminderOutcome: Equatable, Sendable {
    case set
    /// iOS notifications are off for Loopr, or the person just refused the prompt.
    case notAllowed
    /// Ten reminders are already waiting.
    case full
    /// The person turned "Reminders you set" off in Settings.
    case familyOff
    case failed
}

/// Posted when the person cancels a Patterns test reminder from Settings. The user info carries the test id.
let looprPatternReminderCancelledName = Notification.Name("com.loopr.patterns.reminder-cancelled")

extension LooprNotificationRuntime {
    /// Asks for permission when it has not been asked, then schedules through the notification layer. Asking
    /// happens here, on the person's confirmation, and never provisionally.
    func scheduleUserReminder(_ draft: UserReminderDraft, askPermission: Bool = true) async -> UserReminderOutcome {
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined:
            // A quiet check never asks, and never writes a result the person did not cause.
            guard askPermission else { return .notAllowed }
            guard await requestPermission() == .available else {
                await policy.recordReminderOutcome(.notAllowed, source: draft.source, title: draft.title,
                                                   minuteOfDay: draft.minuteOfDay, repeatsDaily: draft.repeatsDaily)
                return .notAllowed
            }
        case .denied:
            await policy.recordReminderOutcome(.notAllowed, source: draft.source, title: draft.title,
                                               minuteOfDay: draft.minuteOfDay, repeatsDaily: draft.repeatsDaily)
            return .notAllowed
        }
        let request = UserReminderRequestFactory.request(
            source: draft.source, objectID: draft.objectID,
            day: draft.repeatsDaily ? UserReminderRequestFactory.recurringDay : Self.dayKey(draft.firstFire),
            fireDate: draft.firstFire, title: draft.title, detail: draft.body,
            repeats: draft.repeatsDaily ? .daily : nil, expiresAt: draft.expiresAt)
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

    func userReminders() async -> [NotificationRequest] {
        (try? await policy.pendingReminders()) ?? []
    }

    func userReminderHistory() async -> [ReminderHistoryEntry] { await policy.reminderHistory() }

    func quietHoursContain(minuteOfDay: Int) async -> Bool { await policy.quietHoursContain(minuteOfDay: minuteOfDay) }

    /// The cancel action in Settings.
    func cancelUserReminder(_ request: NotificationRequest) async {
        // A rule reminder is one reminder however many days it has planned, and Cancel turns it off for good.
        if ProtocolRuleReminder.isRuleReminder(request), let key = ProtocolRuleReminder.ruleKey(from: request.identity.objectID) {
            await ProtocolRuleReminderPlanning.shared.remove(RuleKey(rawValue: key))
            return
        }
        try? await policy.remove(family: .userReminders, objectID: request.identity.objectID, day: request.identity.day)
        if request.reminderSource == .patternsTest, let id = Self.patternTestID(from: request.identity.objectID) {
            await MainActor.run {
                NotificationCenter.default.post(name: looprPatternReminderCancelledName, object: nil,
                                                userInfo: ["testID": id.uuidString])
            }
        }
    }

    /// Cancels every reminder one source set, or one reminder when `objectID` is given.
    func cancelUserReminders(source: UserReminderSource, objectID: String? = nil) async {
        let waiting = await userReminders().filter { $0.reminderSource == source }
        for request in waiting where objectID == nil || request.identity.objectID == objectID {
            try? await policy.remove(family: .userReminders, objectID: request.identity.objectID, day: request.identity.day)
        }
    }

    static func patternObjectID(_ testID: UUID) -> String { "patterns." + testID.uuidString }
    static func patternTestID(from objectID: String) -> UUID? {
        objectID.hasPrefix("patterns.") ? UUID(uuidString: String(objectID.dropFirst("patterns.".count))) : nil
    }

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The next time it is `minuteOfDay` after `date`, on the phone's clock.
    static func nextOccurrence(ofMinute minuteOfDay: Int, after date: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60),
                          matchingPolicy: .nextTime)
    }

    /// Adopts or removes the pending requests earlier builds scheduled straight with the system, so none keeps
    /// firing without a place in Settings.
    func migrateLegacyReminders() async {
        let key = "loopr.reminders.legacy-migrated.v1" // gitleaks:allow
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let summary = await LegacyReminderMigration.run(center: LiveLegacyReminderCenter(center: UNUserNotificationCenter.current()), policy: policy)
        guard summary.complete else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !summary.patternTestIDs.isEmpty {
            let stored = Set(UserDefaults.standard.stringArray(forKey: LegacyReminderMigration.patternsToRestoreKey) ?? [])
            UserDefaults.standard.set(Array(stored.union(summary.patternTestIDs.map(\.uuidString))),
                                      forKey: LegacyReminderMigration.patternsToRestoreKey)
        }
    }
}

// MARK: Migration

/// One pending request an earlier build scheduled straight with the system.
nonisolated struct LegacyPendingReminder: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    var minuteOfDay: Int?
    var repeats: Bool
    var nextFire: Date?
}

nonisolated protocol LegacyReminderCenter: Sendable {
    func pending() async -> [LegacyPendingReminder]
    func remove(identifiers: [String]) async
}

nonisolated struct LiveLegacyReminderCenter: LegacyReminderCenter, @unchecked Sendable {
    let center: UNUserNotificationCenter

    func pending() async -> [LegacyPendingReminder] {
        await center.pendingNotificationRequests().compactMap { request in
            guard request.identifier.hasPrefix(LegacyReminderMigration.askPrefix)
                    || request.identifier.hasPrefix(LegacyReminderMigration.patternsPrefix) else { return nil }
            let trigger = request.trigger as? UNCalendarNotificationTrigger
            let minute = trigger.flatMap { t in t.dateComponents.hour.map { $0 * 60 + (t.dateComponents.minute ?? 0) } }
            return LegacyPendingReminder(identifier: request.identifier, title: request.content.title, body: request.content.body,
                                         minuteOfDay: minute, repeats: trigger?.repeats ?? false,
                                         nextFire: trigger?.nextTriggerDate())
        }
    }

    func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

nonisolated enum LegacyReminderMigration {
    static let askPrefix = "loopr.agent.reminder."
    static let patternsPrefix = "loopr.pattern.test."
    /// Tests that had reminders under the old scheme, for the Patterns engine to schedule again.
    static let patternsToRestoreKey = "loopr.reminders.patterns-to-restore"

    struct Summary: Equatable, Sendable {
        var adopted = 0
        var removed = 0
        var patternTestIDs: [UUID] = []
        /// False when the pass could not finish, so the next launch tries again.
        var complete = true
    }

    /// Ask reminders move into the notification layer with the same words, time and repeat. Patterns test
    /// reminders were one request per day, so they are removed, and the engine schedules one repeating reminder
    /// for each running test. A request the layer refuses, because the family is off or ten are waiting, is removed.
    static func run(center: any LegacyReminderCenter, policy: NotificationPolicy, now: Date = Date()) async -> Summary {
        var summary = Summary()
        let legacy = await center.pending()
        guard !legacy.isEmpty else { return summary }
        var testIDs: [UUID] = []
        var toRemove: [String] = []
        for item in legacy {
            if item.identifier.hasPrefix(askPrefix) {
                let suffix = String(item.identifier.dropFirst(askPrefix.count))
                guard let minute = item.minuteOfDay, UUID(uuidString: suffix) != nil else { toRemove.append(item.identifier); continue }
                let fire = item.nextFire ?? LooprNotificationRuntime.nextOccurrence(ofMinute: minute, after: now) ?? now
                let request = UserReminderRequestFactory.request(
                    source: .ask, objectID: "ask." + suffix,
                    day: item.repeats ? UserReminderRequestFactory.recurringDay : LooprNotificationRuntime.dayKey(fire),
                    fireDate: fire, title: item.title, detail: item.body, repeats: item.repeats ? .daily : nil)
                switch try? await policy.schedule(request) {
                case .scheduled?, .duplicate?, .deferred?: summary.adopted += 1
                case nil: summary.complete = false; continue
                default: break
                }
                toRemove.append(item.identifier)
            } else if item.identifier.hasPrefix(patternsPrefix) {
                let suffix = String(item.identifier.dropFirst(patternsPrefix.count))
                if let id = UUID(uuidString: String(suffix.prefix(36))), !testIDs.contains(id) { testIDs.append(id) }
                toRemove.append(item.identifier)
            }
        }
        if !toRemove.isEmpty { await center.remove(identifiers: toRemove) }
        summary.removed = toRemove.count - summary.adopted
        summary.patternTestIDs = testIDs
        return summary
    }
}
#endif
