import Foundation
import StorageKit

public struct FoodOverviewData: Sendable {
    public let meals: [FoodMeal]
    public let drinks: [FoodDrink]
    public let days: [FoodDayRecord]
    public let targets: [FoodTargetSettings]
    public init(meals: [FoodMeal], drinks: [FoodDrink], days: [FoodDayRecord], targets: [FoodTargetSettings]) {
        self.meals = meals; self.drinks = drinks; self.days = days; self.targets = targets
    }
}

public struct FoodDaySummary: Sendable {
    public let date: Date
    public let localDay: String
    public let meals: [FoodMeal]
    public let drinks: [FoodDrink]
    public let record: FoodDayRecord?
    public let settings: FoodTargetSettings?
    public let target: FoodTarget
    public var isCompleted: Bool { record?.completedAt != nil }
    public var items: [FoodItem] { meals.flatMap(\.items) }
    public var isEstimated: Bool { items.contains(where: \.isEstimated) }
    /// Alcohol came from a logged drink or a meal item that reports it.
    public var logsAlcohol: Bool {
        drinks.contains { $0.kind == .alcohol } || items.contains { ($0.nutrients[.alcoholUnits] ?? 0) > 0 }
    }
    /// A display tolerance for the weekly summary, not a calorie adjustment.
    public var isOnTarget: Bool {
        let energy = total(.energy)
        guard isCompleted, energy.isComplete, let value = energy.knownValue, let target = target.energy else { return false }
        return abs(value - target) <= target * 0.05
    }
    public var water: Double? {
        let values = drinks.compactMap(\.waterMillilitres)
        return Self.total(values, completed: isCompleted)
    }

    public init(date: Date, calendar: Calendar, data: FoodOverviewData,
                active: FoodActiveEnergy? = nil, strain: FoodStrain? = nil) throws {
        self.date = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: self.date) else { throw FoodError.invalidRecord }
        let key = try FoodMeal.day(at: date, timeZoneIdentifier: calendar.timeZone.identifier)
        localDay = key
        meals = data.meals.filter { $0.localDay == key }
        drinks = data.drinks.filter { $0.localDay == key }
        record = data.days.first { $0.localDay == key }
        settings = data.targets.filter { $0.confirmedAt < end }.max { $0.confirmedAt < $1.confirmedAt }
        target = try FoodTarget.resolve(settings: settings, plan: record?.allowance, active: active, actualStrain: strain)
    }

    public func total(_ nutrient: FoodNutrient) -> FoodNutrientTotal {
        Self.total(nutrient, items: items, drinks: drinks, completed: isCompleted)
    }

    /// One day's total of a nutrient from its items and drinks. A completed day with nothing logged is a known zero.
    static func total(_ nutrient: FoodNutrient, items: [FoodItem], drinks: [FoodDrink], completed: Bool) -> FoodNutrientTotal {
        let readings = items.map { $0.nutrients[nutrient] } + drinks.map { drink -> Double? in
            switch nutrient {
            case .energy: return drink.energy
            case .caffeine: return drink.knownCaffeineMilligrams
            case .alcoholUnits: return drink.knownAlcoholUnits
            default: return drink.kind == .water ? 0 : drink.additionalNutrients?[nutrient]
            }
        }
        return .init(values: readings.isEmpty && completed ? [0] : readings)
    }

    private static func total(_ values: [Double], completed: Bool) -> Double? {
        let sum = values.reduce(0, +)
        return values.isEmpty && !completed || !sum.isFinite ? nil : sum
    }
}

extension FoodOverviewData {
    /// The same data with every day after `localDay` left out, so a week read on a past day stops at that day.
    public func through(localDay: String) -> FoodOverviewData {
        .init(meals: meals.filter { $0.localDay <= localDay }, drinks: drinks.filter { $0.localDay <= localDay },
              days: days.filter { $0.localDay <= localDay }, targets: targets)
    }
}

/// "This week" on Food: the shown day's ISO week, Monday up to that day. The week chart, its on-target line and the
/// longevity lens (`AppFoodRepository.longevity`, which reads the same week through the same day) all count these
/// finished days, so the two cards never give two different counts (ICP R2-UPG-8).
public struct FoodWeekSoFar: Sendable {
    public let week: FoodISOWeek
    /// Monday up to the shown day, oldest first. A day missing from the summaries is left out.
    public let days: [FoodDaySummary]
    /// How many days of the week come before the shown day, 0 on a Monday.
    public let dayIndex: Int

    /// Nil when the shown day's key is not a valid local day.
    public init?(day: FoodDaySummary, summaries: [FoodDaySummary]) {
        guard let week = try? FoodISOWeek(containing: day.localDay), let index = week.days.firstIndex(of: day.localDay) else { return nil }
        self.week = week
        dayIndex = index
        days = summaries.filter { week.contains(localDay: $0.localDay) && $0.localDay <= day.localDay }
            .sorted { $0.localDay < $1.localDay }
    }

    public var finishedDays: Int { days.filter(\.isCompleted).count }
    public var onTargetDays: Int { days.filter(\.isOnTarget).count }

    /// Under the week chart: how many finished days landed within 5% of their target.
    public var onTargetLine: String {
        switch finishedDays {
        case 0: "No finished days yet this week"
        case 1: "Within 5% of target on \(onTargetDays) of 1 finished day"
        default: "Within 5% of target on \(onTargetDays) of \(finishedDays) finished days"
        }
    }

    /// What VoiceOver reads for `onTargetLine`.
    public var spokenOnTargetLine: String {
        onTargetLine.replacingOccurrences(of: "5%", with: "five percent")
    }

    /// Midnight of each of the week's seven days in `calendar`, Monday first, for the chart's axis. The days after
    /// the shown day keep their place on the axis with no bar.
    public func axisDates(shownDay: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: shownDay)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - dayIndex, to: start) }
    }
}

extension FoodStore {
    /// Seven-day overview reads payloads in one snapshot and leaves photo
    /// bytes on disk. Target history is small and preserves past settings.
    public func overview(from firstDay: String, through lastDay: String) throws -> FoodOverviewData {
        try database.read { db in
            let arguments: StatementArguments = [firstDay, lastDay]
            let meals = try Data.fetchAll(db, sql: "SELECT payload FROM food_meal WHERE local_day BETWEEN ? AND ? ORDER BY occurred_at, id", arguments: arguments)
                .map { data in let meal = try JSONDecoder().decode(FoodMeal.self, from: data); try meal.validate(); return meal }
            let drinks = try Data.fetchAll(db, sql: "SELECT payload FROM food_drink WHERE local_day BETWEEN ? AND ? ORDER BY occurred_at, id", arguments: arguments).map(Self.decodeDrink)
            let days = try Data.fetchAll(db, sql: "SELECT payload FROM food_day WHERE local_day BETWEEN ? AND ? ORDER BY local_day", arguments: arguments).map(Self.decodeDay)
            let targets = try Data.fetchAll(db, sql: "SELECT payload FROM food_target ORDER BY confirmed_at, id").map(Self.decodeTarget)
            return .init(meals: meals, drinks: drinks, days: days, targets: targets)
        }
    }
}
