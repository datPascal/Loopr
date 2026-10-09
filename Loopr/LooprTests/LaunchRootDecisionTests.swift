import DesignSystem
import DomainKit
import Foundation
import OnboardingKit
import Testing
import TodayKit

@testable import Loopr

/// A returning user must open straight into the shell, a new user must get
/// onboarding, and a cached flag that the durable store contradicts must
/// send the user back to onboarding.
struct LaunchRootDecisionTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "loopr.tests.launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func snapshot(_ stage: OnboardingStage) -> OnboardingSnapshot {
        OnboardingSnapshot(stage: stage, lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: First frame

    @Test
    func cachedOnboardedFlagOpensTheShellOnTheFirstFrame() {
        #expect(LaunchRootDecision.initialOnboardingCompleted(
            root: .onboarding, composition: .production, cachedOnboardingCompleted: true
        ))
    }

    @Test
    func noCachedFlagStartsOnboarding() {
        #expect(!LaunchRootDecision.initialOnboardingCompleted(
            root: .onboarding, composition: .production, cachedOnboardingCompleted: false
        ))
    }

    @Test
    func fixtureLaunchesKeepTheirDeclaredRoot() {
        // A stray production flag must not skip onboarding in the onboarding
        // and pairing fixture modes that UI tests walk.
        #expect(!LaunchRootDecision.initialOnboardingCompleted(
            root: .onboarding, composition: .onboarding, cachedOnboardingCompleted: true
        ))
        #expect(!LaunchRootDecision.initialOnboardingCompleted(
            root: .onboarding, composition: .pairing, cachedOnboardingCompleted: true
        ))
        #expect(LaunchRootDecision.initialOnboardingCompleted(
            root: .main, composition: .populated, cachedOnboardingCompleted: false
        ))
    }

    // MARK: Reconciliation

    @Test
    func finishedDurableSnapshotKeepsTheShell() async {
        let repository = InMemoryOnboardingRepository(snapshot: snapshot(.mainShell))
        let outcome = await LaunchRootDecision.reconcile { try await repository.load() }
        #expect(outcome == .keep)
    }

    @Test
    func wipedDurableStoreReturnsToOnboarding() async {
        let repository = InMemoryOnboardingRepository()
        let outcome = await LaunchRootDecision.reconcile { try await repository.load() }
        #expect(outcome == .returnToOnboarding)
    }

    @Test
    func unfinishedDurableSnapshotReturnsToOnboarding() {
        for stage in OnboardingStage.allCases where stage != .mainShell {
            #expect(LaunchRootDecision.reconcile(persistedStage: stage) == .returnToOnboarding)
        }
    }

    @Test
    func unreadableStoreLeavesTheRootAlone() async {
        struct ReadFailure: Error {}
        let outcome = await LaunchRootDecision.reconcile { throw ReadFailure() }
        #expect(outcome == .undetermined)
    }

    // MARK: Flag store

    @Test
    func flagIsSetOnceOnboardingFinishesAndClearedOnReconciliation() {
        let defaults = isolatedDefaults()
        let store = LaunchOnboardingFlagStore(defaults: defaults)
        #expect(!store.isOnboardingCompleted)
        store.markOnboardingCompleted()
        #expect(store.isOnboardingCompleted)
        #expect(LaunchOnboardingFlagStore(defaults: defaults).isOnboardingCompleted)
        store.clear()
        #expect(!store.isOnboardingCompleted)
    }

    @Test
    func deleteAllRegistryCoversBothLaunchCaches() {
        #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.contains(LaunchOnboardingFlagStore.key))
        #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.contains(TodayLaunchSnapshotStore.key))
    }

    // MARK: Today launch snapshot

    @Test
    func todaySnapshotRoundTripsForTheSameDay() {
        let store = TodayLaunchSnapshotStore(defaults: isolatedDefaults())
        store.write(TodayFixtures.populated)
        #expect(store.read(for: TodayFixtures.day) == TodayFixtures.populated)
    }

    @Test
    func todaySnapshotFromAnotherDayIsNeverShown() {
        let store = TodayLaunchSnapshotStore(defaults: isolatedDefaults())
        store.write(TodayFixtures.populated)
        let nextDay = DayIdentity(year: 2023, month: 11, day: 15)
        #expect(store.read(for: nextDay) == nil)
    }

    @Test
    func finishedEmptyLoadClearsTheSnapshotButAFailureKeepsIt() {
        let store = TodayLaunchSnapshotStore(defaults: isolatedDefaults())
        store.write(TodayFixtures.populated)
        store.record(summary: nil, loadState: .failed("offline"))
        #expect(store.read(for: TodayFixtures.day) != nil)
        store.record(summary: nil, loadState: .loading)
        #expect(store.read(for: TodayFixtures.day) != nil)
        store.record(summary: nil, loadState: .loaded)
        #expect(store.read(for: TodayFixtures.day) == nil)
    }

    @Test @MainActor
    func todayViewModelWaitsForFreshSummaryBeforeShowingTheSavedDay() async {
        let refreshed = TodayFixtures.summary(for: .partial)
        let repository = InMemoryTodayRepository(values: [TodayFixtures.day: refreshed])
        let viewModel = TodayViewModel(
            repository: repository,
            lastKnownSummary: TodayFixtures.populated,
            day: TodayFixtures.day
        )
        #expect(viewModel.loadState == .idle)
        #expect(viewModel.summary == nil)

        await viewModel.load(day: TodayFixtures.day)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.summary == refreshed)
    }
}
