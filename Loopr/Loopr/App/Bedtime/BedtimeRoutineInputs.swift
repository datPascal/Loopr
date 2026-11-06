import DomainKit
import Foundation
import RoutineKit

/// The production inputs for the bedtime activity, over the routine store. The composition builds one and hands it to
/// `BedtimeActivityRuntime.shared.setProvider(_:)`:
///
///     await BedtimeActivityRuntime.shared.setProvider(BedtimeRoutineInputs(
///         store: routineStore, sources: routineSources,
///         plannedBedtimeMinute: { now, zone in <Sleep's tonight plan, minutes after midnight> },
///         sleepStart: { since, now in <the band's main sleep start on or after `since`> }))
///
/// Rules come from the active protocol's newest version. Checks come from `RoutineDayEvaluation`, the same call Today's
/// rail makes, so a rule the person ticks there reads as done here after `BedtimeActivityRuntime.reconcile()`.
nonisolated struct BedtimeRoutineInputs: BedtimeActivityInputProviding {
    let store: RoutineStore
    let sources: RoutineSourceProvider
    let plannedBedtimeMinute: @Sendable (Date, TimeZone) async -> Int?
    let sleepStartReader: @Sendable (Date, Date) async -> Date?

    init(store: RoutineStore, sources: RoutineSourceProvider,
         plannedBedtimeMinute: @escaping @Sendable (Date, TimeZone) async -> Int? = { _, _ in nil },
         sleepStart: @escaping @Sendable (Date, Date) async -> Date? = { _, _ in nil }) {
        self.store = store
        self.sources = sources
        self.plannedBedtimeMinute = plannedBedtimeMinute
        sleepStartReader = sleepStart
    }

    func tonight(now: Date, timeZone: TimeZone) async -> BedtimeTonight {
        let rules = (try? store.activeProtocol())?.latestVersion.rules ?? []
        return BedtimeTonight(rules: rules, plannedBedtimeMinute: await plannedBedtimeMinute(now, timeZone))
    }

    func checks(day: DayIdentity, now: Date, timeZone: TimeZone) async -> [RuleCheck] {
        guard let snapshots = try? await sources.snapshots(for: day, timeZoneID: timeZone.identifier, now: now) else { return [] }
        let result = try? RoutineDayEvaluation(store: store).evaluate(day: day, now: now, timeZone: timeZone, sources: snapshots)
        return result?.checks ?? []
    }

    func sleepStart(since: Date, now: Date) async -> Date? { await sleepStartReader(since, now) }
}
