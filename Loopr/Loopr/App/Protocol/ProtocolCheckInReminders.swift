import Foundation
import JournalKit
import NotificationKit
import SettingsKit

/// The evening check-in reminder the "Your list is ready" card offers (ICP R1-SEN-04), through NotificationKit's
/// "Reminders you set" (DEC-07.1). Permission is asked on the person's "Remind me" tap and never before.
extension ProtocolTabComposition {
    /// The person's own database gets the real reminder. A DEBUG fixture launch gets one that only remembers the time,
    /// so the screenshot tour can show the card after "Remind me" without touching the simulator's notifications.
    static func checkInReminder(repositories: ProductRepositoryContainer?) -> (any ProtocolCheckInReminding)? {
        #if canImport(UserNotifications)
        if repositories?.persistent != nil { return ProtocolCheckInNotificationReminder() }
        #endif
        #if DEBUG
        if repositories?.isFixtureComposition == true { return ProtocolCheckInFixtureReminder.shared }
        #endif
        return nil
    }
}

#if canImport(UserNotifications)
nonisolated struct ProtocolCheckInNotificationReminder: ProtocolCheckInReminding {
    func waitingMinute() async -> Int? {
        await LooprNotificationRuntime.shared.protocolCheckInReminderMinute(calendar: .current)
    }

    func set(minuteOfDay: Int) async -> String? {
        let outcome = await LooprNotificationRuntime.shared.scheduleProtocolCheckInReminder(minuteOfDay: minuteOfDay, calendar: .current)
        return ProtocolRuleNotificationReminders.message(outcome)
    }
}

extension LooprNotificationRuntime {
    /// The waiting check-in reminder's minute of the day on `calendar`'s clock, or nil.
    func protocolCheckInReminderMinute(calendar: Calendar) async -> Int? {
        guard let request = await userReminders().first(where: ProtocolCheckInReminder.isCheckInReminder) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: request.fireDate)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    func scheduleProtocolCheckInReminder(minuteOfDay: Int, calendar: Calendar) async -> UserReminderOutcome {
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined: guard await requestPermission() == .available else { return .notAllowed }
        case .denied: return .notAllowed
        }
        switch ProtocolCheckInReminder.build(minuteOfDay: minuteOfDay, now: Date(), calendar: calendar, pending: await userReminders()) {
        case .refused(.full): return .full
        case .refused(.invalidTime): return .failed
        case .request(let request, let replacesPending):
            if replacesPending {
                try? await policy.remove(family: .userReminders, objectID: request.identity.objectID, day: request.identity.day)
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
}
#endif

#if DEBUG
/// The fixture launch's check-in reminder: it keeps the time in memory for the launch and schedules nothing.
nonisolated final class ProtocolCheckInFixtureReminder: ProtocolCheckInReminding, @unchecked Sendable {
    static let shared = ProtocolCheckInFixtureReminder()
    private let lock = NSLock()
    private var minute: Int?

    func waitingMinute() async -> Int? { lock.withLock { minute } }

    func set(minuteOfDay: Int) async -> String? {
        lock.withLock { minute = minuteOfDay }
        return nil
    }
}
#endif
