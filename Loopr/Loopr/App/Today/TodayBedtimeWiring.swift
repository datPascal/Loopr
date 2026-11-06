import DomainKit
import Foundation
import RoutineKit
import SleepKit
import TodayKit

/// Hands the bedtime Live Activity runtime (DEC-12.17) its production inputs: the routine store behind Today's rail,
/// the same source snapshots, tonight's planned bedtime from Sleep and the night's start from the band. Today calls it
/// on every load; it attaches once per storage generation. Fixture compositions attach nothing, so a UI test never
/// starts a real activity unless the bedtime probe asks for one.
@MainActor
enum TodayBedtimeWiring {
    private static var attachedGeneration: UInt64?

    static func attachIfNeeded(environment: AppEnvironment, repositories: ProductRepositoryContainer?) {
        guard let repositories, let persistent = repositories.persistent,
              attachedGeneration != repositories.storageGeneration else { return }
        attachedGeneration = repositories.storageGeneration
        let wiring = TodayRoutineWiring.make(environment: environment, repositories: repositories, persistent: persistent)
        let sleep = persistent.sleep
        let detail = SleepNightDetails.detailSource(environment: environment, repositories: repositories)
        let inputs = BedtimeRoutineInputs(
            store: wiring.store, sources: wiring.provider,
            plannedBedtimeMinute: { now, zone in
                await plannedBedtime(now: now, zone: zone, sleep: sleep, goal: { await detail?.sleepGoalMinutes() })
            },
            sleepStart: { since, now in await nightStart(since: since, now: now, sleep: sleep) })
        Task { await BedtimeActivityRuntime.shared.setProvider(inputs) }
    }

    /// Sleep's plan for tonight, as minutes after midnight, the same plan the dial's evening centre counts down to.
    nonisolated static func plannedBedtime(now: Date, zone: TimeZone, sleep: any SleepRepository,
                                           goal: @Sendable () async -> Double?) async -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = TodayNoteRailMapping.day(now, calendar: calendar)
        guard let snapshot = try? await sleep.readSleepDay(for: day) else { return nil }
        let insights = SleepNightInsights(snapshot: snapshot, goalMinutes: await goal(), calendar: calendar)
        return TodayDialInputMapping.tonight(insights.tonight)?.bedtimeMinuteOfDay
    }

    /// When the band saw tonight's main sleep start, on or after `since` and not after `now`.
    nonisolated static func nightStart(since: Date, now: Date, sleep: any SleepRepository) async -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = TodayNoteRailMapping.day(now, calendar: calendar)
        for day in [today, today.adding(days: 1)].compactMap({ $0 }) {
            guard let main = try? await sleep.readSleepDay(for: day)?.mainSleep, main.start >= since, main.start <= now else { continue }
            return main.start
        }
        return nil
    }
}
