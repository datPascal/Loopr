import Foundation

/// The groups the picker shows, in this order. A group appears only when one of its metrics has stored data.
public enum PublishGroup: String, CaseIterable, Codable, Sendable, Hashable {
    case sleep = "Sleep"
    case heart = "Heart"
    case fitness = "Fitness"
    case food = "Food"
    case bloodTests = "Blood tests"
    case protocolRules = "Protocol"

    public var title: String { rawValue }
}

/// The three periods the person can publish. Twelve months is 365 days ending on the export day.
public enum PublishPeriod: String, CaseIterable, Codable, Sendable, Hashable {
    case days30
    case days90
    case months12

    public var days: Int {
        switch self {
        case .days30: 30
        case .days90: 90
        case .months12: 365
        }
    }

    public var title: String {
        switch self {
        case .days30: "Last 30 days"
        case .days90: "Last 90 days"
        case .months12: "Last 12 months"
        }
    }
}

/// The first and last day of a published period as local calendar days, `yyyy-MM-dd`, both included.
public struct PublishPeriodRange: Codable, Equatable, Sendable {
    public var id: String
    public var days: Int
    public var from: String
    public var through: String

    public init(id: String, days: Int, from: String, through: String) {
        self.id = id
        self.days = days
        self.from = from
        self.through = through
    }

    /// The period that ends on the local day of `now` in `timeZone`.
    public init(period: PublishPeriod, endingOn now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let through = PublishDay.label(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        let last = PublishDay.ordinal(through) ?? 0
        self.init(id: period.rawValue, days: period.days, from: PublishDay.label(ordinal: last - (period.days - 1)), through: through)
    }

    /// Whether a local day label falls inside the period.
    public func contains(_ day: String) -> Bool {
        day >= from && day <= through && PublishDay.ordinal(day) != nil
    }
}

/// One metric the picker can show. `hasData` false means the metric is listed as absent and cannot be picked.
public struct PublishMetricDescriptor: Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var unit: String
    public var group: PublishGroup
    public var hasData: Bool

    public var id: String { key }

    public init(key: String, name: String, unit: String, group: PublishGroup, hasData: Bool) {
        self.key = key
        self.name = name
        self.unit = unit
        self.group = group
        self.hasData = hasData
    }
}

/// One local day and its value. Days without a reading are not part of a series.
public struct PublishDayValue: Codable, Equatable, Sendable {
    public var date: String
    public var value: Double

    public init(date: String, value: Double) {
        self.date = date
        self.value = value
    }
}

/// One picked metric: what it is, where its numbers came from, and its daily values, oldest first.
public struct PublishMetricSeries: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var unit: String
    public var group: PublishGroup
    public var source: String
    public var values: [PublishDayValue]

    public init(key: String, name: String, unit: String, group: PublishGroup, source: String, values: [PublishDayValue]) {
        self.key = key
        self.name = name
        self.unit = unit
        self.group = group
        self.source = source
        self.values = values
    }

    /// The most recent value, or nil when the period holds none.
    public var latest: PublishDayValue? { values.last }

    /// The mean of the values in the period, or nil when the period holds none.
    public var average: Double? {
        values.isEmpty ? nil : values.reduce(0) { $0 + $1.value } / Double(values.count)
    }
}

/// Everything one published dashboard holds. Both files are rendered from this value and from nothing else.
public struct PublishDashboard: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generator: String
    public var exportedAt: Date
    public var timeZone: String
    public var period: PublishPeriodRange
    public var includesBloodTests: Bool
    public var metrics: [PublishMetricSeries]

    public init(schemaVersion: Int = PublishDashboard.currentSchemaVersion, generator: String = "Loopr",
                exportedAt: Date, timeZone: String, period: PublishPeriodRange,
                includesBloodTests: Bool, metrics: [PublishMetricSeries]) {
        self.schemaVersion = schemaVersion
        self.generator = generator
        self.exportedAt = exportedAt
        self.timeZone = timeZone
        self.period = period
        self.includesBloodTests = includesBloodTests
        self.metrics = metrics
    }

    /// Builds a dashboard from the series the person picked. Blood test series are dropped unless the person
    /// switched them on. Values outside the period, repeated days and values that are not finite numbers are
    /// dropped, and a day keeps its last value. Metrics follow the picker order: group, then name.
    public static func make(series: [PublishMetricSeries], period: PublishPeriod, exportedAt: Date,
                            timeZone: TimeZone, includeBloodTests: Bool) -> PublishDashboard {
        let range = PublishPeriodRange(period: period, endingOn: exportedAt, timeZone: timeZone)
        let kept = series.filter { includeBloodTests || $0.group != .bloodTests }
        var seen = Set<String>()
        let metrics: [PublishMetricSeries] = kept.compactMap { item in
            guard seen.insert(item.key).inserted else { return nil }
            var byDay: [String: Double] = [:]
            for entry in item.values where entry.value.isFinite && range.contains(entry.date) {
                byDay[entry.date] = entry.value
            }
            var clean = item
            clean.values = byDay.keys.sorted().map { PublishDayValue(date: $0, value: byDay[$0] ?? 0) }
            return clean
        }
        .sorted { lhs, rhs in
            let left = PublishGroup.allCases.firstIndex(of: lhs.group) ?? 0
            let right = PublishGroup.allCases.firstIndex(of: rhs.group) ?? 0
            return left != right ? left < right : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return PublishDashboard(exportedAt: exportedAt, timeZone: timeZone.identifier, period: range,
                                includesBloodTests: includeBloodTests, metrics: metrics)
    }
}

/// Calendar arithmetic on `yyyy-MM-dd` labels. It needs no time zone: a label names a calendar day.
public enum PublishDay {
    public static func label(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Days since 1970-01-01 for a label, or nil when the label is not a real date.
    public static func ordinal(_ label: String) -> Int? {
        let parts = label.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        return civilToDays(year: year, month: month, day: day)
    }

    public static func label(ordinal: Int) -> String {
        let (year, month, day) = daysToCivil(ordinal)
        return label(year: year, month: month, day: day)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    // Howard Hinnant's civil-from-days algorithms, proleptic Gregorian calendar.
    private static func civilToDays(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysToCivil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
