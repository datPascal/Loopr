import BodyKit
import DesignSystem
import DomainKit
import FoodKit
import Foundation
import HealthKitBridge
import JournalKit
import RoutineKit
import SleepKit
import Testing
import WorkoutKit
@testable import Loopr

private nonisolated struct RoutineGate: AppleHealthSourceGating {
    let off: Set<AppleHealthSourceKind>
    func allowsSource(_ kind: AppleHealthSourceKind) async -> Bool { !off.contains(kind) }
}

private nonisolated struct RoutineReader: AppleHealthSourceReading {
    let results: [AppleHealthSourceKind: AppleHealthReadResult]
    func read(_ kind: AppleHealthSourceKind, from start: Date, to end: Date) async -> AppleHealthReadResult {
        results[kind] ?? .absent(.noSamples)
    }
}

private nonisolated struct RoutineTestFailure: Error {}

private let zoneID = "Australia/Perth"
private let zone = TimeZone(identifier: zoneID)!
private let day = DayIdentity(year: 2026, month: 10, day: 20)
private let clock = RoutineDayClock(day: day, timeZone: zone)!
private func at(_ minutes: Double) -> Date { clock.start.addingTimeInterval(minutes * 60) }

private func record(_ id: String, at minutes: Double, alcohol: Double? = 0, caffeine: Double? = 0, meal: Bool) -> JournalIntakeRecord {
    JournalIntakeRecord(source: JournalSourceRecord(id: id, domain: .food, title: id, occurredAt: at(minutes), updatedAt: at(minutes)),
                        alcoholUnits: alcohol, caffeineMilligrams: caffeine, isMeal: meal)
}

private func completion(at minutes: Double = 22 * 60) -> JournalSourceRecord {
    JournalSourceRecord(id: "completion", domain: .food, title: "Completed food log", occurredAt: clock.start, updatedAt: at(minutes))
}

private func food(_ records: [JournalIntakeRecord], closed: Bool = false,
                  energy: FoodNutrientTotal = FoodNutrientTotal(values: []),
                  protein: FoodNutrientTotal = FoodNutrientTotal(values: []),
                  fibre: FoodNutrientTotal = FoodNutrientTotal(values: [])) -> RoutineFoodDay {
    RoutineFoodDay(intake: JournalFoodDay(records: records, completion: closed ? completion() : nil),
                   energy: energy, protein: protein, fibre: fibre)
}

private func workout(_ activity: ActivityType, from start: Double, minutes: Double, state: WorkoutLifecycleState = .completed) -> WorkoutRecord {
    WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "w-\(UUID())"), activity: activity, source: .manual,
                  state: state, createdAt: at(start), startedAt: at(start), endedAt: at(start + minutes))
}

private func night(startingAt minutes: Double, partial: Bool = false, confidence: Double = 0.9) -> SleepSessionSummary {
    SleepSessionSummary(id: "night", start: at(minutes), end: at(minutes + 480), durationMinutes: 480, isMainSleep: true,
                        isPartial: partial, confidence: confidence, state: .partial)
}

private func steps(_ value: Double, localDay: String? = "2026-10-20") -> AppleHealthSample {
    AppleHealthSample(kind: .steps, value: value, original: AppleHealthOriginalReading(value: value, unit: .count),
                      start: clock.start, end: at(600), localDay: localDay, provenance: AppleHealthProvenance(sourceName: "Apple Watch"))
}

@MainActor struct RoutineSourceProviderTests {
    // MARK: Food

    @Test func foodMapsNutrientTotalsAndKeepsOnlyTheDaysRecords() {
        let records = [
            record("breakfast", at: 8 * 60, meal: true),
            record("lunch", at: 12.5 * 60, meal: true),
            record("espresso", at: 15 * 60, alcohol: 0, caffeine: 80, meal: false),
            record("wine", at: 20 * 60, alcohol: 2, caffeine: 0, meal: false),
            record("last-night", at: -120, alcohol: 5, caffeine: 200, meal: false),
            record("tomorrow", at: 1_500, alcohol: 5, caffeine: 200, meal: true)
        ]
        let snapshot = RoutineSourceMapping.food(food(records, energy: FoodNutrientTotal(values: [600, nil]),
                                                      protein: FoodNutrientTotal(values: [30, 12]),
                                                      fibre: FoodNutrientTotal(values: [])), clock: clock)
        #expect(snapshot.access == .available && snapshot.source == .food)
        #expect(snapshot.readings[.proteinG] == .measured(42))
        #expect(snapshot.readings[.energyKcal] == .atLeast(600), "one item did not report energy")
        #expect(snapshot.readings[.fibreG] == nil, "nothing reported fibre, so it stays missing")
        #expect(snapshot.readings[.alcoholDrinks] == .measured(2))
        #expect(snapshot.readings[.lastCaffeineTime] == .measured(900))
        #expect(snapshot.readings[.lastMealTime] == .measured(750))
    }

    @Test func aClosedLogTurnsMissingIntoKnownZeroAndNoEvents() {
        let snapshot = RoutineSourceMapping.food(food([record("dinner", at: 18 * 60, meal: true)], closed: true), clock: clock)
        #expect(snapshot.readings[.alcoholDrinks] == .measured(0))
        #expect(snapshot.readings[.lastCaffeineTime] == .noEvents)
        #expect(snapshot.readings[.lastMealTime] == .measured(1_080))
        let empty = RoutineSourceMapping.food(food([], closed: true), clock: clock)
        #expect(empty.readings[.alcoholDrinks] == .measured(0))
    }

    /// ICP R1-VET-05: "none happened" counts only on a day with at least one Food entry. A closed log with nothing in it
    /// leaves late caffeine and the last meal not known, so their rules are never kept by an empty day.
    @Test func noneHappenedNeedsAtLeastOneEntryThatDay() throws {
        let empty = RoutineSourceMapping.food(food([], closed: true), clock: clock)
        #expect(empty.readings[.lastCaffeineTime] == nil && empty.readings[.lastMealTime] == nil)

        let drinkOnly = RoutineSourceMapping.food(food([record("water", at: 9 * 60, meal: false)], closed: true), clock: clock)
        #expect(drinkOnly.readings[.lastCaffeineTime] == .noEvents, "a logged drink with no caffeine is a day with entries")
        #expect(drinkOnly.readings[.lastMealTime] == .noEvents)

        // An entry from the day before does not count for this one.
        let yesterday = JournalIntakeRecord(
            source: JournalSourceRecord(id: "late", domain: .food, title: "late", occurredAt: at(-60), updatedAt: at(-60)),
            alcoholUnits: 0, caffeineMilligrams: 0, isMeal: true)
        let elsewhere = RoutineSourceMapping.food(food([yesterday], closed: true), clock: clock)
        #expect(elsewhere.readings[.lastCaffeineTime] == nil && elsewhere.readings[.lastMealTime] == nil)

        // Through the evaluator at the end of the day: not known on the empty day, kept on the day with an entry.
        let caffeine = ProtocolRule(key: "caffeine-cutoff", title: "No caffeine after 14:00", group: .food,
                                    target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastCaffeineTime.rawValue, value: 839),
                                    source: .food)
        let context = try RoutineEvaluationContext(day: day, now: at(1_440), timeZone: zone)
        let unknown = RuleEvaluator.evaluate(caffeine, context: context, sources: RoutineSourceSnapshots(food: empty))
        #expect(unknown.state == .unknown)
        let kept = RuleEvaluator.evaluate(caffeine, context: context, sources: RoutineSourceSnapshots(food: drinkOnly))
        #expect(kept.state == .kept)
    }

    @Test func anOpenLogWithNothingBadDoesNotClaimZero() {
        let snapshot = RoutineSourceMapping.food(food([record("dinner", at: 18 * 60, meal: true)]), clock: clock)
        #expect(snapshot.readings[.alcoholDrinks] == nil, "no drink logged is not the same as no drinks")
        #expect(snapshot.readings[.lastCaffeineTime] == nil)
        #expect(snapshot.readings[.lastMealTime] == .measured(1_080))
        #expect(RoutineSourceMapping.food(food([]), clock: clock).readings.isEmpty)
    }

    @Test func recordsThatDoNotSayTheirAlcoholOrCaffeineMakeFloors() {
        let records = [record("wine", at: 19 * 60, alcohol: 1, caffeine: nil, meal: false),
                       record("stew", at: 19.5 * 60, alcohol: nil, caffeine: 40, meal: true)]
        let snapshot = RoutineSourceMapping.food(food(records), clock: clock)
        #expect(snapshot.readings[.alcoholDrinks] == .atLeast(1))
        #expect(snapshot.readings[.lastCaffeineTime] == .atLeast(1_170))
        let closed = RoutineSourceMapping.food(food(records, closed: true), clock: clock)
        #expect(closed.readings[.alcoholDrinks] == .atLeast(1), "a closed log cannot supply the figure a record left out")
    }

    @Test func aCompletionFromAnotherDayDoesNotCloseThisOne() {
        let other = JournalSourceRecord(id: "completion", domain: .food, title: "Completed food log",
                                        occurredAt: clock.start.addingTimeInterval(-86_400), updatedAt: at(-60))
        let day = RoutineFoodDay(intake: JournalFoodDay(records: [], completion: other), energy: FoodNutrientTotal(values: []),
                                 protein: FoodNutrientTotal(values: []), fibre: FoodNutrientTotal(values: []))
        #expect(RoutineSourceMapping.food(day, clock: clock).readings.isEmpty)
    }

    // MARK: Band

    @Test func bandMapsZonesAndTheNight() {
        let zones = [BodyZoneMinutes(id: 1, name: "Recovery", minutes: 60), BodyZoneMinutes(id: 2, name: "Aerobic", minutes: 48),
                     BodyZoneMinutes(id: 3, name: "Tempo", minutes: 9), BodyZoneMinutes(id: 4, name: "Threshold", minutes: 6),
                     BodyZoneMinutes(id: 5, name: "Peak", minutes: 3)]
        let band = RoutineBandDay(zoneMinutes: zones, night: night(startingAt: 22 * 60 + 10), sleepLatencyMinutes: 12, sleepingHeartRate: 51)
        let snapshot = RoutineSourceMapping.band(band, clock: clock)
        #expect(snapshot.readings[.zone2Minutes] == .measured(48))
        #expect(snapshot.readings[.zone45Minutes] == .measured(9))
        #expect(snapshot.readings[.inBedTime] == .measured(1_330))
        #expect(snapshot.readings[.sleepOnsetTime] == .measured(1_342))
        #expect(snapshot.readings[.sleepHR] == .measured(51))
    }

    @Test func aNightAfterMidnightIsPastTheDaysEnd() {
        let band = RoutineBandDay(zoneMinutes: [], night: night(startingAt: 24 * 60 + 30), sleepLatencyMinutes: 0)
        let snapshot = RoutineSourceMapping.band(band, clock: clock)
        #expect(snapshot.readings[.inBedTime] == .measured(1_470) && snapshot.readings[.sleepOnsetTime] == .measured(1_470))
    }

    @Test func bandLeavesOutWhatTheAnalyticsDoNotHold() {
        #expect(RoutineSourceMapping.band(RoutineBandDay(zoneMinutes: []), clock: clock).readings.isEmpty, "no zone data is not zero minutes")
        let noLatency = RoutineSourceMapping.band(RoutineBandDay(zoneMinutes: [], night: night(startingAt: 1_320)), clock: clock)
        #expect(noLatency.readings[.inBedTime] == .measured(1_320) && noLatency.readings[.sleepOnsetTime] == nil && noLatency.readings[.sleepHR] == nil)
        let partial = RoutineBandDay(zoneMinutes: [], night: night(startingAt: 1_320, partial: true), sleepLatencyMinutes: 5, sleepingHeartRate: 50)
        #expect(RoutineSourceMapping.band(partial, clock: clock).readings.isEmpty)
        let unsure = RoutineBandDay(zoneMinutes: [], night: night(startingAt: 1_320, confidence: 0.4), sleepLatencyMinutes: 5)
        #expect(RoutineSourceMapping.band(unsure, clock: clock).readings.isEmpty)
        let before = RoutineBandDay(zoneMinutes: [], night: night(startingAt: -600), sleepLatencyMinutes: 5)
        #expect(RoutineSourceMapping.band(before, clock: clock).readings.isEmpty, "last night belongs to the day before")
        let zonesMissingTwo = RoutineBandDay(zoneMinutes: [BodyZoneMinutes(id: 2, name: "Aerobic", minutes: 20),
                                                           BodyZoneMinutes(id: 4, name: "Threshold", minutes: 5)])
        let partialZones = RoutineSourceMapping.band(zonesMissingTwo, clock: clock)
        #expect(partialZones.readings[.zone2Minutes] == .measured(20) && partialZones.readings[.zone45Minutes] == nil)
    }

    // MARK: Fitness

    @Test func fitnessCountsCompletedWorkoutsThatStartedOnTheDay() {
        let workouts = [workout(.strength, from: 7 * 60, minutes: 50), workout(.strength, from: 18 * 60, minutes: 30),
                        workout(.yoga, from: 20 * 60, minutes: 20), workout(.run, from: 6 * 60, minutes: 40),
                        workout(.strength, from: 9 * 60, minutes: 40, state: .active),
                        workout(.strength, from: -300, minutes: 40), workout(.yoga, from: 1_500, minutes: 40)]
        let snapshot = RoutineSourceMapping.fitness(workouts, clock: clock)
        #expect(snapshot.readings[.strengthSessions] == .measured(2))
        #expect(snapshot.readings[.mobilitySessions] == .measured(1))
        #expect(snapshot.readings[.workoutMinutes] == .measured(140))
    }

    @Test func fitnessWithNoCompletedWorkoutHasNoReadingsAtAll() {
        #expect(RoutineSourceMapping.fitness([], clock: clock).readings.isEmpty)
        let running = RoutineSourceMapping.fitness([workout(.run, from: 600, minutes: 30)], clock: clock)
        #expect(running.readings == [.workoutMinutes: .measured(30)], "a run says nothing about strength sessions")
    }

    // MARK: Apple Health

    @Test func appleHealthMapsEachKindAndBlocksOnlyItsOwnMetric() {
        let weight = AppleHealthSample(kind: .weight, value: 71.2, original: AppleHealthOriginalReading(value: 71.2, unit: .kilograms),
                                       start: at(420), end: at(421), provenance: AppleHealthProvenance(sourceName: "Scale"))
        let results: [AppleHealthSourceKind: AppleHealthReadResult] = [
            .steps: .values([steps(9_100), steps(400, localDay: "2026-10-19")]),
            .weight: .values([weight]), .daylight: .absent(.switchedOff), .vo2Max: .absent(.notAuthorized)
        ]
        let snapshot = RoutineSourceMapping.appleHealth(results, clock: clock)
        #expect(snapshot.readings == [.steps: .measured(9_100), .weightKg: .measured(71.2)])
        #expect(snapshot.blocked == [.daylightMinutes: .switchedOff, .vo2max: .denied])
        #expect(snapshot.access == .available)
    }

    @Test func appleHealthFindingNothingLeavesAMetricMissingNotBlocked() {
        let snapshot = RoutineSourceMapping.appleHealth([.steps: .absent(.noSamples), .daylight: .values([steps(10, localDay: "2026-10-19")]),
                                                         .vo2Max: .absent(.unavailable), .weight: .absent(.queryFailed("locked"))], clock: clock)
        #expect(snapshot.readings.isEmpty)
        #expect(snapshot.blocked == [.vo2max: .unavailable, .weightKg: .unavailable])
    }

    // MARK: The provider

    @Test func theProviderBuildsEverySourceFromItsReader() async throws {
        let reader = RoutineReader(results: [.steps: .values([steps(9_100)])])
        let provider = RoutineSourceProvider(
            readFood: { _, _ in food([record("lunch", at: 12 * 60, meal: true)], protein: FoodNutrientTotal(values: [38])) },
            readTraining: { [workout(.strength, from: 7 * 60, minutes: 45)] },
            readBand: { _, _, _ in RoutineBandDay(zoneMinutes: [BodyZoneMinutes(id: 2, name: "Aerobic", minutes: 50)]) },
            appleHealth: AppleHealthSources(gate: RoutineGate(off: [.weight]), makeReader: { reader }))
        let snapshots = try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(14 * 60))
        #expect(snapshots.food.readings[.proteinG] == .measured(38) && snapshots.food.readings[.lastMealTime] == .measured(720))
        #expect(snapshots.fitness.readings[.strengthSessions] == .measured(1))
        #expect(snapshots.band.readings[.zone2Minutes] == .measured(50))
        #expect(snapshots.appleHealth.readings[.steps] == .measured(9_100))
        #expect(snapshots.appleHealth.blocked[.weightKg] == .switchedOff, "a switched-off kind never reaches Apple Health")
        #expect(snapshots.manual == RoutineManualSnapshot())

        // The evaluator, not the provider, decides: 38 g at 14:00 is a partial figure.
        let protein = ProtocolRule(key: "protein", title: "Protein", group: .food,
                                   target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 130), source: .food)
        let context = try RoutineEvaluationContext(day: day, now: at(14 * 60), timeZone: zone)
        let outcome = RuleEvaluator.evaluate(protein, context: context, sources: snapshots)
        #expect(outcome.state == .pending && outcome.measuredValue == 38)
    }

    @Test func aSourceThatFailsOrIsNotWiredInIsClosedAndItsRulesAreUnknown() async throws {
        let provider = RoutineSourceProvider(readFood: { _, _ in throw RoutineTestFailure() }, readTraining: nil,
                                             readBand: { _, _, _ in nil }, appleHealth: nil)
        let snapshots = try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(600))
        for snapshot in [snapshots.food, snapshots.fitness, snapshots.band, snapshots.appleHealth] {
            #expect(snapshot.access == .unavailable && snapshot.readings.isEmpty, "\(snapshot.source)")
        }
        let zone2 = ProtocolRule(key: "zone2", title: "Zone 2", target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 45), source: .band)
        let context = try RoutineEvaluationContext(day: day, now: at(1_440), timeZone: zone)
        let outcome = RuleEvaluator.evaluate(zone2, context: context, sources: snapshots)
        #expect(outcome.state == .unknown && outcome.reason == .sourceUnavailable)
    }

    @Test func cancellationStopsTheRead() async {
        let provider = RoutineSourceProvider(readFood: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            try await provider.snapshots(for: day, timeZoneID: zoneID, now: at(600))
        }
    }

    @Test func anUnknownTimeZoneIsRefused() async {
        let provider = RoutineSourceProvider()
        await #expect(throws: RoutineError.invalidCheck) {
            try await provider.snapshots(for: day, timeZoneID: "Not/AZone", now: at(600))
        }
    }
}
