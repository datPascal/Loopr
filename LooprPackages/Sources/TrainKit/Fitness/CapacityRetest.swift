import Foundation

/// How often a protocol asks for a test, such as every month. The protocol's rule in the Tests group sets it.
public struct CapacityCadence: Equatable, Sendable {
    public enum Unit: String, Sendable { case day, week, month, year }

    public let count: Int
    public let unit: Unit

    /// Nil unless `count` is at least 1.
    public init?(count: Int, unit: Unit) {
        guard count >= 1 else { return nil }
        self.count = count; self.unit = unit
    }

    /// Reads a protocol rule's unit text: "day", "week", "month", "year" in singular or plural, with or without
    /// "per" or "every", and "daily", "weekly", "monthly", "quarterly" (three months), "yearly" and "annual".
    /// Nil for anything else, so a rule Loopr cannot read sets no retest date.
    public init?(count: Double?, unitText: String?) {
        let number = count ?? 1
        guard number.isFinite, number >= 1, number == number.rounded(), let text = unitText else { return nil }
        let name = text.lowercased().filter(\.isLetter)
        let cleaned = ["per", "every"].reduce(name) { $0.hasPrefix($1) ? String($0.dropFirst($1.count)) : $0 }
        let whole = Int(number)
        switch cleaned {
        case "day", "days", "daily": self.init(count: whole, unit: .day)
        case "week", "weeks", "weekly": self.init(count: whole, unit: .week)
        case "month", "months", "monthly": self.init(count: whole, unit: .month)
        case "quarterly": self.init(count: whole * 3, unit: .month)
        case "year", "years", "yearly", "annual", "annually": self.init(count: whole, unit: .year)
        default: return nil
        }
    }

    public func date(after date: Date, calendar: Calendar) -> Date? {
        let component: Calendar.Component = switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return calendar.date(byAdding: component, value: count, to: date)
    }
}

public enum CapacityRetest: Equatable, Sendable {
    /// The protocol has no rule for this test.
    case noRule
    /// A rule exists but nothing is recorded yet, so there is no date to count from.
    case firstTest(CapacityCadence)
    /// Latest result plus the cadence. A date in the past means the test is due.
    case due(on: Date, CapacityCadence)

    public var date: Date? {
        if case .due(let date, _) = self { date } else { nil }
    }

    public static func make(kind: CapacityTestKind, latest: CapacityResult?, cadences: [CapacityTestKind: CapacityCadence],
                            calendar: Calendar) -> CapacityRetest {
        guard kind.isRetestable, let cadence = cadences[kind] else { return .noRule }
        guard let latest else { return .firstTest(cadence) }
        guard let date = cadence.date(after: latest.recordedAt, calendar: calendar) else { return .firstTest(cadence) }
        return .due(on: date, cadence)
    }
}
