import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// ICP R1-UPG-1: a Journal habit that became a rule is answered once, as the rule. The answer is written back to the
/// habit's history with the habit's own meaning, so Patterns and Insights keep one history. Answers from before the move
/// stay as they were.
final class ProtocolHabitMirrorTests: XCTestCase {
    private let zone = "UTC"
    private let day = DayIdentity(year: 2026, month: 10, day: 20)
    private let earlier = DayIdentity(year: 2026, month: 3, day: 12)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Clock: DateProviding {
        let date: Date
        func now() -> Date { date }
    }

    private func preset(_ catalogID: String, _ number: Int) throws -> HabitDefinition {
        let item = try XCTUnwrap(HabitCatalog.byID[catalogID])
        return HabitDefinition(id: HabitID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!),
                               source: .preset(catalogID: catalogID), name: item.name, question: item.question, sortOrder: number,
                               createdAt: now, questionPeriod: .evening)
    }

    private func check(_ key: RuleKey, _ state: CheckState, person: Bool = false) throws -> RuleCheck {
        try RuleCheck(ruleKey: key, day: day, version: 1, state: state, source: .manual, overriddenByPerson: person, recordedAt: now)
    }

    func testTheHabitMapsTheWayTheMoveReadsIt() throws {
        let alcohol = try preset("alcohol", 1)
        XCTAssertEqual(alcohol.routineHabit.catalogID, "alcohol")
        XCTAssertTrue(RoutineHabitMigration.isWrittenAsAvoid(alcohol.routineHabit))
        var renamed = alcohol
        renamed.name = "Wine"
        XCTAssertNil(renamed.routineHabit.catalogID, "An edited preset moved as the person's own habit")
    }

    func testAKeptAvoidRuleIsANoInTheJournalAndUndoClearsIt() async throws {
        let alcohol = try preset("alcohol", 1)
        let store = InMemoryHabitStore(definitions: [alcohol])
        let mirror = ProtocolHabitMirror(habits: store, dateProvider: Clock(date: now))
        let key = RoutineHabitMigration.ruleKey(forHabit: alcohol.id.rawValue)

        // A build 21 answer on another day.
        try await HabitCheckInService(store: store, dateProvider: Clock(date: now))
            .answer(habitID: alcohol.id, day: earlier, timeZoneID: zone, answer: .yes, source: .morningCheckIn)

        let set = try await mirror.ruleChanged(key, day: day, check: try check(key, .kept), timeZoneID: zone)
        XCTAssertEqual(set, .set(.no))
        var record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.response(for: alcohol.id)?.answer, .no, "Kept No alcohol means no drink")

        let missed = try await mirror.ruleChanged(key, day: day, check: try check(key, .missed, person: true), timeZoneID: zone)
        XCTAssertEqual(missed, .set(.yes))
        record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.response(for: alcohol.id)?.answer, .yes)

        let cleared = try await mirror.ruleChanged(key, day: day, check: try check(key, .pending), timeZoneID: zone)
        XCTAssertEqual(cleared, .clear)
        record = await store.dayRecord(for: day)
        XCTAssertNil(record?.response(for: alcohol.id))
        XCTAssertFalse(record?.hasUserOverride(for: alcohol.id) ?? false, "The Journal's auto-fill may answer the day again")

        let old = await store.dayRecord(for: earlier)
        XCTAssertEqual(old?.response(for: alcohol.id)?.answer, .yes, "The answer from before the move is untouched")
    }

    func testARuleToDoIsAYesWhenKept() async throws {
        let meditated = try preset("meditated", 2)
        let store = InMemoryHabitStore(definitions: [meditated])
        let key = RoutineHabitMigration.ruleKey(forHabit: meditated.id.rawValue)
        let change = try await ProtocolHabitMirror(habits: store, dateProvider: Clock(date: now))
            .ruleChanged(key, day: day, check: try check(key, .kept), timeZoneID: zone)
        XCTAssertEqual(change, .set(.yes))
        let record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.response(for: meditated.id)?.answer, .yes)
    }

    func testARuleThatWasNoHabitLeavesTheJournalAlone() async throws {
        let store = InMemoryHabitStore()
        let change = try await ProtocolHabitMirror(habits: store, dateProvider: Clock(date: now))
            .ruleChanged("screens-off", day: day, check: try check("screens-off", .kept), timeZoneID: zone)
        XCTAssertEqual(change, .keep)
        let record = await store.dayRecord(for: day)
        XCTAssertNil(record)
    }

    @MainActor
    func testTheJournalNeitherAsksNorEditsAHabitThatIsARule() async throws {
        let alcohol = try preset("alcohol", 1)
        let napped = try preset("napped", 2)
        let model = HabitViewModel(store: InMemoryHabitStore(definitions: [alcohol, napped]),
                                   ruleHabitIDs: { [alcohol.id] })
        await model.load()
        XCTAssertEqual(model.checkInDefinitions.map(\.id), [napped.id])
        XCTAssertEqual(model.ruleDefinitions.map(\.id), [alcohol.id])
        XCTAssertEqual(model.completion(for: day).total, 1)
        XCTAssertEqual(model.activeDefinitions.count, 2, "The habit and its history stay")
    }
}
