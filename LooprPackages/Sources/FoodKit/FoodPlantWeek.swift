import Foundation

/// An ISO 8601 week: Monday first, week 1 holds the year's first Thursday, so a year has 52 or 53 weeks.
///
/// The arithmetic is on local day strings (`yyyy-MM-dd`, the form meals and drinks store), not on `Calendar`
/// settings, so a calendar with Sunday as first weekday cannot shift a week. A calendar only supplies the time
/// zone when a `Date` is turned into a local day.
public struct FoodISOWeek: Hashable, Comparable, Identifiable, Sendable {
    public let year: Int
    public let week: Int
    /// Days since 1970-01-01 of this week's Monday.
    private let mondayDay: Int
    public var id: String { String(format: "%04d-W%02d", year, week) }

    public init(containing localDay: String) throws {
        guard let day = FoodLocalDay.daysSinceEpoch(localDay) else { throw FoodError.invalidRecord }
        self.init(mondayDay: day - (FoodLocalDay.isoWeekday(day) - 1))
    }

    /// The week the instant falls in, as seen from the calendar's time zone.
    public init(containing date: Date, calendar: Calendar) throws {
        try self.init(containing: FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier))
    }

    /// The seven local days, Monday first.
    public var days: [String] { (0..<7).map { FoodLocalDay.string(daysSinceEpoch: mondayDay + $0) } }
    public var firstDay: String { FoodLocalDay.string(daysSinceEpoch: mondayDay) }
    public var lastDay: String { FoodLocalDay.string(daysSinceEpoch: mondayDay + 6) }
    public func contains(localDay: String) -> Bool {
        guard let day = FoodLocalDay.daysSinceEpoch(localDay) else { return false }
        return (mondayDay...(mondayDay + 6)).contains(day)
    }
    public var previous: FoodISOWeek { Self(mondayDay: mondayDay - 7) }
    public var next: FoodISOWeek { Self(mondayDay: mondayDay + 7) }

    private init(mondayDay: Int) {
        self.mondayDay = mondayDay
        let thursday = mondayDay + 3
        year = FoodLocalDay.civil(thursday).year
        week = (thursday - FoodLocalDay.daysSinceEpoch(year: year, month: 1, day: 1)) / 7 + 1
    }

    public static func < (lhs: FoodISOWeek, rhs: FoodISOWeek) -> Bool { lhs.mondayDay < rhs.mondayDay }
}

/// Day arithmetic on `yyyy-MM-dd` strings in the proleptic Gregorian calendar (Howard Hinnant's civil-date
/// algorithms), which is what `FoodMeal.day(at:timeZoneIdentifier:)` produces.
enum FoodLocalDay {
    static func daysSinceEpoch(_ localDay: String) -> Int? {
        let parts = localDay.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), year >= 1, (1...daysIn(month: month, year: year)).contains(day) else { return nil }
        return daysSinceEpoch(year: year, month: month, day: day)
    }

    static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func string(daysSinceEpoch days: Int) -> String {
        let parts = civil(days)
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    /// Monday is 1 and Sunday is 7. 1970-01-01 was a Thursday.
    static func isoWeekday(_ days: Int) -> Int { ((days + 3) % 7 + 7) % 7 + 1 }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// A plant counted in a week.
public struct FoodWeekPlant: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let category: FoodPlantCategory?
    /// Where it came from, each source once: an edit first, then Open Food Facts, then a photo estimate.
    public let sources: [FoodPlantSource]
    /// The earliest local day this week that held it.
    public let firstLocalDay: String
    /// Items this week that held it.
    public let itemCount: Int
    public var id: String { key }
}

/// Distinct plants in one ISO week. Weeks and meals are grouped by the local day stored on each meal, so a meal
/// logged on Sunday night in another time zone stays in the week of the day it was eaten, whichever zone the phone
/// is in now.
public struct FoodPlantWeek: Equatable, Sendable {
    /// The "30 plants a week" aim the Food screen counts toward.
    public static let weeklyGoal = 30

    public let week: FoodISOWeek
    /// Distinct plants, sorted by name.
    public let plants: [FoodWeekPlant]
    public var count: Int { plants.count }
    /// Plants still missing to reach `weeklyGoal`; zero once reached.
    public var remainingToGoal: Int { max(0, Self.weeklyGoal - count) }

    public init(week: FoodISOWeek, meals: [FoodMeal], list: FoodPlantList) {
        self.week = week
        struct Tally { var plant: FoodItemPlant; var sources: Set<FoodPlantSource>; var firstDay: String; var items: Int }
        var tallies: [String: Tally] = [:]
        for meal in meals where week.contains(localDay: meal.localDay) {
            for item in meal.items {
                for plant in item.plants(in: list) {
                    if var tally = tallies[plant.key] {
                        tally.sources.insert(plant.source); tally.items += 1
                        if meal.localDay < tally.firstDay { tally.firstDay = meal.localDay }
                        tallies[plant.key] = tally
                    } else {
                        tallies[plant.key] = Tally(plant: plant, sources: [plant.source], firstDay: meal.localDay, items: 1)
                    }
                }
            }
        }
        plants = tallies.values.map { tally in
            FoodWeekPlant(key: tally.plant.key, name: tally.plant.name, category: tally.plant.category,
                sources: FoodPlantSource.allCases.filter(tally.sources.contains), firstLocalDay: tally.firstDay, itemCount: tally.items)
        }.sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
    }

    /// The week the instant falls in, as seen from the calendar's time zone.
    public init(containing date: Date, calendar: Calendar, meals: [FoodMeal], list: FoodPlantList) throws {
        self.init(week: try FoodISOWeek(containing: date, calendar: calendar), meals: meals, list: list)
    }

    /// Every week that has a meal, keyed by week.
    public static func weeks(meals: [FoodMeal], list: FoodPlantList) -> [FoodISOWeek: FoodPlantWeek] {
        var result: [FoodISOWeek: FoodPlantWeek] = [:]
        for week in Set(meals.compactMap { try? FoodISOWeek(containing: $0.localDay) }) {
            result[week] = FoodPlantWeek(week: week, meals: meals, list: list)
        }
        return result
    }

    /// Plants in this week that none of the given earlier weeks held. With no earlier weeks every plant is new,
    /// so callers pass the weeks they have and say how many.
    public func newPlants(comparedWith earlier: [FoodPlantWeek]) -> [FoodWeekPlant] {
        let known = Set(earlier.filter { $0.week < week }.flatMap { $0.plants.map(\.key) })
        return plants.filter { !known.contains($0.key) }
    }
}
