import Foundation
import XCTest
import SyncKit

final class BandAlarmFrameTests: XCTestCase {
    func testUnrepresentableDatesThrowInsteadOfTrappingInIntegerConversion() {
        for interval in [Double.nan, .infinity, -.infinity, -1, 1e100, Double(UInt32.max) + 1] {
            XCTAssertThrowsError(try BandAlarmFrame(fireDate: Date(timeIntervalSince1970: interval), driftSeconds: 0))
        }
        XCTAssertThrowsError(try BandAlarmFrame(fireDate: Date(timeIntervalSince1970: 1), driftSeconds: Int64.max))
        XCTAssertThrowsError(try BandAlarmFrame(fireDate: Date(timeIntervalSince1970: 1), driftSeconds: Int64.min))
    }

    func testClockShiftPreservesSubsecondsAndReadbackReversesIt() throws {
        let wake = Date(timeIntervalSince1970: 1_790_000_000.5)
        let frame = try BandAlarmFrame(fireDate: wake, driftSeconds: 120)
        XCTAssertEqual(frame.epochSeconds, 1_789_999_880)
        XCTAssertEqual(frame.subsecondTicks, 16_384)
        XCTAssertEqual(BandAlarmFrame.wallDate(fromBandEpochSeconds: frame.epochSeconds, driftSeconds: 120),
                       Date(timeIntervalSince1970: 1_790_000_000))
    }
}
