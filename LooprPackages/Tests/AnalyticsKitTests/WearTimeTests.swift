import Foundation
import XCTest
@testable import AnalyticsKit

final class WearTimeTests: XCTestCase {
    private let start: TimeInterval = 1_788_739_200

    private func seconds(minutes: ClosedRange<Int>, bpm: Double? = 70, skin: Bool = true) -> [WearSample] {
        minutes.flatMap { minute in
            stride(from: 0, to: 60, by: 10).map { WearSample(timestamp: start + Double(minute * 60 + $0), bpm: bpm, skinContact: skin) }
        }
    }

    func test_countsDistinctWornMinutes() {
        XCTAssertEqual(WearTime.wornMinutes(seconds(minutes: 0...29)), 30)
    }

    func test_gapsAreNotCounted() {
        let samples = seconds(minutes: 0...9) + seconds(minutes: 200...214)
        XCTAssertEqual(WearTime.wornMinutes(samples), 25)
    }

    func test_zeroHeartRateAndNoContactAreOffWrist() {
        let samples = seconds(minutes: 0...9, bpm: 0) + seconds(minutes: 10...19, skin: false)
            + seconds(minutes: 20...24, bpm: nil) + seconds(minutes: 25...29)
        XCTAssertEqual(WearTime.wornMinutes(samples), 5)
    }

    func test_exactlySixtyMinutesPasses() {
        XCTAssertEqual(WearTime.wornMinutes(seconds(minutes: 0...58)), 59)
        XCTAssertFalse(WearTime.hasEnoughWear(59))
        XCTAssertEqual(WearTime.wornMinutes(seconds(minutes: 0...59)), 60)
        XCTAssertTrue(WearTime.hasEnoughWear(60))
    }
}
