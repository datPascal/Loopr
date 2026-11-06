import AnalyticsKit
import DataKit
import DomainKit
import Foundation
import HealthKitBridge
import OnboardingKit
import ProfileKit
import SettingsKit
import Testing
import TrainKit
import WorkoutKit
@testable import Loopr

/// ICP round 3: what onboarding takes in is what the shell shows, a fresh launch shows nothing the person did not
/// give, and Fitness and Data read one VO₂max with one year rule.
@MainActor
struct FreshLaunchCoherenceTests {
    private func aboutYou(birthYear: String, sex: OnboardingProfileForm.SexChoice?) -> ProfileDraft {
        var form = OnboardingProfileForm()
        form.birthYear = birthYear
        form.sex = sex
        return form.draft(currentYear: ProfileSettings.currentYear())
    }

    private func profileStep(_ profile: InMemoryProfileRepository) async throws -> OnboardingFlowController {
        try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(snapshot: OnboardingSnapshot(stage: .profileSetup, lastUpdatedAt: Date())),
            profileRepository: profile, goalsRepository: profile)
    }

    #if DEBUG
    /// R3-NEW-1: About you's birth year and sex reach Profile, Data and Fitness in a fixture launch.
    @Test func aboutYouInAFixtureOnboardingReachesProfileDataAndFitness() async throws {
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=onboarding"], environment: [:])
        let flow = try await profileStep(ProductFixtureProfile.onboardingRepository(for: environment.composition))
        _ = try await flow.completeProfile(aboutYou(birthYear: "1993", sex: .female))

        let shell = ProductRepositoryContainer(environment: environment)
        let data = try #require(LooprAgeSource.dataProfile(shell))
        let fitness = try #require(LooprAgeSource.fitnessProfile(shell))
        #expect(await data()?.birthYear == 1993)
        #expect(await fitness()?.birthYear == 1993)
        #expect(await fitness()?.biologicalSex == .female)
        let settings = ProfileBackedSettingsRepository(settings: InMemorySettingsRepository(initial: SettingsSnapshot()),
                                                       profile: shell.fixtureProfile)
        let shown = await settings.snapshot().profile
        #expect(shown.birthYear == 1993)
        #expect(shown.biologicalSex == BiologicalSex.female.rawValue)
    }
    #endif

    /// R3-NEW-1 and R3-UPG-4 in production: onboarding and the shell each open the app's SQLite store, so the profile
    /// About you saves is the one Profile shows and the age rulers read, and Profile's sex row writes that same field.
    @Test func aboutYouInProductionIsTheProfileTheShellReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-you-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = AgentFixtures.Suite()
        let environment = AppEnvironment(composition: .production, root: .onboarding, storageURL: root.appendingPathComponent("Loopr.sqlite"),
            applicationVersion: "about-you", dateProvider: SystemDateProvider(), calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(), uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())

        let onboarding = try PersistentProductRepositories(environment: environment, defaults: suite.defaults)
        let flow = try await OnboardingFlowController(
            repository: InMemoryOnboardingRepository(snapshot: OnboardingSnapshot(stage: .profileSetup, lastUpdatedAt: Date())),
            profileRepository: onboarding.profile, goalsRepository: onboarding.profile)
        _ = try await flow.completeProfile(aboutYou(birthYear: "1993", sex: nil))

        let shell = try PersistentProductRepositories(environment: environment, defaults: suite.defaults)
        let sources = FitnessSources.live(shell)
        #expect(await sources.profile?()?.birthYear == 1993)
        let settings = ProfileBackedSettingsRepository(settings: shell.settings, profile: shell.profile)
        var snapshot = await settings.snapshot()
        #expect(snapshot.profile.birthYear == 1993)
        #expect(snapshot.profile.biologicalSex == nil)

        // Skipped in onboarding, set in Profile.
        snapshot.profile.biologicalSex = BiologicalSex.male.rawValue
        try await settings.update(snapshot)
        #expect(try await shell.profile.readProfile()?.biologicalSex == .male)
        #expect(try await shell.profile.readProfile()?.birthYear == 1993)
        #expect(await sources.profile?()?.biologicalSex == .male)
    }

    #if DEBUG
    /// R3-NEW-3: onboarding, pairing and empty launches seed no workout and list nothing under Your data.
    @Test func freshLaunchesSeedNothingThePersonDidNotGive() async throws {
        for mode in ["onboarding", "pairing", "empty"] {
            let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=\(mode)"], environment: [:])
            #expect(environment.composition.startsFresh, "\(mode)")
            let repositories = ProductRepositoryContainer(environment: environment)
            let store = try #require(repositories.workoutStore)
            #expect(await store.all().isEmpty, "\(mode) seeded workouts")
            #expect(await repositories.detectedWorkouts?.allDetections().isEmpty ?? true, "\(mode) seeded a detection")

            let model = YourDataModel(repositories: repositories)
            await model.load()
            let inventory = try #require(model.inventory, "\(mode)")
            #expect(inventory.bandRecords == 0 && inventory.healthRecords == 0 && inventory.importedDays == 0, "\(mode)")
            #expect(inventory.meals == 0 && inventory.photos == 0 && inventory.workouts == 0, "\(mode)")
            #expect(inventory.checkIns == 0 && inventory.notes == 0, "\(mode)")
        }
        let populated = ProductRepositoryContainer(environment: AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"],
                                                                                    environment: [:]))
        #expect(await populated.workoutStore?.all().isEmpty == false)
    }
    #endif

    /// R3-OPT-3: the Fitness gauge and the Data year card show one VO₂max and one change, from the same samples and the
    /// same rule, even when the stored daily history holds other values.
    @Test func fitnessAndDataShowOneVO2MaxAndOneYearChange() throws {
        let now = AppTrainFixtures.now, calendar = AppTrainFixtures.calendar
        let result = AppleHealthReadResult.values(FitnessFixtures.vo2MaxSamples)
        let readings = LooprAgeSource.vo2MaxReadings(result)
        let gauge = try #require(VO2MaxGauge.make(readings: readings, now: now, age: 38, group: .male, calendar: calendar).gauge)
        let change = try #require(gauge.changeOverTwelveMonths)

        let staleHistory = (0..<400).compactMap { day -> MetricHistoryPoint? in
            calendar.date(byAdding: .day, value: -day, to: now).map { MetricHistoryPoint(day: $0, value: 48.1, source: .appleHealth) }
        }
        let series = DataOverviewMapping.vo2MaxSeries(history: staleHistory, appleHealth: result, now: now, calendar: calendar)
        let row = try #require(DataYearComparisonRule.compare([series], now: now, calendar: calendar).rows.first)
        #expect(abs(row.thisYear - gauge.value) < 1e-9)
        #expect(abs((row.thisYear - row.lastYear) - change) < 1e-9)
        #expect(row.valueText.hasPrefix("44.1"))
        #expect(row.title == "VO₂max")
    }
}
