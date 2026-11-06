import DomainKit
import FoodKit
import Foundation
import JournalKit
import RoutineKit
import Testing
@testable import Loopr

private nonisolated struct StackReadFailure: Error {}

private let zoneID = "Australia/Perth"
private let zone = TimeZone(identifier: zoneID)!
private let day = DayIdentity(year: 2026, month: 10, day: 20)
private let localDay = "2026-10-20"
private let clock = RoutineDayClock(day: day, timeZone: zone)!
private func at(_ minutes: Double) -> Date { clock.start.addingTimeInterval(minutes * 60) }

private func supplement(_ name: String, schedule: StackSchedule = .morning, active: Bool = true, sort: Int) throws -> SupplementItem {
    try SupplementItem(name: name, dose: DoseAmount(amount: 1, unit: .capsules), form: .capsule, schedule: schedule, isActive: active,
                       startDay: "2026-01-01", sortOrder: sort, createdAt: at(Double(sort)))
}

private func tick(_ id: UUID, _ slot: StackSlot = .morning, _ state: StackTickState = .taken) -> StackTick {
    StackTick(itemID: id, localDay: localDay, slot: slot, state: state, recordedAt: at(480))
}

private func rule(_ metric: String, _ kind: RuleTargetKind = .atLeast, _ value: Double = 1) -> ProtocolRule {
    ProtocolRule(key: RuleKey(rawValue: metric.replacingOccurrences(of: ":", with: "-")), title: metric, group: .supplements,
                 target: RuleTarget(kind: kind, metric: metric, value: value), source: .food)
}

/// The Food tab's stack ticks reach Protocol checks: `RoutineSourceProvider` reads both lanes through `readStack`,
/// `SupplementRoutineFeed` turns them into readings and `RuleEvaluator` decides.
@MainActor struct RoutineSupplementSourceTests {
    /// D3 taken, omega-3 skipped, creatine not recorded, zinc paused, magnesium due in the evening; metformin taken.
    private func stack() throws -> (RoutineStackDay, [SupplementItem], MedicationItem) {
        let d3 = try supplement("D3", sort: 0), omega = try supplement("Omega-3", sort: 1), creatine = try supplement("Creatine", sort: 2)
        let zinc = try supplement("Zinc", active: false, sort: 3), magnesium = try supplement("Mg", schedule: .evening, sort: 4)
        let metformin = try MedicationItem(name: "Metformin", dose: DoseAmount(amount: 500, unit: .mg), schedule: .morning,
                                           startDay: "2026-01-01", createdAt: at(0))
        let items = [d3, omega, creatine, zinc, magnesium]
        let ticks = [tick(d3.id), tick(omega.id, .morning, .skipped), tick(zinc.id), tick(magnesium.id, .evening)]
        return (RoutineStackDay(supplements: StackDay(localDay: localDay, supplements: items, ticks: ticks),
                                medication: StackDay(localDay: localDay, medication: [metformin], ticks: [tick(metformin.id)])), items, metformin)
    }

    private func outcome(_ rule: ProtocolRule, _ snapshots: RoutineSourceSnapshots, at minutes: Double = 1_500) throws -> RuleOutcome {
        RuleEvaluator.evaluate(rule, context: try RoutineEvaluationContext(day: day, now: at(minutes), timeZone: zone), sources: snapshots)
    }

    @Test func theMappingGivesEachDecidedItemAndLaneAReadingAndNothingForTheRest() throws {
        let (day, _, _) = try stack()
        let snapshot = RoutineSourceMapping.food(meals: nil, stack: day)
        #expect(snapshot.access == .available)
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:d3")!] == .measured(1))
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:omega-3")!] == .measured(0))
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:mg")!] == .measured(1))
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:creatine")!] == nil, "not recorded")
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:zinc")!] == nil, "paused, so not due")
        #expect(snapshot.itemReadings[RoutineItemMetric(rawValue: "medication_taken:metformin")!] == .measured(1))
        // A skipped dose decides the lane; creatine's missing tick keeps adherence open.
        #expect(snapshot.readings[.supplementsAllTaken] == .measured(0))
        #expect(snapshot.readings[.supplementAdherence] == nil)
        #expect(snapshot.readings[.medicationAllTaken] == .measured(1))
        // The meals could not be read, so their metrics are blocked and the stack's are not.
        #expect(snapshot.blocked[.proteinG] == .unavailable && snapshot.blocked[.lastMealTime] == .unavailable)
        #expect(snapshot.blocked[.supplementsAllTaken] == nil)
    }

    @Test func rulesOnEachSupplementMetricEvaluateKeptMissedOrUnknown() async throws {
        let (stackDay, _, _) = try stack()
        let provider = RoutineSourceProvider(readFood: nil, readStack: { key in
            #expect(key == localDay)
            return stackDay
        })
        let snapshots = try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(1_500))
        #expect(try outcome(rule("supplement_taken:d3"), snapshots).state == .kept)
        #expect(try outcome(rule("supplement_taken:omega-3"), snapshots).state == .missed)
        let creatine = try outcome(rule("supplement_taken:creatine"), snapshots)
        #expect(creatine.state == .unknown && creatine.reason == .noData, "a dose with no tick is never a miss")
        #expect(try outcome(rule("supplement_taken:zinc"), snapshots).state == .unknown)
        #expect(try outcome(rule("supplements_all_taken"), snapshots).state == .missed)
        #expect(try outcome(rule("medication_taken:metformin"), snapshots).state == .kept)
        #expect(try outcome(rule("medication_all_taken"), snapshots).state == .kept)
        #expect(try outcome(rule("supplement_adherence", .atLeast, 0.5), snapshots).state == .unknown)
        // During the day a dose still to be ticked is pending.
        let morning = try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(600))
        #expect(try outcome(rule("supplement_taken:creatine"), morning, at: 600).state == .pending)
    }

    @Test func aFullyRecordedDayGivesTheAdherenceExperimentsRead() async throws {
        let a = try supplement("A", sort: 0), b = try supplement("B", sort: 1), c = try supplement("C", schedule: .both, sort: 2)
        let ticks = [tick(a.id), tick(b.id, .morning, .skipped), tick(c.id), tick(c.id, .evening)]
        let stackDay = RoutineStackDay(supplements: StackDay(localDay: localDay, supplements: [a, b, c], ticks: ticks),
                                       medication: StackDay(localDay: localDay, medication: [], ticks: []))
        let snapshots = try await RoutineSourceProvider(readStack: { _ in stackDay }).snapshots(for: day, timeZoneID: zoneID, now: at(1_300))
        #expect(snapshots.food.readings[.supplementAdherence] == .measured(0.75))
        #expect(try outcome(rule("supplement_adherence", .atLeast, 0.75), snapshots, at: 1_300).state == .kept)
        #expect(try outcome(rule("supplement_adherence", .atLeast, 0.8), snapshots, at: 1_300).state == .missed)
        // The medication lane is empty, so its rule has nothing to read.
        #expect(try outcome(rule("medication_all_taken"), snapshots).state == .unknown)
    }

    @Test func aStackThatFailsBlocksOnlyItsOwnRulesAndMealsStillCount() async throws {
        let meals = RoutineFoodDay(intake: JournalFoodDay(records: [], completion: nil), energy: FoodNutrientTotal(values: []),
                                   protein: FoodNutrientTotal(values: [140]), fibre: FoodNutrientTotal(values: []))
        let provider = RoutineSourceProvider(readFood: { _, _ in meals }, readStack: { _ in throw StackReadFailure() })
        let snapshots = try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(1_500))
        #expect(snapshots.food.readings[.proteinG] == .measured(140))
        let protein = ProtocolRule(key: "protein", title: "Protein", group: .food, target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 130), source: .food)
        #expect(try outcome(protein, snapshots).state == .kept)
        for metric in ["supplement_taken:d3", "supplements_all_taken", "medication_taken:metformin", "medication_all_taken", "supplement_adherence"] {
            let result = try outcome(rule(metric), snapshots)
            #expect(result.state == .unknown && result.reason == .sourceUnavailable, "\(metric)")
        }
        // With neither part readable, Food is closed.
        let none = try await RoutineSourceProvider(readFood: { _, _ in throw StackReadFailure() }, readStack: { _ in throw StackReadFailure() })
            .snapshots(for: day, timeZoneID: zoneID, now: at(600))
        #expect(none.food.access == .unavailable && none.food.readings.isEmpty && none.food.itemReadings.isEmpty)
    }

    @Test func theCancellationOfAStackReadEndsTheWholeRead() async {
        let provider = RoutineSourceProvider(readStack: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(600)) }
    }

    @Test func theFoodFixtureStackFeedsTheLiveProvider() async throws {
        let repository = ProductRepositoryContainer(environment: AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:]))
            .fixtureFoodRepository
        let provider = RoutineSourceProvider.live(food: repository, sleep: nil, readTraining: nil, analytics: nil, appleHealth: nil)
        let fixtureDay = DayIdentity(year: 2023, month: 11, day: 14)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let now = calendar.date(from: .init(year: 2023, month: 11, day: 14, hour: 13, minute: 30))!
        let snapshots = try await provider.snapshots(for: fixtureDay, timeZoneID: zoneID, now: now)
        #expect(snapshots.food.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:d3")!] == .measured(1))
        #expect(snapshots.food.itemReadings[RoutineItemMetric(rawValue: "supplement_taken:mg")!] == nil)
        let context = try RoutineEvaluationContext(day: fixtureDay, now: now, timeZone: zone)
        #expect(RuleEvaluator.evaluate(rule("supplement_taken:d3"), context: context, sources: snapshots).state == .kept)
        #expect(RuleEvaluator.evaluate(rule("supplement_taken:mg"), context: context, sources: snapshots).state == .pending)
    }
}
