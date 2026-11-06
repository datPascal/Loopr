import FoodKit
import Foundation
import Testing

struct FoodStackShelfTests {
    private func taken(_ item: SupplementItem, _ slot: StackSlot = .morning) -> StackTick {
        StackTick(itemID: item.id, localDay: Stack.day, slot: slot, state: .taken, recordedAt: Stack.stamp)
    }

    @Test func theContractStackReadsSixOfSevenTakenWithEachLaneInItsSlot() throws {
        let items = try Stack.contractStack()
        let ticks = items.filter { $0.name != "Mg" }.map { taken($0, $0.schedule == .evening ? .evening : .morning) }
        let shelf = FoodStackShelf(supplements: StackDay(localDay: Stack.day, supplements: items, ticks: ticks),
                                   medication: StackDay(localDay: Stack.day, medication: [], ticks: []), items: items)
        #expect(shelf.morning.map(\.name) == ["D3", "Omega-3", "Creatine", "B12", "Fibre"])
        #expect(shelf.evening.map(\.name) == ["Glycine", "Mg"])
        #expect(shelf.medication.isEmpty)
        #expect(shelf.supplementsHeadline == "6 of 7 taken" && shelf.medicationHeadline == nil)
        #expect(shelf.evening.last?.isTaken == false && shelf.morning.allSatisfy { $0.isTaken })
        #expect(shelf.evening.last?.key == "supplement-mg-evening")
        #expect(shelf.evening.last?.identifier == "food-stack-item-supplement-mg-evening")
        // Each capsule wears the item's own pair.
        #expect(shelf.morning.first?.colors == CapsuleColors(first: "#E8B84A", second: "#F4E3A8"))
        #expect(shelf.morning.allSatisfy { $0.shape == .capsule && $0.lane == .supplement })
    }

    @Test func medicationGetsItsOwnLaneOfTabletsAndPausedItemsAreNotDue() throws {
        let both = try Stack.supplement("Fish oil", schedule: .both, form: .softgel, sort: 0)
        let paused = try Stack.supplement("Zinc", active: false, sort: 1)
        let later = try Stack.supplement("Iron", startDay: "2026-11-01", sort: 2)
        let drops = try Stack.supplement("D3 drops", form: .drop, sort: 3, key: "d3-drops")
        let medicine = try Stack.medicine("Metformin", schedule: .evening)
        let shelf = FoodStackShelf(supplements: StackDay(localDay: Stack.day, supplements: [both, paused, later, drops], ticks: [taken(both)]),
                                   medication: StackDay(localDay: Stack.day, medication: [medicine], ticks: []), items: [both, paused, later, drops])
        #expect(shelf.morning.map(\.name) == ["Fish oil", "D3 drops"])
        #expect(shelf.evening.map(\.name) == ["Fish oil"])
        #expect(shelf.morning.map(\.shape) == [.softgel, .drop])
        #expect(shelf.supplementsHeadline == "1 of 3 taken")
        #expect(shelf.medication.map(\.key) == ["medication-metformin-evening"])
        #expect(shelf.medication.allSatisfy { $0.shape == .tablet && $0.colors == FoodStackShelf.medicationColors && $0.lane == .medication })
        #expect(shelf.medicationHeadline == "0 of 1 taken")
        // An item without colours takes a contract pair, the same one each time.
        #expect(FoodStackShelf.palette.contains(shelf.morning[1].colors))
        #expect(FoodStackShelf.colors(forKey: "d3-drops") == shelf.morning[1].colors)
        #expect(shelf.morning[0].accessibilityLabel == "Fish oil, 1000 mg, morning, taken")
        #expect(shelf.evening[0].accessibilityLabel == "Fish oil, 1000 mg, evening, not taken yet")
    }

    @Test func nothingDueIsAnEmptyShelf() {
        let shelf = FoodStackShelf(supplements: StackDay(localDay: Stack.day, supplements: [], ticks: []),
                                   medication: StackDay(localDay: Stack.day, medication: [], ticks: []), items: [])
        #expect(shelf.isEmpty && shelf.supplementsHeadline == nil)
    }

    @Test func aTapTakesADueOrSkippedDoseAndClearsATakenOne() throws {
        #expect(FoodStackTap.action(for: .notRecorded) == .take)
        #expect(FoodStackTap.action(for: .skipped(at: Stack.stamp, note: nil)) == .take)
        #expect(FoodStackTap.action(for: .taken(at: Stack.stamp, note: nil)) == .clear)

        let items = try Stack.contractStack()
        let shelf = FoodStackShelf(supplements: StackDay(localDay: Stack.day, supplements: items, ticks: []),
                                   medication: StackDay(localDay: Stack.day, medication: [], ticks: []), items: items)
        let mg = try #require(shelf.evening.last)
        let ticked = shelf.toggling(mg, at: Stack.stamp)
        #expect(ticked.evening.last?.isTaken == true && ticked.supplementsTaken == 1)
        #expect(ticked.morning == shelf.morning)
        let cleared = ticked.toggling(try #require(ticked.evening.last), at: Stack.stamp)
        #expect(cleared.evening.last?.isTaken == false && cleared.supplementsTaken == 0)
    }
}
