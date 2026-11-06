import DomainKit
import Foundation

/// Civil-day arithmetic on `yyyy-MM-dd` keys. A day key carries no time zone;
/// the zone only matters when a key is compared with a clock reading or when
/// the end of a local day is needed for the answer deadline.
public enum PatternDays {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    public static func add(_ days: Int, to key: String) -> String? {
        guard let day = DayIdentity(habitKey: key),
              let date = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let moved = utc.date(byAdding: .day, value: days, to: date) else { return nil }
        let parts = utc.dateComponents([.year, .month, .day], from: moved)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        return DayIdentity(year: year, month: month, day: dayOfMonth).habitKey
    }

    /// `count` consecutive day keys starting at `key`.
    public static func range(from key: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { add($0, to: key) }
    }

    /// Whole days from `lhs` to `rhs`. Positive when `rhs` is later.
    public static func distance(from lhs: String, to rhs: String) -> Int? {
        guard let a = DayIdentity(habitKey: lhs), let b = DayIdentity(habitKey: rhs),
              let first = utc.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
              let second = utc.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return nil }
        return utc.dateComponents([.day], from: first, to: second).day
    }

    /// The local day key for `now` in `timeZoneID`.
    public static func key(at now: Date, timeZoneID: String) -> String? {
        guard let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return DayIdentity(year: year, month: month, day: day).habitKey
    }

    /// The first instant after the local day `key` ends in `timeZoneID`.
    public static func endOfDay(_ key: String, timeZoneID: String) -> Date? {
        guard let zone = TimeZone(identifier: timeZoneID), let day = DayIdentity(habitKey: key) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: start)
    }

    /// The first day of the week containing `key`. `firstWeekday` follows
    /// `Calendar` (1 Sunday ... 7 Saturday); the default is Monday.
    public static func weekStart(containing key: String, firstWeekday: Int = 2) -> String? {
        guard let day = DayIdentity(habitKey: key),
              let date = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        let weekday = utc.component(.weekday, from: date)
        let back = (weekday - firstWeekday + 7) % 7
        return add(-back, to: key)
    }
}
