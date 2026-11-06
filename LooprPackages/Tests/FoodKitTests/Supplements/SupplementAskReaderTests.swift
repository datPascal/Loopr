import FoodKit
import Foundation
import Testing

struct SupplementAskReaderTests {
    private let at = Stack.stamp

    @Test func askReadsDosesWithTheirStateAndKeepsTheLanesApart() throws {
        let context = try LongevityStore(); defer { withExtendedLifetime(context) {} }
        let store = SupplementStore(database: context.database)
        let d3 = try Stack.supplement("D3", amount: 2_000, unit: .iu, schedule: .both, sort: 0)
        let paused = try Stack.supplement("Fibre", active: false, sort: 1)
        let pill = try Stack.medicine("Ramipril", amount: 5, schedule: .morning, prescriber: "Dr. Weber", notes: "private note")
        for item in [d3, paused] { try store.save(item) }
        try store.save(pill)
        try store.record(.taken, itemID: d3.id, day: "2026-10-21", slot: .morning, at: at, note: "with food")
        try store.record(.skipped, itemID: d3.id, day: "2026-10-21", slot: .evening, at: at)
        try store.record(.taken, itemID: pill.id, day: "2026-10-20", slot: .morning, at: at)

        let snapshot = try store.askSnapshot(from: "2026-10-20", through: "2026-10-21")
        #expect(snapshot.firstDay == "2026-10-20" && snapshot.lastDay == "2026-10-21")
        // Two days of D3, morning then evening, and nothing for the paused item.
        #expect(snapshot.supplements.map { "\($0.localDay) \($0.slot.rawValue) \($0.status.rawValue)" } == [
            "2026-10-20 morning notRecorded", "2026-10-20 evening notRecorded", "2026-10-21 morning taken", "2026-10-21 evening skipped",
        ])
        #expect(snapshot.supplements.allSatisfy { $0.name == "D3" && $0.dose == "2000 IU" })
        #expect(snapshot.supplements[2].note == "with food" && snapshot.supplements[2].recordedAt == at && snapshot.supplements[0].recordedAt == nil)
        #expect(snapshot.medication.map { "\($0.localDay) \($0.name) \($0.status.rawValue)" } == [
            "2026-10-20 Ramipril taken", "2026-10-21 Ramipril notRecorded",
        ])
        #expect(snapshot.supplements.allSatisfy { $0.name != "Ramipril" } && snapshot.medication.allSatisfy { $0.name != "D3" })
        // Prescriber and notes stay out of what Ask reads.
        #expect(!String(describing: snapshot).contains("Dr. Weber") && !String(describing: snapshot).contains("private note"))
    }

    @Test func anEmptyStackGivesAnEmptySnapshotAndABadRangeThrows() throws {
        let context = try LongevityStore(); defer { withExtendedLifetime(context) {} }
        let store = SupplementStore(database: context.database)
        let snapshot = try store.askSnapshot(from: "2026-10-20", through: "2026-10-21")
        #expect(snapshot.supplements.isEmpty && snapshot.medication.isEmpty)
        #expect(throws: StackError.invalidDay) { try store.askSnapshot(from: "2026-10-22", through: "2026-10-21") }
    }
}
