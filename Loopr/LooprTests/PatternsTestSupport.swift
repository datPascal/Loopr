import AIKit
import DomainKit
import FoodKit
import Foundation
import JournalKit
import StorageKit
@testable import Loopr

/// Shared pieces for the FT-05.4b suites. Alex lives in Australia/Perth. Every source here is a stub, and nothing
/// touches the network.
enum PatternsFixtures4b {
    static let zone = TimeZone(identifier: "Australia/Perth")!
    static var zoneID: String { zone.identifier }
    /// Fri 16 Oct 2026, 12:00 in Perth.
    static let now = AgentFixtures.now
    static let today = "2026-10-16"

    /// 200 bootstrap replicates instead of 2,000. Gates and thresholds stay at the defaults.
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

    static func lcg(_ seed: UInt32, _ count: Int) -> [UInt32] {
        var state = seed
        return (0..<count).map { _ in state = state &* 1_664_525 &+ 1_013_904_223; return state }
    }
    static func bit(_ value: UInt32) -> Bool { (value >> 24) & 1 == 1 }
    static func noise(_ value: UInt32) -> Double { Double(Int((value >> 16) % 3) - 1) }

    static func outcome(_ key: String, _ metrics: [HabitOutcomeMetricID: Double]) -> HabitOutcomeSnapshot {
        let day = DayIdentity(habitKey: key)!
        let next = DayIdentity(habitKey: PatternDays.add(1, to: key)!)!
        return HabitOutcomeSnapshot(behaviorDay: day, behaviorTimeZoneID: zoneID, sleepSessionID: "night-\(key)", outcomeDay: next,
                                    metrics: metrics, priorDayStrain: nil, sourceVersions: ["fixture": "1"], builtAt: Date(timeIntervalSince1970: 0))
    }

    static let firstKey = "2026-08-17"
    static let sixtyKeys = PatternDays.range(from: "2026-08-17", count: 60)

    /// Sixty nights where eating after 21:00 goes with a sleep score 12 points lower.
    static func lateDinnerData() -> PatternDataBox {
        let late = lcg(11, 60).map(bit), noises = lcg(101, 60).map(noise)
        let box = PatternDataBox()
        box.update {
            $0.food[.lateMeal] = sixtyKeys.enumerated().map { PatternExposureDay(dayKey: $0.element, timeZoneID: zoneID, exposed: late[$0.offset]) }
            for (index, key) in sixtyKeys.enumerated() {
                $0.outcomes[key] = outcome(key, [.sleepScore: 75 - (late[index] ? 12 : 0) + noises[index], .deepSleepMinutes: 80 + 2 * noises[index]])
            }
        }
        return box
    }

    static func found(_ candidate: String, _ habit: String, _ title: String, _ predicate: PatternPredicate, _ metric: HabitOutcomeMetricID,
                      _ strength: PatternStrength, _ difference: Double, with: Int = 9, without: Int = 14) -> FoundPattern {
        FoundPattern(
            candidateID: candidate, habitID: HabitID(rawValue: UUID(uuidString: habit)!), title: title, predicate: predicate, metric: metric,
            strength: strength,
            effect: PatternEffect(adjustedDifference: difference, rawDifference: difference, withMean: nil, withoutMean: nil, intervalLower: nil,
                                  intervalUpper: nil, pValue: 0.004, practicalThreshold: 3, unit: metric.unit),
            nights: PatternNights(with: with, without: without), windowEnd: today, algorithmVersion: "test", foundAt: now)
    }
    static let alcohol = found("journal.00000000-0000-0000-0000-000000005001", "00000000-0000-0000-0000-000000005001", "Alcohol",
                               .journalAnswer(name: "Alcohol"), .hrvRMSSD, .strong, -8)
    static let lateDinner = found("food.lateMeal", "FC100000-0000-4000-8000-000000000001", "Last meal after 21:00",
                                  .food(label: "when you eat after 21:00"), .deepSleepMinutes, .clear, -14, with: 12, without: 38)
    static let legDay = found("legDay", "FC200000-0000-4000-8000-000000000002", "Leg day", .legDay, .restingHeartRate, .clear, 3, with: 4, without: 7)

    static func engine(store: any PatternStore = InMemoryPatternStore(), data: PatternDataBox = PatternDataBox(),
                       reminders: any PatternReminderScheduling = NoPatternReminders(), policy: PatternPolicy = shortPolicy,
                       now: Date = now, recountDelay: Duration = .seconds(2)) -> PatternsEngine {
        PatternsEngine(store: store, provider: LooprPatternExposureProvider(data: data, timeZone: { zone }, policy: policy),
                       reminders: reminders, policy: policy, now: { now }, timeZone: { zone }, recountDelay: recountDelay)
    }
}

/// A stub of everything the app reads, held in a box so a test can change it between runs, as a deletion would.
final class PatternDataBox: PatternSourceData, @unchecked Sendable {
    struct Values {
        var definitions: [HabitDefinition] = []
        var records: [HabitDayRecord] = []
        var food: [FoodAssociationKind: [PatternExposureDay]] = [:]
        var training = PatternTrainingInput()
        var steps: [String: Double] = [:]
        var outcomes: [String: HabitOutcomeSnapshot] = [:]
    }
    private let lock = NSLock()
    private var values = Values()
    private var threads: [Bool] = []
    private var foodCount = 0
    /// How many times discovery asked for the food answers, which is once for each run.
    var foodReads: Int { lock.withLock { foodCount } }
    var read: Values { lock.withLock { values } }
    func update(_ change: (inout Values) -> Void) { lock.withLock { change(&values) } }
    /// Whether each read ran on the main thread.
    var mainThreadReads: [Bool] { lock.withLock { threads } }
    private func note() { lock.withLock { threads.append(Thread.isMainThread) } }

    func journalDefinitions() async throws -> [HabitDefinition] { note(); return read.definitions }
    func journalRecords() async throws -> [HabitDayRecord] { note(); return read.records }
    func foodAnswers(endingOn day: String) async throws -> [FoodAssociationKind: [PatternExposureDay]] {
        note(); lock.withLock { foodCount += 1 }; return read.food
    }
    func training(from firstDay: String, to lastDay: String) async throws -> PatternTrainingInput { note(); return read.training }
    func steps(from firstDay: String, to lastDay: String) async throws -> [String: Double] { note(); return read.steps }
    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet {
        note()
        let all = read.outcomes
        return PatternOutcomeSet(outcomes: records.compactMap { all[$0.behaviorDay.habitKey] })
    }
}

/// Counts what the engine asked the system to schedule.
final class SpyPatternReminders: PatternReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scheduled: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var cancelledAll = 0
    private(set) var askedPermission: [Bool] = []
    var allow = true
    /// What a refusal looks like. `allow = false` means the person refused notifications.
    var refusal: PatternReminderOutcome = .notAllowed
    func schedule(_ test: PatternTest, now: Date, askPermission: Bool) async -> PatternReminderOutcome {
        lock.withLock { scheduled.append(test.id); askedPermission.append(askPermission) }
        return allow ? .scheduled : refusal
    }
    func cancel(testID: UUID) async { lock.withLock { cancelled.append(testID) } }
    func cancelAll() async { lock.withLock { cancelledAll += 1 } }
}
