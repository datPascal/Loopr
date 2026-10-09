import Foundation
import Testing
import DomainKit
import ProfileKit

struct ProfileKitTests {
    @Test
    func optionalProfileFieldsRoundTripAsAbsent() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider()
        )
        let profile = try await repository.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))

        #expect(profile.displayName == "Ari")
        #expect(profile.birthYear == nil)
        #expect(profile.biologicalSex == nil)
        #expect(profile.heightCentimeters == nil)
        #expect(profile.weightKilograms == nil)
        #expect(profile.timezoneIdentifier == nil)
        #expect(profile.heightValue == .absent)
        #expect(profile.weightValue == .absent)
        #expect((try await repository.readProfile())?.draft() == ProfileDraft(displayName: "Ari", unitSystem: .metric))
    }

    @Test
    func blankOptionalTextNormalizesToAbsent() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider()
        )
        let profile = try await repository.saveProfile(
            ProfileDraft(displayName: " Ari ", timezoneIdentifier: "   ", unitSystem: .metric)
        )
        #expect(profile.displayName == "Ari")
        #expect(profile.timezoneIdentifier == nil)
        #expect(await repository.readProfileState() == .present(profile))
    }

    @Test
    func invalidDraftsFailClosed() async {
        let repository = InMemoryProfileRepository()

        await #expect(throws: ProfileValidationError.missingUnitSystem) {
            _ = try await repository.saveProfile(ProfileDraft(displayName: "Ari"))
        }
        await #expect(throws: ProfileValidationError.invalidWeight(10)) {
            _ = try await repository.saveProfile(ProfileDraft(displayName: "Ari", weightKilograms: 10, unitSystem: .metric))
        }
    }

    @Test
    func unitsConvertRoundTripWithoutRoundingAwayInput() {
        let centimeters = 180.0
        let inches = UnitConverter.centimetersToInches(centimeters)
        #expect(abs(UnitConverter.inchesToCentimeters(inches) - centimeters) < 0.000_001)

        let kilograms = 72.5
        let pounds = UnitConverter.kilogramsToPounds(kilograms)
        #expect(abs(UnitConverter.poundsToKilograms(pounds) - kilograms) < 0.000_001)
    }

    @Test
    func goalsValidateAndReplaceByType() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider(values: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
            ])
        )
        let first = try await repository.saveGoal(type: .steps, target: 8_000, unit: "steps", isEnabled: true)
        let second = try await repository.saveGoal(type: .steps, target: 10_000, unit: "steps", isEnabled: true)
        #expect(first.target == 8_000)
        #expect((try await repository.readGoals()).count == 1)
        #expect((try await repository.readGoals()).first?.id == second.id)

        await #expect(throws: GoalValidationError.nonPositiveTarget) {
            _ = try await repository.saveGoal(type: .sleep, target: 0, unit: "hours", isEnabled: true)
        }
    }

    @Test
    func resetProfileClearsProfileUnitsAndGoals() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider()
        )
        _ = try await repository.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        _ = try await repository.saveGoal(type: .sleep, target: 8, unit: "hours", isEnabled: true)

        try await repository.resetProfile()
        #expect(try await repository.readProfile() == nil)
        #expect((try await repository.readGoals()).isEmpty)
        #expect(await repository.readProfileState() == .noRecordsYet)

        try await repository.deleteAllData()
        #expect((try await repository.readGoals()).isEmpty)
    }

    @Test
    func typedGoalStateDistinguishesAbsentFromPresent() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider()
        )
        #expect(await repository.readGoalsState() == .noRecordsYet)
        _ = try await repository.saveGoal(type: .sleep, target: 8, unit: "hours")
        if case .present(let goals) = await repository.readGoalsState() {
            #expect(goals.count == 1)
        } else {
            Issue.record("Expected a present goal state")
        }
    }

    @Test
    func typedValidationStateExposesRecoverableInputErrors() {
        let repository = InMemoryProfileRepository()
        #expect(repository.validateDraft(ProfileDraft(unitSystem: .metric)) == .valid)
        #expect(repository.validateDraft(ProfileDraft(displayName: "Ari")) == .invalid(.missingUnitSystem))
        #expect(repository.validateGoal(target: -1, unit: "steps") == .invalid(.nonPositiveTarget))
        #expect(repository.validateGoal(target: 8, unit: "hours") == .valid)
    }

    @Test
    func schemaMigrationIsExplicitAndIdempotent() throws {
        let snapshot = ProfileStoreSnapshot(schemaVersion: 0, profile: nil, goals: [])
        let migrated = try ProfileSchemaMigration.migrate(snapshot)
        #expect(migrated.schemaVersion == ProfileSchemaMigration.currentVersion)
        #expect(try ProfileSchemaMigration.migrate(migrated) == migrated)
        #expect(throws: ProfileRepositoryError.migrationFailed("Unsupported schema version -1.")) {
            _ = try ProfileSchemaMigration.migrate(ProfileStoreSnapshot(schemaVersion: -1, profile: nil, goals: []))
        }
    }

    @Test
    func exportAndRestoreRoundTripCanonicalProfileAndGoals() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider(values: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
            ])
        )
        _ = try await repository.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        _ = try await repository.saveGoal(type: .steps, target: 8_000, unit: "steps")
        let exported = try await repository.exportSnapshot()

        try await repository.deleteAllData()
        try await repository.restoreSnapshot(exported)
        #expect(try await repository.readProfile()?.displayName == "Ari")
        #expect((try await repository.readGoals()).count == 1)
    }

    @Test
    func displayNameIsOptionalAndStoredEmpty() async throws {
        let repository = InMemoryProfileRepository(
            dateProvider: FixedDateProvider(),
            uuidProvider: FixedUUIDProvider()
        )
        let unnamed = try await repository.saveProfile(ProfileDraft(birthYear: 1990, unitSystem: .imperial))
        #expect(unnamed.displayName == "")
        #expect(unnamed.birthYear == 1990)
        let blank = try await repository.saveProfile(ProfileDraft(displayName: "   ", unitSystem: .metric))
        #expect(blank.displayName == "")
    }

    @Test
    func estimatedMaxHeartRateUsesTanakaWithinSupportedAges() {
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 30) == 187)
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 40) == 180)
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 13) == 199)
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 120) == 124)
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 12) == nil)
        #expect(ProfileEstimates.estimatedMaxHeartRate(age: 121) == nil)
    }

    @Test
    func ageAndBirthYearRoundTripAndMatchValidatorRange() throws {
        let year = 2026
        for age in [ProfileEstimates.supportedAges.lowerBound, 34, ProfileEstimates.supportedAges.upperBound] {
            let birthYear = ProfileEstimates.birthYear(age: age, currentYear: year)
            #expect(ProfileEstimates.age(birthYear: birthYear, currentYear: year) == age)
            try ProfileValidator.validate(ProfileDraft(birthYear: birthYear, unitSystem: .metric), currentYear: year)
        }
        #expect(throws: ProfileValidationError.self) {
            try ProfileValidator.validate(ProfileDraft(birthYear: year - 12, unitSystem: .metric), currentYear: year)
        }
    }
}

private struct FixedDateProvider: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor FixedUUIDProvider: UUIDProviding {
    private var values: [UUID]

    init(values: [UUID] = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]) {
        self.values = values
    }

    func nextUUID() -> UUID {
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}
