import DomainKit
import Foundation

// Experiments count in civil days. A `DayIdentity` is a calendar date with no time zone, so adding days to it never
// meets a 23 or 25 hour day. The only place a time zone matters is turning an instant into a day, and that goes
// through `ExperimentCalendar`, which the caller injects.

private let civilCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

public extension DayIdentity {
    /// Noon UTC on this civil date, or nil for a date that does not exist.
    private var civilNoon: Date? {
        guard routineDayKey != nil else { return nil }
        return civilCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// The civil day `days` later (or earlier, when negative). Nil for a date that does not exist.
    func adding(days: Int) -> DayIdentity? {
        guard let noon = civilNoon, let moved = civilCalendar.date(byAdding: .day, value: days, to: noon) else { return nil }
        let parts = civilCalendar.dateComponents([.year, .month, .day], from: moved)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return DayIdentity(year: year, month: month, day: day)
    }

    /// Whole civil days from this day to `other`. Positive when `other` is later.
    func days(until other: DayIdentity) -> Int? {
        guard let from = civilNoon, let to = other.civilNoon else { return nil }
        return civilCalendar.dateComponents([.day], from: from, to: to).day
    }
}

/// Turns instants into local days with an injected calendar (and so an injected time zone).
///
/// The night rule: a night belongs to the local day it starts on. A night is the sleep that follows an evening, so a
/// sleep that starts at 23:30 on the 14th is the 14th's night, and so is one that starts at 00:40 on the 15th, because
/// the evening it follows is the 14th's. A sleep that starts before `nightCutoffHour` (default 12:00) therefore counts
/// for the day before. The cutoff makes a late bedtime after midnight land on the evening the person took the
/// intervention, which is the evening the schedule asks about. It also makes the repeated hour when clocks go back
/// harmless, since both copies of 02:30 sit before noon.
public struct ExperimentCalendar: Sendable {
    public let calendar: Calendar
    public let nightCutoffHour: Int

    public init(calendar: Calendar, nightCutoffHour: Int = 12) {
        self.calendar = calendar
        self.nightCutoffHour = min(max(nightCutoffHour, 0), 23)
    }

    /// The local calendar day an instant falls on.
    public func localDay(of instant: Date) -> DayIdentity {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return DayIdentity(year: parts.year ?? 1, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// The day whose night a sleep belongs to, from the instant the sleep started.
    public func nightDay(sleepStart instant: Date) -> DayIdentity {
        let day = localDay(of: instant)
        let hour = calendar.component(.hour, from: instant)
        guard hour < nightCutoffHour else { return day }
        return day.adding(days: -1) ?? day
    }

    /// The night that starts this evening, as the person sees it right now.
    public func tonight(at now: Date) -> DayIdentity { localDay(of: now) }
}
