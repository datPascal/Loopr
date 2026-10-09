import XCTest
@testable import AnalyticsKit

final class Gen5MGIdentityLabelTests: XCTestCase {
    func testUncertainIdentityNeverClaimsMG() {
        XCTAssertEqual(
            Gen5ModelPresentation.label(model: "whoopMG", identityConfirmed: false),
            "Experimental Gen 5 device"
        )
        XCTAssertEqual(
            Gen5ModelPresentation.label(model: "whoopMG", identityConfirmed: true),
            "MG band (Experimental Beta)"
        )
    }
}

final class Gen5NoMedicalClaimTests: XCTestCase {
    func testNoECGClinicalBloodPressureOrMedicalClaimIsReachable() {
        XCTAssertTrue(Gen5ModelPresentation.reachableMedicalClaims.isEmpty)
        for claim in Gen5ModelPresentation.forbiddenMedicalClaims {
            XCTAssertFalse(Gen5ModelPresentation.reachableMedicalClaims.contains(claim))
        }
    }
}
