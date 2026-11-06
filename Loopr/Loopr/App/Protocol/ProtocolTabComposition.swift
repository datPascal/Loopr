import DomainKit
import Foundation
import JournalKit
import RoutineKit

/// Builds the Protocol tab's model from the app's repositories: the production database with the live source
/// snapshots and Patterns, or in DEBUG fixture launches the throwaway fixture protocol.
@MainActor
enum ProtocolTabComposition {
    static func model(repositories: ProductRepositoryContainer?, habits: HabitViewModel) -> ProtocolTabModel {
        let clock = Self.clock(repositories: repositories)
        let model = ProtocolTabModel(source: source(repositories: repositories), habits: habits, timeZone: clock.timeZone,
                                     now: clock.now)
        #if DEBUG
        model.initialSegment = MainTabLaunchState.protocolSegment(ProcessInfo.processInfo.arguments)
            .flatMap(ProtocolSegment.init(rawValue:))
        #endif
        // Files from the share sheet, Files and the Rules segment's importer all pass through the one inbox (LV-07.4).
        let inbox = RoutineFileInbox.shared
        model.openFile = { url in inbox.receive(url) }
        model.attach(incoming: inbox.incoming)
        #if canImport(UserNotifications)
        // Rule reminders only on the person's own protocol, never on a fixture launch.
        if repositories?.persistent != nil { model.reminders = ProtocolRuleNotificationReminders() }
        #endif
        #if DEBUG
        // A fixture launch keeps its reminders in memory, so the tour shows the switch and the bell (ICP R1-HAB-03).
        if model.reminders == nil, repositories?.isFixtureComposition == true { model.reminders = ProtocolRuleFixtureReminders.shared }
        #endif
        return model
    }

    /// The tab's clock and zone: the environment's in production. A fixture launch reads Today's one clock and zone, so
    /// the rosettes, the deck and a saved rule tell the same hour as Today's rail (ICP R3-OPT-1, R3-OPT-2).
    static func clock(repositories: ProductRepositoryContainer?) -> (now: @Sendable () -> Date, timeZone: TimeZone) {
        let environment = repositories?.environment
        let timeZoneProvider: any TimeZoneProviding = environment?.timeZoneProvider ?? SystemTimeZoneProvider()
        let dateProvider: any DateProviding = environment?.dateProvider ?? SystemDateProvider()
        #if DEBUG
        if let repositories, repositories.isFixtureComposition {
            let clock = TodayDialFixtureClock.clock(environment: repositories.environment)
            let pinned = clock.now
            return ({ pinned }, clock.calendar.timeZone)
        }
        #endif
        return ({ dateProvider.now() }, timeZoneProvider.timeZone)
    }

    /// Reads which Journal habits are protocol rules now, so the Journal's screens leave their questions out (ICP
    /// R1-UPG-1). Nil without the production database: fixtures carry no moved habits.
    static func ruleHabitIDs(_ repositories: ProductRepositoryContainer?) -> (@Sendable () async -> Set<HabitID>)? {
        guard let database = repositories?.persistent?.database else { return nil }
        return { RoutineHabitAnswerMirror.habitIDsWithRules(database: database) }
    }

    static func source(repositories: ProductRepositoryContainer?) -> any ProtocolTabSource {
        if let repositories, let persistent = repositories.persistent {
            let environment = repositories.environment
            let provider = RoutineSourceProvider.live(
                food: AppFoodRepository(store: persistent.food, environment: environment), sleep: persistent.sleep,
                readTraining: { @Sendable [store = persistent.workouts] in try await store.journalAutoFillRecords() },
                analytics: persistent.analytics, appleHealth: persistent.healthSync.appleHealthSources())
            let timeZoneProvider = environment.timeZoneProvider
            let engine: PatternsEngine? = LooprPatternsRuntime.isEnabled ? (try? LooprPatternsRuntime.shared.configure(persistent)) : nil
            let database = persistent.database
            let habitStore = persistent.habits
            #if canImport(UserNotifications)
            // The rule reminders count what the sources saw this week too (ICP round 4, Q5).
            Task { await ProtocolRuleReminderPlanning.shared.attach { day, zone, now in
                try await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now)
            } }
            let answered: (@Sendable (RuleKey) async -> Void)? = { key in await ProtocolRuleReminderPlanning.shared.answered(key) }
            #else
            let answered: (@Sendable (RuleKey) async -> Void)? = nil
            #endif
            return ProtocolTabLoader(
                store: RoutineStore(database: database),
                timeZone: { timeZoneProvider.timeZone },
                snapshots: { day, zone, now in try await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now) },
                prepare: { now in _ = await RoutineJournalMigration.runOnce(database: database, habits: habitStore, now: now) },
                patterns: { now in await ProtocolTabPatterns.state(engine: engine, now: now) },
                experiments: ExperimentStore(database: database),
                experimentInputs: ProtocolExperimentInputs.live(history: LooprMetricHistory.shared,
                                                                timeZone: { timeZoneProvider.timeZone }),
                habits: habitStore,
                answered: answered)
        }
        #if DEBUG
        if let repositories, repositories.isFixtureComposition {
            let environment = repositories.environment
            let zone = TodayDialFixtureClock.timeZone
            let patternsEnabled = LooprPatternsRuntime.isEnabled
            if let stores = ProtocolTabFixture.stores(environment: environment) {
                return ProtocolTabLoader(
                    store: stores.routine,
                    timeZone: { zone },
                    snapshots: { day, zone, now in ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now) },
                    prepare: nil,
                    patterns: { _ in
                        var engine: PatternsEngine?
                        if patternsEnabled { engine = await fixturePatternsEngine() }
                        return await ProtocolTabPatterns.state(engine: engine, now: PatternsFixtures.fixedNow)
                    },
                    experiments: stores.experiments,
                    experimentInputs: { experiment in ProtocolTabFixture.experimentInputs(experiment) })
            }
        }
        #endif
        return UnavailableProtocolSource()
    }

    #if DEBUG
    /// The launch's one Patterns fixture, shared with the Patterns screen.
    private static func fixturePatternsEngine() async -> PatternsEngine {
        await PatternsFixtures.shared().engine
    }
    #endif
}

/// The source when no database is open, such as after a storage failure. Every read says so and every write fails.
nonisolated struct UnavailableProtocolSource: ProtocolTabSource {
    func load(now: Date) async -> ProtocolTabContent {
        ProtocolTabContent(routine: .unavailable(ProtocolTabLoader.unavailableMessage))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws { throw RoutineError.missingProtocol }
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws { throw RoutineError.missingProtocol }
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws { throw RoutineError.missingProtocol }
}
