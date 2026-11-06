import Foundation
import SwiftUI

/// Everything the Food tab's longevity objects draw, loaded beside the day summary. Each part is optional: a part that
/// could not load draws its own absent state, and the rest of the screen is unaffected.
public struct FoodLongevity {
    /// False until the first load finishes, so the sections do not flash their absent states while loading.
    public var isLoaded: Bool
    public var targets: FoodProtocolTargets
    public var plants: FoodPlantWeek?
    /// This week's plants that none of the four weeks before held.
    public var newPlants: [FoodWeekPlant]
    /// False when none of the four weeks before had a meal, so no plant can be called new.
    public var hasEarlierWeeks: Bool
    public var lens: FoodLongevityLens?
    /// The seven-day weight average the lens divided by.
    public var bodyWeightKilograms: Double?
    public var barcodedItems: Int
    public var stack: FoodStackShelf?
    /// The camera's sticker for each meal with a photo, by meal id.
    public var stickers: [UUID: Image]
    /// Grows by one when the camera's finish hands back to the tab, so the ring dots settle once more.
    public var settleToken: Int

    public init(isLoaded: Bool = false, targets: FoodProtocolTargets = .none, plants: FoodPlantWeek? = nil, newPlants: [FoodWeekPlant] = [],
                hasEarlierWeeks: Bool = false, lens: FoodLongevityLens? = nil, bodyWeightKilograms: Double? = nil,
                barcodedItems: Int = 0, stack: FoodStackShelf? = nil, stickers: [UUID: Image] = [:], settleToken: Int = 0) {
        self.isLoaded = isLoaded; self.targets = targets; self.plants = plants; self.newPlants = newPlants; self.hasEarlierWeeks = hasEarlierWeeks
        self.lens = lens; self.bodyWeightKilograms = bodyWeightKilograms; self.barcodedItems = barcodedItems
        self.stack = stack; self.stickers = stickers; self.settleToken = settleToken
    }
}

extension FoodMealDraft {
    /// A new meal that repeats `meal` at `date`. Each item is copied through `FoodItem.duplicated(addingEditAt:)`, so
    /// it keeps its values, provenance, Open Food Facts group, ingredients and plants, and records the repeat as an edit.
    public static func repeating(_ meal: FoodMeal, at date: Date, timeZoneIdentifier: String) -> FoodMealDraft {
        FoodMealDraft(slot: meal.slot, occurredAt: date, timeZoneIdentifier: timeZoneIdentifier,
                      items: meal.items.map { $0.duplicated(addingEditAt: date) }, note: meal.note)
    }
}
