import Foundation
import Testing
import DesignSystem
@testable import HeartKit

/// Every Heart metric has its own believable number, and it is the number the
/// metric page ends on.
struct HeartFixtureCoherenceTests {
    private let snapshot = HeartFixtures.snapshot(for: .partial)

    @Test func eachRowMatchesTheSharedFixtureTruth() {
        for metric in snapshot.metrics {
            guard let link = metric.id.metricLinkID else { continue }
            #expect(metric.numericValue == LooprFixtureMetrics.today(link), "\(metric.id)")
        }
    }

    @Test func noTwoHeartMetricsShareOneNumber() {
        let values = snapshot.metrics.compactMap(\.value)
        #expect(values.count >= 5)
        #expect(Set(values).count == values.count)
    }

    @Test func metricsLooprDoesNotCalculateAreAbsentNotInvented() {
        let dip = snapshot.metric(.heartRateDip)
        #expect(dip?.value == nil)
        #expect(dip?.state == .absent)
        #expect(snapshot.metric(.frequencyDomain) == nil)
        #expect(snapshot.metric(.quality) == nil)
    }

    @Test func weekTrendEndsOnTheFixtureDay() {
        #expect(snapshot.trend.count == 7)
        #expect(snapshot.trend.last?.value == snapshot.metric(.restingHeartRate)?.value)
        #expect(snapshot.trend.last?.localDay == "2023-11-14")
    }
}
