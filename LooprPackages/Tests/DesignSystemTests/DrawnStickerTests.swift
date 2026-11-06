import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

/// The drawn sticker for a meal with no photo, shared by Food's rail and Today's dial: a symbol and a palette per meal
/// slot, and the rim of a photo sticker.
struct DrawnStickerTests {
    @Test
    func eachMealSlotHasItsSymbolAndAnythingElseGetsAKnifeAndFork() {
        #expect(LooprDrawnSticker.symbol(forMeal: "Breakfast") == "sunrise.fill")
        #expect(LooprDrawnSticker.symbol(forMeal: "lunch") == "fork.knife")
        #expect(LooprDrawnSticker.symbol(forMeal: "Snack") == "carrot.fill")
        #expect(LooprDrawnSticker.symbol(forMeal: "Dinner") == "moon.stars.fill")
        #expect(LooprDrawnSticker.symbol(forMeal: "Supper") == "fork.knife")
    }

    @Test
    func eachMealSlotHasItsOwnColoursAndAnythingElseTakesDinners() {
        let slots = ["Breakfast", "Lunch", "Snack", "Dinner"].map(LooprDrawnSticker.palette(forMeal:))
        #expect(Set(slots.map { "\($0.deep)" }).count == 4)
        #expect(LooprDrawnSticker.palette(forMeal: "Supper") == LooprDrawnSticker.palette(forMeal: "Dinner"))
        #expect(LooprDrawnSticker.palette(forMeal: "breakfast") == LooprDrawnSticker.palette(forMeal: "Breakfast"))
    }

    @Test
    func theDefaultRimMatchesAPhotoSticker() {
        // Today's photo sticker is 33 across with a 28 photo: 2.5 of rim on each side.
        #expect(abs(LooprDrawnSticker.rimShare * 33 - 2.5) < 1e-9)
    }
}
