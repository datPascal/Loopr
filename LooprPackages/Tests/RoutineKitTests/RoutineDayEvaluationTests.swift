import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

private final class DayTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineDayTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    var evaluation: RoutineDayEvaluation { RoutineDayEvaluation(store: store) }
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "routine-day-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

private let zone = TimeZone(identifier: "Australia/Perth")!
private let day = DayIdentity(year: 2026, month: 10, day: 20)
private let clock = RoutineDayClock(day: day, timeZone: zone)!
private let created = Date(timeIntervalSince1970: 1_790_000_000)
private func at(_ minutes: Double) -> Date { clock.start.addingTimeInterval(minutes * 60) }

private let protein: RuleKey = "protein"
private let alcohol: RuleKey = "alcohol"
private let zone2: RuleKey = "zone2"
private let lightsOut: RuleKey = "lights-out"
private let strength: RuleKey = "strength"
private let steps: RuleKey = "steps"
private let magnesium: RuleKey = "magnesium"

private func rules() -> [ProtocolRule] {
    [
        ProtocolRule(key: protein, title: "Protein", group: .food,
                     target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 130, unit: "g"), source: .food),
        ProtocolRule(key: alcohol, title: "Alcohol", group: .food,
                     target: RuleTarget(kind: .atMost, metric: "alcohol_drinks", value: 1, unit: "drinks"), source: .food),
        ProtocolRule(key: zone2, title: "Zone 2", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 45, unit: "min"), source: .band),
        ProtocolRule(key: lightsOut, title: "Lights out", group: .sleep,
                     target: RuleTarget(kind: .atMost, metric: "sleep_onset_time", value: 1_305, unit: "min"),
                     timeOfDayMinutes: 1_305, source: .band, isEvening: true),
        ProtocolRule(key: strength, title: "Strength", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: "strength_sessions", value: 1), source: .fitness),
        ProtocolRule(key: steps, title: "Steps", group: .custom,
                     target: RuleTarget(kind: .atLeast, metric: "steps", value: 8_000), source: .appleHealth),
        ProtocolRule(key: magnesium, title: "Magnesium", group: .supplements, timeOfDayMinutes: 1_290, source: .manual)
    ]
}

private func snapshots(food: [RoutineMetric: MetricReading] = [:], band: [RoutineMetric: MetricReading] = [:],
                       fitness: RoutineSourceSnapshot = .closed(.fitness),
                       appleHealth: [RoutineMetric: MetricReading] = [:]) -> RoutineSourceSnapshots {
    RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band, readings: band),
                           food: RoutineSourceSnapshot(source: .food, readings: food),
                           fitness: fitness,
                           appleHealth: RoutineSourceSnapshot(source: .appleHealth, readings: appleHealth))
}

private func setUp() throws -> (DayTestDatabase, ProtocolID) {
    let context = try DayTestDatabase()
    let id = ProtocolID()
    try context.store.createProtocol(RoutineProtocol(id: id, name: "Sleep first", createdAt: created), rules: rules())
    return (context, id)
}

struct RoutineDayEvaluationTests {
    @Test func aMixedDayCountsEachStateAndStoresEveryRule() throws {
        let (context, id) = try setUp()
        let sources = snapshots(food: [.proteinG: .measured(142), .alcoholDrinks: .measured(2)],
                                band: [.zone2Minutes: .measured(30)],
                                appleHealth: [.steps: .measured(9_000)])
        let result = try #require(try context.evaluation.evaluate(day: day, now: at(22 * 60), timeZone: zone, sources: sources))

        #expect(result.checks.map(\.ruleKey) == [protein, alcohol, zone2, lightsOut, strength, steps, magnesium])
        #expect(result.checks.map(\.state) == [.kept, .missed, .pending, .pending, .unknown, .kept, .pending])
        let summary = result.summary
        #expect(summary.kept == 2 && summary.missed == 1 && summary.pending == 3 && summary.unknown == 1)
        #expect(summary.total == 7 && summary.decided == 3 && summary.version == 1 && summary.day == day)
        #expect(summary.keptShare == 2.0 / 3.0)
        #expect(result.unknownReasons == [strength: .sourceUnavailable])
        #expect(result.checks[2].measuredValue == 30, "the partial figure is stored with the pending check")

        let stored = try context.store.checks(protocolID: id, day: day)
        #expect(Set(stored.map(\.ruleKey)) == Set(rules().map(\.key)))
        #expect(stored.allSatisfy { $0.version == 1 && $0.recordedAt == at(22 * 60) && !$0.overriddenByPerson })
        #expect(stored.first { $0.ruleKey == strength }?.source == .fitness)
    }

    @Test func theKeptShareCountsDecidedRulesOnly() throws {
        let (context, _) = try setUp()
        // One kept, nothing missed, five unknown and the night still pending: the share is 100 percent of the one decided rule.
        let sources = snapshots(food: [.proteinG: .measured(150)])
        let result = try #require(try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone, sources: sources))
        #expect(result.summary.kept == 1 && result.summary.missed == 0)
        #expect(result.summary.unknown == 5 && result.summary.pending == 1)
        #expect(result.summary.keptShare == 1)
    }

    @Test func aDayOfUnknownsHasNoShareAndNoMisses() throws {
        let (context, id) = try setUp()
        let result = try #require(try context.evaluation.evaluate(day: day, now: at(1_440 + 800), timeZone: zone,
                                                                   sources: RoutineSourceSnapshots()))
        #expect(result.summary.unknown == 7 && result.summary.decided == 0 && result.summary.keptShare == nil)
        let history = try rules().flatMap { try context.store.history(protocolID: id, ruleKey: $0.key) }
        #expect(history.count == 7 && history.allSatisfy { $0.state == .unknown })
        #expect(Set(result.unknownReasons.values) == [.sourceUnavailable, .notTicked])
    }

    @Test func noActiveProtocolMeansNothingToEvaluate() throws {
        let context = try DayTestDatabase()
        #expect(try context.evaluation.evaluate(day: day, now: at(600), timeZone: zone, sources: RoutineSourceSnapshots()) == nil)
        #expect(throws: RoutineError.missingProtocol) { try context.evaluation.tick(ruleKey: magnesium, day: day, at: at(600)) }
    }

    @Test func aLaterEvaluationReplacesWhatTheSourceNowSays() throws {
        let (context, id) = try setUp()
        _ = try context.evaluation.evaluate(day: day, now: at(10 * 60), timeZone: zone,
                                            sources: snapshots(food: [.proteinG: .measured(40)]), version: nil)
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day)?.state == .pending)
        let result = try #require(try context.evaluation.evaluate(day: day, now: at(15 * 60), timeZone: zone,
                                                                   sources: snapshots(food: [.proteinG: .measured(135)])))
        #expect(result.checks.first?.state == .kept)
        #expect(try context.store.history(protocolID: id, ruleKey: protein).count == 1)
    }

    @Test func aManualTickPersistsAndSurvivesEvaluation() throws {
        let (context, id) = try setUp()
        let tick = try context.evaluation.tick(ruleKey: magnesium, day: day, at: at(20 * 60), value: 400)
        #expect(tick.state == .kept && tick.source == .manual && !tick.overriddenByPerson && tick.measuredValue == 400)
        #expect(try context.store.check(protocolID: id, ruleKey: magnesium, day: day) == tick)

        let result = try #require(try context.evaluation.evaluate(day: day, now: at(1_440 + 60), timeZone: zone,
                                                                   sources: RoutineSourceSnapshots()))
        let stored = try #require(result.checks.last)
        #expect(stored.ruleKey == magnesium && stored.state == .kept && stored.measuredValue == 400)
        #expect(result.unknownReasons[magnesium] == nil)
    }

    @Test func takingATickBackReturnsTheRuleToPendingThenUnknown() throws {
        let (context, id) = try setUp()
        try context.evaluation.tick(ruleKey: magnesium, day: day, at: at(20 * 60))
        let during = try #require(try context.evaluation.untick(ruleKey: magnesium, day: day, now: at(21 * 60), timeZone: zone,
                                                                  sources: RoutineSourceSnapshots()))
        #expect(during.checks.last?.state == .pending)
        try context.evaluation.tick(ruleKey: magnesium, day: day, at: at(22 * 60))
        let after = try #require(try context.evaluation.untick(ruleKey: magnesium, day: day, now: at(1_440 + 5), timeZone: zone,
                                                                 sources: RoutineSourceSnapshots()))
        #expect(after.checks.last?.state == .unknown && after.unknownReasons[magnesium] == .notTicked)
        #expect(try context.store.history(protocolID: id, ruleKey: magnesium).count == 1)
    }

    /// LV-04 step 3: Today's hold-to-tick writes once; a second hold the same day writes nothing.
    @Test func tickOnceWritesOnceAndASecondTickChangesNothing() throws {
        let (context, id) = try setUp()
        let first = try #require(try context.evaluation.tickOnce(ruleKey: magnesium, day: day, at: at(20 * 60)))
        #expect(first.state == .kept && first.source == .manual && first.recordedAt == at(20 * 60))
        #expect(try context.evaluation.tickOnce(ruleKey: magnesium, day: day, at: at(21 * 60)) == nil)
        #expect(try context.store.check(protocolID: id, ruleKey: magnesium, day: day) == first)
        // An evaluation in between keeps the tick, and the next hold still writes nothing.
        _ = try context.evaluation.evaluate(day: day, now: at(21 * 60 + 30), timeZone: zone, sources: RoutineSourceSnapshots())
        #expect(try context.evaluation.tickOnce(ruleKey: magnesium, day: day, at: at(22 * 60)) == nil)
        #expect(try context.store.check(protocolID: id, ruleKey: magnesium, day: day)?.state == .kept)
        #expect(throws: RoutineError.notManualRule(protein)) { try context.evaluation.tickOnce(ruleKey: protein, day: day, at: at(600)) }
    }

    @Test func onlyAManualRuleCanBeTicked() throws {
        let (context, _) = try setUp()
        #expect(throws: RoutineError.notManualRule(protein)) { try context.evaluation.tick(ruleKey: protein, day: day, at: at(600)) }
        #expect(throws: RoutineError.unknownRule("nothing")) { try context.evaluation.tick(ruleKey: "nothing", day: day, at: at(600)) }
    }

    @Test func anOverrideReplacesASourceResultAndSurvivesEveryReevaluation() throws {
        let (context, id) = try setUp()
        _ = try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone,
                                            sources: snapshots(food: [.proteinG: .measured(90), .alcoholDrinks: .measured(0)]))
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day)?.state == .missed)

        let override = try context.evaluation.override(ruleKey: protein, day: day, state: .kept, at: at(1_440 + 30))
        #expect(override.state == .kept && override.source == .manual && override.overriddenByPerson && override.measuredValue == 90)

        // The source later says something else, and the day is evaluated three more times.
        let later: [Double] = [1_500, 2_040, 6_440]
        for minutes in later {
            let result = try #require(try context.evaluation.evaluate(day: day, now: at(minutes), timeZone: zone,
                                                                       sources: snapshots(food: [.proteinG: .measured(10)])))
            #expect(result.checks.first == override)
            #expect(result.summary.kept >= 1)
            #expect(result.unknownReasons[protein] == nil)
        }
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day) == override)
    }

    @Test func aPersonCanMarkASwitchedOffSourceRuleKeptAndItCountsInTheShare() throws {
        let (context, _) = try setUp()
        let first = try #require(try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone, sources: RoutineSourceSnapshots()))
        #expect(first.summary.keptShare == nil)
        try context.evaluation.override(ruleKey: strength, day: day, state: .kept, at: at(1_500))
        let second = try #require(try context.evaluation.evaluate(day: day, now: at(1_600), timeZone: zone, sources: RoutineSourceSnapshots()))
        #expect(second.summary.kept == 1 && second.summary.unknown == 6 && second.summary.keptShare == 1)
    }

    @Test func aTickAfterAMissedOverrideReplacesIt() throws {
        let (context, id) = try setUp()
        try context.evaluation.override(ruleKey: magnesium, day: day, state: .missed, at: at(21 * 60))
        let tick = try context.evaluation.tick(ruleKey: magnesium, day: day, at: at(22 * 60))
        #expect(tick.state == .kept && !tick.overriddenByPerson)
        #expect(try context.store.check(protocolID: id, ruleKey: magnesium, day: day) == tick)
    }

    @Test func takingBackAnOverrideLetsTheSourceDecideAgain() throws {
        let (context, id) = try setUp()
        let sources = snapshots(food: [.proteinG: .measured(150)])
        _ = try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone, sources: sources)
        try context.evaluation.override(ruleKey: protein, day: day, state: .missed, at: at(1_500))
        let result = try #require(try context.evaluation.untick(ruleKey: protein, day: day, now: at(1_600), timeZone: zone, sources: sources))
        #expect(result.checks.first?.state == .kept && result.checks.first?.overriddenByPerson == false)
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day)?.source == .food)
    }

    @Test func aNewVersionIsEvaluatedAndOlderDaysKeepTheirVersionNumber() throws {
        let (context, id) = try setUp()
        _ = try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone, sources: snapshots(food: [.proteinG: .measured(150)]))
        let second = try context.store.saveVersion(protocolID: id, rules: Array(rules().prefix(2)), at: created.addingTimeInterval(86_400))
        let nextDay = DayIdentity(year: 2026, month: 10, day: 21)
        let nextClock = try #require(RoutineDayClock(day: nextDay, timeZone: zone))
        let result = try #require(try context.evaluation.evaluate(day: nextDay, now: nextClock.start.addingTimeInterval(36_000), timeZone: zone,
                                                                   sources: snapshots(food: [.proteinG: .measured(150)])))
        #expect(result.summary.version == 2 && result.summary.total == 2 && second.number == 2)
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day)?.version == 1)
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: nextDay)?.version == 2)
        // An explicit version evaluates that version's rules.
        let first = try #require(try context.store.version(protocolID: id, number: 1))
        let old = try #require(try context.evaluation.evaluate(day: day, now: at(1_440), timeZone: zone, sources: snapshots(), version: first))
        #expect(old.summary.total == 7 && old.summary.version == 1)
    }

    @Test func aVersionOfAnotherProtocolIsRefused() throws {
        let (context, _) = try setUp()
        let other = ProtocolID()
        let foreign = try context.store.createProtocol(RoutineProtocol(id: other, name: "Other", createdAt: created), rules: [], activate: false)
        #expect(throws: RoutineError.missingVersion) {
            try context.evaluation.evaluate(day: day, now: at(600), timeZone: zone, sources: RoutineSourceSnapshots(), version: foreign)
        }
    }

    @Test func aSummaryOfNoChecksIsEmpty() {
        let summary = RoutineDaySummary(protocolID: ProtocolID(), version: 1, day: day, checks: [])
        #expect(summary.total == 0 && summary.keptShare == nil)
    }

    // MARK: Version in force

    @Test func aPastDayIsScoredAgainstTheVersionThatWasInForceThen() throws {
        let context = try DayTestDatabase()
        let id = ProtocolID()
        let early = clock.start.addingTimeInterval(-10 * 86_400)
        // Version 1 asks for 100 g of protein. Version 2, made at noon on the day itself, asks for 150 g and adds a rule.
        let strict = ProtocolRule(key: protein, title: "Protein", group: .food,
                                  target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 150), source: .food)
        let lenient = ProtocolRule(key: protein, title: "Protein", group: .food,
                                   target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 100), source: .food)
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Mine", createdAt: early), rules: [lenient])
        let dayTwelve = clock.start.addingTimeInterval(12 * 3_600)
        try context.store.saveVersion(protocolID: id, rules: [strict, ProtocolRule(key: "walk", title: "Walk")], at: dayTwelve)
        let sources = snapshots(food: [.proteinG: .measured(120)])

        let before = DayIdentity(year: 2026, month: 10, day: 19)
        let beforeClock = try #require(RoutineDayClock(day: before, timeZone: zone))
        let past = try #require(try context.evaluation.evaluate(day: before, now: beforeClock.end, timeZone: zone, sources: sources))
        #expect(past.summary.version == 1 && past.summary.total == 1 && past.checks.first?.state == .kept, "120 g meets version 1")

        let sameDay = try #require(try context.evaluation.evaluate(day: day, now: clock.end, timeZone: zone, sources: sources))
        #expect(sameDay.summary.version == 2 && sameDay.summary.total == 2, "a version made during the day applies to that day")
        #expect(sameDay.checks.first?.state == .missed, "120 g misses version 2")

        let later = DayIdentity(year: 2026, month: 10, day: 25)
        let laterClock = try #require(RoutineDayClock(day: later, timeZone: zone))
        #expect(try context.evaluation.evaluate(day: later, now: laterClock.end, timeZone: zone, sources: sources)?.summary.version == 2)
    }

    @Test func aDayFromBeforeTheProtocolExistedUsesVersionOne() throws {
        let context = try DayTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Mine", createdAt: clock.start.addingTimeInterval(5 * 86_400)),
                                         rules: [ProtocolRule(key: protein, title: "Protein", group: .food,
                                                              target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 100), source: .food)])
        try context.store.saveVersion(protocolID: id, rules: rules(), at: clock.start.addingTimeInterval(6 * 86_400))
        let result = try #require(try context.evaluation.evaluate(day: day, now: clock.end, timeZone: zone, sources: snapshots()))
        #expect(result.summary.version == 1 && result.summary.total == 1, "migrated history belongs to version 1")
        #expect(try context.store.versionInForce(protocolID: id, at: clock.end) == nil)
        #expect(try context.store.versionInForce(protocolID: id, at: clock.end.addingTimeInterval(6 * 86_400))?.number == 2)
    }
}
