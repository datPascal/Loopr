import Foundation
import SwiftUI

/// One civil calendar day, as the tabs show it.
///
/// DesignSystem has no dependency on DomainKit, so it carries its own day
/// value. The app converts `DomainKit.DayIdentity` into this at the edge.
/// Every calculation anchors on local noon, so a day that starts at 01:00
/// (a DST change at midnight) or lasts 23 or 25 hours still steps by exactly
/// one civil day.
public struct LooprDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil day `date` falls on in `calendar`'s time zone.
    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Local noon on this day. Noon exists on every civil day in every time
    /// zone, which midnight does not.
    public func noon(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// The first instant of this day in `calendar`'s time zone.
    public func start(in calendar: Calendar) -> Date? {
        noon(in: calendar).map { calendar.startOfDay(for: $0) }
    }

    /// The day `offset` civil days away. Negative is earlier.
    public func adding(days offset: Int, calendar: Calendar) -> LooprDay? {
        guard let noon = noon(in: calendar),
              let moved = calendar.date(byAdding: .day, value: offset, to: noon) else { return nil }
        return LooprDay(date: moved, calendar: calendar)
    }

    /// Whole civil days from `other` to this day. Positive when this day is
    /// later.
    public func days(since other: LooprDay, calendar: Calendar) -> Int? {
        guard let from = other.noon(in: calendar), let to = noon(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    public static func < (lhs: LooprDay, rhs: LooprDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// The words the tabs use for a day and a night.
///
/// Formatting is fixed to English with a POSIX locale, like every other date
/// label in Loopr, so "Tue 22 Sep" reads the same on every device.
public enum LooprDayLabel {
    /// "Today", "Yesterday", or "Tue 22 Sep". A day in another year than
    /// `today` carries the year: "Tue 22 Sep 2025".
    public static func title(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        if day == today { return "Today" }
        if today.adding(days: -1, calendar: calendar) == day { return "Yesterday" }
        return date(for: day, today: today, calendar: calendar)
    }

    /// "Tue 22 Sep", with the year when it is not `today`'s year.
    public static func date(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        guard let noon = day.noon(in: calendar) else { return day.description }
        let format = day.year == today.year ? "EEE d MMM" : "EEE d MMM yyyy"
        return formatter(format, calendar: calendar).string(from: noon)
    }

    /// The spoken form: "Wednesday 23 September".
    public static func spokenDate(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        guard let noon = day.noon(in: calendar) else { return day.description }
        let format = day.year == today.year ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return formatter(format, calendar: calendar).string(from: noon)
    }

    /// The spoken title plus the date when the title is relative:
    /// "Yesterday, Wednesday 23 September".
    public static func spokenTitle(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        let spoken = spokenDate(for: day, today: today, calendar: calendar)
        let title = title(for: day, today: today, calendar: calendar)
        guard day == today || today.adding(days: -1, calendar: calendar) == day else { return spoken }
        return "\(title), \(spoken)"
    }

    /// The night a day's sleep belongs to runs from the evening before into
    /// the morning of that day. "Last night" only when that morning is today.
    public static func nightTitle(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        day == today ? "Last night" : nightRange(for: day, today: today, calendar: calendar)
    }

    /// "Tue 22 → Wed 23 Sep", or "Mon 31 Aug → Tue 1 Sep" across a month.
    public static func nightRange(for day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        guard let evening = day.adding(days: -1, calendar: calendar) else {
            return date(for: day, today: today, calendar: calendar)
        }
        return nightRange(from: evening, to: day, today: today, calendar: calendar)
    }

    /// A night between two civil days, for a sleep whose own start and end
    /// are known.
    public static func nightRange(from start: LooprDay, to end: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        guard let startNoon = start.noon(in: calendar) else { return date(for: end, today: today, calendar: calendar) }
        let endLabel = date(for: end, today: today, calendar: calendar)
        if start == end { return endLabel }
        let startFormat = start.month == end.month && start.year == end.year ? "EEE d" : "EEE d MMM"
        return "\(formatter(startFormat, calendar: calendar).string(from: startNoon)) → \(endLabel)"
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        LooprDateFormatterCache.formatter(format, calendar: calendar)
    }
}

/// How long ago the band last handed Loopr data, in the words a header uses.
public enum LooprSyncAge {
    /// Minutes under an hour, whole hours under a day, then whole days:
    /// "Synced just now", "Synced 12 min ago", "Synced 5 h ago",
    /// "Synced 1 day ago", "Synced 3 days ago".
    public static func label(ageMinutes: Int) -> String {
        guard ageMinutes >= 1 else { return "Synced just now" }
        if ageMinutes < 60 { return "Synced \(ageMinutes) min ago" }
        let hours = ageMinutes / 60
        if hours < 24 { return "Synced \(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "Synced 1 day ago" : "Synced \(days) days ago"
    }

    /// Nil when Loopr has never received data. A sync stamped in the future
    /// (a clock change) reads as just now rather than as a negative age.
    public static func label(lastSync: Date?, now: Date) -> String? {
        guard let lastSync else { return nil }
        return label(ageMinutes: max(0, Int(now.timeIntervalSince(lastSync) / 60)))
    }
}

/// What Loopr knows about one day's derived numbers.
public enum LooprDayDataStatus: String, Equatable, Sendable {
    /// At least one band value was derived for the day.
    case hasData
    /// The day was derived and produced nothing, or the band recorded no
    /// second in it.
    case noData
    /// Raw data exists but the day has not been derived yet.
    case unknown
}

/// The day a tab shows and what the header can do with it. The app builds
/// one of these from its shared day selection and puts it in the
/// environment; screens read `\.looprDayNavigation` and stay unaware of how
/// the day was chosen.
public struct LooprDayNavigation: Equatable, Sendable {
    public let day: LooprDay
    public let today: LooprDay
    /// The earliest day the band recorded anything. Nil before any data,
    /// which pins the navigator to today.
    public let earliest: LooprDay?
    public let calendar: Calendar
    public let status: LooprDayDataStatus
    /// The newest day with data, when it is not `day`. The empty state
    /// offers it as the next step.
    public let latestDayWithData: LooprDay?
    /// True while the default day is still being worked out at launch.
    public let isResolving: Bool
    /// When the band last handed Loopr any data.
    public let lastSyncedAt: Date?
    /// The clock for ages such as "Synced 12 min ago". Nil means the real
    /// clock; fixture launches pin it so their ages stay fixed.
    public let now: Date?
    private let onSelect: @MainActor @Sendable (LooprDay) -> Void

    public init(
        day: LooprDay,
        today: LooprDay,
        earliest: LooprDay?,
        calendar: Calendar,
        status: LooprDayDataStatus = .unknown,
        latestDayWithData: LooprDay? = nil,
        isResolving: Bool = false,
        lastSyncedAt: Date? = nil,
        now: Date? = nil,
        onSelect: @escaping @MainActor @Sendable (LooprDay) -> Void
    ) {
        self.day = day
        self.today = today
        self.earliest = earliest
        self.calendar = calendar
        self.status = status
        self.latestDayWithData = latestDayWithData
        self.isResolving = isResolving
        self.lastSyncedAt = lastSyncedAt
        self.now = now
        self.onSelect = onSelect
    }

    public var isToday: Bool { day == today }

    /// The lower bound: the earliest recorded day, never later than today.
    public var lowerBound: LooprDay { min(earliest ?? today, today) }

    public var canGoBack: Bool { day > lowerBound }
    public var canGoForward: Bool { day < today }

    /// "Today", "Yesterday" or "Tue 22 Sep".
    public var title: String { LooprDayLabel.title(for: day, today: today, calendar: calendar) }
    /// "Wed 23 Sep".
    public var dateText: String { LooprDayLabel.date(for: day, today: today, calendar: calendar) }
    /// "Yesterday, Wednesday 23 September".
    public var spokenTitle: String { LooprDayLabel.spokenTitle(for: day, today: today, calendar: calendar) }
    /// "Last night" or "Tue 22 → Wed 23 Sep".
    public var nightTitle: String { LooprDayLabel.nightTitle(for: day, today: today, calendar: calendar) }
    /// "Tue 22 → Wed 23 Sep".
    public var nightRange: String { LooprDayLabel.nightRange(for: day, today: today, calendar: calendar) }

    /// The day `offset` steps away, clamped to the navigable range.
    public func clamped(_ offset: Int) -> LooprDay {
        guard let target = day.adding(days: offset, calendar: calendar) else { return day }
        return min(max(target, lowerBound), today)
    }

    @MainActor public func step(by offset: Int) {
        let target = clamped(offset)
        guard target != day else { return }
        onSelect(target)
    }

    @MainActor public func goBack() { step(by: -1) }
    @MainActor public func goForward() { step(by: 1) }
    @MainActor public func goToToday() { if !isToday { onSelect(today) } }

    @MainActor public func select(_ target: LooprDay) {
        let bounded = min(max(target, lowerBound), today)
        guard bounded != day else { return }
        onSelect(bounded)
    }

    public static func == (lhs: LooprDayNavigation, rhs: LooprDayNavigation) -> Bool {
        lhs.day == rhs.day && lhs.today == rhs.today && lhs.earliest == rhs.earliest
            && lhs.calendar.timeZone == rhs.calendar.timeZone && lhs.status == rhs.status
            && lhs.latestDayWithData == rhs.latestDayWithData && lhs.isResolving == rhs.isResolving
            && lhs.lastSyncedAt == rhs.lastSyncedAt && lhs.now == rhs.now
    }
}

private struct LooprDayNavigationKey: EnvironmentKey {
    static let defaultValue: LooprDayNavigation? = nil
}

public extension EnvironmentValues {
    /// The shared day the four day tabs show. Nil outside those tabs and in
    /// previews, where screens keep their own labels.
    var looprDayNavigation: LooprDayNavigation? {
        get { self[LooprDayNavigationKey.self] }
        set { self[LooprDayNavigationKey.self] = newValue }
    }
}

/// Decides whether a tab header shows a status chip at all.
///
/// A chip used to sit in every header, mostly saying "Partial data" or "Not
/// measured" next to content that already said so. It now appears only when
/// the person can do something about it.
public enum LooprHeaderStatus {
    /// The state worth a chip, or nil. `isToday` matters for staleness:
    /// yesterday's numbers are not out of date just because it is not
    /// yesterday any more. `dayIsEmpty` drops it too: the empty day's own
    /// card already says when the band last synced.
    public static func actionableState(_ state: MetricState?, isToday: Bool, dayIsEmpty: Bool = false) -> MetricState? {
        guard let state else { return nil }
        switch state {
        case .stale: return isToday && !dayIsEmpty ? .stale : nil
        case .disconnected, .bluetoothOff, .permissionDenied, .recoverableError, .destructiveFailure:
            return state
        case .loading, .noRecords, .absent, .measuredZero, .partial, .lowConfidence, .settling, .unsupportedHardware:
            return nil
        }
    }

    /// The chip for an actionable state, tinted with the tab's accent unless
    /// the state is a failure.
    public static func chip(for state: MetricState?, isToday: Bool, dayIsEmpty: Bool = false,
                            accent: LooprColorToken) -> StatusChip? {
        guard let actionable = actionableState(state, isToday: isToday, dayIsEmpty: dayIsEmpty) else { return nil }
        switch actionable {
        case .recoverableError, .destructiveFailure:
            return StatusChip(actionable.title, symbol: actionable.symbol, tone: .critical)
        default:
            return StatusChip(actionable.title, symbol: actionable.symbol, accent: accent)
        }
    }
}
