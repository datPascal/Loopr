import Foundation
import NotificationKit
import RoutineKit

/// Turns a due test into a "Reminders you set" request (DEC-07.1).
///
/// The text names the test and nothing else: never a lab value, a result or a date of birth, because the lock screen
/// shows it as written. The person confirms the exact words before it is set. It fires once, at 09:00 on the day the
/// test is due (or the next 09:00 when that day has passed), and it counts toward the cap of 10 pending reminders
/// that every source shares.
public enum LabTestReminder {
    public enum Refusal: Equatable, Sendable {
        case full(limit: Int)
        case invalidTime
    }

    public enum Outcome: Equatable, Sendable {
        /// Schedule this request. `replacesPending` is true when a reminder for the same test is already waiting, so
        /// the caller removes it first and the count does not grow.
        case request(NotificationRequest, replacesPending: Bool)
        case refused(Refusal)
    }

    public static let minuteOfDay = 9 * 60
    public static let longestTitle = 40

    /// One reminder per rule: `tests.blood-test`.
    public static func objectID(_ key: RuleKey) -> String { "tests.\(key.rawValue)" }

    /// "Blood test due". A custom test keeps the person's own title.
    public static func title(for test: LabTestDue) -> String {
        let name = test.title
        let clipped = name.count > longestTitle ? String(name.prefix(longestTitle)).trimmingCharacters(in: .whitespaces) : name
        return "\(clipped) due"
    }

    public static let detail = "Open Loopr to log it."

    public static func isTestReminder(_ request: NotificationRequest) -> Bool {
        request.identity.family == .userReminders && request.identity.objectID.hasPrefix("tests.")
    }

    /// 09:00 on the due day, or the next 09:00 when that has passed or the test has no date yet.
    public static func fireDate(for test: LabTestDue, now: Date, calendar: Calendar) -> Date? {
        let from = max(calendar.startOfDay(for: test.nextDue ?? now), now)
        return calendar.nextDate(after: from, matching: DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60),
                                 matchingPolicy: .nextTime)
    }

    /// - Parameter pending: what `pendingReminders()` returns now, from every source.
    public static func build(test: LabTestDue, now: Date, calendar: Calendar, pending: [NotificationRequest]) -> Outcome {
        guard let fire = fireDate(for: test, now: now, calendar: calendar) else { return .refused(.invalidTime) }
        let object = objectID(test.ruleKey)
        let waiting = pending.filter { $0.identity.family == .userReminders }
        let replaces = waiting.contains { $0.identity.objectID == object }
        let limit = NotificationFamily.userReminderLimit
        if !replaces, Set(waiting.map(\.identity)).count >= limit { return .refused(.full(limit: limit)) }
        let parts = calendar.dateComponents([.year, .month, .day], from: fire)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let request = NotificationRequest(
            identity: NotificationIdentity(family: .userReminders, objectID: object, day: day), fireDate: fire,
            title: title(for: test), detail: detail, sensitivity: .userRequestedAlert, deepLink: .today(day),
            quietHoursBehavior: .deliver)
        return .request(request, replacesPending: replaces)
    }
}
