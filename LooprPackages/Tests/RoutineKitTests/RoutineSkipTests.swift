import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

/// ICP R1-HAB-01: "Skip today" is a fifth check state. It is stored through the person's override, survives automatic
/// rechecks, is left out of the day's kept share, and Undo takes it back. Payloads written before it existed decode as
/// they were.
struct RoutineSkipTests {
    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineSkipTests-\(UUID().uuidString)")
        let database: StorageDatabase
        let store: RoutineStore
        init() throws {
            database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "routine-skip-tests")
            store = RoutineStore(database: database)
        }
        deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
    }

    private let zone = TimeZone(identifier: "UTC")!
    private let day = DayIdentity(year: 2023, month: 11, day: 14)
    private let created = Date(timeIntervalSince1970: 1_699_900_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rules() -> [ProtocolRule] {
        [
            ProtocolRule(key: "protein", title: "Protein", group: .food,
                         target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 130, unit: "g"), source: .food),
            ProtocolRule(key: "magnesium", title: "Magnesium", group: .supplements, timeOfDayMinutes: 1_290, isEvening: true)
        ]
    }

    @Test func aCheckWrittenBeforeSkipExistedDecodesUnchanged() throws {
        let old = """
            {"day":{"day":14,"era":1,"month":11,"year":2023},"measuredValue":82,"overriddenByPerson":false,"recordedAt":721692800,
             "ruleKey":"protein","source":"food","state":"kept","version":1}
            """
        let check = try JSONDecoder().decode(RuleCheck.self, from: Data(old.utf8))
        #expect(check.state == .kept && check.measuredValue == 82 && check.source == .food && !check.overriddenByPerson)
        for state in ["kept", "missed", "pending", "unknown"] {
            #expect(CheckState(rawValue: state) != nil, "\(state) still decodes")
        }
        let skipped = try RuleCheck(ruleKey: "magnesium", day: day, version: 1, state: .skipped, source: .manual,
                                    overriddenByPerson: true, recordedAt: now)
        let encoded = try JSONEncoder().encode(skipped)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"skipped\""))
        #expect(try JSONDecoder().decode(RuleCheck.self, from: encoded) == skipped)
    }

    @Test func aSkipIsStoredSurvivesRechecksAndIsLeftOutOfTheShare() throws {
        let context = try Context()
        let id = ProtocolID()
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Mine", createdAt: created), rules: rules())
        let evaluation = RoutineDayEvaluation(store: context.store)
        let sources = RoutineSourceSnapshots(food: RoutineSourceSnapshot(source: .food, readings: [.proteinG: .measured(140)]))
        let first = try #require(try evaluation.evaluate(day: day, now: now, timeZone: zone, sources: sources))
        let measured = first.checks.first { $0.ruleKey == "protein" }
        let skip = try evaluation.override(ruleKey: "protein", day: day, state: .skipped, at: now)
        #expect(skip.state == .skipped && skip.overriddenByPerson)
        #expect(skip.measuredValue == measured?.measuredValue, "What Food measured stays with the skip")

        let again = try #require(try evaluation.evaluate(day: day, now: now, timeZone: zone, sources: sources))
        #expect(again.checks.first { $0.ruleKey == "protein" }?.state == .skipped, "A recheck keeps the person's skip")
        #expect(again.summary.skipped == 1)
        #expect(again.summary.decided == 0)
        #expect(again.summary.keptShare == nil, "A skip is neither kept nor missed")
        #expect(again.summary.total == 2)

        let undone = try #require(try evaluation.untick(ruleKey: "protein", day: day, now: now, timeZone: zone, sources: sources))
        #expect(undone.checks.first { $0.ruleKey == "protein" }?.state == measured?.state, "Undo goes back to what Food says")
    }

    @Test func aSkippedNightIsNotAdherence() throws {
        let skip = try RuleCheck(ruleKey: "magnesium", day: day, version: 1, state: .skipped, source: .manual,
                                 overriddenByPerson: true, recordedAt: now)
        #expect(ExperimentAdherence.from(skip) == .unknown)
    }

    @Test func onlyKeptMissedAndSkippedCanBeChosen() throws {
        let context = try Context()
        let id = ProtocolID()
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Mine", createdAt: created), rules: rules())
        #expect(throws: RoutineError.invalidOverride) {
            try context.store.overrideCheck(protocolID: id, ruleKey: "magnesium", day: day, state: .unknown, at: now)
        }
        let skipped = try context.store.overrideCheck(protocolID: id, ruleKey: "magnesium", day: day, state: .skipped, at: now)
        #expect(try context.store.check(protocolID: id, ruleKey: "magnesium", day: day) == skipped)
    }
}
