import CoreGraphics
import DomainKit
import Foundation
import RoutineKit

/// How one rule dot draws.
public enum ProtocolDotState: String, Equatable, Sendable {
    /// Filled in the Protocol accent.
    case kept
    /// A muted fill.
    case missed
    /// An outline: the rule can still be decided.
    case pending
    /// A short dash: no source could say. Never drawn as a miss.
    case unknown
    /// A ring with a slash: the person skipped it, or a running test keeps it off that night. Neither kept nor missed.
    case skipped

    /// Stored or evaluated state to dot. A rule with no check is pending until the day is over and unknown after it.
    public static func from(_ state: CheckState?, phase: ProtocolDayPhase) -> ProtocolDotState {
        switch state {
        case .kept?: .kept
        case .missed?: .missed
        case .skipped?: .skipped
        case .pending?: phase == .past || phase == .beforeProtocol ? .unknown : .pending
        case .unknown?: .unknown
        case nil: phase == .past || phase == .beforeProtocol ? .unknown : .pending
        }
    }
}

public struct ProtocolDot: Equatable, Sendable, Identifiable {
    public var id: RuleKey { ruleKey }
    public let ruleKey: RuleKey
    public let state: ProtocolDotState
    public let minuteOfDay: Int?
}

/// The ISO week the tab shows, Monday first, with the locale's weekday names.
public struct ProtocolWeekCalendar: Sendable {
    public let calendar: Calendar
    public let locale: Locale

    /// `timeZone` decides the local day. The week starts on Monday whatever the locale says (ISO 8601).
    public init(timeZone: TimeZone, locale: Locale) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.locale = locale
        self.calendar = calendar
        self.locale = locale
    }

    public func date(_ day: DayIdentity) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }

    public func day(_ date: Date) -> DayIdentity {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DayIdentity(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public func adding(_ days: Int, to day: DayIdentity) -> DayIdentity? {
        guard let date = date(day), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return self.day(moved)
    }

    /// 1 for Monday to 7 for Sunday.
    public func isoWeekday(_ day: DayIdentity) -> Int? {
        guard let date = date(day) else { return nil }
        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % 7 + 1
    }

    /// Monday to Sunday of the week that holds `day`.
    public func week(containing day: DayIdentity) -> [DayIdentity] {
        guard let weekday = isoWeekday(day), let monday = adding(1 - weekday, to: day) else { return [] }
        return (0..<7).compactMap { adding($0, to: monday) }
    }

    /// Whole days from `earlier` to `later`.
    public func days(from earlier: DayIdentity, to later: DayIdentity) -> Int? {
        guard let start = date(earlier), let end = date(later) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// "Thursday", in the locale.
    public func weekdayName(_ day: DayIdentity) -> String {
        guard let date = date(day) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    /// "Monday 13 Nov", in the locale, for the sheet a rosette opens.
    public func dayTitle(_ day: DayIdentity) -> String {
        guard let date = date(day) else { return weekdayName(day) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
        return formatter.string(from: date)
    }

    /// "T", the locale's narrow standalone weekday.
    public func weekdayLetter(_ day: DayIdentity) -> String {
        guard let date = date(day) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? []
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    /// The identifier part for a day, the same in every locale: "monday" to "sunday".
    public func identifierKey(_ day: DayIdentity) -> String {
        guard let weekday = isoWeekday(day) else { return "day" }
        return ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"][weekday - 1]
    }
}

/// Which rules a day's rosette draws, and how many.
///
/// The rule: a day draws one dot per rule that has a time, and one per rule without a time once that rule has an
/// answer that day (kept, not kept or skipped). Timed rules come first, earliest first, then the others in the
/// version's order. A rosette holds at most 16 dots; past that the first 16 draw and the spoken summary still counts
/// every rule. A day ahead draws no rule dots: the week view marks it with one small dot (ICP R1-DES-05). Days before
/// the protocol draw only checks that were stored for them.
public enum ProtocolRosetteRules {
    public static let maximumDots = 16

    public static func dots(for day: ProtocolDayInput) -> [ProtocolDot] {
        Array(counted(day).prefix(maximumDots))
    }

    /// Every dot the day would draw without the cap.
    public static func counted(_ day: ProtocolDayInput) -> [ProtocolDot] {
        let shown = day.rules.enumerated().filter { _, item in
            switch day.phase {
            case .future: false
            case .beforeProtocol: item.state != nil
            case .past, .today: item.rule.timeOfDayMinutes != nil || item.hasAnswer
            }
        }
        let ordered = shown.sorted { lhs, rhs in
            switch (lhs.element.rule.timeOfDayMinutes, rhs.element.rule.timeOfDayMinutes) {
            case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }
        return ordered.map { _, item in
            ProtocolDot(ruleKey: item.rule.key, state: day.phase == .future ? .pending : .from(item.state, phase: day.phase),
                        minuteOfDay: item.rule.timeOfDayMinutes)
        }
    }
}

/// Where the dots of one rosette sit. Up to 8 dots share one ring; 9 to 16 split over two rings, the outer one
/// holding 60 percent, rounded up. One dot sits in the middle. Positions start at twelve o'clock and run clockwise.
public enum ProtocolRosetteLayout {
    public static let innerRingFraction: CGFloat = 0.52

    public static func rings(count: Int) -> (outer: Int, inner: Int) {
        let count = min(max(count, 0), ProtocolRosetteRules.maximumDots)
        guard count > 8 else { return (count, 0) }
        let outer = Int((Double(count) * 0.6).rounded(.up))
        return (outer, count - outer)
    }

    /// The dot radius for `count` dots on a rosette of `radius`.
    public static func dotRadius(count: Int, radius: CGFloat) -> CGFloat {
        count > 8 ? radius * 0.2 : radius * 0.28
    }

    public static func positions(count: Int, center: CGPoint, radius: CGFloat) -> [CGPoint] {
        let count = min(max(count, 0), ProtocolRosetteRules.maximumDots)
        guard count > 0 else { return [] }
        if count == 1 { return [center] }
        let (outer, inner) = rings(count: count)
        return ring(outer, center: center, radius: radius)
            + ring(inner, center: center, radius: radius * innerRingFraction, offset: inner > 0 ? 0.5 : 0)
    }

    private static func ring(_ count: Int, center: CGPoint, radius: CGFloat, offset: Double = 0) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let angle = -Double.pi / 2 + (Double(index) + offset) / Double(count) * 2 * .pi
            return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
    }
}

/// One day of the week as the rosette row draws and speaks it.
public struct ProtocolDayPresentation: Equatable, Sendable, Identifiable {
    public var id: String { identifierKey }
    public let day: DayIdentity
    public let phase: ProtocolDayPhase
    public let identifierKey: String
    public let letter: String
    public let name: String
    public let dots: [ProtocolDot]
    public let kept: Int
    public let missed: Int
    public let pending: Int
    public let unknown: Int
    public let skipped: Int

    public var total: Int { kept + missed + pending + unknown + skipped }
    public var isToday: Bool { phase == .today }
    /// Today pulses until every rule it draws is decided.
    public var pulses: Bool { isToday && dots.contains { $0.state == .pending } }

    /// "Thursday, 6 of 8 rules kept, 2 pending."
    public var accessibilitySummary: String {
        let label = isToday ? "Today, \(name)" : name
        switch phase {
        case .future:
            return total == 0 ? "\(label), no rules with a time" : "\(label), \(total) \(total == 1 ? "rule" : "rules") ahead"
        case .beforeProtocol where total == 0:
            return "\(label), before your protocol started"
        default:
            guard total > 0 else { return "\(label), no rules with a time and nothing decided" }
            var parts = ["\(label), \(kept) of \(total) \(total == 1 ? "rule" : "rules") kept"]
            if missed > 0 { parts.append("\(missed) not kept") }
            if pending > 0 { parts.append("\(pending) pending") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if unknown > 0 { parts.append("\(unknown) not known") }
            return parts.joined(separator: ", ")
        }
    }

    /// The dots draw a rule without a time only once it is decided, but the spoken counts take every rule of a past day,
    /// today or a day ahead, so the rosette says "4 of 10 rules kept" and "10 rules ahead" where the header says 10
    /// rules (ICP R2-UPG-4, R3-UPG-6).
    public static func make(_ input: ProtocolDayInput, week: ProtocolWeekCalendar) -> ProtocolDayPresentation {
        let counted = ProtocolRosetteRules.counted(input)
        let spoken: [ProtocolDotState] = switch input.phase {
        case .past, .today: input.rules.map { ProtocolDotState.from($0.state, phase: input.phase) }
        case .future: input.rules.map { _ in .pending }
        case .beforeProtocol: counted.map(\.state)
        }
        func count(_ state: ProtocolDotState) -> Int { spoken.filter { $0 == state }.count }
        return ProtocolDayPresentation(
            day: input.day, phase: input.phase, identifierKey: week.identifierKey(input.day),
            letter: week.weekdayLetter(input.day), name: week.weekdayName(input.day),
            dots: Array(counted.prefix(ProtocolRosetteRules.maximumDots)),
            kept: count(.kept), missed: count(.missed), pending: count(.pending), unknown: count(.unknown),
            skipped: count(.skipped))
    }
}
