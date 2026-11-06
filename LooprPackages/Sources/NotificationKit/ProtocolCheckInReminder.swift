import Foundation

/// The evening check-in reminder, one of "Reminders you set" (DEC-07.1). Loopr offers it once, on the "Your list is
/// ready" card after a template (ICP R1-SEN-04), and sets it only when the person taps "Remind me". One reminder for
/// the whole protocol, daily at the time the card named, with a title and a line that name no rule and no value. It
/// uses its own object ID beside the rule reminders (`protocol.rule.<key>`), so saving rules never moves or removes it.
/// Quiet hours do not hold it back, and it counts toward the cap of 10 pending reminders that all sources share. A
/// tap opens the day's check-in.
public enum ProtocolCheckInReminder {
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

    public static let objectID = "protocol.checkin"
    public static let title = "Evening check-in"
    public static let detail = "Your rules for today are ready to answer."

    public static func isCheckInReminder(_ request: NotificationRequest) -> Bool {
        request.identity.family == .userReminders && request.identity.objectID == objectID
    }

    /// - Parameters:
    ///   - minuteOfDay: 0 to 1439, in `calendar`'s time zone.
    ///   - pending: what `pendingReminders()` returns now, from every source.
    public static func build(minuteOfDay: Int, now: Date, calendar: Calendar, pending: [NotificationRequest]) -> Outcome {
        guard (0..<1_440).contains(minuteOfDay),
              let fire = calendar.nextDate(after: now, matching: DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60),
                                           matchingPolicy: .nextTime) else { return .refused(.invalidTime) }
        let identity = NotificationIdentity(family: .userReminders, objectID: objectID, day: "recurring")
        let waiting = Set(pending.map(\.identity).filter { $0.family == .userReminders })
        let replaces = waiting.contains(identity)
        let limit = NotificationFamily.userReminderLimit
        if !replaces, waiting.count >= limit { return .refused(.full(limit: limit)) }
        let parts = calendar.dateComponents([.year, .month, .day], from: fire)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let request = NotificationRequest(
            identity: identity, fireDate: fire, title: title, detail: detail, sensitivity: .userRequestedAlert,
            deepLink: .journal(day), quietHoursBehavior: .deliver, repeats: .daily)
        return .request(request, replacesPending: replaces)
    }
}
