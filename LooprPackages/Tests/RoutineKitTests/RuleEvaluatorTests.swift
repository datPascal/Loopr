import DomainKit
import Foundation
import RoutineKit
import Testing

private let zone = TimeZone(identifier: "Australia/Perth")!
private let day = DayIdentity(year: 2026, month: 10, day: 20)
private let clock = RoutineDayClock(day: day, timeZone: zone)!

/// Wall-clock minutes after midnight of the rule's day. 1440 and above is the next day.
private func context(at minutes: Double) throws -> RoutineEvaluationContext {
    try RoutineEvaluationContext(day: day, now: clock.start.addingTimeInterval(minutes * 60), timeZone: zone)
}

private func rule(_ metric: RoutineMetric, _ kind: RuleTargetKind, _ value: Double? = nil, time: Int? = nil) -> ProtocolRule {
    ProtocolRule(key: RuleKey(rawValue: "r-\(metric.rawValue)"), title: "Rule", group: .custom,
                 target: RuleTarget(kind: kind, metric: metric.rawValue, value: value), timeOfDayMinutes: time,
                 source: metric.source)
}

private func snapshots(_ readings: [RoutineMetric: MetricReading], access: RoutineSourceAccess = .available,
                       blocked: [RoutineMetric: RoutineSourceAccess] = [:]) -> RoutineSourceSnapshots {
    func snapshot(_ source: CheckSource) -> RoutineSourceSnapshot {
        RoutineSourceSnapshot(source: source, access: access, blocked: blocked,
                              readings: readings.filter { $0.key.source == source })
    }
    return RoutineSourceSnapshots(band: snapshot(.band), food: snapshot(.food), fitness: snapshot(.fitness),
                                  appleHealth: snapshot(.appleHealth))
}

private func evaluate(_ rule: ProtocolRule, at minutes: Double, _ readings: [RoutineMetric: MetricReading] = [:],
                      access: RoutineSourceAccess = .available,
                      blocked: [RoutineMetric: RoutineSourceAccess] = [:]) throws -> RuleOutcome {
    RuleEvaluator.evaluate(rule, context: try context(at: minutes),
                           sources: snapshots(readings, access: access, blocked: blocked))
}

private let noon = 12.0 * 60
private let evening = 21.0 * 60
private let dayEnd = 1_440.0

struct RuleEvaluatorTests {
    // MARK: Quantities that grow through the day

    @Test func atLeastIsKeptAsSoonAsTheTargetIsReached() throws {
        let protein = rule(.proteinG, .atLeast, 130)
        let outcome = try evaluate(protein, at: noon, [.proteinG: .measured(142)])
        #expect(outcome.state == .kept && outcome.measuredValue == 142 && outcome.source == .food && outcome.reason == nil)
        #expect(try evaluate(protein, at: noon, [.proteinG: .measured(130)]).state == .kept)
        #expect(try evaluate(protein, at: noon, [.proteinG: .atLeast(131)]).state == .kept, "a floor above the target proves it")
    }

    @Test func atLeastBelowTheTargetIsPendingWithTheFigureSoFar() throws {
        let protein = rule(.proteinG, .atLeast, 130)
        let outcome = try evaluate(protein, at: evening, [.proteinG: .measured(38)])
        #expect(outcome.state == .pending && outcome.measuredValue == 38 && outcome.reason == nil)
        #expect(try evaluate(protein, at: dayEnd - 1, [.proteinG: .measured(129.9)]).state == .pending)
    }

    @Test func atLeastBelowTheTargetIsMissedOnceTheDayEnds() throws {
        let protein = rule(.proteinG, .atLeast, 130)
        let outcome = try evaluate(protein, at: dayEnd, [.proteinG: .measured(90)])
        #expect(outcome.state == .missed && outcome.measuredValue == 90)
        #expect(try evaluate(protein, at: dayEnd + 600, [.proteinG: .measured(0)]).state == .missed)
    }

    @Test func aFloorBelowTheTargetIsNotAMissAtDayEnd() throws {
        // Some logged items did not report protein, so 90 g is a minimum.
        let outcome = try evaluate(rule(.proteinG, .atLeast, 130), at: dayEnd, [.proteinG: .atLeast(90)])
        #expect(outcome.state == .unknown && outcome.reason == .partialData && outcome.measuredValue == 90)
    }

    @Test func atMostIsMissedTheMomentTheLimitIsCrossed() throws {
        let alcohol = rule(.alcoholDrinks, .atMost, 1)
        let outcome = try evaluate(alcohol, at: noon, [.alcoholDrinks: .measured(2)])
        #expect(outcome.state == .missed && outcome.measuredValue == 2)
        #expect(try evaluate(alcohol, at: noon, [.alcoholDrinks: .atLeast(2)]).state == .missed, "a floor over the limit proves the breach")
    }

    @Test func atMostWithinTheLimitStaysPendingUntilTheDayEnds() throws {
        let alcohol = rule(.alcoholDrinks, .atMost, 1)
        #expect(try evaluate(alcohol, at: evening, [.alcoholDrinks: .measured(1)]).state == .pending)
        let end = try evaluate(alcohol, at: dayEnd, [.alcoholDrinks: .measured(1)])
        #expect(end.state == .kept && end.measuredValue == 1)
        #expect(try evaluate(alcohol, at: dayEnd, [.alcoholDrinks: .measured(0)]).state == .kept, "a closed log with no drinks is a known zero")
    }

    @Test func aFloorWithinTheLimitCannotProveAtMost() throws {
        let alcohol = rule(.alcoholDrinks, .atMost, 2)
        #expect(try evaluate(alcohol, at: evening, [.alcoholDrinks: .atLeast(1)]).state == .pending)
        let end = try evaluate(alcohol, at: dayEnd, [.alcoholDrinks: .atLeast(1)])
        #expect(end.state == .unknown && end.reason == .partialData)
    }

    @Test func exactlyIsKeptOnlyWhenTheDayEndsOnTheTarget() throws {
        let sessions = rule(.strengthSessions, .exactly, 1)
        #expect(try evaluate(sessions, at: noon, [.strengthSessions: .measured(1)]).state == .pending)
        #expect(try evaluate(sessions, at: dayEnd, [.strengthSessions: .measured(1)]).state == .kept)
        #expect(try evaluate(sessions, at: noon, [.strengthSessions: .measured(2)]).state == .missed)
        #expect(try evaluate(sessions, at: dayEnd, [.strengthSessions: .measured(0)]).state == .missed)
        #expect(try evaluate(sessions, at: dayEnd, [.strengthSessions: .atLeast(1)]).state == .unknown)
    }

    @Test func doneIsKeptWhenTheSourceSawAnything() throws {
        let workout = rule(.workoutMinutes, .done)
        #expect(try evaluate(workout, at: noon, [.workoutMinutes: .measured(20)]).state == .kept)
        #expect(try evaluate(workout, at: noon, [.workoutMinutes: .measured(0)]).state == .pending)
        #expect(try evaluate(workout, at: dayEnd, [.workoutMinutes: .measured(0)]).state == .missed)
    }

    // MARK: Missing readings

    @Test func aMissingReadingIsPendingDuringTheDayAndUnknownAfterIt() throws {
        let protein = rule(.proteinG, .atLeast, 130)
        let during = try evaluate(protein, at: noon)
        #expect(during.state == .pending && during.measuredValue == nil)
        let after = try evaluate(protein, at: dayEnd)
        #expect(after.state == .unknown && after.reason == .noData && after.measuredValue == nil)
    }

    @Test func aReadingThatIsNotARealNumberCountsAsMissing() throws {
        let protein = rule(.proteinG, .atLeast, 130)
        #expect(try evaluate(protein, at: dayEnd, [.proteinG: .measured(.nan)]).state == .unknown)
        #expect(try evaluate(protein, at: dayEnd, [.proteinG: .measured(-5)]).state == .unknown)
        #expect(try evaluate(protein, at: dayEnd, [.proteinG: .atLeast(.infinity)]).state == .unknown)
    }

    @Test func noEventsOnAnAmountMetricIsIgnored() throws {
        #expect(try evaluate(rule(.proteinG, .atLeast, 1), at: dayEnd, [.proteinG: .noEvents]).state == .unknown)
    }

    @Test func aDayThatHasNotStartedIsPending() throws {
        #expect(try evaluate(rule(.proteinG, .atLeast, 130), at: -300).state == .pending)
    }

    // MARK: Times of day

    @Test func lastMealAtOrBeforeTheLimitIsKeptOnceTheLimitPasses() throws {
        let kitchen = rule(.lastMealTime, .atMost, 18 * 60 + 30, time: 18 * 60 + 30)
        let meal = [RoutineMetric.lastMealTime: MetricReading.measured(17 * 60)]
        let before = try evaluate(kitchen, at: 17.5 * 60, meal)
        #expect(before.state == .pending && before.measuredValue == 1_020, "another meal could still follow")
        let after = try evaluate(kitchen, at: 18 * 60 + 30, meal)
        #expect(after.state == .kept && after.measuredValue == 1_020)
        let exactly = try evaluate(kitchen, at: 18 * 60 + 30, [.lastMealTime: .measured(18 * 60 + 30)])
        #expect(exactly.state == .kept, "a meal at 18:30 is at the limit, not past it")
    }

    @Test func aMealPastTheLimitIsMissedAtOnce() throws {
        let kitchen = rule(.lastMealTime, .atMost, 18 * 60 + 30)
        let outcome = try evaluate(kitchen, at: 19 * 60, [.lastMealTime: .measured(18 * 60 + 31)])
        #expect(outcome.state == .missed && outcome.measuredValue == 1_111)
    }

    @Test func aClosedLogWithoutAMealKeepsAnAtMostLimit() throws {
        let kitchen = rule(.lastMealTime, .atMost, 18 * 60 + 30)
        #expect(try evaluate(kitchen, at: noon, [.lastMealTime: .noEvents]).state == .kept)
        #expect(try evaluate(rule(.lastMealTime, .atLeast, 17 * 60), at: noon, [.lastMealTime: .noEvents]).state == .missed)
    }

    @Test func aFloorOnTheLastCaffeineTimeCanOnlyProveABreach() throws {
        let cutoff = rule(.lastCaffeineTime, .atMost, 14 * 60)
        #expect(try evaluate(cutoff, at: 15 * 60, [.lastCaffeineTime: .atLeast(15 * 60)]).state == .missed)
        #expect(try evaluate(cutoff, at: 13 * 60, [.lastCaffeineTime: .atLeast(9 * 60)]).state == .pending)
        let after = try evaluate(cutoff, at: 15 * 60, [.lastCaffeineTime: .atLeast(9 * 60)])
        #expect(after.state == .unknown && after.reason == .partialData, "an item with unknown caffeine could be later")
    }

    @Test func sleepOnsetByAMinuteMeansBeforeThatMinute() throws {
        let lightsOut = rule(.sleepOnsetTime, .atMost, 21 * 60 + 45, time: 21 * 60 + 45)
        let before = try evaluate(lightsOut, at: dayEnd + 480, [.sleepOnsetTime: .measured(21 * 60 + 44)])
        #expect(before.state == .kept && before.measuredValue == 1_304)
        #expect(try evaluate(lightsOut, at: dayEnd + 480, [.sleepOnsetTime: .measured(21 * 60 + 45)]).state == .missed)
        #expect(try evaluate(lightsOut, at: dayEnd + 480, [.sleepOnsetTime: .measured(24 * 60 + 30)]).state == .missed,
                "00:30 the next morning is past 21:45")
        #expect(try evaluate(rule(.inBedTime, .atMost, 22 * 60 + 30), at: dayEnd + 480, [.inBedTime: .measured(22 * 60 + 30)]).state == .missed)
    }

    @Test func aRulesReminderTimeNeverDecidesTheResult() throws {
        let lightsOut = rule(.sleepOnsetTime, .atMost, 22 * 60 + 30, time: 21 * 60 + 45)
        // The night's reading is final the moment it exists, before or after the reminder.
        #expect(try evaluate(lightsOut, at: 10 * 60, [.sleepOnsetTime: .measured(22 * 60)]).state == .kept)
        #expect(try evaluate(rule(.proteinG, .atLeast, 130, time: 9 * 60), at: 20 * 60, [.proteinG: .measured(40)]).state == .pending,
                "a quantity rule is not missed because its reminder time went by")
    }

    @Test func aNightIsPendingUntilTheBandHasHadTheMorningToScoreIt() throws {
        let lightsOut = rule(.sleepOnsetTime, .atMost, 22 * 60 + 30)
        #expect(try evaluate(lightsOut, at: 23 * 60).state == .pending)
        #expect(try evaluate(lightsOut, at: dayEnd + 719).state == .pending)
        let late = try evaluate(lightsOut, at: dayEnd + 720)
        #expect(late.state == .unknown && late.reason == .noData)
    }

    @Test func settledReadingsDecideAtOnce() throws {
        #expect(try evaluate(rule(.sleepHR, .atMost, 55), at: dayEnd + 60, [.sleepHR: .measured(52)]).state == .kept)
        #expect(try evaluate(rule(.sleepHR, .atMost, 55), at: dayEnd + 60, [.sleepHR: .measured(58)]).state == .missed)
        #expect(try evaluate(rule(.vo2max, .atLeast, 45), at: noon, [.vo2max: .measured(47.5)]).state == .kept)
        #expect(try evaluate(rule(.weightKg, .exactly, 70), at: noon, [.weightKg: .measured(70)]).state == .kept)
        #expect(try evaluate(rule(.weightKg, .exactly, 70), at: noon, [.weightKg: .measured(70.4)]).state == .missed)
    }

    // MARK: Switched off, denied, unavailable

    @Test func aSourceThatCannotAnswerMakesTheRuleUnknownEvenWithReadingsInTheSnapshot() throws {
        let steps = rule(.steps, .atLeast, 8_000)
        let readings: [RoutineMetric: MetricReading] = [.steps: .measured(9_000)]
        let off = try evaluate(steps, at: noon, readings, access: .switchedOff)
        #expect(off.state == .unknown && off.reason == .sourceSwitchedOff && off.measuredValue == nil)
        #expect(try evaluate(steps, at: noon, readings, access: .denied).reason == .accessDenied)
        #expect(try evaluate(steps, at: dayEnd, readings, access: .unavailable).reason == .sourceUnavailable)
    }

    @Test func oneAppleHealthKindSwitchedOffDoesNotBlockTheOthers() throws {
        let blocked: [RoutineMetric: RoutineSourceAccess] = [.weightKg: .switchedOff, .vo2max: .denied]
        let readings: [RoutineMetric: MetricReading] = [.steps: .measured(9_000), .weightKg: .measured(70)]
        #expect(try evaluate(rule(.weightKg, .atMost, 80), at: noon, readings, blocked: blocked).reason == .sourceSwitchedOff)
        #expect(try evaluate(rule(.vo2max, .atLeast, 40), at: noon, readings, blocked: blocked).reason == .accessDenied)
        #expect(try evaluate(rule(.steps, .atLeast, 8_000), at: noon, readings, blocked: blocked).state == .kept)
    }

    // MARK: Every source

    @Test func everyAutomaticSourceEvaluatesFromItsOwnSnapshot() throws {
        let cases: [(RoutineMetric, MetricReading, Double)] = [
            (.proteinG, .measured(135), 130), (.fibreG, .measured(32), 30), (.energyKcal, .measured(2_100), 2_000),
            (.zone2Minutes, .measured(50), 45), (.zone45Minutes, .measured(12), 10),
            (.strengthSessions, .measured(1), 1), (.mobilitySessions, .measured(1), 1), (.workoutMinutes, .measured(40), 30),
            (.steps, .measured(9_500), 8_000), (.daylightMinutes, .measured(75), 60)
        ]
        for (metric, reading, target) in cases {
            let outcome = try evaluate(rule(metric, .atLeast, target), at: noon, [metric: reading])
            #expect(outcome.state == .kept && outcome.source == metric.source, "\(metric.rawValue)")
        }
    }

    // MARK: Manual ticks

    @Test func aManualRuleIsKeptWhenTicked() throws {
        let magnesium = ProtocolRule(key: "magnesium", title: "Magnesium", target: .done, timeOfDayMinutes: 21 * 60 + 30, source: .manual)
        let ticked = RoutineSourceSnapshots(manual: RoutineManualSnapshot(ticked: ["magnesium"], values: ["magnesium": 12]))
        let outcome = RuleEvaluator.evaluate(magnesium, context: try context(at: 8 * 60), sources: ticked)
        #expect(outcome.state == .kept && outcome.source == .manual && outcome.measuredValue == 12, "ticking early is fine")
    }

    @Test func anUntickedManualRuleIsPendingThenUnknownNeverMissed() throws {
        let magnesium = ProtocolRule(key: "magnesium", title: "Magnesium", target: .done, timeOfDayMinutes: 21 * 60 + 30, source: .manual)
        let empty = RoutineSourceSnapshots()
        let late = RuleEvaluator.evaluate(magnesium, context: try context(at: 23 * 60), sources: empty)
        #expect(late.state == .pending, "the reminder time passing does not end the day")
        let over = RuleEvaluator.evaluate(magnesium, context: try context(at: dayEnd), sources: empty)
        #expect(over.state == .unknown && over.reason == .notTicked)
    }

    // MARK: Rules the evaluator cannot read

    @Test func aRuleItCannotReadIsUnknown() throws {
        func outcome(_ rule: ProtocolRule) throws -> RuleOutcome {
            RuleEvaluator.evaluate(rule, context: try context(at: noon), sources: snapshots([.proteinG: .measured(500), .steps: .measured(500)]))
        }
        let noMetric = ProtocolRule(key: "a", title: "A", target: RuleTarget(kind: .atLeast, value: 1), source: .food)
        let madeUp = ProtocolRule(key: "b", title: "B", target: RuleTarget(kind: .atLeast, metric: "kale_g", value: 1), source: .food)
        let wrongSource = ProtocolRule(key: "c", title: "C", target: RuleTarget(kind: .atLeast, metric: "steps", value: 1), source: .food)
        let noValue = ProtocolRule(key: "d", title: "D", target: RuleTarget(kind: .done, metric: "protein_g"), source: .food)
        for rule in [noMetric, madeUp, wrongSource] {
            let result = try outcome(rule)
            #expect(result.state == .unknown && result.reason == .unsupportedRule, "\(rule.key.rawValue)")
        }
        #expect(try outcome(noValue).state == .kept, "done needs no target value")
    }

    // MARK: Never a No

    @Test func noMissingBlockedOrPartialReadingEverProducesAMiss() throws {
        let kinds: [RuleTargetKind] = [.done, .atLeast, .atMost, .exactly]
        let times: [Double] = [-60, 0, noon, evening, dayEnd - 1, dayEnd, dayEnd + 600, dayEnd + 720, dayEnd + 2_000]
        for metric in RoutineMetric.allCases where metric.source != .manual {
            for kind in kinds {
                let target: Double? = kind == .done ? nil : 10
                let subject = ProtocolRule(key: "x", title: "X", target: RuleTarget(kind: kind, metric: metric.rawValue, value: target),
                                           source: metric.source)
                for minutes in times {
                    let ctx = try context(at: minutes)
                    for access in [RoutineSourceAccess.switchedOff, .denied, .unavailable] {
                        let blocked = RuleEvaluator.evaluate(subject, context: ctx, sources: snapshots([metric: .measured(0)], access: access))
                        #expect(blocked.state == .unknown, "\(metric.rawValue) \(kind) \(access)")
                    }
                    let silent = RuleEvaluator.evaluate(subject, context: ctx, sources: snapshots([:]))
                    #expect(silent.state == .pending || silent.state == .unknown, "\(metric.rawValue) \(kind) at \(minutes)")
                    let floor = RuleEvaluator.evaluate(subject, context: ctx, sources: snapshots([metric: .atLeast(0)]))
                    #expect(floor.state != .kept || kind == .atLeast || kind == .done || metric.nature == .settled)
                    #expect(floor.state != .missed || metric.nature == .settled, "a floor of 0 never proves a miss")
                }
            }
        }
    }

    // MARK: The day clock

    @Test func theDayClockCountsWallClockMinutesAcrossMidnight() throws {
        #expect(clock.minutes(of: clock.start) == 0)
        #expect(clock.minutes(of: clock.start.addingTimeInterval(21 * 3_600 + 45 * 60 + 30)) == 1_305.5)
        #expect(clock.wholeMinute(of: clock.start.addingTimeInterval(21 * 3_600 + 45 * 60 + 59)) == 1_305)
        #expect(clock.wholeMinute(of: clock.start.addingTimeInterval(24 * 3_600 + 30 * 60)) == 1_470)
        #expect(clock.wholeMinute(of: clock.start.addingTimeInterval(-60)) == -1)
        #expect(clock.contains(clock.start) && !clock.contains(clock.end) && clock.contains(clock.end.addingTimeInterval(-1)))
    }

    @Test func theDayClockFollowsTheWallClockThroughAClockChange() throws {
        // 2026-11-01 in New York is 25 hours long: the clocks go back at 02:00.
        let newYork = TimeZone(identifier: "America/New_York")!
        let longDay = try #require(RoutineDayClock(day: DayIdentity(year: 2026, month: 11, day: 1), timeZone: newYork))
        #expect(longDay.end.timeIntervalSince(longDay.start) == 25 * 3_600)
        #expect(longDay.minutes(of: longDay.start.addingTimeInterval(11 * 3_600)) == 600, "eleven hours in is 10:00 on the wall clock")
        #expect(longDay.minutes(of: longDay.end) == 1_440)
        let next = try #require(RoutineDayClock(day: DayIdentity(year: 2026, month: 11, day: 2), timeZone: newYork))
        #expect(next.minutes(of: longDay.start) == -1_440, "the day before is one day back")
        #expect(RoutineDayClock(day: DayIdentity(year: 2026, month: 2, day: 30), timeZone: newYork) == nil)
    }
}
