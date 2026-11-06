import Foundation
import HealthKitBridge
import ProfileKit
import TrainKit

/// The one place the two age rulers read their inputs: the Fitness tab's Ages bar and the Data tab's age ruler. Both
/// read the birth year and sex from here and VO₂max from here, so one launch never draws "Real age 38, Cardio age 32"
/// on Fitness while Data says "No age yet" (R2-OPT-23). VO₂max this year against last has one rule here too
/// (`vo2MaxYear`), which the Fitness gauge and the Data tab's year card both read (R3-OPT-3).
///
/// - Production: the stored profile, and Apple Health through `AppleHealthSources`.
/// - A fixture launch: the launch's one profile (`ProductRepositoryContainer.fixtureProfile`, the one Profile saves
///   into), and the Train fixture's Apple Watch readings under `--loopr-train-fixture`. `--loopr-data-fixture` keeps
///   its own world (`DataOverviewFixtures`).
@MainActor
enum LooprAgeSource {
    /// The stored profile, or nil when this composition has none.
    static func profile(_ repositories: ProductRepositoryContainer?) -> (@Sendable () async -> Profile?)? {
        if let persistent = repositories?.persistent {
            let store = persistent.profile
            return { try? await store.readProfile() }
        }
        #if DEBUG
        if let repositories, repositories.isFixtureComposition {
            let store = repositories.fixtureProfile
            return { try? await store.readProfile() }
        }
        #endif
        return nil
    }

    /// The profile as the Fitness tab reads it.
    static func fitnessProfile(_ repositories: ProductRepositoryContainer?) -> (@Sendable () async -> FitnessProfile?)? {
        guard let read = profile(repositories) else { return nil }
        return { await read().map { FitnessProfile(birthYear: $0.birthYear, biologicalSex: $0.biologicalSex) } }
    }

    /// The profile as the Data tab reads it.
    static func dataProfile(_ repositories: ProductRepositoryContainer?) -> (@Sendable () async -> DataOverviewProfile?)? {
        guard let read = profile(repositories) else { return nil }
        return { await read().map { DataOverviewProfile(birthYear: $0.birthYear, biologicalSex: $0.biologicalSex) } }
    }

    /// VO₂max samples in a window, or nil when this composition has no source for them.
    static func vo2Max(_ repositories: ProductRepositoryContainer?,
                       arguments: [String] = ProcessInfo.processInfo.arguments) -> (@Sendable (Date, Date) async -> AppleHealthReadResult)? {
        if let persistent = repositories?.persistent {
            let appleHealth = persistent.healthSync.appleHealthSources()
            return { from, to in await appleHealth.read(.vo2Max, from: from, to: to) }
        }
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested(arguments: arguments),
           !FitnessFixtures.isAbsentRequested(arguments: arguments) {
            let samples = FitnessFixtures.vo2MaxSamples
            return { _, _ in .values(samples) }
        }
        #endif
        return nil
    }

    /// Apple Health's VO₂max samples as readings, the way the Fitness gauge reads them. Empty for no samples.
    nonisolated static func vo2MaxReadings(_ result: AppleHealthReadResult?) -> [VO2MaxReading] {
        (result?.samples ?? []).compactMap(FitnessInputMapping.reading)
    }

    /// VO₂max this year against last: the 42-day median today against the same median a year earlier
    /// (`VO2MaxYearChange`). The Fitness gauge's "Up 2.6 in 12 months" and the Data tab's year card both use it, so the
    /// two tabs show one value and one change (R3-OPT-3). Nil when today's window has too few readings.
    nonisolated static func vo2MaxYear(_ readings: [VO2MaxReading], now: Date, calendar: Calendar) -> VO2MaxYearChange? {
        VO2MaxYearChange.make(readings: readings, now: now, calendar: calendar)
    }
}
