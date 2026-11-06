import Foundation
import DomainKit
import JournalKit

/// Forces all legacy read/modify/save callers to read the same day snapshot.
actor OverlappingHabitStore: HabitStore {
    let base: any HabitStore
    private let reads: HabitReadBarrier
    init(base: any HabitStore, readers: Int) {
        self.base = base; reads = HabitReadBarrier(readers)
    }
    func definitions(includeArchived: Bool) async throws -> [HabitDefinition] { return try await base.definitions(includeArchived: includeArchived) }
    func definition(id: HabitID) async throws -> HabitDefinition? { return try await base.definition(id: id) }
    func saveDefinition(_ definition: HabitDefinition) async throws { return try await base.saveDefinition(definition) }
    func setArchived(_ archived: Bool, habitID: HabitID, at date: Date) async throws { return try await base.setArchived(archived, habitID: habitID, at: date) }
    func deleteHabit(id: HabitID) async throws { return try await base.deleteHabit(id: id) }
    func dayRecord(for day: DayIdentity) async throws -> HabitDayRecord? {
        let value = try await base.dayRecord(for: day)
        await reads.arrive()
        return value
    }
    func dayRecords() async throws -> [HabitDayRecord] { return try await base.dayRecords() }
    func saveDayRecord(_ record: HabitDayRecord) async throws { return try await base.saveDayRecord(record) }
    func updateDayRecord(for day: DayIdentity, _ update: @Sendable (HabitDayRecord?) throws -> HabitDayRecord?) async throws { try await base.updateDayRecord(for: day, update) }
    func outcome(for day: DayIdentity) async throws -> HabitOutcomeSnapshot? { return try await base.outcome(for: day) }
    func outcomes() async throws -> [HabitOutcomeSnapshot] { return try await base.outcomes() }
    func saveOutcome(_ outcome: HabitOutcomeSnapshot) async throws { return try await base.saveOutcome(outcome) }
    func removeOutcome(for day: DayIdentity) async throws { return try await base.removeOutcome(for: day) }
    func outcomeExclusion(for day: DayIdentity) async throws -> HabitOutcomeExclusionRecord? { return try await base.outcomeExclusion(for: day) }
    func outcomeExclusions() async throws -> [HabitOutcomeExclusionRecord] { return try await base.outcomeExclusions() }
    func saveOutcomeExclusion(_ exclusion: HabitOutcomeExclusionRecord) async throws { return try await base.saveOutcomeExclusion(exclusion) }
    func removeOutcomeExclusion(for day: DayIdentity) async throws { return try await base.removeOutcomeExclusion(for: day) }
    func estimate(for habitID: HabitID) async throws -> HabitImpactEstimate? { return try await base.estimate(for: habitID) }
    func estimates() async throws -> [HabitImpactEstimate] { return try await base.estimates() }
    func saveEstimate(_ estimate: HabitImpactEstimate) async throws { return try await base.saveEstimate(estimate) }
    func settings() async throws -> HabitSettings { return try await base.settings() }
    func saveSettings(_ settings: HabitSettings) async throws { return try await base.saveSettings(settings) }
    func todaySelection() async throws -> HabitTodaySelection? { return try await base.todaySelection() }
    func saveTodaySelection(_ selection: HabitTodaySelection?) async throws { return try await base.saveTodaySelection(selection) }
    func migrationReceipt() async throws -> HabitMigrationReceipt? { return try await base.migrationReceipt() }
    func completeMigration(definitions: [HabitDefinition], dayRecords: [HabitDayRecord], receipt: HabitMigrationReceipt) async throws { return try await base.completeMigration(definitions: definitions, dayRecords: dayRecords, receipt: receipt) }
    func replaceSourceRecords(definitions: [HabitDefinition], dayRecords: [HabitDayRecord]) async throws { return try await base.replaceSourceRecords(definitions: definitions, dayRecords: dayRecords) }
    func deleteDerivedData() async throws { return try await base.deleteDerivedData() }
    func deleteAllHabitData() async throws { return try await base.deleteAllHabitData() }
}

private actor HabitReadBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ remaining: Int) { self.remaining = remaining }
    func arrive() async {
        remaining -= 1
        if remaining == 0 {
            let ready = waiters; waiters = []
            for waiter in ready { waiter.resume() }
        } else if remaining > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
