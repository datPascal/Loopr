import XCTest
@testable import DomainKit

final class LoadAwareStrainTargetTests: XCTestCase {
    func testRecoveryBandEdgesStayConsistent() throws {
        for (recovery, lower, upper) in [(33.0, 4.0, 10.0), (34, 10, 14), (66, 10, 14), (67, 14, 18)] {
            let target = try XCTUnwrap(StrainTarget(recovery: recovery))
            XCTAssertEqual(target.lower, lower); XCTAssertEqual(target.upper, upper)
            let heavy = try XCTUnwrap(StrainTarget(recovery: recovery, trainingLoad: .init(fitness: 10, fatigue: 12, days: 42)))
            XCTAssertEqual(heavy.lower, lower - 2); XCTAssertEqual(heavy.upper, upper - 2)
            XCTAssertEqual(heavy.reason, "Lower because your last 7 days were heavy.")
        }
    }
    func testThresholdsAndWarmup() throws {
        XCTAssertNil(StrainTarget(recovery: nil, trainingLoad: .init(fitness: 10, fatigue: 12, days: 42)))
        XCTAssertNil(StrainTarget(recovery: 74, trainingLoad: .init(fitness: 10, fatigue: 12, days: 41))?.reason)
        XCTAssertNil(StrainTarget(recovery: 74, trainingLoad: .init(fitness: 10, fatigue: 11, days: 42))?.reason)
        let lighter = try XCTUnwrap(StrainTarget(recovery: 67, trainingLoad: .init(fitness: 10, fatigue: 8, days: 42)))
        XCTAssertEqual(lighter.range, 14...20)
        XCTAssertNil(StrainTarget(recovery: 66, trainingLoad: .init(fitness: 10, fatigue: 8, days: 42))?.reason)
        XCTAssertNil(StrainTarget(recovery: 74, trainingLoad: .init(fitness: 0, fatigue: 0, days: 42))?.reason)
        XCTAssertEqual(lighter.position(of: 20.04), .within)
        XCTAssertEqual(lighter.position(of: 20.06), .above)
    }
}
