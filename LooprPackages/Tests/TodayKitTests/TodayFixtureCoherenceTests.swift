import Foundation
import Testing
import DesignSystem
@testable import TodayKit

/// The Today fixture must tell the same story as every other fixture: its
/// numbers come from `LooprFixtureMetrics`, which the metric pages read too.
struct TodayFixtureCoherenceTests {
    private let links: [TodayMetricID: String] = [
        .readiness: LooprMetricLinkID.recovery,
        .sleep: LooprMetricLinkID.sleepDuration,
        .heart: LooprMetricLinkID.restingHeartRate,
        .strain: LooprMetricLinkID.strain,
        .stress: LooprMetricLinkID.stress,
        .hrv: LooprMetricLinkID.rmssd,
        .steps: LooprMetricLinkID.steps,
        .calories: LooprMetricLinkID.activeEnergy
    ]

    @Test func populatedNumbersMatchTheSharedFixtureTruth() {
        let summary = TodayFixtures.populated
        for (id, link) in links {
            let metric = summary.metric(id)
            #expect(metric?.numericValue == LooprFixtureMetrics.today(link), "\(id)")
            #expect(metric?.value != nil, "\(id)")
        }
        #expect(summary.sleepNeedMinutes == LooprFixtureMetrics.sleepNeedMinutes)
    }

    @Test func displayStringsAgreeWithTheNumbers() {
        let summary = TodayFixtures.populated
        let recovery = LooprFixtureMetrics.today(LooprMetricLinkID.recovery)
        #expect(recovery == 79)
        #expect(summary.metric(.readiness)?.value == recovery.map { String(format: "%.0f", $0) })
        #expect(summary.metric(.sleep)?.value == "7:42")
        #expect(summary.metric(.strain)?.value == "8.6")
        #expect(summary.metric(.steps)?.value == "8,240")
        #expect(summary.metric(.heart)?.value != summary.metric(.hrv)?.value)
    }

    @Test func theStateMatrixUsesTheSameBelievableDay() {
        let partial = TodayFixtures.summary(for: .partial)
        #expect(partial.metric(.hrv)?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.rmssd))
        #expect(partial.metric(.heart)?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.restingHeartRate))
        let values = [TodayMetricID.hrv, .heart, .strain, .stress, .steps].compactMap { partial.metric($0)?.value }
        #expect(Set(values).count == values.count, "No two Today metrics should share one number")
    }

    @Test func thePopulatedDayHasNoFillerAndNoContradiction() {
        let summary = TodayFixtures.populated
        #expect(!summary.notableChanges.contains { $0.localizedCaseInsensitiveContains("steadily") })
        #expect(summary.metrics.allSatisfy { $0.confidence?.lowercased() != "high confidence" })
    }
}
