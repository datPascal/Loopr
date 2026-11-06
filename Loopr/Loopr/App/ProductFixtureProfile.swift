#if DEBUG
import Foundation
import ProfileKit

/// The profile a fixture launch starts with (DEBUG only). Profile, Data and Fitness share one copy per launch
/// (`ProductRepositoryContainer.fixtureProfile`), so a birth year saved in Profile is the one the age rulers read.
nonisolated enum ProductFixtureProfile {
    /// Alex in the populated launch: born 1985, so 38 on the fixture day in November 2023, the age the Data and
    /// Fitness fixtures use.
    static let populatedBirthYear = 1985

    static func profile(for composition: AppEnvironment.Composition) -> Profile? {
        guard composition == .populated else { return nil }
        let created = Date(timeIntervalSince1970: 1_690_000_000)
        return Profile(id: UUID(uuidString: "5A1E0000-0000-4000-8000-00000000A1E5") ?? UUID(), displayName: "Alex",
                       birthYear: populatedBirthYear, biologicalSex: .male, unitSystem: .metric,
                       createdAt: created, updatedAt: created)
    }

    static func repository(for composition: AppEnvironment.Composition) -> InMemoryProfileRepository {
        InMemoryProfileRepository(profile: profile(for: composition))
    }

    /// The profile onboarding saved in this launch, waiting for the shell that opens after it. Onboarding and the shell
    /// each own a repository container, so without the hand-off the birth year typed in About you was lost: Data asked
    /// for a birth year, Fitness asked again and Profile was blank (R3-NEW-1). Production needs none of this: both
    /// containers open the same SQLite profile.
    @MainActor private static var onboardingHandOff: [AppEnvironment.Composition: InMemoryProfileRepository] = [:]

    /// The profile a fixture onboarding saves into. The shell opened after it, in the same launch mode, reads it.
    @MainActor static func onboardingRepository(for composition: AppEnvironment.Composition) -> InMemoryProfileRepository {
        let repository = repository(for: composition)
        onboardingHandOff[composition] = repository
        return repository
    }

    /// The launch's profile for the shell: the one onboarding saved into, when this launch ran onboarding first.
    @MainActor static func shellRepository(for composition: AppEnvironment.Composition) -> InMemoryProfileRepository {
        onboardingHandOff.removeValue(forKey: composition) ?? repository(for: composition)
    }
}
#endif
