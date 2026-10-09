import XCTest
import ProtocolKit

final class CapabilityStateLadderTests: XCTestCase {
    func testEveryCapabilityStartsUnknownForEachGen5Model() {
        let matrix = Gen5CapabilityMatrix()
        for model in [BandModel.whoop5, .whoopMG] {
            for capability in Gen5Capability.allCases {
                XCTAssertEqual(matrix.state(for: capability, model: model), .unknown)
            }
        }
    }

    func testTransitionsAreSequentialAndIndependent() throws {
        var matrix = Gen5CapabilityMatrix()
        XCTAssertThrowsError(try matrix.transition(.history, model: .whoop5, to: .betaEnabled))
        try matrix.transition(.history, model: .whoop5, to: .observed)
        try matrix.transition(.history, model: .whoop5, to: .fixtureVerified)
        try matrix.transition(.history, model: .whoop5, to: .hardwareVerified(model: .whoop5, firmware: "1.2.3"))
        try matrix.transition(.history, model: .whoop5, to: .betaEnabled)
        try matrix.transition(.history, model: .whoop5, to: .suspended)
        XCTAssertEqual(matrix.state(for: .history, model: .whoop5), .suspended)
        XCTAssertEqual(matrix.state(for: .history, model: .whoopMG), .unknown)
        XCTAssertEqual(matrix.state(for: .acknowledgement, model: .whoop5), .unknown)
    }

    func testRejectsStableUnknownAndCrossModelHardwareEvidence() throws {
        var matrix = Gen5CapabilityMatrix()

        XCTAssertThrowsError(try matrix.transition(.history, model: .whoop4, to: .observed)) { error in
            XCTAssertEqual(error as? CapabilityTransitionError, .unsupportedModel(.whoop4))
        }
        XCTAssertThrowsError(try matrix.transition(.history, model: .unknownGen5, to: .observed)) { error in
            XCTAssertEqual(error as? CapabilityTransitionError, .unsupportedModel(.unknownGen5))
        }

        try matrix.transition(.history, model: .whoop5, to: .observed)
        try matrix.transition(.history, model: .whoop5, to: .fixtureVerified)
        XCTAssertThrowsError(
            try matrix.transition(
                .history,
                model: .whoop5,
                to: .hardwareVerified(model: .whoopMG, firmware: "1.2.3")
            )
        ) { error in
            XCTAssertEqual(
                error as? CapabilityTransitionError,
                .hardwareEvidenceModelMismatch(expected: .whoop5, actual: .whoopMG)
            )
        }
        XCTAssertEqual(matrix.state(for: .history, model: .whoop5), .fixtureVerified)

        XCTAssertThrowsError(
            try CapabilityState.fixtureVerified.transitioning(
                to: .hardwareVerified(model: .unknownGen5, firmware: "1.2.3")
            )
        ) { error in
            XCTAssertEqual(error as? CapabilityTransitionError, .invalidHardwareEvidence)
        }
        XCTAssertThrowsError(
            try CapabilityState.fixtureVerified.transitioning(
                to: .hardwareVerified(model: .whoop5, firmware: "   ")
            )
        ) { error in
            XCTAssertEqual(error as? CapabilityTransitionError, .invalidHardwareEvidence)
        }
    }
}
