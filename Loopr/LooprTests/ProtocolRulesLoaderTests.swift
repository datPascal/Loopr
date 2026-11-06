import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit
import Testing
@testable import Loopr

/// LV-07.4: the Protocol tab loader's Rules writes on a real `RoutineStore`: an edit is one new version, the history
/// lists every version, a template starts version 1 once, and the tab's header data carries author and lineage.
@MainActor struct ProtocolRulesLoaderTests {
    private let zone = TimeZone(identifier: "UTC")!
    /// Tue 14 Nov 2023, 22:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-rules-\(UUID().uuidString)")
        let store: RoutineStore
        init() throws {
            store = RoutineStore(database: try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"),
                                                               applicationVersion: "protocol-rules-tests"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func loader(_ context: Context) -> ProtocolTabLoader {
        ProtocolTabLoader(store: context.store, timeZone: { [zone] in zone }, snapshots: { _, _, _ in RoutineSourceSnapshots() })
    }

    @Test func aTemplateThenAnEditMakeTwoVersions() async throws {
        let context = try Context()
        let loader = loader(context)
        #expect(await loader.load(now: now).routine == .noProtocol)

        try await loader.installTemplate(.sleepFirst, now: now)
        await #expect(throws: ProtocolEditError.protocolExists) { try await loader.installTemplate(.sleepFirst, now: now) }
        let data = try #require(await loader.load(now: now).routineData)
        #expect(data.version == 1 && data.protocolName == "Sleep first")
        #expect(data.lineage?.forkedFromName == "sleep-first")

        let rules = data.rules.map { $0.key == "in-bed" ? $0.with(rebuttal: .some("Tomorrow starts tonight.")) : $0 }
        let saved = try await loader.saveRules(rules, now: now.addingTimeInterval(60))
        #expect(saved.number == 2)
        #expect(try await loader.versions().map(\.number) == [1, 2])
        #expect(try await loader.protocolFile().rules.allSatisfy { $0.rebuttal == nil }, "the shared file has no rebuttal")
        #expect(await loader.load(now: now).routineData?.rules.first { $0.key == "in-bed" }?.rebuttal == "Tomorrow starts tonight.")
    }

    /// ICP R1-VET-08, R1-HAB-02: the Rules list's progress comes from the week's checks and readings, and a rule on
    /// chosen days gets no check on its off day.
    @Test func theTabDataCarriesTheWeeksProgressAndSkipsOffDays() async throws {
        let context = try Context()
        let id = ProtocolID()
        let swim = ProtocolRule(key: "swim", title: "Swim", cadence: .timesAWeek(3))
        let zone2 = ProtocolRule(key: "zone2", title: "Zone 2, 150 min a week",
                                 target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150, unit: "min"),
                                 source: .band, cadence: RuleCadence(unit: .week))
        let gym = ProtocolRule(key: "gym", title: "Gym", cadence: .on([.monday]))
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Shifts", createdAt: now.addingTimeInterval(-3 * 86_400)),
                                         rules: [swim, zone2, gym])
        try context.store.recordCheck(RuleCheck(ruleKey: "swim", day: DayIdentity(year: 2023, month: 11, day: 13), version: 1,
                                                state: .kept, source: .manual, recordedAt: now), protocolID: id)
        let loader = ProtocolTabLoader(store: context.store, timeZone: { [zone] in zone }, snapshots: { day, _, _ in
            RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band, readings: [.zone2Minutes: .measured(day.day == 13 ? 40 : 72)]))
        })
        let data = try #require(await loader.load(now: now).routineData)
        #expect(data.progress["swim"] == .times(done: 1, target: 3))
        #expect(data.progress["zone2"] == .amount(measured: 112, target: 150, unit: "min"))
        #expect(data.progress["gym"] == nil)
        let tuesday = try context.store.checks(protocolID: id, day: DayIdentity(year: 2023, month: 11, day: 14))
        #expect(!tuesday.contains { $0.ruleKey == "gym" }, "Tuesday is an off day for the gym")
    }
}
