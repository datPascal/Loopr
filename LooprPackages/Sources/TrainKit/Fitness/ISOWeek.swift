import DomainKit
import Foundation

/// An ISO 8601 week: it starts on Monday, and week 1 is the week that holds the year's first Thursday. The calendar
/// is injected so a test, or a person who travels, fixes the time zone. Only the zone is read from it; the week rule
/// is always ISO, whatever first weekday or locale the calendar carries.
public struct ISOWeek: Equatable, Hashable, Sendable {
    public let yearForWeekOfYear: Int
    public let weekOfYear: Int
    /// Monday 00:00 in the calendar's zone.
    public let start: Date
    /// The next Monday 00:00. The week holds dates before this one.
    public let end: Date
    /// The seven local days, Monday first.
    public let days: [DayIdentity]

    public init?(containing date: Date, calendar: Calendar) {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let iso = Self.isoCalendar(like: calendar)
        guard let interval = iso.dateInterval(of: .weekOfYear, for: date) else { return nil }
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: interval.start)
        guard let year = parts.yearForWeekOfYear, let week = parts.weekOfYear else { return nil }
        var days: [DayIdentity] = []
        for offset in 0..<7 {
            guard let day = iso.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
            let day3 = iso.dateComponents([.era, .year, .month, .day], from: day)
            guard let era = day3.era, let y = day3.year, let m = day3.month, let d = day3.day else { return nil }
            days.append(DayIdentity(era: era, year: y, month: m, day: d))
        }
        yearForWeekOfYear = year
        weekOfYear = week
        start = interval.start
        end = interval.end
        self.days = days
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// A Gregorian calendar in the given calendar's zone with Monday first and four days in week 1.
    static func isoCalendar(like calendar: Calendar) -> Calendar {
        var iso = Calendar(identifier: .gregorian)
        iso.timeZone = calendar.timeZone
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        return iso
    }
}
