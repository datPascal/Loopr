#if DEBUG
import DomainKit
import Foundation
import HealthKitBridge
import ProfileKit
import RoutineKit
import TodayKit

/// Where the populated fixture's Fitness tab reads its day (DEBUG only). Fitness used to read nothing in the populated
/// launch: no plans, no band days, no profile. So it said "Nothing planned yet" and "The band has no zone data this
/// week yet" beside Today's "Zone 2, 48 of 45 min" and Food's "Upper A is planned" for the same day (R2-UPG-1). Through
/// this seam it reads what the other tabs read:
/// - the clock: Today's pinned clock on the fixture day (`TodayDialLoader.clock`),
/// - the plans: the Train fixture's program, where the fixture day is Upper A, the session Food's allowance names,
/// - the band days: `TodayNoteRailFixture.zoneMinutes`, the minutes Today's dial and Zone 2 rule read,
/// - the rules: the Protocol tab's fixture protocol,
/// - the profile: the launch's one fixture profile, the one Profile edits (`ProductRepositoryContainer.fixtureProfile`),
/// - the recovery: Today's fixture history (`TodayFixtureHistorySeam`).
/// `--loopr-train-fixture` keeps its own Perth world (`AppTrainFixtures`, `FitnessFixtures`), and production reads the
/// app's stores (`FitnessSources.live`).
@MainActor
enum FitnessFixtureDaySeam {
    static func applies(environment: AppEnvironment, repositories: ProductRepositoryContainer?,
                        arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        repositories?.isFixtureComposition != false && environment.composition == .populated
            && !AppTrainFixtures.isRequested(arguments: arguments)
    }

    /// The fixture day the Fitness tab shows, the day Today shows.
    static func day(environment: AppEnvironment) -> DayIdentity {
        environment.productDay(fixture: TodayFixtures.day)
    }

    /// Today's clock on the fixture day.
    static func clock(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> (now: Date, calendar: Calendar) {
        let loader = TodayDialLoader(environment: environment, repositories: repositories, history: EmptyMetricHistoryProvider())
        let clock = loader.clock(for: day(environment: environment))
        return (clock.now, clock.calendar)
    }

    /// The recovery the plan card's chip reads: Today's fixture history.
    static func history(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> (any MetricHistoryProviding)? {
        TodayFixtureHistorySeam.history(environment: environment, repositories: repositories)
    }

    static func sources(environment: AppEnvironment, repositories: ProductRepositoryContainer?,
                        arguments: [String] = ProcessInfo.processInfo.arguments) -> FitnessSources {
        let fixtureDay = day(environment: environment)
        let readRules = protocolRules(environment: environment, arguments: arguments)
        let clock = clock(environment: environment, repositories: repositories)
        let now = clock.now, timeZone = clock.calendar.timeZone
        return FitnessSources(
            bandDay: { day in TodayNoteRailFixture.zoneMinutes(on: day, fixtureDay: fixtureDay, now: now, timeZone: timeZone) },
            // Birth year, sex and VO₂max come from the source the Data tab's ruler reads (R2-OPT-23). The populated
            // launch has no Apple Health store, so there are no VO₂max readings on either tab.
            vo2Max: LooprAgeSource.vo2Max(repositories, arguments: arguments) ?? { _, _ in .absent(.noSamples) },
            profile: LooprAgeSource.fitnessProfile(repositories),
            rules: readRules,
            recorder: FitnessFixtures.recorder)
    }

    /// The Protocol tab's fixture rules, the ones Today's rail and the Protocol tab show.
    static func protocolRules(environment: AppEnvironment, arguments: [String] = ProcessInfo.processInfo.arguments)
        -> @Sendable () async -> [ProtocolRule] {
        let clock = TodayDialFixtureClock.clock(environment: environment, arguments: arguments)
        let store = ProtocolTabFixture.store(now: clock.now, timeZone: clock.calendar.timeZone,
                                             empty: ProtocolTabFixture.startsEmpty(arguments))
        return { (try? store?.activeProtocol())?.latestVersion.rules ?? [] }
    }

    /// The Protocol tab's rules first, then a fixture's own rule only for a metric the protocol has no rule for. The
    /// first matching rule sets a target, so Fitness's zone 2 week follows the protocol's "Zone 2, 150 min a week"
    /// (R2-OPT-16, ICP R3-VET-05) instead of a second, weekly 180 that no tab shows.
    nonisolated static func rules(protocol protocolRules: [ProtocolRule], extras: [ProtocolRule]) -> [ProtocolRule] {
        let metrics = Set(protocolRules.compactMap(\.target.metric))
        return protocolRules + extras.filter { rule in rule.target.metric.map { !metrics.contains($0) } ?? false }
    }

    /// When the seam was first read. One instant per launch, so a timer never restarts when the screen redraws.
    nonisolated static let launchedAt = Date()

    /// The capacity timers run on the fixture's clock from launch, in real seconds.
    static func capacityClock(start: Date) -> @Sendable () -> Date {
        let launchedAt = Self.launchedAt
        return { start.addingTimeInterval(max(0, Date().timeIntervalSince(launchedAt))) }
    }
}
#endif
