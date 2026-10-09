import Foundation
import Testing
import DomainKit
import DesignSystem
import AnalyticsKit
@testable import BodyKit

struct BodyKitTests {
    @Test
    func stateMatrixCoversAllFourteenStatesAndSeparatesZeroFromAbsent() {
        #expect(BodyFixtures.allStates.count == 14)

        let absent = BodyFixtures.snapshot(for: .absent).metric(.steps)
        let zero = BodyFixtures.snapshot(for: .measuredZero).metric(.steps)
        #expect(absent?.value == nil)
        #expect(absent?.state == .absent)
        #expect(zero?.value == "0")
        #expect(zero?.state == .measuredZero)
        #expect(absent?.accessibilitySummary != zero?.accessibilitySummary)
    }

    @Test
    func bodyProjectionPreservesCanonicalActivitySources() {
        let snapshot = BodyFixtures.populated
        #expect(snapshot.source == "ANA-05/ANA-07 canonical")
        #expect(snapshot.algorithmVersion == "activity.v1")
        #expect(snapshot.metric(.strain)?.source == "ANA-05.activity")
        #expect(snapshot.metric(.zones)?.source == "ANA-05.zones")
        #expect(snapshot.composition.source == "APP-02A.profile")
    }

    @Test
    func ageUnavailableStatesNeverExposeFabricatedValues() {
        let snapshot = BodyFixtures.populated
        #expect(snapshot.cardioAgePresentation.isAvailable == false)
        #expect(snapshot.looprAgePresentation.isAvailable == false)
        #expect(snapshot.looprAge?.looprAgeYears == nil)
        #expect(snapshot.cardioAge?.isAvailable == false)
    }

    @Test
    func cardioAgeRejectsALooprOwnedVO2Estimate() {
        let stored = CardioAgeResult(
            ageYears: 34, displayLabel: "34 years", status: .available, vo2max: 42,
            source: .looprExerciseEstimate, referenceGroup: nil, referenceVersion: 1,
            confidence: 0.9, absenceReason: nil
        )
        let presentation = BodyDaySnapshot.cardioAgePresentation(for: stored)
        #expect(!presentation.isAvailable)
        if case .unavailable(let reason, _) = presentation {
            #expect(reason == "Cardio Age needs VO₂ max from Apple Health or a lab test.")
        } else {
            Issue.record("Loopr-owned VO₂ estimate reached Cardio Age")
        }

        let eligible = CardioAgeResult(
            ageYears: 34, displayLabel: "34 years", status: .available, vo2max: 42,
            source: .healthKit, referenceGroup: nil, referenceVersion: 1,
            confidence: 0.9, absenceReason: nil
        )
        #expect(BodyDaySnapshot.cardioAgePresentation(for: eligible).isAvailable)
    }

    @Test
    func agePresentationsUseHumanCopyInsteadOfInternalCodes() {
        let snapshot = BodyFixtures.populated
        let presentations = [snapshot.cardioAgePresentation, snapshot.looprAgePresentation]

        for presentation in presentations {
            guard case .unavailable(let reason, _) = presentation else {
                Issue.record("Fixture age presentation unexpectedly became available")
                continue
            }
            #expect(!reason.contains("ANA-"))
            #expect(!reason.contains("noVO2MaxSource"))
            #expect(!reason.contains("compositeNotYetValidated"))
        }
    }

    @Test @MainActor
    func viewModelReadsRepositoryWithoutDerivingMetrics() async {
        let repository = InMemoryBodyRepository(values: [BodyFixtures.day: BodyFixtures.populated])
        let viewModel = BodyViewModel(repository: repository)

        await viewModel.load(day: BodyFixtures.day)

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.snapshot == BodyFixtures.populated)
        #expect(viewModel.snapshot?.metric(.strain)?.value == "8.6")
    }

    @Test
    func repositoryDeleteIsExplicit() async throws {
        let repository = InMemoryBodyRepository(values: [BodyFixtures.day: BodyFixtures.populated])
        #expect(try await repository.readBodyDay(for: BodyFixtures.day) != nil)
        await repository.deleteAll()
        #expect(try await repository.readBodyDay(for: BodyFixtures.day) == nil)
    }

    @Test @MainActor
    func screenConstructsForAllBodyRoutes() {
        let repository = InMemoryBodyRepository(values: [BodyFixtures.day: BodyFixtures.populated])
        let viewModel = BodyViewModel(repository: repository)
        _ = BodyScreen(viewModel: viewModel)
        _ = BodyLoadScreen(snapshot: BodyFixtures.populated)
        _ = BodyAgeScreen(title: "Cardio Age", presentation: BodyFixtures.populated.cardioAgePresentation)
        _ = BodyAgeScreen(title: "Loopr Age", presentation: BodyFixtures.populated.looprAgePresentation)
        #expect(BodyRoute.allCases.count == 4)
    }
}
