import Foundation

/// The weekly review reminder, one of "Reminders you set" (DEC-07.1). It is off until the person turns it on in
/// Settings > Notifications. It fires every Sunday at 18:00 on the phone's clock, quiet hours do not hold it back, and
/// it counts toward the cap of 10 pending reminders that all sources share. Its text names the review and nothing
/// else, so the lock screen never shows a health value. A tap opens the review sheet.
public enum WeeklyReviewReminder {
    public enum Refusal: Equatable, Sendable {
        /// Ten reminders are already waiting, and this one would be an eleventh.
        case full(limit: Int)
        case invalidTime
    }

    public enum Outcome: Equatable, Sendable {
        /// Schedule this request. `replacesPending` is true when the reminder is already waiting, so the caller removes
        /// it first and the count does not grow.
        case request(NotificationRequest, replacesPending: Bool)
        case refused(Refusal)
    }

    /// One reminder for the whole app.
    public static let objectID = "weekly.review"
    public static let title = "Weekly review"
    public static let detail = "Your week is ready to read."
    /// Sunday, as `Calendar` numbers weekdays.
    public static let weekday = 1
    /// 18:00, an hour after the review opens on Today.
    public static let minuteOfDay = 18 * 60

    public static func isWeeklyReviewReminder(_ request: NotificationRequest) -> Bool {
        request.identity.family == .userReminders && request.identity.objectID == objectID
    }

    /// - Parameter pending: what `pendingReminders()` returns now, from every source.
    public static func build(now: Date, calendar: Calendar, pending: [NotificationRequest]) -> Outcome {
        let parts = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, weekday: weekday)
        guard let fire = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) else {
            return .refused(.invalidTime)
        }
        let identity = NotificationIdentity(family: .userReminders, objectID: objectID, day: "recurring")
        let waiting = Set(pending.map(\.identity).filter { $0.family == .userReminders })
        let replaces = waiting.contains(identity)
        let limit = NotificationFamily.userReminderLimit
        if !replaces, waiting.count >= limit { return .refused(.full(limit: limit)) }
        let request = NotificationRequest(
            identity: identity, fireDate: fire, title: title, detail: detail, sensitivity: .userRequestedAlert,
            deepLink: .weeklyReview(objectID), quietHoursBehavior: .deliver, repeats: .weekly)
        return .request(request, replacesPending: replaces)
    }
}
