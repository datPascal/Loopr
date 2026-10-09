import DomainKit
import XCTest

final class ZoneTwoRangeTests: XCTestCase {
    func testReserveUsesMedianAndRoundsInsideRange() {
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: 190, restingNights: [50, 51, 52, 53, 54, 55, 90]), .init(lower: 136, upper: 148, source: .restingHeartRate))
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: 200, restingNights: [50, 60])?.range, 142...156)
    }
    func testOnlyLatestFourteenValidNightsCount() {
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: 200, restingNights: [100] + Array(repeating: 50, count: 14))?.range, 140...154)
    }
    func testMissingRestingFallsBackAndMissingMaximumStaysMissing() {
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: 200, restingNights: [])?.range, 120...139)
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: 200, restingNights: [.nan, 0, 250])?.range, 120...139)
        XCTAssertNil(ZoneTwoRange.resolve(maximum: nil, restingNights: [50]))
    }
    func testTargetMatchesSharedZoneTwoIncludingEditedBoundaries() {
        let settings = HeartRateZoneSettings(manualMaximum: 184, innerBoundaries: [58, 68, 78, 88])
        for nights: [Double] in [[51], []] {
            let zones = settings.resolved(age: nil, restingNights: nights)!
            XCTAssertEqual(ZoneTwoRange.resolve(zones: zones)?.range, zones.bpmRange(for: 2))
        }
    }
    func testManualWinsWithoutOtherInputs() {
        XCTAssertEqual(ZoneTwoRange.resolve(maximum: nil, restingNights: [], manual: 131...144), .init(lower: 131, upper: 144, source: .manual))
        XCTAssertNil(ZoneTwoRange.resolve(maximum: nil, restingNights: [], manual: 20...250))
    }
}
