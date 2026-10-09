import AnalyticsKit
import XCTest

final class TargetZoneTimelineTests: XCTestCase {
    func testRangeBoundariesAndMissingReadings() {
        let samples = [ActivityHeartRateSample(timestamp: 0, bpm: 130),
                       .init(timestamp: 2, bpm: .nan, valid: false),
                       .init(timestamp: 4, bpm: 150), .init(timestamp: 5, bpm: 151),
                       .init(timestamp: 7, bpm: 129)]
        let spans = TargetZoneTimeline.spans(samples, range: 130...150, start: 0, end: 10)
        XCTAssertEqual(spans.map(\.position), [.inside, .inside, .above, .below])
        XCTAssertEqual(spans.map { $0.end - $0.start }, [2, 1, 2, 3])
    }
    func testGapsAndSessionEndDoNotExtendReadings() {
        let spans = TargetZoneTimeline.spans([.init(timestamp: 0, bpm: 140), .init(timestamp: 60, bpm: 140)],
                                            range: 130...150, start: 0, end: 62)
        XCTAssertEqual(spans.map { $0.end - $0.start }, [5, 2])
        XCTAssertTrue(TargetZoneTimeline.spans([], range: 130...150, start: 0, end: 10).isEmpty)
    }
}
