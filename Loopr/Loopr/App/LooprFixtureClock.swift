import DomainKit
import Foundation
import TodayKit

/// The one clock of a fixture launch, so every tab tells the same hour of the same day.
///
/// The fixture day stands at 13:30. `--loopr-today-clock=morning` moves it to 07:12 and `--loopr-today-clock=evening`
/// to 19:49, the contract's two phones. `--loopr-today-clock=night` is 21:50, when the Protocol deck holds the 21:30 and
/// 21:45 rules, and `--loopr-today-clock=HH:MM` names any minute. Today's dial, rail and timeline, the Protocol tab (its rosettes, deck, rule
/// edits and day sheet), Food and Fitness read this clock, so a rule Today calls open is open on Protocol too and a
/// version saved on Protocol is in force on Today (ICP R3-OPT-1, R3-OPT-2, R3-OPT-5). The zone is the one the fixture
/// night was built in (`SleepClock.calendar`), so last night sits at the bottom of the dial whatever zone the simulator
/// is in. Production never reads this: it reads the environment's clock and zone.
nonisolated enum TodayDialFixtureClock {
    static let argumentPrefix = "--loopr-today-clock="
    static let morningMinute = 7 * 60 + 12
    static let eveningMinute = 19 * 60 + 49
    static let nightMinute = 21 * 60 + 50
    static let defaultMinute = 13 * 60 + 30

    static func minuteOfDay(arguments: [String]) -> Int {
        let value = arguments.last { $0.hasPrefix(argumentPrefix) }.map { String($0.dropFirst(argumentPrefix.count)) }
        switch value {
        case "morning": return morningMinute
        case "evening": return eveningMinute
        case "night": return nightMinute
        default:
            let parts = value?.split(separator: ":").compactMap { Int($0) } ?? []
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return defaultMinute }
            return parts[0] * 60 + parts[1]
        }
    }

    /// True when the launch names a clock with `--loopr-today-clock=`.
    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix(argumentPrefix) }
    }

    /// The pinned instant on `day`, or nil when the day cannot be placed.
    static func now(day: DayIdentity, calendar: Calendar, arguments: [String]) -> Date? {
        guard let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else { return nil }
        let start = calendar.startOfDay(for: noon)
        let minute = minuteOfDay(arguments: arguments)
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start)
    }

    /// The pinned minute on the day `date` falls on in `calendar`, for a tab that keeps its own fixture zone (Food, the
    /// Train fixture). Its clock then reads the same hour as Today's.
    static func now(sameDayAs date: Date, calendar: Calendar,
                    arguments: [String] = ProcessInfo.processInfo.arguments) -> Date {
        let start = calendar.startOfDay(for: date)
        let minute = minuteOfDay(arguments: arguments)
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start)
            ?? start.addingTimeInterval(TimeInterval(minute * 60))
    }

    /// The zone fixture launches read their day in.
    static var timeZone: TimeZone { Calendar.current.timeZone }

    /// The launch's clock: the pinned minute on the fixture day, in `timeZone`.
    @MainActor
    static func clock(environment: AppEnvironment,
                      arguments: [String] = ProcessInfo.processInfo.arguments) -> (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = environment.productDay(fixture: TodayFixtures.day)
        return (now(day: day, calendar: calendar, arguments: arguments) ?? environment.dateProvider.now(), calendar)
    }
}
