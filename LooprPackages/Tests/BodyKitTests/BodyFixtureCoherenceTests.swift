import Foundation
import Testing
import DesignSystem
@testable import BodyKit

/// Body rows agree with Today and with their metric pages, and the zone
/// minutes the zone chart draws add up to the zones row.
struct BodyFixtureCoherenceTests {
    private let snapshot = BodyFixtures.snapshot(for: .partial)

    @Test func rowsMatchTheSharedFixtureTruth() {
        #expect(snapshot.metric(.strain)?.value == String(format: "%.1f", LooprFixtureMetrics.today(LooprMetricLinkID.strain) ?? -1))
        #expect(snapshot.metric(.steps)?.value == LooprUnitFormatter.number(LooprFixtureMetrics.today(LooprMetricLinkID.steps) ?? -1))
        #expect(snapshot.metric(.energy)?.value == String(format: "%.0f", LooprFixtureMetrics.today(LooprMetricLinkID.activeEnergy) ?? -1))
    }

    @Test func zoneMinutesAddUpAndOnlyAppearWithData() {
        let total = snapshot.zoneMinutes.reduce(0) { $0 + $1.minutes }
        #expect(snapshot.metric(.zones)?.value == String(format: "%.0f", total))
        #expect(BodyFixtures.snapshot(for: .absent).zoneMinutes.isEmpty)
        #expect(BodyFixtures.snapshot(for: .measuredZero).zoneMinutes.isEmpty)
    }

    @Test func noFillerRowsOrHighConfidenceLines() {
        #expect(snapshot.metric(.effort) == nil)
        #expect(snapshot.metrics.allSatisfy { $0.confidence?.lowercased() != "high confidence" })
    }
}
