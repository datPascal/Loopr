import AnalyticsKit
import XCTest

private func unsignedFixtureCard() -> ModelCard {
    ModelCard(
        modelVersion: 1,
        referenceVersion: 1,
        outcome: "unsigned fixture",
        horizon: "not approved",
        targetPopulation: "synthetic",
        referenceProfile: [:],
        coefficients: [:],
        transforms: [:],
        referencePopulation: "synthetic",
        subgroupPerformance: [:],
        calibrationEvidence: ModelCardEvidence(summary: "not validated"),
        discriminationEvidence: ModelCardEvidence(summary: "not validated"),
        uncertaintyEvidence: ModelCardEvidence(summary: "not validated"),
        stabilityEvidence: ModelCardEvidence(summary: "not validated"),
        referenceRiskAnchors: [
            ReferenceRiskAnchor(age: 20, risk: 0.5),
            ReferenceRiskAnchor(age: 50, risk: 1),
            ReferenceRiskAnchor(age: 80, risk: 2)
        ],
        validatedAgeRange: 20...80,
        reviewSignOff: ModelCardReviewSignOff(reviewer: "", signedAt: nil, signature: "", approved: false)
    )
}

final class CompositeGateTests: XCTestCase {
    func testBundledCompositeIsUnavailableForEveryInput() {
        let evaluation = CompositeRiskModel().evaluate(
            features: CompositeRiskFeatures(values: ["cardioCapacity": 40]),
            realAgeYears: 40
        )
        XCTAssertNil(evaluation.looprAgeYears)
        XCTAssertEqual(evaluation.absenceReason, .compositeValidationIncomplete)
    }
}

final class AgeConversionSolverTests: XCTestCase {
    func testSyntheticSignedCardInterpolatesAndClampsBoundaries() {
        let card = signedCard()
        let solver = AgeConversionSolver()
        let middle = solver.solve(modeledRisk: 1.5, modelCard: card)
        XCTAssertEqual(middle.ageYears!, 65, accuracy: 1e-9)
        XCTAssertNil(middle.boundary)
        XCTAssertEqual(solver.solve(modeledRisk: 0.1, modelCard: card).boundary, .lower)
        XCTAssertEqual(solver.solve(modeledRisk: 99, modelCard: card).boundary, .upper)
    }

    private func signedCard() -> ModelCard {
        ModelCard(
            modelVersion: 7,
            referenceVersion: 2,
            outcome: "synthetic outcome",
            horizon: "10 years",
            targetPopulation: "synthetic",
            referenceProfile: [:],
            coefficients: [:],
            transforms: [:],
            referencePopulation: "synthetic",
            subgroupPerformance: ["all": 1],
            calibrationEvidence: ModelCardEvidence(summary: "synthetic"),
            discriminationEvidence: ModelCardEvidence(summary: "synthetic"),
            uncertaintyEvidence: ModelCardEvidence(summary: "synthetic"),
            stabilityEvidence: ModelCardEvidence(summary: "synthetic"),
            referenceRiskAnchors: [
                ReferenceRiskAnchor(age: 20, risk: 0.5),
                ReferenceRiskAnchor(age: 50, risk: 1),
                ReferenceRiskAnchor(age: 80, risk: 2)
            ],
            validatedAgeRange: 20...80,
            reviewSignOff: ModelCardReviewSignOff(
                reviewer: "test reviewer",
                signedAt: Date(timeIntervalSince1970: 1),
                signature: "test-signature",
                approved: true
            )
        )
    }
}

final class NoHeuristicFallbackTests: XCTestCase {
    func testUnsignedFixtureCannotReachAge() {
        let evaluation = CompositeRiskModel().evaluate(
            features: CompositeRiskFeatures(values: ["cardioCapacity": 99]),
            realAgeYears: 50,
            modelCard: unsignedFixtureCard()
        )
        XCTAssertNil(evaluation.looprAgeYears)
        XCTAssertEqual(evaluation.availability, .unavailable(reason: .compositeValidationIncomplete))
    }
}

final class CompositeUIStateTests: XCTestCase {
    func testUnavailableCopyContainsNoSyntheticNumber() {
        let state = CompositeUIState.unavailableNoModel
        XCTAssertNil(state.numericAge)
        XCTAssertTrue(state.visibleCopy.localizedCaseInsensitiveContains("unavailable"))
        XCTAssertFalse(state.visibleCopy.contains("0 years"))
    }
}

final class LooprAgeCompositeUnavailableTests: XCTestCase {
    func testUnsignedAndMissingDomainResultsRemainAbsent() {
        let noModel = CompositeRiskModel().evaluate(
            features: CompositeRiskFeatures(values: [:]),
            realAgeYears: 40,
            modelCard: unsignedFixtureCard()
        )
        XCTAssertNil(noModel.looprAgeYears)

        let result = LooprAgeResult(
            realAgeYears: 40,
            cardioAge: nil,
            modelWindow: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1),
            contributors: [],
            coverage: .empty,
            confidence: 0,
            confidenceTier: .unavailable,
            modelVersion: 1,
            referenceVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 0),
            absenceReason: .missingRequiredDomain
        )
        XCTAssertNil(result.looprAgeYears)
        XCTAssertEqual(CompositeUIState.forResult(result), .unavailableMissingDomain)
    }

    func testFreshFullHistoryPartialHistoryAndDeclinedCurveRemainUnavailable() {
        let cases: [LooprAgeAbsenceReason] = [
            .compositeNotYetValidated, // fresh install
            .compositeNotYetValidated, // complete 180-day contributor history
            .compositeNotYetValidated, // provisional 90-179-day history
            .declinedReferenceCurve
        ]
        for reason in cases {
            let result = LooprAgeResult(
                realAgeYears: 40,
                cardioAge: nil,
                modelWindow: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1),
                contributors: [],
                coverage: .empty,
                confidence: 0,
                confidenceTier: .unavailable,
                modelVersion: 1,
                referenceVersion: 1,
                generatedAt: Date(timeIntervalSince1970: 0),
                absenceReason: reason
            )
            XCTAssertNil(result.looprAgeYears)
        }
    }
}
