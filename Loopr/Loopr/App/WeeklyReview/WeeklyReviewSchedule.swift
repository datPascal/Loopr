import DomainKit
import Foundation
import RoutineKit
import Synchronization

// When the weekly review (LV-09.2, DEC-12.12) is offered. The review covers one ISO week, Monday to Sunday. Today
// offers it from Sunday 17:00 until Monday 12:00 on the phone's clock, once per ISO week: opening it from anywhere
// marks the week seen and the card goes. The Protocol tab and the reminder open it any day.

/// One ISO week: its Monday and its key, such as `2026-W43`.
nonisolated struct WeeklyReviewWeek: Equatable, Hashable, Sendable {
    let monday: DayIdentity
    /// `YYYY-Www` on the ISO 8601 calendar, the key the seen state is stored under.
    let isoKey: String

    var days: [DayIdentity] { (0..<7).compactMap { monday.adding(days: $0) } }
    var sunday: DayIdentity { monday.adding(days: 6) ?? monday }
}

/// The span Today shows the card for one week.
nonisolated struct WeeklyReviewWindow: Equatable, Sendable {
    let week: WeeklyReviewWeek
    /// Sunday 17:00 of the week.
    let opens: Date
    /// Monday 12:00 of the week after.
    let closes: Date

    func contains(_ date: Date) -> Bool { opens <= date && date < closes }
}

nonisolated enum WeeklyReviewSchedule {
    /// Sunday from 17:00.
    static let opensMinute = 17 * 60
    /// Until Monday 12:00.
    static let closesMinute = 12 * 60

    /// The ISO calendar in `calendar`'s time zone.
    static func isoCalendar(_ calendar: Calendar) -> Calendar {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        iso.locale = calendar.locale
        return iso
    }

    /// The ISO week `date` falls in, on `calendar`'s clock.
    static func week(containing date: Date, calendar: Calendar) -> WeeklyReviewWeek? {
        let iso = isoCalendar(calendar)
        guard let start = iso.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        let day = iso.dateComponents([.year, .month, .day], from: start)
        let week = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day,
              let weekYear = week.yearForWeekOfYear, let number = week.weekOfYear else { return nil }
        return WeeklyReviewWeek(monday: DayIdentity(year: year, month: month, day: dayOfMonth),
                                isoKey: String(format: "%04d-W%02d", weekYear, number))
    }

    /// Sunday 17:00 to Monday 12:00 for `week`.
    static func window(for week: WeeklyReviewWeek, calendar: Calendar) -> WeeklyReviewWindow? {
        let iso = isoCalendar(calendar)
        let sunday = week.sunday
        guard let nextMonday = week.monday.adding(days: 7),
              let opens = iso.date(from: DateComponents(year: sunday.year, month: sunday.month, day: sunday.day,
                                                        hour: opensMinute / 60, minute: opensMinute % 60)),
              let closes = iso.date(from: DateComponents(year: nextMonday.year, month: nextMonday.month, day: nextMonday.day,
                                                         hour: closesMinute / 60, minute: closesMinute % 60)) else { return nil }
        return WeeklyReviewWindow(week: week, opens: opens, closes: closes)
    }

    /// The newest week whose review has opened: this week from Sunday 17:00, the week before until then. The Protocol
    /// row and the reminder open this one.
    static func reviewWeek(at now: Date, calendar: Calendar) -> WeeklyReviewWeek? {
        guard let thisWeek = week(containing: now, calendar: calendar) else { return nil }
        if let window = window(for: thisWeek, calendar: calendar), now >= window.opens { return thisWeek }
        guard let lastWeekDay = isoCalendar(calendar).date(byAdding: .day, value: -7, to: now) else { return nil }
        return week(containing: lastWeekDay, calendar: calendar)
    }

    /// The window Today offers next: last week's while it is still open (until Monday 12:00), else this week's, which
    /// opens on Sunday at 17:00. Nil when that week was already seen. The card draws only inside the window.
    static func todayWindow(at now: Date, calendar: Calendar, hasSeen: (String) -> Bool) -> WeeklyReviewWindow? {
        guard let thisWeek = week(containing: now, calendar: calendar),
              let lastWeekDay = isoCalendar(calendar).date(byAdding: .day, value: -7, to: now),
              let lastWeek = week(containing: lastWeekDay, calendar: calendar) else { return nil }
        let candidate: WeeklyReviewWindow?
        if let previous = window(for: lastWeek, calendar: calendar), now < previous.closes {
            candidate = previous
        } else {
            candidate = window(for: thisWeek, calendar: calendar)
        }
        guard let candidate, !hasSeen(candidate.week.isoKey) else { return nil }
        return candidate
    }

    /// "19 Oct", the Monday of the week, for the Protocol row.
    static func mondayText(_ week: WeeklyReviewWeek, calendar: Calendar, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        style.locale = locale
        let iso = isoCalendar(calendar)
        guard let date = iso.date(from: DateComponents(year: week.monday.year, month: week.monday.month,
                                                       day: week.monday.day, hour: 12)) else { return week.isoKey }
        return date.formatted(style)
    }
}

/// Which weeks' reviews the person opened, one ISO week key each. Production keeps it in the standard defaults on this
/// iPhone; fixture launches keep it for the launch only. It holds no health data. Delete all data clears the key.
nonisolated struct WeeklyReviewSeenStore: @unchecked Sendable {
    static let key = "loopr.weeklyReview.seenWeeks"
    /// Older weeks fall off, so the list stays short.
    static let capacity = 12
    private static let launchOnly = Mutex<[String]>([])

    private let defaults: UserDefaults?

    /// `defaults` nil keeps the seen weeks for this launch only.
    init(defaults: UserDefaults?) { self.defaults = defaults }

    static func standard(persisting: Bool) -> WeeklyReviewSeenStore {
        WeeklyReviewSeenStore(defaults: persisting ? .standard : nil)
    }

    var seenWeeks: [String] {
        if let defaults { return defaults.stringArray(forKey: Self.key) ?? [] }
        return Self.launchOnly.withLock { $0 }
    }

    func hasSeen(_ isoKey: String) -> Bool { seenWeeks.contains(isoKey) }

    func markSeen(_ isoKey: String) {
        var list = seenWeeks.filter { $0 != isoKey }
        list.append(isoKey)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        if let defaults { defaults.set(list, forKey: Self.key) } else { Self.launchOnly.withLock { $0 = list } }
    }
}
