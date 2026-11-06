import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit

/// Moves the Journal's habit questions and answers into protocol version 1, once. This file only maps the Journal's
/// types onto RoutineKit's plain ones. What becomes a rule, and what each answer means, is decided and tested in
/// `RoutineHabitMigration`. Nothing is removed from the Journal.
nonisolated enum RoutineJournalMigration {
    /// The mapping lives in JournalKit (`HabitDefinition.routineHabit`), where the Protocol tab reads it too.
    static func habit(_ definition: HabitDefinition) -> JournalHabit { definition.routineHabit }

    /// The mapping lives in JournalKit (`HabitDayRecord.routineResponses`), where "Use my questions" reads it too.
    static func responses(_ records: [HabitDayRecord]) -> [JournalHabitResponse] {
        records.flatMap(\.routineResponses)
    }

    /// Runs at startup. Returns nil when the Journal could not be read or the write failed, and the next launch tries
    /// again. The common cases, a finished migration or no habit to move, cost one small read.
    @discardableResult
    static func runOnce(database: StorageDatabase, habits: any HabitStore, now: Date) async -> JournalHabitMigrationOutcome? {
        do {
            guard try RoutineHabitMigration.isPending(database: database) else { return .alreadyDone }
            let definitions = try await habits.definitions(includeArchived: true)
            guard definitions.contains(where: { !$0.isArchived }) else { return .nothingToMigrate }
            let records = try await habits.dayRecords()
            return try RoutineHabitMigration.run(database: database, habits: definitions.map(habit),
                                                 responses: responses(records), now: now)
        } catch {
            return nil
        }
    }
}

/// Keeps a migrated habit's Journal history in step with its rule (ICP R1-UPG-1). The Protocol tab and Today's rail call
/// it after every write a person makes on a rule. A rule that did not come from a habit is left alone, and a failure
/// here never undoes the rule answer: the rule is the place the person answers, the Journal copy follows it.
nonisolated enum RoutineHabitAnswerMirror {
    static func ruleChanged(_ key: RuleKey, day: DayIdentity, store: RoutineStore, habits: (any HabitStore)?,
                            timeZoneID: String) async {
        guard let habits, RoutineHabitMigration.habitID(forRuleKey: key) != nil else { return }
        do {
            guard let active = try store.activeProtocol() else { return }
            let check = try store.check(protocolID: active.routineProtocol.id, ruleKey: key, day: day)
            try await ProtocolHabitMirror(habits: habits).ruleChanged(key, day: day, check: check, timeZoneID: timeZoneID)
        } catch {
            // The rule answer is saved. The Journal copy catches up on the next answer for that day.
        }
    }

    /// The habits that have a rule, for the Journal screens that must not ask or edit them again.
    static func habitIDsWithRules(database: StorageDatabase) -> Set<HabitID> {
        let ids = (try? RoutineHabitMigration.habitIDsWithRules(store: RoutineStore(database: database))) ?? []
        return Set(ids.map(HabitID.init(rawValue:)))
    }
}
