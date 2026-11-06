import FoodKit
import Foundation
import StorageKit
import Testing

struct SupplementStoreTests {
    private let at = Stack.stamp
    /// The database file is closed and deleted when its `LongevityStore` is released, so a test keeps the fixture alive
    /// to the end of its scope with `defer { withExtendedLifetime(fixture) {} }`. Swift may otherwise release it after its
    /// last use, which closes the connection under a store that is still in use.
    private final class Fixture {
        let context: LongevityStore
        let store: SupplementStore
        init() throws { context = try LongevityStore(); store = SupplementStore(database: context.database) }
    }

    @Test func stacksAndMedicationPersistThroughARestartAndStayInTheirOwnLists() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let context = fixture.context, store = fixture.store
        let omega = try Stack.supplement("Omega-3", form: .softgel, brand: "Nordic", colors: CapsuleColors(first: "#D98E3F", second: "#F2C48B"), key: nil)
        let mg = try Stack.supplement("Magnesium", amount: 300, schedule: .evening, form: .powder, sort: 1)
        let both = try Stack.supplement("Vitamin D3", amount: 2_000, unit: .iu, schedule: .both, sort: 2)
        let pill = try Stack.medicine("Ramipril", amount: 5, prescriber: "Dr. Weber", notes: "With water", sort: 0)
        for item in [omega, mg, both] { try store.save(item) }
        try store.save(pill)
        try context.database.databasePool.close()

        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "supplement-tests")
        defer { try? reopened.databasePool.close() }
        let again = SupplementStore(database: reopened)
        #expect(try again.supplements() == [omega, mg, both])
        #expect(try again.medication() == [pill])
        // The lists are different types and the medicine is in none of the supplement ones.
        #expect(try again.supplements().allSatisfy { $0.name != "Ramipril" })
        #expect(try again.supplementDay(Stack.day).doses.allSatisfy { $0.name != "Ramipril" })
        #expect(try again.medicationDay(Stack.day).doses.map(\.name) == ["Ramipril"])
        #expect(try again.supplements()[2].schedule.slots == [.morning, .evening])
    }

    @Test func keysAreStableUniquePerLaneAndNeverChangeWhenTheNameDoes() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        #expect(try Stack.supplement("Vitamin D3").key == "vitamin-d3")
        #expect(try Stack.supplement("Ömega 3 (fish oil)").key == "omega-3-fish-oil")
        #expect(try Stack.supplement("!!!").key == "item")
        var item = try Stack.supplement("Vitamin D3")
        try store.save(item)
        #expect(try store.uniqueKey(forName: "Vitamin D3", lane: .supplement) == "vitamin-d3-2")
        #expect(try store.uniqueKey(forName: "Vitamin D3", lane: .medication) == "vitamin-d3")
        // A second item with the same key in the same lane is refused; the other lane may reuse it.
        #expect(throws: StackError.duplicateKey) { try store.save(Stack.supplement("Other", key: "vitamin-d3")) }
        try store.save(Stack.medicine("Vitamin D3"))
        // Renaming keeps the key.
        item.name = "D3 drops"
        try store.save(item)
        #expect(try store.supplements().first?.key == "vitamin-d3" && store.supplements().first?.name == "D3 drops")
        // The key cannot be swapped under an id, and an id cannot move lanes.
        let swapped = try SupplementItem(id: item.id, key: "other", name: "D3 drops", dose: item.dose, form: .capsule, schedule: .morning,
            startDay: "2026-01-01", createdAt: at)
        #expect(throws: StackError.invalidItem) { try store.save(swapped) }
        let medicine = try MedicationItem(id: item.id, name: "Same id", dose: item.dose, schedule: .morning, startDay: "2026-01-01", createdAt: at)
        #expect(throws: StackError.wrongLane) { try store.save(medicine) }
    }

    @Test func invalidItemsAreRefused() throws {
        let dose = DoseAmount(amount: 1, unit: .mg)
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "  ", dose: dose, form: .capsule, schedule: .morning, startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "A", dose: DoseAmount(amount: 0, unit: .mg), form: .capsule, schedule: .morning, startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "A", dose: DoseAmount(amount: .nan, unit: .mg), form: .capsule, schedule: .morning, startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "A", dose: dose, form: .capsule, schedule: .morning, startDay: "2026-02-30", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "A", dose: dose, form: .capsule, colors: .init(first: "red", second: "#FFFFFF"), schedule: .morning, startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try SupplementItem(name: "A", dose: dose, form: .capsule, schedule: .morning, startDay: "2026-01-01", sortOrder: -1, createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try MedicationItem(name: "A", dose: dose, prescriber: "  ", schedule: .morning, startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(throws: StackError.invalidItem) { try MedicationItem(name: "A", dose: dose, schedule: .morning, notes: String(repeating: "x", count: 2_001), startDay: "2026-01-01", createdAt: Stack.stamp) }
        #expect(DoseAmount(amount: 2_000, unit: .iu).text == "2000 IU" && DoseAmount(amount: 2.5, unit: .g).text == "2.5 g")
    }

    @Test func aMissingRecordIsNotRecordedAndOnlyAnExplicitSkipIsSkipped() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let item = try Stack.supplement("Creatine", schedule: .both)
        try store.save(item)
        var day = try store.supplementDay(Stack.day)
        #expect(day.doses.map(\.state) == [.notRecorded, .notRecorded])
        #expect(day.takenDoses == 0 && day.skippedDoses == 0 && day.notRecordedDoses == 2 && !day.isFullyRecorded)

        try store.record(.taken, itemID: item.id, day: Stack.day, slot: .morning, at: at, note: "  with breakfast ")
        day = try store.supplementDay(Stack.day)
        #expect(day.doses(in: .morning)[0].state == .taken(at: at, note: "with breakfast"))
        #expect(day.doses(in: .evening)[0].state == .notRecorded && day.skippedDoses == 0)

        try store.record(.skipped, itemID: item.id, day: Stack.day, slot: .evening, at: at.addingTimeInterval(60))
        day = try store.supplementDay(Stack.day)
        #expect(day.doses(in: .evening)[0].state == .skipped(at: at.addingTimeInterval(60), note: nil))
        #expect(day.takenDoses == 1 && day.skippedDoses == 1 && day.isFullyRecorded)

        // Clearing returns a dose to "not recorded", not to "skipped".
        #expect(try store.clearTick(itemID: item.id, day: Stack.day, slot: .evening))
        #expect(try store.supplementDay(Stack.day).doses(in: .evening)[0].state == .notRecorded)
        #expect(try store.clearTick(itemID: item.id, day: Stack.day, slot: .evening) == false)
        // Another day has no record at all.
        #expect(try store.supplementDay("2026-10-20").doses.allSatisfy { $0.state == .notRecorded })
    }

    @Test func tickingTheSameStateAgainChangesNothingAndTheOtherStateReplacesIt() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let context = fixture.context, store = fixture.store
        let item = try Stack.supplement("D3")
        try store.save(item)
        let first = try store.record(.taken, itemID: item.id, day: Stack.day, slot: .morning, at: at, note: "first")
        let again = try store.record(.taken, itemID: item.id, day: Stack.day, slot: .morning, at: at.addingTimeInterval(500), note: "second")
        #expect(again == first && again.recordedAt == at && again.note == "first")
        #expect(try context.database.tableRowCounts()["supplement_tick"] == 1)
        #expect(try store.tick(itemID: item.id, day: Stack.day, slot: .morning) == first)

        let skipped = try store.record(.skipped, itemID: item.id, day: Stack.day, slot: .morning, at: at.addingTimeInterval(900))
        #expect(skipped.state == .skipped && skipped.recordedAt == at.addingTimeInterval(900) && skipped.note == nil)
        #expect(try context.database.tableRowCounts()["supplement_tick"] == 1)
        #expect(try store.ticks(lane: .supplement, localDay: Stack.day) == [skipped])
        #expect(try store.ticks(lane: .medication, localDay: Stack.day).isEmpty)
    }

    @Test func tickingRefusesPausedItemsUnscheduledSlotsBadDaysAndStrangers() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let morning = try Stack.supplement("D3", schedule: .morning)
        try store.save(morning)
        #expect(throws: StackError.slotNotScheduled) { try store.record(.taken, itemID: morning.id, day: Stack.day, slot: .evening, at: at) }
        #expect(throws: StackError.invalidDay) { try store.record(.taken, itemID: morning.id, day: "2026-13-01", slot: .morning, at: at) }
        #expect(throws: StackError.invalidTick) { try store.record(.taken, itemID: morning.id, day: Stack.day, slot: .morning, at: at, note: String(repeating: "x", count: 501)) }
        #expect(throws: StackError.missingItem) { try store.record(.taken, itemID: UUID(), day: Stack.day, slot: .morning, at: at) }
        try store.record(.taken, itemID: morning.id, day: Stack.day, slot: .morning, at: at)
        try store.setActive(false, itemID: morning.id)
        #expect(throws: StackError.itemPaused) { try store.record(.skipped, itemID: morning.id, day: Stack.day, slot: .morning, at: at) }
        #expect(throws: StackError.missingItem) { try store.setActive(false, itemID: UUID()) }
    }

    @Test func pausedItemsAreNotDueKeepTheirHistoryAndComeBackWhenResumed() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let kept = try Stack.supplement("Creatine", sort: 0)
        let paused = try Stack.supplement("Fibre", sort: 1)
        let later = try Stack.supplement("Glycine", schedule: .evening, startDay: "2026-11-01", sort: 2)
        for item in [kept, paused, later] { try store.save(item) }
        try store.record(.taken, itemID: paused.id, day: Stack.day, slot: .morning, at: at)
        try store.setActive(false, itemID: paused.id)
        var day = try store.supplementDay(Stack.day)
        // Fibre is paused and Glycine starts in November, so only Creatine is due.
        #expect(day.doses.map(\.itemKey) == ["creatine"] && day.dueDoses == 1 && day.itemsDue == 1)
        #expect(try store.supplements().first { $0.id == paused.id }?.isActive == false)
        try store.setActive(true, itemID: paused.id)
        day = try store.supplementDay(Stack.day)
        #expect(day.doses.map(\.itemKey) == ["creatine", "fibre"])
        #expect(day.doses[1].state.isTaken)
        #expect(try store.supplementDay("2026-11-01").doses.map(\.itemKey) == ["creatine", "fibre", "glycine"])
        #expect(try store.supplementDay("2026-10-31").doses.map(\.itemKey) == ["creatine", "fibre"])
    }

    @Test func theMockupsStackReadsSixOfSevenTaken() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let items = try Stack.contractStack()
        for item in items { try store.save(item) }
        for item in items.prefix(6) { try store.record(.taken, itemID: item.id, day: Stack.day, slot: item.schedule.slots[0], at: at) }
        let day = try store.supplementDay(Stack.day)
        #expect(day.itemsDue == 7 && day.itemsAllTaken == 6 && day.dueDoses == 7 && day.takenDoses == 6)
        #expect(day.doses(in: .morning).map(\.name) == ["D3", "Omega-3", "Creatine", "B12", "Fibre"])
        #expect(day.doses(in: .evening).map(\.name) == ["Glycine", "Mg"])
        #expect(day.doses(in: .evening)[1].state == .notRecorded)
        #expect(try store.supplements().compactMap(\.colors).count == 7)
    }

    @Test func aItemWithBothSlotsCountsAsTakenOnlyWhenBothDosesAre() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let item = try Stack.supplement("D3", schedule: .both)
        try store.save(item)
        try store.record(.taken, itemID: item.id, day: Stack.day, slot: .morning, at: at)
        #expect(try store.supplementDay(Stack.day).itemsAllTaken == 0)
        try store.record(.taken, itemID: item.id, day: Stack.day, slot: .evening, at: at)
        let day = try store.supplementDay(Stack.day)
        #expect(day.itemsAllTaken == 1 && day.itemsDue == 1 && day.dueDoses == 2)
    }

    @Test func medicationHasItsOwnTicksAndNeverShowsInTheSupplementDay() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let store = fixture.store
        let supplement = try Stack.supplement("D3")
        let medicine = try Stack.medicine("Ramipril", schedule: .both)
        try store.save(supplement); try store.save(medicine)
        try store.record(.taken, itemID: medicine.id, day: Stack.day, slot: .evening, at: at)
        #expect(try store.supplementDay(Stack.day).takenDoses == 0 && store.supplementDay(Stack.day).dueDoses == 1)
        #expect(try store.medicationDay(Stack.day).takenDoses == 1 && store.medicationDay(Stack.day).dueDoses == 2)
        #expect(try store.ticks(lane: .supplement, localDay: Stack.day).isEmpty)
        #expect(try store.ticks(lane: .medication, localDay: Stack.day).count == 1)
        let days = try store.supplementDays(from: "2026-10-19", through: "2026-10-21")
        #expect(days.map(\.localDay) == ["2026-10-19", "2026-10-20", "2026-10-21"] && days.allSatisfy { $0.lane == .supplement })
        #expect(try store.medicationDays(from: "2026-10-19", through: "2026-10-21").allSatisfy { $0.lane == .medication && $0.dueDoses == 2 })
        #expect(throws: StackError.invalidDay) { try store.supplementDays(from: "2026-10-21", through: "2026-10-19") }
        #expect(throws: StackError.invalidDay) { try store.supplementDays(from: "2024-01-01", through: "2026-10-19") }
    }

    @Test func deletingAnItemDeletesItsTicksAndDeletingADayKeepsTheItems() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let context = fixture.context, store = fixture.store
        let first = try Stack.supplement("D3"), second = try Stack.supplement("Mg", schedule: .evening, sort: 1)
        try store.save(first); try store.save(second)
        try store.record(.taken, itemID: first.id, day: Stack.day, slot: .morning, at: at)
        try store.record(.taken, itemID: first.id, day: "2026-10-20", slot: .morning, at: at)
        try store.record(.skipped, itemID: second.id, day: Stack.day, slot: .evening, at: at)
        try context.database.delete(localDay: Stack.day)
        let counts = try context.database.tableRowCounts()
        #expect(counts["supplement_item"] == 2 && counts["supplement_tick"] == 1)
        #expect(try store.tick(itemID: first.id, day: "2026-10-20", slot: .morning) != nil)
        #expect(try store.deleteItem(id: first.id))
        #expect(try context.database.tableRowCounts()["supplement_tick"] == 0)
        #expect(try store.deleteItem(id: first.id) == false)
        #expect(try store.supplements() == [second])
    }

    @Test func deletingAllAccountDataEmptiesTheStackTables() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let context = fixture.context, store = fixture.store
        let item = try Stack.supplement("D3"), pill = try Stack.medicine("Ramipril")
        try store.save(item); try store.save(pill)
        try store.record(.taken, itemID: item.id, day: Stack.day, slot: .morning, at: at)
        try store.record(.taken, itemID: pill.id, day: Stack.day, slot: .morning, at: at)
        let seeded = try context.database.tableRowCounts()
        #expect(seeded["supplement_item"] == 2 && seeded["supplement_tick"] == 2)
        try context.database.deleteAllAccountData()
        let after = try context.database.tableRowCounts()
        for table in SupplementStorageSchema.tableNames { #expect(after[table] == 0, "\(table)") }
        #expect(try store.supplements().isEmpty && store.medication().isEmpty)
    }

    @Test func aCorruptPayloadIsReportedNotSwallowed() throws {
        let fixture = try Fixture(); defer { withExtendedLifetime(fixture) {} }
        let context = fixture.context, store = fixture.store
        try store.save(Stack.supplement("D3"))
        try context.database.write { db in try db.execute(sql: "UPDATE supplement_item SET payload = X'7B7D'") }
        #expect(throws: StackError.corruptRecord) { try store.supplements() }
    }
}
