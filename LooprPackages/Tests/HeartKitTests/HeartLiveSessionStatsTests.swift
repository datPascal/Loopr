import HeartKit
import DomainKit
import BluetoothKit
import XCTest

final class HeartLiveSessionStatsTests: XCTestCase {
    func testAverageMaximumElapsedAndTimeInZone() {
        var stats = HeartLiveSessionStats()
        let start = Date(timeIntervalSince1970: 100)
        for (second, bpm) in [(0, 100.0), (1, 110), (2, 120), (3, 130)] {
            stats.append(HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: bpm,
                rrMilliseconds: nil, receivedAt: start.addingTimeInterval(Double(second))))
        }
        XCTAssertEqual(stats.averageBPM, 115)
        XCTAssertEqual(stats.maximumBPM, 130)
        XCTAssertEqual(stats.elapsed(at: start.addingTimeInterval(10)), 10)
        let zones = HeartRateZoneSettings().resolved(age: 40)!
        XCTAssertEqual(stats.seconds(in: 1, zones: zones), 1)
        XCTAssertEqual(stats.seconds(in: 2, zones: zones), 2)
    }

    func testGapsDoNotInventZoneTime() {
        var stats = HeartLiveSessionStats()
        let start = Date(timeIntervalSince1970: 100)
        for second in [0.0, 1.0, 20.0] {
            stats.append(HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 120,
                rrMilliseconds: nil, receivedAt: start.addingTimeInterval(second)))
        }
        XCTAssertEqual(stats.seconds(in: 2, zones: HeartRateZoneSettings().resolved(age: 40)!), 1)
    }
}
