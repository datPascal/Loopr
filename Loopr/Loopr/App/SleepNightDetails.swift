import DomainKit
import Foundation
import ProfileKit
import SleepKit

/// What the Sleep tab reads beside the night's snapshot in production: the
/// night's heart rate from the history database and the saved sleep need from
/// the profile. Both reads run off the main actor.
nonisolated struct AppSleepNightDetailSource: SleepNightDetailSource {
    let analytics: CanonicalDailyAnalytics
    let goals: (any GoalsRepository)?

    func overnightHeartRate(from start: Date, to end: Date) async -> [SleepHeartRateMinute] {
        guard end > start else { return [] }
        return (try? await analytics.overnightHeartRate(from: start, to: end)) ?? []
    }

    /// The sleep need the person saved, or nil before they save one. Every reader then falls back to the same 8 h, but
    /// Sleep calls it the default rather than "your" need (Data ICP R4-SW-02).
    func sleepGoalMinutes() async -> Double? {
        guard let goals, let all = try? await goals.readGoals(),
              all.contains(where: { $0.type == .sleep && $0.isEnabled }) else { return nil }
        return SleepNeed.minutes(from: all)
    }
}

/// Reads a sleep goal the way the Today goals adapter does: an enabled goal of
/// type sleep, in hours or minutes. Any other unit is ignored rather than
/// guessed at.
nonisolated enum SleepGoalReading {
    static func minutes(_ goals: [Goal]) -> Double? {
        SleepNeed.minutes(from: goals)
    }
}

/// Per-minute heart rate for one night, from per-second rows.
nonisolated enum SleepHeartRateReading {
    /// Longest night the reader will fetch, so a broken window cannot pull a
    /// day of rows onto a screen.
    static let maximumSpan: TimeInterval = 16 * 3_600

    /// Folds `(timestamp, bpm)` rows into one mean per whole minute. Rows
    /// with no heart rate (0 or less) are skipped, never averaged in as zero.
    static func minutes(_ rows: [(timestamp: Int64, bpm: Double)]) -> [SleepHeartRateMinute] {
        var sums: [Int64: (total: Double, count: Int)] = [:]
        for row in rows where row.bpm > 0 && row.bpm.isFinite {
            let minute = row.timestamp / 60
            let current = sums[minute] ?? (0, 0)
            sums[minute] = (current.total + row.bpm, current.count + 1)
        }
        return sums.keys.sorted().compactMap { minute in
            guard let value = sums[minute], value.count > 0 else { return nil }
            return SleepHeartRateMinute(date: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
                                        bpm: value.total / Double(value.count))
        }
    }
}

/// Builds the Sleep view model for the tab and its detail screens.
@MainActor
enum SleepNightDetails {
    static func viewModel(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> SleepViewModel {
        if let persistent = repositories?.persistent {
            return SleepViewModel(repository: persistent.sleep, correctionRepository: persistent.sleep,
                                  detailSource: detailSource(environment: environment, repositories: repositories))
        }
        let isFixture = repositories?.isFixtureComposition != false
        // The populated fixture carries one correction so its Corrections
        // row and screen can be seen and tested; every other composition
        // starts with an empty audit trail.
        let seed = isFixture && environment.composition == .populated ? SleepFixtures.corrections : []
        return SleepViewModel(repository: repository(environment: environment, repositories: repositories),
                              correctionRepository: InMemorySleepCorrectionRepository(seed: seed),
                              detailSource: detailSource(environment: environment, repositories: repositories))
    }

    /// The saved sleep need and heart-rate reader the Sleep tab uses. Fixture launches use the fixture source.
    static func detailSource(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> (any SleepNightDetailSource)? {
        if let persistent = repositories?.persistent {
            return AppSleepNightDetailSource(analytics: persistent.analytics, goals: persistent.profile)
        }
        return repositories?.isFixtureComposition != false ? SleepFixtures.DetailSource() : nil
    }

    /// The plan the Sleep tab's Tonight card shows for `day`, worked out the way the Sleep view model does it.
    /// Nil with fewer than three recent nights or no night read.
    static func tonightPlan(day: DayIdentity, environment: AppEnvironment, repositories: ProductRepositoryContainer?) async -> SleepTonightPlan? {
        let source = repository(environment: environment, repositories: repositories)
        guard let snapshot = try? await source.readSleepDay(for: day) else { return nil }
        let goal = await detailSource(environment: environment, repositories: repositories)?.sleepGoalMinutes()
        return SleepNightInsights(snapshot: snapshot, goalMinutes: goal).tonight
    }

    /// The night reader for this composition: the database in production, the fixture night otherwise. Today's
    /// timeline reads the wake time from it, and the Sleep tab shows the same nights.
    static func repository(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> any SleepRepository {
        if let persistent = repositories?.persistent { return persistent.sleep }
        let snapshot = SleepFixtures.snapshot(for: ProductFixture.metricState(for: environment.composition))
        let isFixture = repositories?.isFixtureComposition != false
        let values = isFixture ? ProductFixture.days(snapshot, day: SleepFixtures.day, composition: environment.composition) : [:]
        return InMemorySleepRepository(values: values)
    }
}
