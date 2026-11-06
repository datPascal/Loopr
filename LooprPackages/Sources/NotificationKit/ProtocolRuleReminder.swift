import Foundation

/// Turns a protocol rule with a time into a "Reminders you set" request (DEC-07.1). Loopr sets one only for a rule the
/// person turned the reminder on for, and only after they confirm it.
///
/// The title is the rule's title. An evening rule with a rebuttal quotes it back at the rule's time (DEC-12.18): the
/// body reads "You wrote this morning: ..." with the person's own words. A rebuttal is text the person wrote to be shown
/// to themselves, so it shows on the lock screen as written; it never holds a health value Loopr measured. The reminder
/// repeats daily, or for a rule on chosen weekdays once a week on each of them, so it never fires on a day off (ICP
/// R2-HAB-06). A rule whose days depend on what happened, such as a running test's off nights or a weekly count already
/// met, gets one request per day instead, which the app plans again when it opens and after every answer (ICP round 4,
/// Q1b and Q5). Quiet hours do not hold it back. One rule is one reminder toward the cap of 10 pending reminders that
/// all sources share, however many requests it has.
///
/// Only a rule the person ticks carries Done and Skip today. A rule the band, Food, Fitness or Apple Health checks gets
/// a plain reminder, so a tap on the lock screen can never answer for the source (ICP round 4, VET).
public enum ProtocolRuleReminder {
    public enum Refusal: Equatable, Sendable {
        /// Ten reminders are already waiting, and this one would be an eleventh.
        case full(limit: Int)
        case invalidTime
    }

    public enum Outcome: Equatable, Sendable {
        /// Schedule this request. `replacesPending` is true when a reminder for the same rule is already waiting, so the
        /// caller removes it first and the count does not grow.
        case request(NotificationRequest, replacesPending: Bool)
        /// A rule on chosen weekdays: one weekly request per day, Monday first. The caller removes every waiting request
        /// of the rule first when `replacesPending` is true, then schedules these.
        case weekdays([NotificationRequest], replacesPending: Bool)
        /// One request on each planned day that is still ahead, soonest first. It can be empty: the rule stays on with
        /// nothing to send until its next plan.
        case dated([NotificationRequest], replacesPending: Bool)
        case refused(Refusal)

        /// The requests to schedule, whichever the case.
        public var requests: [NotificationRequest] {
            switch self {
            case .request(let request, _): [request]
            case .weekdays(let requests, _), .dated(let requests, _): requests
            case .refused: []
            }
        }

        public var replacesPending: Bool {
            switch self {
            case .request(_, let replaces), .weekdays(_, let replaces), .dated(_, let replaces): replaces
            case .refused: false
            }
        }
    }

    /// When a rule's reminder fires.
    public enum Schedule: Equatable, Sendable {
        /// Again and again: every day, or once a week on each of these `Calendar` weekdays (Sunday is 1). Empty, or all
        /// seven, is every day.
        case repeating(weekdays: Set<Int>)
        /// Once on each of these days (year, month and day in the calendar's time zone), at the rule's time. A day whose
        /// time has passed is left out.
        case days([DateComponents])
    }

    public static let objectIDPrefix = "protocol.rule."

    /// One reminder per rule key: `protocol.rule.in-bed`.
    public static func objectID(ruleKey: String) -> String { objectIDPrefix + ruleKey }

    public static func ruleKey(from objectID: String) -> String? {
        objectID.hasPrefix(objectIDPrefix) ? String(objectID.dropFirst(objectIDPrefix.count)) : nil
    }

    public static func isRuleReminder(_ request: NotificationRequest) -> Bool {
        request.identity.family == .userReminders && request.identity.objectID.hasPrefix(objectIDPrefix)
    }

    /// "You wrote this morning: "Tomorrow starts tonight."" for an evening rule with a rebuttal, else a plain line.
    public static func detail(rebuttal: String?, isEvening: Bool) -> String {
        if isEvening, let quoted = rebuttal?.trimmingCharacters(in: .whitespacesAndNewlines), !quoted.isEmpty {
            return "You wrote this morning: \"\(quoted)\""
        }
        return "A rule from your protocol is due now."
    }

    // MARK: Answering from the lock screen (ICP R3-HAB-02)

    /// What the person picked on a rule reminder without opening Loopr.
    public enum Action: String, Equatable, Sendable {
        /// "Done": the rule is kept that day.
        case done
        /// "Skip today": the rule is neither kept nor missed that day.
        case skipToday
    }

    /// One answer from a rule reminder: the rule and what was picked. The day is the one the reminder came on.
    public struct Answer: Equatable, Sendable {
        public let ruleKey: String
        public let action: Action
        public init(ruleKey: String, action: Action) { self.ruleKey = ruleKey; self.action = action }
    }

    /// True for the two actions a rule reminder carries.
    public static func isAnswerAction(_ actionIdentifier: String) -> Bool {
        action(for: actionIdentifier) != nil
    }

    static func action(for actionIdentifier: String) -> Action? {
        switch actionIdentifier {
        case NotificationCategoryCatalog.ruleDoneAction: .done
        case NotificationCategoryCatalog.ruleSkipTodayAction: .skipToday
        default: nil
        }
    }

    /// The answer a notification response carries, read from the payload Loopr put on the request
    /// (`NotificationResponsePayload.userInfo(for:)`). Nil for any other action, any other notification, or a payload
    /// without a rule key, so nothing is written for a response Loopr cannot place.
    public static func answer(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Answer? {
        guard let action = action(for: actionIdentifier),
              NotificationResponsePayload.family(from: userInfo) == .userReminders,
              let object = userInfo[NotificationResponsePayload.objectKey] as? String,
              let key = ruleKey(from: object), !key.isEmpty else { return nil }
        return Answer(ruleKey: key, action: action)
    }

    /// The identity's day for the weekly request on `weekday` (`Calendar` numbering, Sunday is 1): "weekday-2" is Monday.
    public static func weekdayKey(_ weekday: Int) -> String { "weekday-\(weekday)" }

    /// The category of a rule's reminder: Done and Skip today for a rule the person ticks, a plain reminder otherwise.
    public static func category(answerable: Bool) -> String {
        answerable ? NotificationCategoryCatalog.protocolRule : NotificationCategoryCatalog.reminder
    }

    /// True when `waiting`, the rule's requests already scheduled, are the same as `planned`: the same days and times,
    /// words and buttons. A repeating request matches on its time and weekday, since its first fire date moves on. A
    /// request saved before reminders named their category never matches, so it is set again with the right buttons.
    public static func isUnchanged(_ waiting: [NotificationRequest], planned: [NotificationRequest], calendar: Calendar) -> Bool {
        func key(_ request: NotificationRequest) -> String? {
            guard request.category != nil else { return nil }
            let when: String
            switch request.repeats {
            case .daily?: when = "daily \(request.minuteOfDay(calendar: calendar))"
            case .weekly?: when = "weekly \(calendar.component(.weekday, from: request.fireDate)) \(request.minuteOfDay(calendar: calendar))"
            case nil: when = "once \(request.fireDate.timeIntervalSince1970)"
            }
            return [request.identity.day, when, request.title, request.detail, request.categoryIdentifier].joined(separator: "|")
        }
        let old = waiting.map(key)
        guard !old.contains(nil) else { return false }
        return Set(old.compactMap { $0 }) == Set(planned.compactMap(key)) && old.count == planned.count
    }

    /// - Parameters:
    ///   - minuteOfDay: the rule's time, 0 to 1439, in `calendar`'s time zone.
    ///   - weekdays: the days the rule is on, as `Calendar` weekday numbers (Sunday is 1). Empty, or all seven, is every
    ///     day: one daily request. Otherwise one weekly request per day.
    ///   - pending: what `pendingReminders()` returns now, from every source.
    public static func build(ruleKey: String, title: String, rebuttal: String?, isEvening: Bool, minuteOfDay: Int,
                             weekdays: Set<Int> = [], now: Date, calendar: Calendar, pending: [NotificationRequest]) -> Outcome {
        build(ruleKey: ruleKey, title: title, rebuttal: rebuttal, isEvening: isEvening, minuteOfDay: minuteOfDay,
              schedule: .repeating(weekdays: weekdays), answerable: true, now: now, calendar: calendar, pending: pending)
    }

    /// - Parameters:
    ///   - schedule: repeating on weekdays, or once on each planned day.
    ///   - answerable: true for a rule the person ticks, whose reminder carries Done and Skip today.
    ///   - pending: what `pendingReminders()` returns now, from every source.
    ///   - standing: the object ids of reminders kept on with nothing waiting, which count toward the cap too.
    public static func build(ruleKey: String, title: String, rebuttal: String?, isEvening: Bool, minuteOfDay: Int,
                             schedule: Schedule, answerable: Bool, now: Date, calendar: Calendar,
                             pending: [NotificationRequest], standing: Set<String> = []) -> Outcome {
        guard (0..<1_440).contains(minuteOfDay), !ruleKey.isEmpty else { return .refused(.invalidTime) }
        let object = objectID(ruleKey: ruleKey)
        // One rule is one reminder in the cap, however many requests it has.
        let waiting = Set(pending.map(\.identity).filter { $0.family == .userReminders }.map(\.objectID)).union(standing)
        let replaces = waiting.contains(object)
        let limit = NotificationFamily.userReminderLimit
        if !replaces, waiting.count >= limit { return .refused(.full(limit: limit)) }
        let text = detail(rebuttal: rebuttal, isEvening: isEvening)
        let buttons = Self.category(answerable: answerable)
        func dayKey(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func make(day: String?, fire: Date, repeats: NotificationRepeat?) -> NotificationRequest {
            let fireDay = dayKey(fire)
            return NotificationRequest(
                identity: NotificationIdentity(family: .userReminders, objectID: object, day: day ?? fireDay), fireDate: fire,
                title: title, detail: text, sensitivity: .userRequestedAlert, deepLink: .journal(fireDay),
                quietHoursBehavior: .deliver, repeats: repeats, category: buttons)
        }
        func request(day: String, matching: DateComponents, repeats: NotificationRepeat) -> NotificationRequest? {
            guard let fire = calendar.nextDate(after: now, matching: matching, matchingPolicy: .nextTime) else { return nil }
            return make(day: day, fire: fire, repeats: repeats)
        }
        let weekdays: Set<Int>
        switch schedule {
        case .repeating(let chosen):
            weekdays = chosen
        case .days(let planned):
            // One request per day still ahead, keyed by its date, so each can go on its own.
            var seen = Set<String>()
            let requests = planned.compactMap { parts -> NotificationRequest? in
                guard let year = parts.year, let month = parts.month, let day = parts.day,
                      let fire = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                                    hour: minuteOfDay / 60, minute: minuteOfDay % 60)),
                      fire > now, seen.insert(dayKey(fire)).inserted else { return nil }
                return make(day: nil, fire: fire, repeats: nil)
            }.sorted { $0.fireDate < $1.fireDate }
            return .dated(requests, replacesPending: replaces)
        }
        let days = weekdays.filter { (1...7).contains($0) }
        guard weekdays.count == days.count else { return .refused(.invalidTime) }
        let time = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        guard !days.isEmpty, days.count < 7 else {
            guard let daily = request(day: "recurring", matching: time, repeats: .daily) else { return .refused(.invalidTime) }
            return .request(daily, replacesPending: replaces)
        }
        // Monday first, the way the rule lists its days.
        let ordered = days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
        let requests = ordered.compactMap { weekday in
            request(day: weekdayKey(weekday),
                    matching: DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, weekday: weekday), repeats: .weekly)
        }
        guard requests.count == ordered.count else { return .refused(.invalidTime) }
        return .weekdays(requests, replacesPending: replaces)
    }
}
