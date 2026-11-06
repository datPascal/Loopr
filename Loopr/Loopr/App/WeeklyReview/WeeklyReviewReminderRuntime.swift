import DesignSystem
import Foundation
import NotificationKit
import SettingsKit

#if canImport(UserNotifications)
/// The weekly review reminder through "Reminders you set" (DEC-07.1). Off until the person turns it on in Settings >
/// Notifications; permission is asked on that tap and never before.
extension LooprNotificationRuntime {
    func weeklyReviewReminderIsWaiting() async -> Bool {
        await userReminders().contains(where: WeeklyReviewReminder.isWeeklyReviewReminder)
    }

    func scheduleWeeklyReviewReminder(calendar: Calendar = .current) async -> UserReminderOutcome {
        switch await refreshAuthorization() {
        case .authorized: break
        case .notDetermined: guard await requestPermission() == .available else { return .notAllowed }
        case .denied: return .notAllowed
        }
        switch WeeklyReviewReminder.build(now: Date(), calendar: calendar, pending: await userReminders()) {
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

    func cancelWeeklyReviewReminder() async {
        try? await policy.remove(family: .userReminders, objectID: WeeklyReviewReminder.objectID)
    }
}
#endif

/// Words for the weekly review row under "Reminders you set".
enum WeeklyReviewReminderCopy {
    static let title = WeeklyReviewReminder.title

    /// "Every Sunday at 18:00. A tap opens your week."
    static var subtitle: String {
        "Every Sunday at \(LooprClockFormat.text(minuteOfDay: WeeklyReviewReminder.minuteOfDay)). A tap opens your week."
    }
}

#if canImport(UserNotifications)
extension WeeklyReviewReminderCopy {
    static func message(_ outcome: UserReminderOutcome) -> String? {
        switch outcome {
        case .set: nil
        case .notAllowed: "Notifications are off for Loopr. Turn them on in the Settings app to get this reminder."
        case .full: "Ten reminders are already waiting. Remove one above to set this one."
        case .familyOff: "Reminders you set is off. Turn it on above to get this reminder."
        case .failed: "Loopr could not set this reminder."
        }
    }
}
#endif
