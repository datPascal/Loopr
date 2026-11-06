import DomainKit
import Foundation
import JournalKit

/// Alex lives in Perth. Every fixture below is deterministic: a small linear
/// congruential generator stands in for "random" nights, so a failure repeats.
enum PatternFixtures {
    static let zoneID = "Australia/Perth"
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID)!
        return calendar
    }
    static var zone: TimeZone { TimeZone(identifier: zoneID)! }

    /// A Perth wall-clock time on a day key.
    static func date(_ key: String, hour: Int = 12, minute: Int = 0) -> Date {
        let day = DayIdentity(habitKey: key)!
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    static func lcg(_ seed: UInt32, _ count: Int) -> [UInt32] {
        var state = seed
        return (0..<count).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return state }
    }
    static func bit(_ value: UInt32) -> Bool { (value >> 24) & 1 == 1 }
    static func noise(_ value: UInt32) -> Double { Double(Int((value >> 16) % 3) - 1) }

    /// Fast statistics: 200 bootstrap replicates instead of 2,000. Gates and thresholds are the defaults.
    static var shortPolicy: PatternPolicy {
        let p = HabitImpactPolicy.default
        return PatternPolicy(impact: HabitImpactPolicy(
            algorithmVersion: p.algorithmVersion, windowDays: p.windowDays, earlyPerGroup: p.earlyPerGroup,
            maturePerGroup: p.maturePerGroup, matureEligibleDays: p.matureEligibleDays,
            minimumAdjustedRows: p.minimumAdjustedRows, trailingBaselineDays: p.trailingBaselineDays,
            minimumBaselineDays: p.minimumBaselineDays, ridgeLambda: p.ridgeLambda, bootstrapReplicates: 200,
            bootstrapBlockDays: p.bootstrapBlockDays, overlapPhiThreshold: p.overlapPhiThreshold,
            minimumDiscordantDays: p.minimumDiscordantDays, practicalThresholds: p.practicalThresholds))
    }

    static func outcome(_ key: String, _ metrics: [HabitOutcomeMetricID: Double]) -> HabitOutcomeSnapshot {
        let day = DayIdentity(habitKey: key)!
        let next = DayIdentity(habitKey: PatternDays.add(1, to: key)!)!
        return HabitOutcomeSnapshot(
            behaviorDay: day, behaviorTimeZoneID: zoneID, sleepSessionID: "night-\(key)",
            outcomeDay: next, metrics: metrics, priorDayStrain: nil, sourceVersions: ["fixture": "1"],
            builtAt: date(key, hour: 23))
    }

    // MARK: Discovery dataset

    static let discoveryFirstDay = "2026-08-02"
    static let discoveryDays = 60
    static var discoveryKeys: [String] { PatternDays.range(from: discoveryFirstDay, count: discoveryDays) }
    static let discoveryEnd = "2026-09-30"

    static let lateDinner = PatternCandidate.food(
        id: "lateMeal", habitID: HabitID(rawValue: UUID(uuidString: "FC100000-0000-4000-8000-000000000001")!),
        title: "Late dinner", label: "a late dinner", metrics: [.sleepScore, .deepSleepMinutes])
    static let alcoholDefinition = HabitDefinition(
        id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000005001")!), source: .custom,
        name: "Alcohol", question: "Did you have alcohol?", sortOrder: 0, createdAt: date("2026-08-01"))
    static var alcohol: PatternCandidate { .journalHabit(alcoholDefinition, metrics: [.hrvRMSSD, .sleepScore]) }
    static var steps: PatternCandidate { .steps() }
    static var trainingHabit: HabitID { PatternCandidate.trainingDay.habitID }

    /// Alex's sixty nights.
    /// - late dinner: sleep score 12 points lower (strong)
    /// - alcohol: HRV 7 ms lower (clear, under twice the 5 ms threshold)
    /// - training and leg day: identical answers, so the engine cannot separate them
    /// - steps over 10,000: only the last twelve days are answered, 30 minutes more sleep (early)
    struct Discovery {
        let late: [Bool], drinks: [Bool], trained: [Bool]
        let stepsFromIndex = 48
        init() {
            late = lcg(11, discoveryDays).map(bit)
            drinks = lcg(23, discoveryDays).map(bit)
            trained = lcg(37, discoveryDays).map(bit)
        }
        func steppedOver(_ index: Int) -> Bool? { index >= stepsFromIndex ? (index - stepsFromIndex).isMultiple(of: 2) : nil }

        func series(includeSteps: Bool = true, includeTrainingPair: Bool = true) -> [PatternExposureSeries] {
            let keys = discoveryKeys
            func make(_ candidate: PatternCandidate, _ values: [Bool]) -> PatternExposureSeries {
                .init(candidateID: candidate.id, days: values.enumerated().map {
                    PatternExposureDay(dayKey: keys[$0.offset], timeZoneID: zoneID, exposed: $0.element)
                })
            }
            var all = [make(lateDinner, late), make(alcohol, drinks)]
            if includeTrainingPair { all += [make(.trainingDay, trained), make(.legDay, trained)] }
            if includeSteps {
                all.append(.init(candidateID: steps.id, days: (stepsFromIndex..<discoveryDays).map {
                    PatternExposureDay(dayKey: keys[$0], timeZoneID: zoneID, exposed: steppedOver($0)!)
                }))
            }
            return all
        }

        func outcomes() -> [String: HabitOutcomeSnapshot] {
            let keys = discoveryKeys
            let sleepNoise = lcg(101, discoveryDays).map(noise), deepNoise = lcg(102, discoveryDays).map(noise)
            let hrvNoise = lcg(103, discoveryDays).map(noise), durationNoise = lcg(104, discoveryDays).map(noise)
            var out: [String: HabitOutcomeSnapshot] = [:]
            for index in 0..<discoveryDays {
                out[keys[index]] = PatternFixtures.outcome(keys[index], [
                    .sleepScore: 75 - (late[index] ? 12 : 0) + sleepNoise[index],
                    .deepSleepMinutes: 80 + 2 * deepNoise[index],
                    .hrvRMSSD: 60 - (drinks[index] ? 7 : 0) + 2 * hrvNoise[index],
                    .sleepDuration: 420 + ((steppedOver(index) ?? false) ? 30 : 0) + 3 * durationNoise[index]
                ])
            }
            return out
        }
    }

    struct AlexProvider: PatternExposureProvider {
        let candidatesToReturn: [PatternCandidate]
        let seriesToReturn: [PatternExposureSeries]
        let outcomesByDay: [String: HabitOutcomeSnapshot]

        func candidates() async throws -> [PatternCandidate] { candidatesToReturn }
        func exposures(endingOn day: String, windowDays: Int) async throws -> [PatternExposureSeries] {
            seriesToReturn.map { entry in .init(candidateID: entry.candidateID, days: entry.days.filter { $0.dayKey <= day }) }
        }
        func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
            .init(outcomes: records.compactMap { outcomesByDay[$0.behaviorDay.habitKey] })
        }
    }

    static func discoveryProvider(includeTrainingPair: Bool = true, includeSteps: Bool = true) -> AlexProvider {
        let data = Discovery()
        var candidates = [lateDinner, alcohol]
        if includeTrainingPair { candidates += [.trainingDay, .legDay] }
        if includeSteps { candidates.append(steps) }
        return AlexProvider(candidatesToReturn: candidates,
                            seriesToReturn: data.series(includeSteps: includeSteps, includeTrainingPair: includeTrainingPair),
                            outcomesByDay: data.outcomes())
    }

    // MARK: Test dataset

    /// Alex starts a test on Sunday 20 September 2026. Day 1 is that Sunday.
    static let testStart = "2026-09-20"
    static var baselineKeys: [String] { PatternDays.range(from: PatternDays.add(-30, to: testStart)!, count: 30) }
    static var testKeys: [String] { PatternDays.range(from: testStart, count: 14) }

    static func startTest(candidate: PatternCandidate = .trainingDay, metric: HabitOutcomeMetricID = .sleepScore,
                          id: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000A1E01")!) throws -> PatternTest {
        try PatternTest.start(candidate: candidate, metric: metric, now: date(testStart, hour: 20, minute: 15),
                              timeZone: zone, reminder: PatternReminder(), id: id)
    }

    /// The test's own metric reads 70 on baseline and missed nights and 80 on kept nights, plus one point of noise
    /// either way. `decoys` are other metrics that move by `delta` on kept nights, which a verdict must ignore.
    static func testOutcomes(test: PatternTest, keptDays: Set<String>,
                             decoys: [HabitOutcomeMetricID: Double] = [:], ownEffect: Double = 10) -> [String: HabitOutcomeSnapshot] {
        let keys = test.baselineDayKeys + test.testDayKeys
        let noises = lcg(201, keys.count).map(noise)
        var out: [String: HabitOutcomeSnapshot] = [:]
        for (index, key) in keys.enumerated() {
            let kept = keptDays.contains(key)
            var metrics: [HabitOutcomeMetricID: Double] = [test.outcomeMetric: 70 + (kept ? ownEffect : 0) + noises[index]]
            for (metric, delta) in decoys { metrics[metric] = 60 + (kept ? delta : 0) + noises[index] }
            out[key] = outcome(key, metrics)
        }
        return out
    }

    struct OutcomeOnly: PatternOutcomeProviding {
        let byDay: [String: HabitOutcomeSnapshot]
        func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
            .init(outcomes: records.compactMap { byDay[$0.behaviorDay.habitKey] })
        }
    }

    // MARK: Synthetic engine output

    static func metric(
        _ id: HabitOutcomeMetricID, status: HabitInsightStatus, adjusted: Double? = 8, raw: Double? = 9,
        p: Double? = 0.001, bootstrapP: Double? = nil, yes: Int = 14, no: Int = 30, overlapping: HabitID? = nil
    ) -> HabitMetricEstimate {
        HabitMetricEstimate(
            metricID: id, yesMean: 80, noMean: 70, rawDifference: raw, adjustedDifference: adjusted,
            intervalLower: 1, intervalUpper: 2, bootstrapPValue: bootstrapP, adjustedPValue: p,
            adjustedRowCount: 37, isClear: status == .clearAssociation,
            sample: HabitMetricSample(yesCount: yes, noCount: no, status: status, overlappingHabitID: overlapping,
                                      validThrough: DayIdentity(habitKey: discoveryEnd)!))
    }

    static func estimate(habit: HabitID, metrics: [HabitMetricEstimate]) -> HabitImpactEstimate {
        HabitImpactEstimate(
            habitID: habit, status: .clearAssociation, yesCount: 14, noCount: 30, eligibleDayCount: 44,
            excludedDayCount: 0, metrics: metrics, windowStart: DayIdentity(habitKey: "2026-08-02")!,
            windowEnd: DayIdentity(habitKey: discoveryEnd)!, calculatedAt: date(discoveryEnd, hour: 21))
    }
}
