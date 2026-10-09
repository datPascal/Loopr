import Foundation
import ProfileKit
import SettingsKit
import Testing

@testable import Loopr

/// Covers the Settings -> ProfileKit write path. Settings carries the only
/// editable copy of the display name and age, so a save has to reach the
/// canonical profile, a cleared field has to clear, and saving an unrelated
/// section must leave the profile intact.
struct ProfileSettingsPersistenceTests {
    private func makeRepository() -> (ProfileBackedSettingsRepository, InMemoryProfileRepository) {
        let profile = InMemoryProfileRepository()
        let repository = ProfileBackedSettingsRepository(
            settings: InMemorySettingsRepository(),
            profile: profile
        )
        return (repository, profile)
    }

    private func snapshot(
        name: String?,
        age: Int?,
        units: SettingsKit.UnitSystem = .metric,
        appearance: AppearanceChoice = .system
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            profile: ProfileSettings(displayName: name, age: age),
            units: units,
            appearance: appearance
        )
    }

    @Test
    func savingNameAndAgeReachesTheCanonicalProfileAndReadsBack() async throws {
        let (repository, profile) = makeRepository()

        try await repository.update(snapshot(name: "Alex", age: 34))

        let stored = try #require(await profile.readProfile())
        #expect(stored.displayName == "Alex")
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        #expect(stored.birthYear == currentYear - 34)

        let reloaded = await repository.snapshot()
        #expect(reloaded.profile.displayName == "Alex")
        #expect(reloaded.profile.age == 34)
    }

    @Test
    func editingAnExistingProfileReplacesTheStoredValues() async throws {
        let (repository, _) = makeRepository()
        try await repository.update(snapshot(name: "Alex", age: 34))

        try await repository.update(snapshot(name: "Alex B", age: 35))

        let reloaded = await repository.snapshot()
        #expect(reloaded.profile.displayName == "Alex B")
        #expect(reloaded.profile.age == 35)
    }

    @Test
    func clearingTheAgeFieldClearsTheStoredBirthYear() async throws {
        let (repository, profile) = makeRepository()
        try await repository.update(snapshot(name: "Alex", age: 34))

        try await repository.update(snapshot(name: "Alex", age: nil))

        let stored = try #require(await profile.readProfile())
        #expect(stored.birthYear == nil)
        #expect(await repository.snapshot().profile.age == nil)
    }

    @Test
    func savingAnotherSectionKeepsTheStoredProfile() async throws {
        let (repository, _) = makeRepository()
        try await repository.update(snapshot(name: "Alex", age: 34))

        // A different destination screen posts the whole snapshot. It carries
        // the loaded profile, so the profile must survive the write.
        var units = await repository.snapshot()
        units.units = .imperial
        units.appearance = .dark
        try await repository.update(units)

        let reloaded = await repository.snapshot()
        #expect(reloaded.units == .imperial)
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.profile.displayName == "Alex")
        #expect(reloaded.profile.age == 34)
    }

    /// The display name became optional in ProfileKit (onboarding lane,
    /// 2026-09-23), so profile data without a name now saves instead of
    /// failing, and the age is not lost.
    @Test
    func profileDataWithoutADisplayNameStillSavesTheOtherFields() async throws {
        let (repository, profile) = makeRepository()

        try await repository.update(snapshot(name: nil, age: 34))
        let stored = try #require(try await profile.readProfile())
        #expect(stored.displayName == "")
        #expect(stored.birthYear != nil)
    }

    @Test
    func savingAnUntouchedProfileSectionBeforeSetupIsNotAFailure() async throws {
        let (repository, profile) = makeRepository()

        try await repository.update(snapshot(name: nil, age: nil, appearance: .dark))

        let stored = try await profile.readProfile()
        #expect(stored == nil)
        #expect(await repository.snapshot().appearance == .dark)
    }
}
