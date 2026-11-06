import DomainKit
import Foundation
import TrainKit
import WorkoutKit

// Fitness round 2 (R2-VET-04, R2-NEW-14): the workout detail splits heart rate by zone and says what the session
// counted for its week. Both come from the sources the Fitness tab's dose reads, so the detail and the dose agree:
// the same zones for the day, the band's minutes winning on a day it covered, and the dose's strength and mobility
// classification.

/// Answers the detail's questions from `FitnessSources`.
nonisolated struct HealthWorkoutDetailContextProvider: WorkoutDetailContextProviding {
    let sources: FitnessSources
    let now: @Sendable () -> Date
    let calendar: Calendar

    func context(for workout: WorkoutRecord) async -> WorkoutDetailContext {
        let now = now()
        let start = workout.startedAt ?? workout.createdAt
        let dayStart = calendar.startOfDay(for: start)
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: start)
        let day = DayIdentity(era: parts.era ?? 1, year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        let bandCovered = FitnessInputMapping.zones(await sources.bandDay?(day)) != nil
        let zones = await sources.heartRateZones?(dayStart)
        let thisWeek = ISOWeek(containing: now, calendar: calendar).map { start >= $0.start && start < $0.end } ?? false
        return WorkoutDetailContext(now: now, calendar: calendar, zones: zones, bandCoveredDay: bandCovered,
                                    sessionKind: Self.sessionKind(workout), isThisWeek: thisWeek)
    }

    /// The dose's classification (`FitnessInputMapping.sessions`): an imported workout's own activity name counts when it
    /// names strength or mobility, otherwise the record's type.
    static func sessionKind(_ workout: WorkoutRecord) -> WorkoutWeekSessionKind? {
        let imported = workout.importedSummary?.activityName.flatMap(DoseSessionKind.classify(activity:))
        switch imported ?? DoseSessionKind.classify(activity: workout.activity.rawValue) {
        case .strength: return .strength
        case .mobility: return .mobility
        case nil: return nil
        }
    }

    /// The sources and clock the Fitness tab uses in this composition: the Fitness fixture with the Train fixture,
    /// production storage otherwise. Other fixture launches get no readings, so the detail shows no zone minutes.
    @MainActor
    static func make(repositories: ProductRepositoryContainer?) -> HealthWorkoutDetailContextProvider {
        var calendar = Calendar(identifier: .gregorian)
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() {
            return HealthWorkoutDetailContextProvider(sources: FitnessFixtures.sources, now: { AppTrainFixtures.now },
                                                      calendar: AppTrainFixtures.calendar)
        }
        #endif
        calendar.timeZone = repositories?.environment.timeZoneProvider.timeZone ?? .current
        let clock = repositories?.environment.dateProvider
        let now: @Sendable () -> Date = { clock?.now() ?? Date() }
        guard repositories?.isFixtureComposition == false, let persistent = repositories?.persistent else {
            return HealthWorkoutDetailContextProvider(sources: FitnessSources(), now: now, calendar: calendar)
        }
        return HealthWorkoutDetailContextProvider(sources: .live(persistent), now: now, calendar: calendar)
    }
}
