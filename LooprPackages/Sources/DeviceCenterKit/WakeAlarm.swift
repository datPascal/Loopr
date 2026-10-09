import DesignSystem
import Foundation

// MARK: - Plan

/// The wake alarm the way a person thinks about it: one wake time, an
/// optional smart window before it, and the days it repeats.
///
/// This is a presentation of `StrapAlarmConfiguration`, not a second store.
/// It reads any configuration Loopr has ever saved and writes one back in the
/// same shape, so alarms saved by older builds keep working.
///
/// The wake time is always the latest moment. With a smart window Loopr may
/// wake the person earlier, in light sleep, but the band alarm and the phone
/// alarm are armed for the wake time itself, so the guarantee never moves.
public struct WakeAlarmPlan: Equatable, Sendable {
    /// The smart window lengths the screen offers. Zero means off.
    public static let smartWindowOptions = [0, 10, 20, 30]
    public static let defaultWakeMinute = 7 * 60
    public static let defaultSmartWindowMinutes = StrapAlarmConfiguration.defaultWindowMinutes
    public static let everyDay = Set(AlarmWeekday.allCases)

    public var isEnabled: Bool
    /// Minute of the local day, 0..<1440. The time Loopr guarantees.
    public var wakeMinute: Int
    /// How many minutes before the wake time Loopr may wake early. Zero is off.
    public var smartWindowMinutes: Int
    public var weekdays: Set<AlarmWeekday>

    public init(
        isEnabled: Bool = false,
        wakeMinute: Int = WakeAlarmPlan.defaultWakeMinute,
        smartWindowMinutes: Int = WakeAlarmPlan.defaultSmartWindowMinutes,
        weekdays: Set<AlarmWeekday> = WakeAlarmPlan.everyDay
    ) {
        self.isEnabled = isEnabled
        self.wakeMinute = Self.normalized(wakeMinute)
        self.smartWindowMinutes = max(0, smartWindowMinutes)
        self.weekdays = weekdays
    }

    /// Reads a saved configuration. A missing or unreadable one becomes the
    /// default plan, switched off.
    public init(configuration: StrapAlarmConfiguration?) {
        guard let configuration,
              let wake = configuration.guaranteedMinute,
              (0..<1_440).contains(wake) else {
            self.init()
            return
        }
        self.init(
            isEnabled: configuration.isEnabled,
            wakeMinute: wake,
            smartWindowMinutes: configuration.windowMinutes,
            // A plan with no days cannot be switched on, so an old record
            // without days opens as every day rather than as a dead end.
            weekdays: configuration.weekdays.isEmpty ? Self.everyDay : configuration.weekdays
        )
    }

    public var hasSmartWindow: Bool { smartWindowMinutes > 0 }

    /// When the smart window opens, as a minute of the day, or nil when off.
    public var windowStartMinute: Int? {
        guard hasSmartWindow else { return nil }
        return Self.normalized(wakeMinute - smartWindowMinutes)
    }

    /// The configuration the strap alarm service saves and arms.
    ///
    /// Off maps to an exact-time alarm. On maps to a wake window that ends at
    /// the wake time, which is the minute `guaranteedMinute` arms both the
    /// band and the phone for.
    public func configuration(updatedAt: Date? = nil) -> StrapAlarmConfiguration {
        let wake = Self.normalized(wakeMinute)
        guard let start = windowStartMinute else {
            return StrapAlarmConfiguration(
                isEnabled: isEnabled,
                startMinute: wake,
                endMinute: wake,
                weekdays: weekdays,
                updatedAt: updatedAt,
                mode: .exactTime
            )
        }
        return StrapAlarmConfiguration(
            isEnabled: isEnabled,
            startMinute: start,
            endMinute: wake,
            weekdays: weekdays,
            updatedAt: updatedAt,
            mode: .wakeWindow
        )
    }

    /// The same plan with a different wake time, keeping the window and days.
    public func withWakeMinute(_ minute: Int) -> WakeAlarmPlan {
        var copy = self
        copy.wakeMinute = Self.normalized(minute)
        return copy
    }

    /// The window lengths to offer, including a saved length that is not one
    /// of the standard options so the screen never hides what is stored.
    public var windowOptions: [Int] {
        Self.smartWindowOptions.contains(smartWindowMinutes)
            ? Self.smartWindowOptions
            : (Self.smartWindowOptions + [smartWindowMinutes]).sorted()
    }

    /// True when saving this draft would change what is stored. Only the
    /// fields a person can see count; a stored exact alarm's old stop time
    /// does not make an untouched draft look edited.
    public func differs(from saved: WakeAlarmPlan?) -> Bool {
        guard let saved else { return true }
        return wakeMinute != saved.wakeMinute
            || smartWindowMinutes != saved.smartWindowMinutes
            || weekdays != saved.weekdays
    }

    static func normalized(_ minute: Int) -> Int {
        ((minute % 1_440) + 1_440) % 1_440
    }
}

// MARK: - Schedule

/// One upcoming wake: the guaranteed time and, with a smart window, when the
/// window opens.
public struct WakeAlarmOccurrence: Equatable, Sendable {
    public let wake: Date
    public let windowStart: Date?

    public init(wake: Date, windowStart: Date?) {
        self.wake = wake
        self.windowStart = windowStart
    }
}

public enum WakeAlarmSchedule {
    /// The next wake strictly after `date`, or nil when the plan is off or has
    /// no days. Reuses the planner the runtime arms from, so the screen can
    /// never promise a different time than the band and phone are given.
    public static func next(
        for plan: WakeAlarmPlan,
        after date: Date,
        calendar: Calendar
    ) -> WakeAlarmOccurrence? {
        let configuration = plan.configuration()
        guard let wake = StrapAlarmSchedulePlanner.nextFireDate(
            for: configuration,
            after: date,
            calendar: calendar
        ) else { return nil }
        return WakeAlarmOccurrence(
            wake: wake,
            windowStart: StrapAlarmSchedulePlanner.nextWindowStart(
                for: configuration,
                after: date,
                calendar: calendar
            )
        )
    }
}

// MARK: - Words

/// Turns wake times into the short sentences the screens show, such as
/// "Tomorrow at 07:00, in 8 h 12 min".
public struct WakeAlarmFormatter: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    /// A wall-clock label for a minute of the day, in the person's 12 or 24
    /// hour style.
    public func time(minuteOfDay minute: Int) -> String {
        let normalized = WakeAlarmPlan.normalized(minute)
        var components = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: 0))
        components.hour = normalized / 60
        components.minute = normalized % 60
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", normalized / 60, normalized % 60)
        }
        return time(date)
    }

    public func time(_ date: Date) -> String {
        LooprDateFormatterCache.formatter(template: "jmm", calendar: calendar, locale: locale).string(from: date)
    }

    /// "Today", "Tomorrow", a weekday name within the week, or a short date.
    public func day(of date: Date, relativeTo now: Date) -> String {
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6:
            return LooprDateFormatterCache.formatter(template: "EEEE", calendar: calendar, locale: locale).string(from: date)
        default:
            return LooprDateFormatterCache.formatter(template: "EEEdMMM", calendar: calendar, locale: locale).string(from: date)
        }
    }

    /// "in 8 h 12 min". Rounds up to the minute so a wake 20 seconds away
    /// reads "in 1 min", never "in 0 min".
    public func countdown(from now: Date, to date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(max(minutes, 1)) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 {
            return remainder == 0 ? "in \(hours) h" : "in \(hours) h \(remainder) min"
        }
        let days = hours / 24
        let leftoverHours = hours % 24
        let dayWord = days == 1 ? "day" : "days"
        return leftoverHours == 0 ? "in \(days) \(dayWord)" : "in \(days) \(dayWord) \(leftoverHours) h"
    }

    /// "Tomorrow at 07:00, in 8 h 12 min". Mid-sentence, "Today" and
    /// "Tomorrow" drop their capital; weekday names keep theirs.
    public func sentence(for date: Date, now: Date, midSentence: Bool = false) -> String {
        "\(dayWord(of: date, now: now, midSentence: midSentence)) at \(time(date)), \(countdown(from: now, to: date))"
    }

    /// "Tomorrow, in 8 h 12 min", for places that already show the time.
    public func shortSentence(for date: Date, now: Date) -> String {
        "\(day(of: date, relativeTo: now)), \(countdown(from: now, to: date))"
    }

    private func dayWord(of date: Date, now: Date, midSentence: Bool) -> String {
        let word = day(of: date, relativeTo: now)
        guard midSentence, word == "Today" || word == "Tomorrow" else { return word }
        return word.lowercased()
    }

    /// "Every day", "Weekdays", "Weekends", or the days in calendar order.
    public func repeatSummary(_ weekdays: Set<AlarmWeekday>) -> String {
        let weekend: Set<AlarmWeekday> = [.saturday, .sunday]
        let workweek = WakeAlarmPlan.everyDay.subtracting(weekend)
        switch weekdays {
        case WakeAlarmPlan.everyDay: return "Every day"
        case workweek: return "Weekdays"
        case weekend: return "Weekends"
        case []: return "No days"
        default:
            let order = orderedWeekdays
            return order.filter(weekdays.contains).map(\.shortName).joined(separator: ", ")
        }
    }

    /// The week in the order this calendar starts it.
    public var orderedWeekdays: [AlarmWeekday] {
        let all = AlarmWeekday.allCases
        let first = max(1, min(7, calendar.firstWeekday))
        return (0..<7).map { all[(first - 1 + $0) % 7] }
    }
}

public extension AlarmWeekday {
    var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    var initial: String {
        switch self {
        case .sunday, .saturday: "S"
        case .monday: "M"
        case .tuesday, .thursday: "T"
        case .wednesday: "W"
        case .friday: "F"
        }
    }
}

// MARK: - Layers

/// What the band side of the alarm is doing, in the terms the screen shows.
public enum WakeAlarmBandLayer: Equatable, Sendable {
    /// The alarm is off, so the band holds nothing.
    case off
    /// The alarm is on but the band is not connected. Loopr writes it when
    /// the band comes back.
    case notConnected
    /// Written, waiting for the band's confirmation.
    case waiting
    /// The band sent its confirmation for this alarm.
    case confirmed
    /// Written, and the band never confirmed it.
    case notConfirmed
    /// The write never reached the band.
    case notArmed

    /// Maps the runtime's evidence and the live connection onto a layer.
    public init(assurance: StrapAlarmAssurance?, alarmEnabled: Bool, bandConnected: Bool) {
        guard alarmEnabled else {
            self = .off
            return
        }
        switch assurance?.band ?? .off {
        case .confirmed: self = .confirmed
        case .waiting: self = bandConnected ? .waiting : .notConnected
        case .unconfirmed: self = bandConnected ? .notConfirmed : .notConnected
        case .notArmed: self = bandConnected ? .notArmed : .notConnected
        // An enabled alarm with no arm on record has not reached the band
        // yet. Connected, the next reconcile writes it within a minute.
        case .off: self = bandConnected ? .waiting : .notConnected
        }
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .notConnected: "Not connected"
        case .waiting: "Waiting"
        case .confirmed: "Confirmed"
        case .notConfirmed: "Not confirmed"
        case .notArmed: "Not set"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            "Turn the alarm on to set it on your band."
        case .notConnected:
            "Your band is not connected. Loopr sets the alarm on it as soon as it reconnects."
        case .waiting:
            "Loopr sent the alarm to your band and is waiting for it to confirm."
        case .confirmed:
            "Your band confirmed it stored the alarm."
        case .notConfirmed:
            "Your band took the alarm but never confirmed it. It may stay silent, so keep the phone alarm on."
        case .notArmed:
            "The alarm did not reach your band. Keep it close and try again."
        }
    }

    public var symbol: String {
        switch self {
        case .off: "minus.circle"
        case .notConnected: "antenna.radiowaves.left.and.right.slash"
        case .waiting: "hourglass"
        case .confirmed: "checkmark.circle"
        case .notConfirmed, .notArmed: "exclamationmark.circle"
        }
    }

    /// Whether a retry button makes sense: the alarm is on, the band is
    /// connected, and it has not confirmed.
    public var canRetry: Bool {
        self == .notConfirmed || self == .notArmed
    }

    public var needsAttention: Bool { canRetry }
}

/// What the phone side of the alarm is doing.
public enum WakeAlarmPhoneLayer: Equatable, Sendable {
    /// The person switched the phone alarm off.
    case disabled
    /// The alarm is off, so nothing is scheduled.
    case idle
    /// A system alarm is scheduled. It rings through silent mode and Focus.
    case systemAlarm
    /// Only a notification could be scheduled.
    case notification
    /// Nothing could be scheduled, with the reason.
    case unavailable(String)

    public init(backup: StrapAlarmAssurance.PhoneBackup?, alarmEnabled: Bool, layerEnabled: Bool) {
        guard layerEnabled else {
            self = .disabled
            return
        }
        guard alarmEnabled else {
            self = .idle
            return
        }
        switch backup {
        case .systemAlarm: self = .systemAlarm
        case .notification: self = .notification
        case .unavailable(let reason): self = .unavailable(reason)
        case nil: self = .unavailable("Loopr has not scheduled the phone alarm yet.")
        }
    }

    public var title: String {
        switch self {
        case .disabled: "Off"
        case .idle: "Ready"
        case .systemAlarm: "Scheduled"
        case .notification: "Notification only"
        case .unavailable: "Not scheduled"
        }
    }

    public var detail: String {
        switch self {
        case .disabled:
            "Only your band will wake you, and it has not always buzzed when asked."
        case .idle:
            "Rings at your wake time once the alarm is on."
        case .systemAlarm:
            "Rings at your wake time, even in silent mode or a Focus."
        case .notification:
            "Loopr could only schedule a notification. The ring switch or a Focus can silence it."
        case .unavailable(let reason):
            reason
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .disabled, .notification, .unavailable: true
        case .idle, .systemAlarm: false
        }
    }
}

// MARK: - Card

/// A suggested wake time from recent nights, offered but never applied on its
/// own.
public struct WakeAlarmSuggestion: Equatable, Sendable {
    public let minuteOfDay: Int
    public let reason: String

    public init(minuteOfDay: Int, reason: String) {
        self.minuteOfDay = WakeAlarmPlan.normalized(minuteOfDay)
        self.reason = reason
    }

    /// Reads the canonical `HH:mm` label SleepKit publishes.
    public init?(localTime: String, reason: String) {
        let parts = localTime.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.init(minuteOfDay: hour * 60 + minute, reason: reason)
    }
}

/// What the compact wake card on Today and Sleep shows.
public enum WakeAlarmCardState: Equatable, Sendable {
    case loading
    /// No alarm is on. `lastWakeMinute` is the time of a saved alarm that is
    /// switched off, so the card can offer it back.
    case notSet(lastWakeMinute: Int?, suggestion: WakeAlarmSuggestion?)
    case scheduled(WakeAlarmCardSummary)

    public static func make(
        configuration: StrapAlarmConfiguration?,
        band: WakeAlarmBandLayer,
        phone: WakeAlarmPhoneLayer,
        suggestion: WakeAlarmSuggestion? = nil,
        now: Date,
        formatter: WakeAlarmFormatter
    ) -> WakeAlarmCardState {
        let plan = WakeAlarmPlan(configuration: configuration)
        guard configuration != nil, plan.isEnabled,
              let occurrence = WakeAlarmSchedule.next(for: plan, after: now, calendar: formatter.calendar) else {
            return .notSet(
                lastWakeMinute: configuration == nil ? nil : plan.wakeMinute,
                suggestion: suggestion
            )
        }
        return .scheduled(WakeAlarmCardSummary(
            wakeTime: formatter.time(occurrence.wake),
            when: formatter.shortSentence(for: occurrence.wake, now: now),
            smartWindow: occurrence.windowStart.map { "Smart wake from \(formatter.time($0))" },
            repeatSummary: formatter.repeatSummary(plan.weekdays),
            warning: Self.warning(band: band, phone: phone)
        ))
    }

    /// One line when something needs a look, most serious first.
    static func warning(band: WakeAlarmBandLayer, phone: WakeAlarmPhoneLayer) -> String? {
        switch (band, phone) {
        case (.notConfirmed, .systemAlarm), (.notArmed, .systemAlarm):
            "Band did not confirm. Your phone alarm is set."
        case (.notConfirmed, _), (.notArmed, _):
            "Band did not confirm. Open to check."
        case (_, .disabled):
            "Phone alarm is off."
        case (_, .unavailable):
            "Phone alarm is not scheduled."
        default:
            nil
        }
    }
}

public struct WakeAlarmCardSummary: Equatable, Sendable {
    public let wakeTime: String
    public let when: String
    public let smartWindow: String?
    public let repeatSummary: String
    public let warning: String?

    public init(wakeTime: String, when: String, smartWindow: String?, repeatSummary: String, warning: String?) {
        self.wakeTime = wakeTime
        self.when = when
        self.smartWindow = smartWindow
        self.repeatSummary = repeatSummary
        self.warning = warning
    }
}
