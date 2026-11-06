import FoodKit
import Foundation
import RoutineKit
import Testing

/// The stack's metric names are RoutineKit's vocabulary, so a Protocol rule written with them evaluates.
struct SupplementVocabularyTests {
    @Test func everyStackMetricNameIsInTheRoutineVocabulary() {
        #expect(SupplementMetric.allTaken == RoutineMetric.supplementsAllTaken.rawValue)
        #expect(SupplementMetric.medicationAllTaken == RoutineMetric.medicationAllTaken.rawValue)
        #expect(SupplementMetric.adherence == RoutineMetric.supplementAdherence.rawValue)
        #expect(SupplementMetric.taken(itemKey: "vitamin-d3") == "supplement_taken:vitamin-d3")
        #expect(SupplementMetric.taken(itemKey: "metformin", lane: .medication) == "medication_taken:metformin")
        for name in [SupplementMetric.allTaken, SupplementMetric.medicationAllTaken, SupplementMetric.adherence,
                     SupplementMetric.taken(itemKey: "vitamin-d3"), SupplementMetric.taken(itemKey: "metformin", lane: .medication)] {
            #expect(RoutineMetricVocabulary.source(ofMetric: name) == .food, "\(name)")
        }
    }

    @Test func snapshotReadingsSplitLaneAndItemMetrics() throws {
        let items = try Stack.contractStack()
        let ticks = items.map { StackTick(itemID: $0.id, localDay: Stack.day, slot: $0.schedule == .evening ? .evening : .morning,
                                          state: .taken, recordedAt: Stack.stamp) }
        let medicine = try Stack.medicine("Metformin")
        let split = SupplementRoutineFeed.snapshotReadings(supplements: StackDay(localDay: Stack.day, supplements: items, ticks: ticks),
                                                           medication: StackDay(localDay: Stack.day, medication: [medicine], ticks: []))
        #expect(split.readings == [.supplementsAllTaken: .measured(1), .supplementAdherence: .measured(1)])
        #expect(split.items.count == 7)
        #expect(split.items[RoutineItemMetric(kind: .supplementTaken, itemKey: "mg")!] == .measured(1))
        #expect(split.items.keys.allSatisfy { $0.kind == .supplementTaken }, "metformin has no tick, so no reading")
    }
}
