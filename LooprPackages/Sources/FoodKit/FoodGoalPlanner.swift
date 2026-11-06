import Foundation

/// How much a person moves outside workouts. Training is left out on purpose: the day's target
/// already adds the planned allowance or the qualified active energy.
public enum FoodActivityLevel: String, CaseIterable, Codable, Sendable {
    case sitting, light, onFeet, physical

    /// Multiplies resting energy into everyday energy.
    public var multiplier: Double {
        switch self {
        case .sitting: 1.2
        case .light: 1.375
        case .onFeet: 1.5
        case .physical: 1.7
        }
    }

    public var title: String {
        switch self {
        case .sitting: "Mostly sitting"
        case .light: "Some walking"
        case .onFeet: "On my feet"
        case .physical: "Physical work"
        }
    }

    public var detail: String {
        switch self {
        case .sitting: "Desk job, little walking"
        case .light: "Desk job, walks or errands most days"
        case .onFeet: "Standing or walking most of the day, like retail or teaching"
        case .physical: "Lifting and carrying at work, like building or farming"
        }
    }
}

/// What the person chose in the planner. Stored with the confirmed targets, so the Food tab can
/// show progress toward the goal weight.
public struct FoodGoalPlan: Codable, Equatable, Sendable {
    public var startWeightKg: Double
    public var goalWeightKg: Double?
    /// Kilograms a week, always zero or positive. The goal says which way.
    public var paceKgPerWeek: Double
    public var activity: FoodActivityLevel

    public init(startWeightKg: Double, goalWeightKg: Double?, paceKgPerWeek: Double, activity: FoodActivityLevel) {
        self.startWeightKg = startWeightKg; self.goalWeightKg = goalWeightKg
        self.paceKgPerWeek = paceKgPerWeek; self.activity = activity
    }

    public func validate() throws {
        guard FoodWeightEntry.validRange.contains(startWeightKg),
              goalWeightKg.map(FoodWeightEntry.validRange.contains) ?? true,
              paceKgPerWeek.isFinite, (0...FoodGoalPlanner.maximumPace).contains(paceKgPerWeek) else { throw FoodError.invalidRecord }
    }
}

/// Works out daily energy and macros for a goal. Pure: nothing here reads a clock or storage.
///
/// Resting energy is Mifflin-St Jeor. Everyday energy is resting times the activity multiplier.
/// A kilogram of body weight is taken as 7,700 kcal, so 0.5 kg a week is 550 kcal a day.
/// Losing weight never goes below 1,200 kcal (women), 1,500 (men) or 1,350 (unspecified); when
/// that floor applies, the pace and the goal date follow the floor, not the chosen pace.
public struct FoodGoalPlanner: Equatable, Sendable {
    public enum Sex: Sendable { case female, male, unspecified }

    public static let energyPerKilogram: Double = 7_700
    public static let maximumPace: Double = 1.0

    public static func paces(for goal: FoodGoal) -> [Double] {
        switch goal {
        case .lose: [0.25, 0.5, 0.75, 1.0]
        case .maintain: [0]
        case .build: [0.1, 0.25, 0.5]
        }
    }

    public static func defaultPace(for goal: FoodGoal) -> Double {
        switch goal {
        case .lose: 0.5
        case .maintain: 0
        case .build: 0.25
        }
    }

    public let goal: FoodGoal
    /// Mifflin-St Jeor, rounded to 10.
    public let restingEnergy: Double
    /// Resting times the activity multiplier, rounded to 10. What keeps the weight steady.
    public let maintenanceEnergy: Double
    /// The daily base target, rounded to 10. Training goes on top each day.
    public let baseEnergy: Double
    /// The lowest base a weight-loss plan goes to.
    public let minimumEnergy: Double
    /// True when the floor raised the base above the chosen pace.
    public let isAtMinimum: Bool
    /// The pace the base actually gives, kilograms a week, signed: negative loses.
    public let weeklyChangeKg: Double
    /// Weeks until the goal weight at that pace. Nil without a goal weight in the goal's direction.
    public let weeksToGoal: Double?
    /// True when the chosen loss is more than 1% of body weight a week.
    public let isFastLoss: Bool
    /// Grams, rounded to 5.
    public let protein: Double
    public let carbs: Double
    public let fat: Double
    /// Millilitres, rounded to 50.
    public let waterMillilitres: Double

    /// Nil when age, height or weight is missing or outside what the formula covers.
    public init?(goal: FoodGoal, age: Int?, sex: Sex, heightCentimetres: Double?, weightKilograms: Double?,
                 goalWeightKilograms: Double? = nil, activity: FoodActivityLevel = .sitting, paceKgPerWeek: Double? = nil) {
        guard let age, (18...100).contains(age),
              let height = heightCentimetres, (120...230).contains(height),
              let weight = weightKilograms, (35...250).contains(weight) else { return nil }
        let offset: Double = switch sex { case .male: 5; case .female: -161; case .unspecified: -78 }
        let minimum: Double = switch sex { case .male: 1_500; case .female: 1_200; case .unspecified: 1_350 }
        let resting = 10 * weight + 6.25 * height - 5 * Double(age) + offset
        let maintenance = resting * activity.multiplier
        let pace = min(max(paceKgPerWeek ?? Self.defaultPace(for: goal), 0), Self.maximumPace)
        let dailyChange = pace * Self.energyPerKilogram / 7
        let energy: Double
        var floored = false
        switch goal {
        case .lose:
            let wanted = maintenance - dailyChange
            floored = wanted < minimum && pace > 0
            energy = max(wanted, min(minimum, maintenance))
        case .maintain: energy = maintenance
        case .build: energy = maintenance + dailyChange
        }
        let base = Self.round(energy, to: 10)
        let weekly = (base - maintenance) * 7 / Self.energyPerKilogram

        // Protein follows the lighter of today's and the goal weight when losing, so a large
        // starting weight does not ask for a large amount.
        let reference = goal == .lose ? min(weight, goalWeightKilograms ?? weight) : weight
        let proteinPerKilogram: Double = switch goal { case .lose: 2.0; case .maintain: 1.6; case .build: 1.8 }
        let protein = Self.round(reference * proteinPerKilogram, to: 5)
        let fat = Self.round(base * 0.25 / 9, to: 5)
        let carbs = Self.round(max(base - protein * 4 - fat * 9, 0) / 4, to: 5)

        var weeks: Double?
        if let target = goalWeightKilograms, abs(weekly) > 0.01 {
            let remaining = target - weight
            if remaining != 0, (remaining < 0) == (weekly < 0) { weeks = abs(remaining / weekly) }
        }

        self.goal = goal
        restingEnergy = Self.round(resting, to: 10)
        maintenanceEnergy = Self.round(maintenance, to: 10)
        baseEnergy = base
        minimumEnergy = minimum
        isAtMinimum = floored
        weeklyChangeKg = weekly
        weeksToGoal = weeks
        isFastLoss = goal == .lose && pace > weight * 0.01
        self.protein = protein; self.fat = fat; self.carbs = carbs
        waterMillilitres = Self.round(weight * 35, to: 50)
    }

    /// The day the goal weight is reached at this pace, or nil.
    public func goalDate(from start: Date, calendar: Calendar) -> Date? {
        guard let weeksToGoal, weeksToGoal.isFinite, weeksToGoal < 520 else { return nil }
        return calendar.date(byAdding: .day, value: Int((weeksToGoal * 7).rounded(.up)), to: start)
    }

    private static func round(_ value: Double, to step: Double) -> Double { (value / step).rounded() * step }
}
