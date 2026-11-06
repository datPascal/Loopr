import Foundation
import NotificationKit

/// Turns a stack slot's reminder time into a "Reminders you set" request (DEC-07.1).
///
/// The text names the slot and nothing else: never a supplement, a medicine, a dose or a health value, because the
/// lock screen shows it as written. The reminder repeats daily at the chosen time, quiet hours do not hold it back, and
/// it counts toward the cap of 10 pending reminders that all sources share.
public enum StackReminder {
    public enum Refusal: Equatable, Sendable {
        /// Ten reminders are already waiting, and this one would be an eleventh.
        case full(limit: Int)
        case invalidTime
    }

    public enum Outcome: Equatable, Sendable {
        /// Schedule this request. `replacesPending` is true when a reminder for the same slot is already waiting, so
        /// the caller removes it first and the count does not grow.
        case request(NotificationRequest, replacesPending: Bool)
        case refused(Refusal)
    }

    /// One reminder per lane and slot: `stack.supplement.morning`, `stack.medication.evening`.
    public static func objectID(lane: StackLane, slot: StackSlot) -> String { "stack.\(lane.rawValue).\(slot.rawValue)" }

    /// "Morning stack" or "Evening medication". The person sees this text when they confirm the reminder.
    public static func title(lane: StackLane, slot: StackSlot) -> String {
        slot.title + " " + (lane == .supplement ? "stack" : "medication")
    }

    public static func detail(lane: StackLane, slot: StackSlot) -> String {
        "Time for your \(slot.rawValue) \(lane == .supplement ? "stack" : "medication")."
    }

    public static func isStackReminder(_ request: NotificationRequest) -> Bool {
        request.identity.family == .userReminders && request.identity.objectID.hasPrefix("stack.")
    }

    /// - Parameters:
    ///   - minuteOfDay: 0 to 1439, in `calendar`'s time zone.
    ///   - pending: what `pendingReminders()` returns now, from every source.
    public static func build(lane: StackLane, slot: StackSlot, minuteOfDay: Int, now: Date, calendar: Calendar,
                             pending: [NotificationRequest]) -> Outcome {
        guard (0..<1_440).contains(minuteOfDay),
              let fire = calendar.nextDate(after: now, matching: DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60),
                                           matchingPolicy: .nextTime) else { return .refused(.invalidTime) }
        let identity = NotificationIdentity(family: .userReminders, objectID: objectID(lane: lane, slot: slot), day: "recurring")
        let waiting = Set(pending.map(\.identity).filter { $0.family == .userReminders })
        let replaces = waiting.contains(identity)
        let limit = NotificationFamily.userReminderLimit
        if !replaces, waiting.count >= limit { return .refused(.full(limit: limit)) }
        let day = (try? FoodMeal.day(at: fire, timeZoneIdentifier: calendar.timeZone.identifier)) ?? ""
        let request = NotificationRequest(
            identity: identity, fireDate: fire, title: title(lane: lane, slot: slot), detail: detail(lane: lane, slot: slot),
            sensitivity: .userRequestedAlert, deepLink: .today(day), quietHoursBehavior: .deliver, repeats: .daily)
        return .request(request, replacesPending: replaces)
    }
}
