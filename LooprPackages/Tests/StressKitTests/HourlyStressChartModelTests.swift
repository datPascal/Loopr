import AnalyticsKit
import Foundation
import XCTest
@testable import StressKit

final class HourlyStressChartModelTests: XCTestCase {
    func testScoredHoursProduceVisibleBarsAndMissingHoursStayMissing() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = Date(timeIntervalSince1970: 1_790_121_600).addingTimeInterval(36_000)
        func feature(_ date: Date, state: StressHourFeature.State = .quiet) -> StressHourFeature {
            StressHourFeature(start: date, end: date.addingTimeInterval(3600), state: state, heartRate: 70, rmssd: 40)
        }
        let baseline = (1...14).map { feature(start.addingTimeInterval(Double(-$0 * 86_400))) }
        let day = HourlyStress.resolve([feature(start), feature(start.addingTimeInterval(3600), state: .active),
                                       feature(start.addingTimeInterval(7200), state: .missing)],
                                      baseline: baseline, calendar: calendar)
        let bars = HourlyStressChartModel.scoredBars(in: day)
        XCTAssertEqual(bars.count, 1)
        let bar = try XCTUnwrap(bars.first)
        XCTAssertEqual(bar.score, 50)
        XCTAssertEqual(HourlyStressChartModel.xUnit, .hour)
        XCTAssertEqual(bar.start, start)
        XCTAssertEqual(bar.end, start.addingTimeInterval(3600))
        XCTAssertGreaterThan(bar.end.timeIntervalSince(bar.start), 0)
        XCTAssertNil(day.hours[1].score)
        XCTAssertNil(day.hours[2].score)
    }
}
