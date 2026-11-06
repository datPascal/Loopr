import DomainKit
import FoodKit
import Foundation
import RoutineKit
import Testing

struct SupplementRoutineFeedTests {
    private let at = Stack.stamp
    private func day(_ supplements: [SupplementItem], ticks: [(SupplementItem, StackSlot, StackTickState)], on localDay: String = Stack.day) -> StackDay {
        StackDay(localDay: localDay, supplements: supplements,
                 ticks: ticks.map { StackTick(itemID: $0.0.id, localDay: localDay, slot: $0.1, state: $0.2, recordedAt: at) })
    }
    private func value(_ metric: String, _ readings: [SupplementReading]) -> Double? { readings.first { $0.metric == metric }?.value }

    @Test func readingsAreOneWhenTakenZeroWhenSkippedAndAbsentWhenNotRecorded() throws {
        let d3 = try Stack.supplement("D3", sort: 0), mg = try Stack.supplement("Mg", schedule: .evening, sort: 1)
        let creatine = try Stack.supplement("Creatine", sort: 2), both = try Stack.supplement("Fibre", schedule: .both, sort: 3)
        let readings = SupplementRoutineFeed.readings(for: day([d3, mg, creatine, both], ticks: [
            (d3, .morning, .taken), (mg, .evening, .skipped), (both, .morning, .taken),
        ]))
        #expect(value("supplement_taken:d3", readings) == 1)
        #expect(value("supplement_taken:mg", readings) == 0)
        // Not recorded gives no reading at all, so the check stays unknown. Half a two-dose item gives none either.
        #expect(value("supplement_taken:creatine", readings) == nil && value("supplement_taken:fibre", readings) == nil)
        // One skipped dose decides the lane even though others are open.
        #expect(value("supplements_all_taken", readings) == 0)
        #expect(readings.allSatisfy { $0.source == .food && $0.localDay == Stack.day })
        // Adherence waits until every due dose is recorded.
        #expect(value("supplement_adherence", readings) == nil)
    }

    @Test func allTakenIsOneOnlyWhenEveryDueDoseIsTakenAndPausedItemsDoNotCount() throws {
        let d3 = try Stack.supplement("D3", sort: 0), mg = try Stack.supplement("Mg", schedule: .evening, sort: 1)
        let paused = try Stack.supplement("Fibre", active: false, sort: 2)
        let open = SupplementRoutineFeed.readings(for: day([d3, mg, paused], ticks: [(d3, .morning, .taken)]))
        #expect(value("supplements_all_taken", open) == nil && value("supplement_taken:d3", open) == 1)
        #expect(value("supplement_taken:fibre", open) == nil)
        let done = SupplementRoutineFeed.readings(for: day([d3, mg, paused], ticks: [(d3, .morning, .taken), (mg, .evening, .taken)]))
        #expect(value("supplements_all_taken", done) == 1 && value("supplement_adherence", done) == 1)
        #expect(SupplementRoutineFeed.readings(for: day([], ticks: [])).isEmpty)
        #expect(SupplementRoutineFeed.readings(for: day([paused], ticks: [])).isEmpty)
    }

    @Test func adherenceIsTakenOverDueOnlyOnceEveryDoseHasARecord() throws {
        let items = try [Stack.supplement("A", sort: 0), Stack.supplement("B", sort: 1), Stack.supplement("C", schedule: .both, sort: 2)]
        let partial = day(items, ticks: [(items[0], .morning, .taken), (items[1], .morning, .skipped), (items[2], .morning, .taken)])
        #expect(SupplementAdherence.fraction(partial) == nil)
        let full = day(items, ticks: [(items[0], .morning, .taken), (items[1], .morning, .skipped), (items[2], .morning, .taken), (items[2], .evening, .taken)])
        #expect(SupplementAdherence.fraction(full) == 0.75)
        #expect(SupplementAdherence.value(forMetric: "supplement_adherence", day: full) == 0.75)
        #expect(SupplementAdherence.value(forMetric: "supplement_taken:a", day: full) == 1)
        #expect(SupplementAdherence.value(forMetric: "supplement_taken:b", day: full) == 0)
        #expect(SupplementAdherence.value(forMetric: "supplement_taken:unknown-key", day: full) == nil)
        #expect(SupplementAdherence.value(forMetric: "supplement_adherence", day: day([], ticks: [])) == nil)
    }

    @Test func medicationHasItsOwnMetricsAndNeverAnswersASupplementMetric() throws {
        let pill = try Stack.medicine("Ramipril", schedule: .both)
        let medicationDay = StackDay(localDay: Stack.day, medication: [pill], ticks: [
            StackTick(itemID: pill.id, localDay: Stack.day, slot: .morning, state: .taken, recordedAt: at),
            StackTick(itemID: pill.id, localDay: Stack.day, slot: .evening, state: .taken, recordedAt: at),
        ])
        let readings = SupplementRoutineFeed.readings(for: medicationDay)
        #expect(readings.map(\.metric).sorted() == ["medication_all_taken", "medication_taken:ramipril"])
        #expect(readings.allSatisfy { $0.value == 1 })
        #expect(SupplementAdherence.value(forMetric: "supplement_taken:ramipril", day: medicationDay) == nil)
        #expect(SupplementAdherence.value(forMetric: "supplement_adherence", day: medicationDay) == nil)
        #expect(SupplementAdherence.value(forMetric: "medication_taken:ramipril", day: medicationDay) == 1)
        #expect(SupplementMetric.taken(itemKey: "x", lane: .medication) == "medication_taken:x")
        #expect(SupplementMetric.allTaken(lane: .supplement) == "supplements_all_taken")
    }

    @Test func rulesBuiltFromTheVocabularyAreValidProtocolRulesWithFoodAsSource() throws {
        let rule = SupplementMetric.rule(key: "d3", title: "Vitamin D3", itemKey: "d3", timeOfDayMinutes: 480)
        let all = SupplementMetric.rule(key: "stack", title: "Whole stack", itemKey: nil)
        #expect(rule.group == .supplements && rule.source == .food && rule.target.metric == "supplement_taken:d3")
        #expect(rule.target.kind == .atLeast && rule.target.value == 1 && all.target.metric == "supplements_all_taken")
        // RoutineKit accepts them in a version.
        let version = try ProtocolVersion(protocolID: ProtocolID(), number: 1, createdAt: at, rules: [rule, all])
        #expect(version.rules.count == 2)
        #expect(SupplementMetric.isSupplementMetric("supplement_taken:d3") && SupplementMetric.isSupplementMetric("medication_all_taken"))
        #expect(!SupplementMetric.isSupplementMetric("protein") && !SupplementMetric.isSupplementMetric("zone2Minutes"))
    }

    @Test func checksAreKeptMissedOrUnknownAndUnknownNeverBecomesMissed() throws {
        let d3 = try Stack.supplement("D3", sort: 0), mg = try Stack.supplement("Mg", schedule: .evening, sort: 1)
        let creatine = try Stack.supplement("Creatine", sort: 2)
        let stackDay = day([d3, mg, creatine], ticks: [(d3, .morning, .taken), (mg, .evening, .skipped)])
        let readings = SupplementRoutineFeed.readings(for: stackDay)
        func check(_ itemKey: String?) throws -> RuleCheck? {
            try SupplementRoutineFeed.check(rule: SupplementMetric.rule(key: RuleKey(rawValue: itemKey ?? "all"), title: "T", itemKey: itemKey),
                                            version: 3, localDay: Stack.day, readings: readings, recordedAt: at)
        }
        let keptCheck = try check("d3")
        let kept = try #require(keptCheck)
        #expect(kept.state == .kept && kept.measuredValue == 1 && kept.source == .food && kept.version == 3 && !kept.overriddenByPerson)
        #expect(kept.day == DayIdentity(year: 2026, month: 10, day: 21))
        let missedCheck = try check("mg")
        let missed = try #require(missedCheck)
        #expect(missed.state == .missed && missed.measuredValue == 0)
        let unknownCheck = try check("creatine")
        let unknown = try #require(unknownCheck)
        #expect(unknown.state == .unknown && unknown.measuredValue == nil)
        // The lane rule: one skipped dose decides it.
        #expect(try check(nil)?.state == .missed)
        // Readings of another day never decide this one.
        let otherDay = try SupplementRoutineFeed.check(rule: SupplementMetric.rule(key: "d3", title: "T", itemKey: "d3"), version: 1,
                                                       localDay: "2026-10-22", readings: readings, recordedAt: at)
        #expect(otherDay?.state == .unknown)
        // Rules this vocabulary does not own are left alone.
        let manual = ProtocolRule(key: "walk", title: "Walk", target: RuleTarget(kind: .atLeast, metric: "supplement_taken:d3", value: 1), source: .manual)
        let other = ProtocolRule(key: "protein", title: "Protein", target: RuleTarget(kind: .atLeast, metric: "protein", value: 120), source: .food)
        #expect(try SupplementRoutineFeed.check(rule: manual, version: 1, localDay: Stack.day, readings: readings, recordedAt: at) == nil)
        #expect(try SupplementRoutineFeed.check(rule: other, version: 1, localDay: Stack.day, readings: readings, recordedAt: at) == nil)
        #expect(throws: RoutineError.invalidCheck) {
            try SupplementRoutineFeed.check(rule: SupplementMetric.rule(key: "d3", title: "T", itemKey: "d3"), version: 1, localDay: "bad", readings: readings, recordedAt: at)
        }
    }

    @Test func ticksReadFromTheStoreFeedTheSameReadings() throws {
        let context = try LongevityStore(); defer { withExtendedLifetime(context) {} }
        let store = SupplementStore(database: context.database)
        let items = try Stack.contractStack()
        for item in items { try store.save(item) }
        for item in items.prefix(6) { try store.record(.taken, itemID: item.id, day: Stack.day, slot: item.schedule.slots[0], at: at) }
        try store.record(.skipped, itemID: items[6].id, day: Stack.day, slot: .evening, at: at)
        let stackDay = try store.supplementDay(Stack.day)
        let readings = SupplementRoutineFeed.readings(for: stackDay)
        #expect(readings.count == 9)
        #expect(SupplementAdherence.fraction(stackDay) == 6.0 / 7.0)
        #expect(value("supplement_taken:mg", readings) == 0 && value("supplement_taken:d3", readings) == 1)
    }
}
