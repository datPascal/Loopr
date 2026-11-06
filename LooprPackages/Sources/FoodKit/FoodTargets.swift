import DesignSystem
import Foundation

public enum FoodGoal: String, CaseIterable, Codable, Sendable {
    case lose, maintain, build
    public var title: String { rawValue.capitalized }
}

/// A confirmed base target excludes the training allowance below. The goal
/// describes the person's choice; it does not invent a deficit or surplus.
public struct FoodTargetSettings: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var goal: FoodGoal
    public var baseEnergy: Double
    public var protein: Double?
    public var carbs: Double?
    public var fat: Double?
    public var waterMillilitres: Double?
    public var adjustsForActiveEnergy: Bool
    public let confirmedAt: Date
    /// What the planner was given, when the targets came from it. Nil for numbers typed by hand
    /// and for targets saved before the planner existed.
    public var plan: FoodGoalPlan?

    public init(id: UUID = UUID(), goal: FoodGoal, baseEnergy: Double, protein: Double? = nil,
                carbs: Double? = nil, fat: Double? = nil, waterMillilitres: Double? = nil,
                adjustsForActiveEnergy: Bool = false, confirmedAt: Date, plan: FoodGoalPlan? = nil) {
        self.id = id; self.goal = goal; self.baseEnergy = baseEnergy
        self.protein = protein; self.carbs = carbs; self.fat = fat
        self.waterMillilitres = waterMillilitres
        self.adjustsForActiveEnergy = adjustsForActiveEnergy; self.confirmedAt = confirmedAt
        self.plan = plan
    }

    public func validate() throws {
        guard baseEnergy.isFinite, baseEnergy > 0,
              confirmedAt.timeIntervalSince1970.isFinite,
              [protein, carbs, fat, waterMillilitres].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw FoodError.invalidRecord }
        try plan?.validate()
    }
}

public enum FoodStrainScale: String, Codable, Sendable {
    case daily21, workout100
    public var maximum: Double { self == .daily21 ? 21 : 100 }
}

public struct FoodStrain: Codable, Equatable, Sendable {
    public let value: Double
    public let scale: FoodStrainScale
    public init(value: Double, scale: FoodStrainScale) { self.value = value; self.scale = scale }
    public var isValid: Bool { value.isFinite && (0...scale.maximum).contains(value) }
}

public struct FoodTrainingAllowance: Codable, Equatable, Sendable {
    public let title: String
    public let energy: Double
    public let plannedStrain: FoodStrain?
    public let confirmedAt: Date
    public init(title: String, energy: Double, plannedStrain: FoodStrain? = nil, confirmedAt: Date) {
        self.title = title; self.energy = energy; self.plannedStrain = plannedStrain; self.confirmedAt = confirmedAt
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              energy.isFinite, energy >= 0, plannedStrain?.isValid != false,
              confirmedAt.timeIntervalSince1970.isFinite else { throw FoodError.invalidRecord }
    }
}

/// Active surplus only, for this local day. It already includes workouts.
/// Callers must not pass total expenditure or a session's gross calories.
public struct FoodActiveEnergy: Equatable, Sendable {
    public let energy: Double
    public let source: String
    public let algorithmVersion: String
    public let hasUsableProfileAndWear: Bool
    public init(energy: Double, source: String, algorithmVersion: String, hasUsableProfileAndWear: Bool) {
        self.energy = energy; self.source = source; self.algorithmVersion = algorithmVersion
        self.hasUsableProfileAndWear = hasUsableProfileAndWear
    }
    public var isUsable: Bool {
        energy.isFinite && energy >= 0 && !source.isEmpty && !algorithmVersion.isEmpty && hasUsableProfileAndWear
    }
}

public struct FoodTarget: Equatable, Sendable {
    public static let policyVersion = "food-target-1"
    public let energy: Double?
    public let adjustment: Double?
    public let reason: String
    public let isEstimated: Bool
    public let plannedStrain: FoodStrain?
    public let actualStrain: FoodStrain?
    public let source: String?

    public static func resolve(settings: FoodTargetSettings?, plan: FoodTrainingAllowance?,
                               active: FoodActiveEnergy?, actualStrain: FoodStrain?) throws -> Self {
        try settings?.validate(); try plan?.validate()
        guard actualStrain?.isValid != false else { throw FoodError.invalidRecord }
        guard let settings else {
            return .init(energy: nil, adjustment: nil, reason: "Set your food goal and daily target.",
                isEstimated: false, plannedStrain: plan?.plannedStrain, actualStrain: actualStrain, source: nil)
        }
        let planned = plan?.energy ?? 0
        let actual = settings.adjustsForActiveEnergy && active?.isUsable == true ? active : nil
        // A partial day's observed activity can exceed the plan, but cannot
        // erase activity still planned for later. Max replaces the allowance;
        // adding these values would count the same activity twice.
        let allowance = max(planned, actual?.energy ?? 0)
        let energy = settings.baseEnergy + allowance
        guard energy.isFinite else { throw FoodError.invalidRecord }
        let usesActual = actual.map { $0.energy > planned } ?? false
        let reason: String
        if usesActual {
            reason = "Target +\(LooprUnitFormatter.number(allowance) ?? "0") kcal from estimated active energy so far."
        } else if let plan, planned > 0 {
            reason = "Your target is \(LooprUnitFormatter.number(planned) ?? "0") kcal higher today because \(plan.title) is planned."
        } else if settings.adjustsForActiveEnergy && actual == nil {
            reason = "Your base target. More profile and wear data are needed to adjust it."
        } else {
            let purpose = switch settings.goal { case .lose: "lose weight"; case .maintain: "maintain weight"; case .build: "build muscle" }
            reason = "Your daily target to \(purpose) is \(energy.formatted(.number.precision(.fractionLength(0)).locale(LooprUnitFormatter.displayLocale))) kcal."
        }
        return .init(energy: energy, adjustment: allowance, reason: reason, isEstimated: usesActual,
            plannedStrain: plan?.plannedStrain, actualStrain: actualStrain, source: usesActual ? actual?.source : nil)
    }
}
