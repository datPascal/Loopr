import Foundation
import XCTest
@testable import HeartKit

final class HeartTimelineRangeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_121_600)
    private func request(duration: Double = 3600, width: Double = 100) -> HeartTimelineRangeRequest {
        HeartTimelineRangeRequest(start: start, end: start.addingTimeInterval(duration), pixelWidth: width)
    }
    func testBoundedCountAndExtremaSurviveReduction() {
        let samples = (0..<3600).map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: $0 == 6 ? 180 : 70) }
        let points = HeartTimelineRange.downsample(samples, request: request())
        XCTAssertEqual(points.count, 300)
        XCTAssertEqual(points.map(\.sampleCount).reduce(0, +), samples.count)
        XCTAssertEqual(points[0].maximum, 180)
        XCTAssertEqual(points[0].minimum, 70)
        XCTAssertEqual(points[0].average, (11 * 70 + 180) / 12.0, accuracy: 0.001)
    }
    func testFineRangeKeepsPerSecondValues() {
        let samples = (0..<30).map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: Double(60 + $0)) }
        let points = HeartTimelineRange.downsample(samples, request: request(duration: 30))
        XCTAssertEqual(points.count, 30)
        XCTAssertEqual(points.map(\.average), samples.map(\.bpm))
        XCTAssertTrue(points.allSatisfy { $0.sampleCount == 1 })
    }
    func testGapsAndHalfOpenBoundsNeverCreateReadings() {
        let samples = [-1, 0, 299, 900, 3600].map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: 70) }
        let points = HeartTimelineRange.downsample(samples, request: request())
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.sampleCount).reduce(0, +), 3)
        XCTAssertFalse(points.contains { $0.start <= start.addingTimeInterval(600) && $0.end > start.addingTimeInterval(600) })
    }
    func testInvalidSamplesEmptyAndZeroRange() {
        let samples = [Double.nan, .infinity, 0, 241].map { HeartRateSample(time: start.timeIntervalSince1970, bpm: $0) }
        XCTAssertTrue(HeartTimelineRange.downsample(samples, request: request()).isEmpty)
        XCTAssertTrue(HeartTimelineRange.downsample([], request: request()).isEmpty)
        XCTAssertTrue(HeartTimelineRange.downsample(samples, request: request(duration: 0)).isEmpty)
    }
    func testBudgetIsBoundedForTinyHugeAndInvalidWidths() {
        XCTAssertEqual(request(width: 1).maximumPoints, 30)
        XCTAssertEqual(request(width: 100000).maximumPoints, 2400)
        XCTAssertEqual(request(width: .nan).maximumPoints, 30)
    }
    func testRangeBoundsCoverLongAndShortCivilDays() {
        for duration in [23 * 3600.0, 25 * 3600.0] {
            let query = request(duration: duration)
            let points = HeartTimelineRange.downsample([
                HeartRateSample(time: start.timeIntervalSince1970, bpm: 65),
                HeartRateSample(time: start.timeIntervalSince1970 + duration - 1, bpm: 75),
                HeartRateSample(time: start.timeIntervalSince1970 + duration, bpm: 90)
            ], request: query)
            XCTAssertEqual(points.map(\.sampleCount).reduce(0, +), 2)
            XCTAssertEqual(points.last?.end, query.end)
            XCTAssertLessThanOrEqual(points.count, query.maximumPoints)
        }
    }

    func testUnconfirmedDataKeepsItsStatusAtEveryZoom() {
        let end = start.addingTimeInterval(300)
        let coarse = HeartTimelineBucket(start: start, end: end, minimum: 120, average: 120, maximum: 120,
            sampleCount: 300, unconfirmedCount: 300)
        let samples = (0..<600).map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: 120) }
        let points = HeartTimelineRange.downsample(samples, request: request(duration: 600), unconfirmed: [coarse])
        XCTAssertTrue(points.filter { $0.end <= end }.allSatisfy(\.isUnconfirmed))
        XCTAssertFalse(points.filter { $0.start >= end }.contains(where: \.isUnconfirmed))
    }
    func testDownsamplingIsDeterministicForUnsortedInputWithoutConfidence() {
        let samples = (0..<600).map { HeartRateSample(time: start.timeIntervalSince1970 + Double($0), bpm: Double(60 + $0 % 20)) }
        XCTAssertEqual(HeartTimelineRange.downsample(samples, request: request(duration: 600)),
            HeartTimelineRange.downsample(samples.reversed(), request: request(duration: 600)))
    }
}
