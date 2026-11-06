import DomainKit
import Foundation
import RoutineKit
import Testing

private let zone = TimeZone(identifier: "Australia/Perth")!
private let day = DayIdentity(year: 2026, month: 10, day: 20)
private let clock = RoutineDayClock(day: day, timeZone: zone)!

private func context(at minutes: Double) throws -> RoutineEvaluationContext {
    try RoutineEvaluationContext(day: day, now: clock.start.addingTimeInterval(minutes * 60), timeZone: zone)
}

private func rule(_ metric: String, _ kind: RuleTargetKind = .atLeast, _ value: Double? = 1, source: CheckSource = .food) -> ProtocolRule {
    ProtocolRule(key: "supplement", title: "Supplement", group: .supplements, target: RuleTarget(kind: kind, metric: metric, value: value),
                 source: source)
}

private func food(_ readings: [RoutineMetric: MetricReading] = [:], items: [RoutineItemMetric: MetricReading] = [:],
                  access: RoutineSourceAccess = .available, blocked: [RoutineMetric: RoutineSourceAccess] = [:]) -> RoutineSourceSnapshots {
    RoutineSourceSnapshots(food: RoutineSourceSnapshot(source: .food, access: access, blocked: blocked, readings: readings, itemReadings: items))
}

/// The stack's metrics: `supplements_all_taken`, `medication_all_taken`, `supplement_adherence` and the item metrics
/// `supplement_taken:<key>` and `medication_taken:<key>`.
struct SupplementMetricTests {
    private let d3 = RoutineItemMetric(kind: .supplementTaken, itemKey: "vitamin-d3")!
    private let metformin = RoutineItemMetric(kind: .medicationTaken, itemKey: "metformin")!

    @Test func itemNamesParseWithTheStacksKeyRule() {
        #expect(RoutineItemMetric(rawValue: "supplement_taken:vitamin-d3") == d3)
        #expect(RoutineItemMetric(rawValue: "medication_taken:metformin") == metformin)
        #expect(d3.rawValue == "supplement_taken:vitamin-d3" && metformin.rawValue == "medication_taken:metformin")
        #expect(d3.source == .food && d3.nature == .settled && d3.unit == .tick)
        #expect(RoutineItemMetric.Kind.supplementTaken.lane == .supplementsAllTaken)
        #expect(RoutineItemMetric.Kind.medicationTaken.lane == .medicationAllTaken)
        for bad in ["supplement_taken:", "supplement_taken:Vitamin D3", "supplement_taken:d3:extra", "protein_g:x", "supplement_taken",
                    "vitamin_taken:d3", "supplement_taken:" + String(repeating: "a", count: 49)] {
            #expect(RoutineItemMetric(rawValue: bad) == nil, "\(bad)")
        }
        #expect(RoutineItemMetric(rawValue: "supplement_taken:" + String(repeating: "a", count: 48)) != nil)
    }

    @Test func theVocabularyKnowsFixedAndItemNames() {
        #expect(RoutineMetricVocabulary.source(ofMetric: "supplements_all_taken") == .food)
        #expect(RoutineMetricVocabulary.source(ofMetric: "medication_all_taken") == .food)
        #expect(RoutineMetricVocabulary.source(ofMetric: "supplement_adherence") == .food)
        #expect(RoutineMetricVocabulary.source(ofMetric: "supplement_taken:mg") == .food)
        #expect(RoutineMetricVocabulary.source(ofMetric: "zone2_minutes") == .band)
        #expect(!RoutineMetricVocabulary.isKnown("kale_g") && !RoutineMetricVocabulary.isKnown("supplement_taken:"))
        #expect(RoutineMetric.supplementAdherence.unit == .fraction && RoutineMetric.supplementsAllTaken.unit == .tick)
        #expect([RoutineMetric.supplementsAllTaken, .medicationAllTaken, .supplementAdherence].allSatisfy { $0.nature == .settled && $0.source == .food })
    }

    @Test func anItemRuleIsKeptMissedOrUnknownButNeverMissedWithoutATick() throws {
        let taken = rule(d3.rawValue)
        #expect(RuleEvaluator.evaluate(taken, context: try context(at: 600), sources: food(items: [d3: .measured(1)])).state == .kept)
        let skipped = RuleEvaluator.evaluate(taken, context: try context(at: 600), sources: food(items: [d3: .measured(0)]))
        #expect(skipped.state == .missed && skipped.measuredValue == 0)
        // Not recorded: pending through the day, unknown after it, never missed.
        #expect(RuleEvaluator.evaluate(taken, context: try context(at: 600), sources: food()).state == .pending)
        let silent = RuleEvaluator.evaluate(taken, context: try context(at: 1_500), sources: food())
        #expect(silent.state == .unknown && silent.reason == .noData)
        // Another item's tick does not count for this one.
        let other = RoutineItemMetric(kind: .supplementTaken, itemKey: "omega-3")!
        #expect(RuleEvaluator.evaluate(taken, context: try context(at: 1_500), sources: food(items: [other: .measured(1)])).state == .unknown)
        // A medicine reads its own lane.
        let medicine = rule(metformin.rawValue)
        #expect(RuleEvaluator.evaluate(medicine, context: try context(at: 600), sources: food(items: [metformin: .measured(1)])).state == .kept)
        #expect(RuleEvaluator.evaluate(medicine, context: try context(at: 600), sources: food(items: [d3: .measured(1)])).state == .pending)
    }

    @Test func anItemRuleFollowsItsLanesAccessAndItsSource() throws {
        let taken = rule(d3.rawValue)
        let closed = RuleEvaluator.evaluate(taken, context: try context(at: 600), sources: RoutineSourceSnapshots())
        #expect(closed.state == .unknown && closed.reason == .sourceUnavailable)
        let off = RuleEvaluator.evaluate(taken, context: try context(at: 600), sources: food(items: [d3: .measured(1)], access: .switchedOff))
        #expect(off.state == .unknown && off.reason == .sourceSwitchedOff)
        // The stack could not be read while the meals could: the lane is blocked, so the item is too.
        let blocked = RuleEvaluator.evaluate(taken, context: try context(at: 600),
                                             sources: food(blocked: [.supplementsAllTaken: .unavailable]))
        #expect(blocked.state == .unknown && blocked.reason == .sourceUnavailable)
        // An item metric belongs to Food only. A manual rule is a tick whatever its metric says.
        let band = RuleEvaluator.evaluate(rule(d3.rawValue, source: .band), context: try context(at: 600), sources: food(items: [d3: .measured(1)]))
        #expect(band.state == .unknown && band.reason == .unsupportedRule)
        let noValue = RuleEvaluator.evaluate(rule(d3.rawValue, .atLeast, nil), context: try context(at: 600), sources: food(items: [d3: .measured(1)]))
        #expect(noValue.reason == .unsupportedRule)
        #expect(RuleEvaluator.evaluate(rule(d3.rawValue, .done, nil), context: try context(at: 600), sources: food(items: [d3: .measured(1)])).state == .kept)
    }

    @Test func laneRulesAndAdherenceEvaluateThroughTheSameEvaluator() throws {
        let all = rule(RoutineMetric.supplementsAllTaken.rawValue)
        #expect(RuleEvaluator.evaluate(all, context: try context(at: 600), sources: food([.supplementsAllTaken: .measured(1)])).state == .kept)
        #expect(RuleEvaluator.evaluate(all, context: try context(at: 600), sources: food([.supplementsAllTaken: .measured(0)])).state == .missed)
        #expect(RuleEvaluator.evaluate(all, context: try context(at: 1_500), sources: food()).state == .unknown)

        let medication = rule(RoutineMetric.medicationAllTaken.rawValue)
        #expect(RuleEvaluator.evaluate(medication, context: try context(at: 600), sources: food([.supplementsAllTaken: .measured(1)])).state == .pending)
        #expect(RuleEvaluator.evaluate(medication, context: try context(at: 600), sources: food([.medicationAllTaken: .measured(1)])).state == .kept)

        // An experiment's intervention rule on adherence: 0.8 or more of the doses.
        let adherence = rule(RoutineMetric.supplementAdherence.rawValue, .atLeast, 0.8)
        let mostly = RuleEvaluator.evaluate(adherence, context: try context(at: 1_300), sources: food([.supplementAdherence: .measured(6.0 / 7)]))
        #expect(mostly.state == .kept && mostly.measuredValue == 6.0 / 7)
        #expect(RuleEvaluator.evaluate(adherence, context: try context(at: 1_300), sources: food([.supplementAdherence: .measured(0.5)])).state == .missed)
        #expect(RuleEvaluator.evaluate(adherence, context: try context(at: 1_500), sources: food()).reason == .noData)
    }
}
