import FoodKit
import Foundation
import Testing

struct FoodLensTilesTests {
    private let week: FoodISOWeek
    init() throws { week = try FoodISOWeek(containing: "2026-10-21") }

    private func data(_ context: LongevityStore, meals: [(day: Int, items: [FoodItem])], complete: [String], drinks: [FoodDrink] = []) throws -> FoodOverviewData {
        .init(meals: try meals.map { try context.meal(at: Longevity.instant(2026, 10, $0.day, 12), zone: Longevity.berlin, items: $0.items) },
              drinks: drinks, days: try complete.map { try Longevity.completeDay($0) }, targets: [])
    }

    private func tile(_ tiles: [FoodLensTile], _ kind: FoodLensTile.Kind) -> FoodLensTile { tiles.first { $0.kind == kind }! }

    @Test func fourTilesInContractOrderWithTheirIdentifiers() {
        let tiles = FoodLensTiles.tiles(lens: nil, bodyWeightKilograms: nil, barcodedItems: 0, proteinTarget: nil, fibreTarget: nil)
        #expect(tiles.map(\.kind) == [.protein, .fibre, .upf, .alcoholFree])
        #expect(tiles.map(\.identifier) == ["food-lens-protein", "food-lens-fibre", "food-lens-upf", "food-lens-alcohol-free"])
        #expect(tiles.map(\.title) == ["Protein", "Fibre", "Ultra-processed", "Alcohol-free"])
    }

    @Test func everyTileSaysWhatItNeedsInsteadOfShowingZero() {
        let none = FoodLongevityLens(week: week, data: .init(meals: [], drinks: [], days: [], targets: []))
        let tiles = FoodLensTiles.tiles(lens: none, bodyWeightKilograms: nil, barcodedItems: 0, proteinTarget: 130, fibreTarget: 35)
        #expect(tiles.allSatisfy { $0.isAbsent && $0.bar == nil && $0.provenance == nil })
        #expect(tile(tiles, .protein).note == "Needs your weight")
        #expect(tile(tiles, .fibre).note == "Needs 3 finished days")
        #expect(tile(tiles, .upf).note == "Needs 3 finished days")
        #expect(tile(tiles, .alcoholFree).note == "Needs 3 finished days")
        let weighed = FoodLensTiles.tiles(lens: none, bodyWeightKilograms: 80, barcodedItems: 0, proteinTarget: nil, fibreTarget: nil)
        #expect(tile(weighed, .protein).note == "Needs 3 finished days")
        #expect(tile(tiles, .protein).accessibilityLabel == "Protein. Needs your weight.")
    }

    @Test func valuesComeWithTheirDaysAndBarsAgainstTheTargets() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, [Longevity.typedItem(nutrients: [.protein: 120, .fibre: 30, .energy: 2_000])]),
            (20, [Longevity.typedItem(nutrients: [.protein: 136, .fibre: 32, .energy: 2_100])]),
            (21, [Longevity.typedItem(nutrients: [.protein: 128, .fibre: 31, .energy: 2_050])]),
        ], complete: ["2026-10-19", "2026-10-20", "2026-10-21"], drinks: [try Longevity.drink(.alcohol, on: "2026-10-20")])
        let lens = FoodLongevityLens(week: week, data: input, bodyWeightKilograms: 80)
        let tiles = FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: 80, barcodedItems: 0, proteinTarget: 160, fibreTarget: 35)
        let protein = tile(tiles, .protein)
        #expect(Longevity.close(protein.value, 1.6) && protein.unit == "g/kg" && protein.fractionDigits == 1)
        #expect(Longevity.close(protein.bar, 0.8))
        #expect(protein.note == "Over 3 finished days")
        let fibre = tile(tiles, .fibre)
        #expect(Longevity.close(fibre.value, 31) && Longevity.close(fibre.bar, 31.0 / 35))
        // Only the 20th answered (a beer): zero alcohol-free days of one answered, over three finished days.
        let alcohol = tile(tiles, .alcoholFree)
        #expect(alcohol.value == 0 && alcohol.unit == "days" && alcohol.note == "Answered on 1 of 3 finished days")
        #expect(tile(tiles, .upf).note == "No barcoded items this week")
        // Without a target there is nothing to fill a bar against.
        let open = FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: 80, barcodedItems: 0, proteinTarget: nil, fibreTarget: nil)
        #expect(tile(open, .protein).bar == nil && tile(open, .fibre).bar == nil && tile(open, .protein).value != nil)
        #expect(tile(tiles, .protein).accessibilityLabel == "Protein, 1.6 grams per kilogram. Over 3 finished days.")
    }

    @Test func aWeeklyNumberWaitsForThreeFinishedDays() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, [Longevity.typedItem(nutrients: [.protein: 120, .fibre: 30])]),
            (20, [Longevity.typedItem(nutrients: [.protein: 136, .fibre: 32])]),
        ], complete: ["2026-10-19", "2026-10-20"], drinks: [try Longevity.drink(.alcohol, on: "2026-10-20")])
        let lens = FoodLongevityLens(week: week, data: input, bodyWeightKilograms: 80)
        #expect(lens.proteinPerKilogram != nil, "The lens has the number; the tile holds it back")
        let tiles = FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: 80, barcodedItems: 0, proteinTarget: 160, fibreTarget: 35)
        #expect(tiles.allSatisfy { $0.isAbsent && $0.bar == nil })
        #expect(tiles.allSatisfy { $0.note == "2 of 3 finished days so far" })
    }

    @Test func alcoholFreeNeedsAnAnswerNotJustFinishedDays() throws {
        let context = try LongevityStore()
        let days = ["2026-10-19", "2026-10-20", "2026-10-21"]
        let meals = [(19, [Longevity.typedItem()]), (20, [Longevity.typedItem()]), (21, [Longevity.typedItem()])]
        let silent = FoodOverviewData(meals: try meals.map { try context.meal(at: Longevity.instant(2026, 10, $0.0, 12), zone: Longevity.berlin, items: $0.1) },
                                      drinks: [], days: try days.map { try Longevity.completeDay($0) }, targets: [])
        let unanswered = tile(FoodLensTiles.tiles(lens: FoodLongevityLens(week: week, data: silent), bodyWeightKilograms: nil, barcodedItems: 0,
                                                  proteinTarget: nil, fibreTarget: nil), .alcoholFree)
        #expect(unanswered.isAbsent && unanswered.note == "Not logged. Tap None today under Drinks.")
        let said = FoodOverviewData(meals: silent.meals, drinks: [], days: try days.enumerated().map { try Longevity.completeDay($1, noAlcohol: $0 < 2) }, targets: [])
        let answered = tile(FoodLensTiles.tiles(lens: FoodLongevityLens(week: week, data: said), bodyWeightKilograms: nil, barcodedItems: 0,
                                                proteinTarget: nil, fibreTarget: nil), .alcoholFree)
        #expect(answered.value == 2 && answered.unit == "days" && answered.note == "Answered on 2 of 3 finished days")
    }

    @Test func ultraProcessedShowsItsCoverageFromTheBarcodedItems() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, [Longevity.scannedItem(nova: 4, energy: 100), Longevity.scannedItem(nova: 1, energy: 300), Longevity.scannedItem(energy: 200),
                  Longevity.typedItem(nutrients: [.energy: 500])]),
            (20, [Longevity.scannedItem(nova: 3, energy: 600), Longevity.scannedItem(nova: 4, energy: 0)]),
            (21, [Longevity.scannedItem(nova: 2, energy: 200), Longevity.scannedItem(nova: 4, energy: 100)]),
            (22, [Longevity.scannedItem(nova: 4, energy: 900)]),
        ], complete: ["2026-10-19", "2026-10-20", "2026-10-21"])
        #expect(FoodLensTiles.barcodedItems(week: week, data: input) == 7)
        let lens = FoodLongevityLens(week: week, data: input)
        let upf = tile(FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: nil, barcodedItems: 7, proteinTarget: nil, fibreTarget: nil), .upf)
        #expect(Longevity.close(upf.value, 20_000.0 / 1_300) && upf.unit == "%" && !upf.isProvisional)
        #expect(Longevity.close(upf.bar, 200.0 / 1_300))
        #expect(upf.note == "6 of 7 barcoded items · 65% of kcal")
        #expect(upf.provenance == .food(.barcode))
        #expect(upf.provenanceQualifier == "65% of kcal")

        // Barcoded items without a group, and nothing else classified.
        let unclassified = try data(context, meals: [(21, [Longevity.scannedItem(energy: 200), Longevity.scannedItem(energy: 100)])],
                                    complete: ["2026-10-19", "2026-10-20", "2026-10-21"])
        let none = FoodLongevityLens(week: week, data: unclassified)
        let tiles = FoodLensTiles.tiles(lens: none, bodyWeightKilograms: nil, barcodedItems: FoodLensTiles.barcodedItems(week: week, data: unclassified),
                                        proteinTarget: nil, fibreTarget: nil)
        #expect(tile(tiles, .upf).note == "No group for 2 barcoded items" && tile(tiles, .upf).isAbsent)
    }

    @Test func fewScannedItemsLeadWithTheCountAndNotAConfidentShare() throws {
        let context = try LongevityStore()
        let input = try data(context, meals: [
            (19, [Longevity.scannedItem(nova: 4, energy: 100), Longevity.scannedItem(nova: 1, energy: 300)]),
            (20, [Longevity.typedItem(nutrients: [.energy: 600])]),
            (21, [Longevity.typedItem(nutrients: [.energy: 600])]),
        ], complete: ["2026-10-19", "2026-10-20", "2026-10-21"])
        let lens = FoodLongevityLens(week: week, data: input)
        let upf = tile(FoodLensTiles.tiles(lens: lens, bodyWeightKilograms: nil, barcodedItems: 2, proteinTarget: nil, fibreTarget: nil), .upf)
        #expect(upf.value == 2 && upf.unit == "items" && upf.isProvisional && upf.bar == nil)
        #expect(upf.note == "25% so far. Needs 5 scanned items for a share")
        #expect(upf.accessibilityLabel == "Ultra-processed, 2 items. 25% so far. Needs 5 scanned items for a share.")
    }
}
