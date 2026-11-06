#if DEBUG
import BodyKit
import DomainKit
import Foundation
import HealthKitBridge
import ProfileKit
import RoutineKit
import TrainKit

/// Fitness data on top of the Train fixture (`--loopr-train-fixture`): Alex, 38, male reference curve,
/// Tuesday 2023-11-14 in Perth, ISO week 46. The band measured Monday (64 zone 2 minutes, 16 hard ones);
/// Tuesday's 48 zone 2 minutes come from a Garmin ride in Apple Health (`HealthWorkoutFixtures`), so the week
/// has 112 and 16, labelled "Band and Apple Health"; Apple Watch gave a 42-day VO₂max median of 44.1, up 2.6 on a year ago; the four
/// capacity tests were last done on 16 October and the protocol retests them monthly. Balance is under
/// Alex's own goal for 85. Everything here stays in memory and never reaches production storage.
///
/// `--loopr-fitness-fixture=absent` keeps the Train fixture and takes every Fitness source away, so the
/// tab shows its absent states.
nonisolated enum FitnessFixtures {
    static let argument = "--loopr-fitness-fixture"
    static let absentArgument = "--loopr-fitness-fixture=absent"

    static func isAbsentRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(absentArgument)
    }

    static var sources: FitnessSources {
        if isAbsentRequested() { return FitnessSources(vo2Max: { _, _ in .absent(.noSamples) }, recorder: absentRecorder) }
        return FitnessSources(
            bandDay: { day in bandDays[day] },
            vo2Max: { _, _ in .values(vo2MaxSamples) },
            profile: { FitnessProfile(birthYear: 1985, biologicalSex: .male) },
            rules: { rules },
            recorder: recorder,
            appleHealthWorkouts: { from, to in HealthWorkoutFixtures.records(from: from, to: to) },
            heartRateZones: { _ in HealthWorkoutFixtures.zones })
    }

    /// The fixture's capacity results and goals, in memory for the life of the launch, so a test saved in
    /// a UI test shows in its tile.
    static let recorder = FitnessFixtureCapacityRecorder(capacity)
    static let absentRecorder = FitnessFixtureCapacityRecorder(FitnessCapacityRecords())
    /// An empty capacity store for the life of a fixture launch without the Train fixture (onboarding, empty and the
    /// rest), so their first test saves (R3-NEW-4).
    static let launchRecorder = FitnessFixtureCapacityRecorder(FitnessCapacityRecords())

    /// The fixture's clock for the capacity timers: it starts at the fixture's Tuesday 10:00 and runs in
    /// real time from launch, so a timed test still takes real seconds.
    static let launchedAt = Date()
    /// `launchedAt` is lazy, so the first read can start it after `Date()` was taken; never run backwards.
    static let clock: @Sendable () -> Date = {
        let started = launchedAt
        return now.addingTimeInterval(max(0, Date().timeIntervalSince(started)))
    }

    private static var calendar: Calendar { AppTrainFixtures.calendar }
    private static var now: Date { AppTrainFixtures.now }

    private static func day(_ value: Int) -> DayIdentity { DayIdentity(year: 2023, month: 11, day: value) }

    private static func zones(_ zone2: Double, _ zone4: Double, _ zone5: Double) -> [BodyZoneMinutes] {
        let names = ["Recovery", "Aerobic", "Tempo", "Threshold", "Peak"]
        let minutes = [38, zone2, 22, zone4, zone5]
        return minutes.enumerated().map { BodyZoneMinutes(id: $0.offset + 1, name: names[$0.offset], minutes: $0.element) }
    }

    /// Monday: 64 zone 2 minutes, 16 in zones 4 and 5. The band was not worn on Tuesday.
    static let bandDays: [DayIdentity: [BodyZoneMinutes]] = [
        day(13): zones(64, 10, 6)
    ]

    private static func sample(_ value: Double, daysAgo: Double, yearsAgo: Int = 0) -> AppleHealthSample {
        let base = calendar.date(byAdding: .year, value: -yearsAgo, to: now) ?? now
        let date = base.addingTimeInterval(-daysAgo * 86_400)
        return AppleHealthSample(kind: .vo2Max, value: value, original: AppleHealthOriginalReading(value: value, unit: .mlPerKgPerMin),
                                 start: date, end: date,
                                 provenance: AppleHealthProvenance(sourceName: "Alex's Apple Watch",
                                                                   sourceBundleIdentifier: "com.apple.health.81C9A3F2",
                                                                   deviceName: "Apple Watch", deviceModel: "Watch"))
    }

    /// Today's window has a median of 44.1; the window a year ago has 41.5.
    static var vo2MaxSamples: [AppleHealthSample] {
        [sample(41.3, daysAgo: 30, yearsAgo: 1), sample(41.5, daysAgo: 15, yearsAgo: 1), sample(41.7, daysAgo: 1, yearsAgo: 1),
         sample(43.8, daysAgo: 35), sample(44.1, daysAgo: 20), sample(44.4, daysAgo: 3)]
    }

    private static func rule(_ key: String, _ title: String, metric: String, value: Double, unit: String,
                             group: RuleGroup = .fitness, source: CheckSource = .fitness,
                             cadence: RuleCadence? = RuleCadence(unit: .week)) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, group: group,
                     target: RuleTarget(kind: .atLeast, metric: metric, value: value, unit: unit), source: source,
                     cadence: cadence)
    }

    static var rules: [ProtocolRule] {
        [rule("zone2", "Zone 2 minutes", metric: DoseTargets.zone2MinutesMetric, value: 180, unit: "min", source: .band),
         rule("hard", "Hard minutes", metric: DoseTargets.zone45MinutesMetric, value: 20, unit: "min", source: .band),
         rule("strength", "Strength sessions", metric: DoseTargets.strengthSessionsMetric, value: 3, unit: "sessions"),
         rule("mobility", "Mobility sessions", metric: DoseTargets.mobilitySessionsMetric, value: 3, unit: "sessions")]
            + CapacityTestKind.allCases.filter(\.isRetestable).map { kind in
                rule("test-\(kind.rawValue)", kind.title, metric: kind.ruleMetric, value: 1, unit: "month", group: .tests,
                     source: .manual, cadence: nil)
            }
    }

    /// 16 October 2023, 08:00 in Perth.
    private static let tested = Date(timeIntervalSince1970: 1_697_414_400)

    static var capacity: FitnessCapacityRecords {
        let zone = AppTrainFixtures.zone.identifier
        let results = [
            try? CapacityResult(kind: .grip, value: 52, side: .right, recordedAt: tested, timeZoneIdentifier: zone),
            try? CapacityResult(kind: .grip, value: 49, side: .left, recordedAt: tested, timeZoneIdentifier: zone),
            try? CapacityResult(kind: .deadHang, value: 84, recordedAt: tested, timeZoneIdentifier: zone),
            try? CapacityResult(kind: .sitToStand, value: 10, recordedAt: tested, timeZoneIdentifier: zone),
            try? CapacityResult(kind: .oneLegBalance, value: 18, side: .left, recordedAt: tested, timeZoneIdentifier: zone),
            // Monday's Lower A, a minute after it ended.
            try? CapacityResult(id: AppTrainFixtures.lowerAWorkoutID, kind: .heartRateRecovery, value: 28,
                                recordedAt: AppTrainFixtures.lowerAEnd, timeZoneIdentifier: zone, source: .workout,
                                workoutID: AppTrainFixtures.lowerAWorkoutID, algorithmVersion: "loopr.workout-hrr.1")
        ].compactMap { $0 }
        let goals = [
            try? CapacityGoal(kind: .grip, targetValue: 30, setAt: tested),
            try? CapacityGoal(kind: .oneLegBalance, targetValue: 30, setAt: tested)
        ].compactMap { $0 }
        return FitnessCapacityRecords(results: results, goals: Dictionary(uniqueKeysWithValues: goals.map { ($0.kind, $0) }))
    }
}

/// Capacity results and goals in memory, for fixture launches and tests.
actor FitnessFixtureCapacityRecorder: FitnessCapacityRecording {
    private var stored: FitnessCapacityRecords

    init(_ records: FitnessCapacityRecords) { stored = records }

    func records() -> FitnessCapacityRecords { stored }

    func save(_ results: [CapacityResult]) throws {
        for result in results {
            stored.results.removeAll { $0.id == result.id }
            stored.results.append(result)
        }
    }

    func save(_ goal: CapacityGoal) throws { stored.goals[goal.kind] = goal }
}
#endif
