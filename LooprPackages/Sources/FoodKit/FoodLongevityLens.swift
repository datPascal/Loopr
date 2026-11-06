import Foundation

/// A mean over the days that contributed, with how many that was.
public struct FoodLensAverage: Equatable, Sendable {
    public let value: Double
    /// Complete days that had a value for this nutrient.
    public let days: Int
    public init(value: Double, days: Int) { self.value = value; self.days = days }
}

/// The ultra-processed share of a week. Only Open Food Facts `nova_group` counts (DEC-12.8): a barcoded item with
/// group 4 is ultra-processed, a barcoded item with group 1 to 3 is classified as not, and every other item,
/// drink and barcoded item without a group is "not classified". Loopr adds no classification of its own.
public struct FoodUltraProcessedShare: Equatable, Sendable {
    /// Energy of nova 4 items over the energy of all classified items, 0 to 1.
    public let share: Double
    /// Classified energy over total energy, 0 to 1. Always shown next to the share.
    public let coverage: Double
    public let ultraProcessedEnergy: Double
    public let classifiedEnergy: Double
    /// Energy of every item and drink with a known energy on the complete days.
    public let totalEnergy: Double
    public let classifiedItems: Int
    /// Items on the complete days that are not classified, including items with no known energy.
    public let unclassifiedItems: Int
    public init(share: Double, coverage: Double, ultraProcessedEnergy: Double, classifiedEnergy: Double, totalEnergy: Double,
                classifiedItems: Int, unclassifiedItems: Int) {
        self.share = share; self.coverage = coverage; self.ultraProcessedEnergy = ultraProcessedEnergy
        self.classifiedEnergy = classifiedEnergy; self.totalEnergy = totalEnergy
        self.classifiedItems = classifiedItems; self.unclassifiedItems = unclassifiedItems
    }
}

/// Alcohol-free days among the finished days. A day with no drink logged is not an answer: it counts as alcohol-free
/// only when the person marked "None today", and as drinking when alcohol was logged. A finished day with neither is
/// unanswered and counts toward neither number (DESIGN_LANGUAGE check 8: missing stays missing).
public struct FoodAlcoholFreeDays: Equatable, Sendable {
    public let alcoholFree: Int
    /// Finished days with an answer: marked "None today", or with alcohol logged.
    public let answered: Int
    /// Days the person marked complete this week.
    public let completeDays: Int
    public init(alcoholFree: Int, answered: Int? = nil, completeDays: Int) {
        self.alcoholFree = alcoholFree; self.answered = answered ?? alcoholFree; self.completeDays = completeDays
    }
}

/// The longevity lens for one ISO week: the four Food tiles and Today's last-meal readout (DEC-12, LV-05).
///
/// Every value is nil, never zero, when its inputs are missing. Averages and counts use only the days the person
/// marked complete, because only a complete day says everything eaten was logged. On a complete day a nutrient's
/// total is the sum of the values the items and drinks reported; a day where no item reported the nutrient does not
/// count for it. A complete day with nothing logged is a known zero, as everywhere in Food.
public struct FoodLongevityLens: Equatable, Sendable {
    public let week: FoodISOWeek
    /// Days this week the person marked complete.
    public let completeDays: Int
    /// Grams of protein per kilogram of body weight per day. Nil without a valid body weight or a day with protein.
    public let proteinPerKilogram: FoodLensAverage?
    /// Grams of fibre per day.
    public let fibrePerDay: FoodLensAverage?
    /// Nil when no energy on a complete day came from a classified barcoded item.
    public let ultraProcessed: FoodUltraProcessedShare?
    /// Nil with no finished day that has an answer about alcohol.
    public let alcoholFree: FoodAlcoholFreeDays?
    /// Whole minutes from the last meal to the bedtime. Nil without a bedtime or without a meal in the 24 hours
    /// before it.
    public let lastMealToBedMinutes: Int?

    private struct Day {
        let items: [FoodItem]
        let drinks: [FoodDrink]
        /// The person marked "None today" for alcohol.
        let noAlcohol: Bool
    }

    public init(week: FoodISOWeek, data: FoodOverviewData, bodyWeightKilograms: Double? = nil, bedtime: Date? = nil) {
        let completed = Set(data.days.filter { $0.completedAt != nil }.map(\.localDay))
        let days = week.days.filter(completed.contains).map { localDay in
            Day(items: data.meals.filter { $0.localDay == localDay }.flatMap(\.items), drinks: data.drinks.filter { $0.localDay == localDay },
                noAlcohol: data.days.first { $0.localDay == localDay }?.noAlcoholAt != nil)
        }
        self.init(week: week, completeDays: days, meals: data.meals, bodyWeightKilograms: bodyWeightKilograms, bedtime: bedtime)
    }

    public init(week: FoodISOWeek, summaries: [FoodDaySummary], bodyWeightKilograms: Double? = nil, bedtime: Date? = nil) {
        let inWeek = summaries.filter { week.contains(localDay: $0.localDay) }
        self.init(week: week, completeDays: inWeek.filter(\.isCompleted).map { Day(items: $0.items, drinks: $0.drinks, noAlcohol: $0.record?.noAlcoholAt != nil) },
            meals: summaries.flatMap(\.meals), bodyWeightKilograms: bodyWeightKilograms, bedtime: bedtime)
    }

    private init(week: FoodISOWeek, completeDays days: [Day], meals: [FoodMeal], bodyWeightKilograms: Double?, bedtime: Date?) {
        self.week = week
        completeDays = days.count

        func daily(_ nutrient: FoodNutrient) -> [Double] {
            days.compactMap { FoodDaySummary.total(nutrient, items: $0.items, drinks: $0.drinks, completed: true).knownValue }
        }
        func average(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            return mean.isFinite ? mean : nil
        }
        if let weight = bodyWeightKilograms, weight.isFinite, FoodWeightEntry.validRange.contains(weight),
           let mean = average(daily(.protein)) {
            proteinPerKilogram = .init(value: mean / weight, days: daily(.protein).count)
        } else { proteinPerKilogram = nil }
        if let mean = average(daily(.fibre)) { fibrePerDay = .init(value: mean, days: daily(.fibre).count) } else { fibrePerDay = nil }

        var ultraProcessedEnergy = 0.0, classifiedEnergy = 0.0, totalEnergy = 0.0
        var classifiedItems = 0, unclassifiedItems = 0
        for day in days {
            totalEnergy += day.drinks.compactMap(\.energy).filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
            for item in day.items {
                let energy = item.nutrients[.energy].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                totalEnergy += energy ?? 0
                let isScanned = item.provenance.contains { $0.source == .barcode }
                if isScanned, let group = item.novaGroup, (1...4).contains(group) {
                    classifiedItems += 1
                    classifiedEnergy += energy ?? 0
                    if group == 4 { ultraProcessedEnergy += energy ?? 0 }
                } else { unclassifiedItems += 1 }
            }
        }
        if classifiedEnergy > 0 {
            ultraProcessed = .init(share: ultraProcessedEnergy / classifiedEnergy, coverage: classifiedEnergy / totalEnergy,
                ultraProcessedEnergy: ultraProcessedEnergy, classifiedEnergy: classifiedEnergy, totalEnergy: totalEnergy,
                classifiedItems: classifiedItems, unclassifiedItems: unclassifiedItems)
        } else { ultraProcessed = nil }

        func positive(_ value: Double?) -> Bool { (value ?? 0) > 0 }
        // The same rule as the Alcohol pattern: any drink or item that reports alcohol makes the day not alcohol free.
        func drank(_ day: Day) -> Bool {
            day.drinks.contains { positive($0.alcoholUnits) } || day.items.contains { positive($0.nutrients[.alcoholUnits]) }
        }
        // Not logging is not an answer. Only a day marked "None today", or one with alcohol logged, is answered.
        let answered = days.filter { drank($0) || $0.noAlcohol }
        if answered.isEmpty { alcoholFree = nil } else {
            alcoholFree = .init(alcoholFree: answered.filter { !drank($0) }.count, answered: answered.count, completeDays: days.count)
        }

        lastMealToBedMinutes = bedtime.flatMap { Self.minutesFromLastMeal(toBedAt: $0, meals: meals) }
    }

    /// Whole minutes between the last meal at or before the bedtime and the bedtime, looking back 24 hours.
    /// Drinks are not meals. A meal after the bedtime is ignored.
    public static func minutesFromLastMeal(toBedAt bedtime: Date, meals: [FoodMeal]) -> Int? {
        guard bedtime.timeIntervalSince1970.isFinite else { return nil }
        let last = meals.map(\.occurredAt).filter { $0 <= bedtime && bedtime.timeIntervalSince($0) <= 86_400 }.max()
        return last.map { Int((bedtime.timeIntervalSince($0) / 60).rounded(.down)) }
    }
}
