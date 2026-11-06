import DomainKit
import Foundation
import RoutineKit

// The link between a Journal habit question and the protocol rule it became (ICP R1-UPG-1). RoutineKit decides what a
// habit becomes and what an answer means; this file maps the Journal's types onto RoutineKit's and writes a rule answer
// back to the Journal's history, so the habit has one answer per day that means the same in both places.

public extension HabitDefinition {
    /// This habit as the move into protocol version 1 reads it. A preset counts as the catalog's only while its name and
    /// question are unchanged, so an edited preset moves as a custom habit.
    var routineHabit: JournalHabit {
        var catalogID: String?
        if case .preset(let id) = source, let item = HabitCatalog.byID[id], item.name == name, item.question == question {
            catalogID = id
        }
        var autoFilled = false
        if case .preset(let id) = source, let question = JournalAutoFillQuestion(rawValue: id) {
            autoFilled = question.accepts(self)
        }
        return JournalHabit(id: id.rawValue, catalogID: catalogID, isAutoFilled: autoFilled, title: checkInTitle,
                            period: checkInPeriod == .evening ? .evening : .today, isYesNo: responseKind == .binary,
                            isArchived: isArchived, sortOrder: sortOrder, createdAt: createdAt)
    }
}

public extension HabitDayRecord {
    /// This day's answers as the move into a protocol reads them.
    var routineResponses: [JournalHabitResponse] {
        responses.map { response in
            let answer: JournalHabitAnswer = switch response.answer {
            case .yes: .yes
            case .no: .no
            case .skipped: .skipped
            }
            return JournalHabitResponse(habitID: response.habitID.rawValue, day: response.behaviorDay, answer: answer,
                                        origin: response.lastUpdateSource == .autoFill ? .autoFill : .person,
                                        recordedAt: response.updatedAt)
        }
    }
}

/// Writes a person's rule answer back to the habit the rule came from. The app calls it after every tick, override and
/// undo on a rule whose key is a habit key; every other rule is left alone.
public struct ProtocolHabitMirror: Sendable {
    private let habits: any HabitStore
    private let dateProvider: any DateProviding

    public init(habits: any HabitStore, dateProvider: any DateProviding = SystemDateProvider()) {
        self.habits = habits
        self.dateProvider = dateProvider
    }

    /// - Parameters:
    ///   - check: the rule's check for `day` as stored after the write. Nil when the day has no check.
    ///   - timeZoneID: the zone a new Journal day record is written in. An existing record keeps its own.
    /// - Returns: the change it made, for tests.
    @discardableResult
    public func ruleChanged(_ key: RuleKey, day: DayIdentity, check: RuleCheck?,
                            timeZoneID: String) async throws -> RoutineHabitMigration.JournalChange {
        guard let id = RoutineHabitMigration.habitID(forRuleKey: key),
              let definition = try await habits.definition(id: HabitID(rawValue: id)),
              definition.responseKind == .binary else { return .keep }
        let habitID = definition.id
        let record = try await habits.dayRecord(for: day)
        let current = record?.response(for: habitID).map { response in
            (answer: Self.answer(response.answer),
             origin: response.lastUpdateSource == .autoFill ? JournalAnswerOrigin.autoFill : .person)
        }
        let change = RoutineHabitMigration.journalChange(after: check,
                                                         avoid: RoutineHabitMigration.isWrittenAsAvoid(definition.routineHabit),
                                                         current: current)
        let now = dateProvider.now()
        switch change {
        case .keep:
            break
        case .set(let answer):
            try await HabitCheckInService(store: habits, dateProvider: dateProvider).answer(
                habitID: habitID, day: day, timeZoneID: record?.behaviorTimeZoneID ?? timeZoneID,
                answer: answer == .yes ? .yes : .no, source: .sameDay)
        case .clear:
            // The day goes back to how it was before the person answered: no answer, and no mark that stops the
            // Journal's own auto-fill from answering it again.
            try await habits.updateDayRecord(for: day) { existing in
                guard var record = existing else { return nil }
                record.responses.removeAll { $0.habitID == habitID }
                if var overrides = record.userOverrideHabitIDs {
                    overrides.remove(habitID)
                    record.userOverrideHabitIDs = overrides
                }
                record.completedAt = nil
                record.updatedAt = now
                return record
            }
        }
        return change
    }

    private static func answer(_ answer: HabitAnswer) -> JournalHabitAnswer {
        switch answer {
        case .yes: .yes
        case .no: .no
        case .skipped: .skipped
        }
    }
}
