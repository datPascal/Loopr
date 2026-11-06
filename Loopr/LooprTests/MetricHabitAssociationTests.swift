import Foundation
import DomainKit
import JournalKit
import Testing
@testable import Loopr

@MainActor
struct MetricHabitAssociationTests {
    @Test func captureAssociationsAreRecomputedFromEligibleSourceDays() async throws {
        let store = try await FiveTabHabitFixture.makeStore(endingOn: DayIdentity(year: 2023, month: 11, day: 14))
        let records = await store.dayRecords()
        #expect(records.count == 120)
        #expect(records.flatMap(\.responses).allSatisfy { HabitEligibility.isEligible($0) })
        let rows = MetricHabitAssociation.select(key: .rmssd, definitions: await store.definitions(),
            estimates: await store.estimates(), through: "2023-11-14", stage: .internalOnly)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.metric.adjustedRowCount >= 30 })
        #expect(rows.first { $0.definition.name == "Alcohol" }?.difference ?? 0 < 0)
    }
    @Test func readsTheHabitEnginesEstimateForTheSelectedMetric() {
        let estimate = HabitFixtures.estimate(status: .clearAssociation)
        let rows = MetricHabitAssociation.select(key: .recovery, definitions: [HabitFixtures.definition],
            estimates: [estimate], through: "2026-10-12", stage: .beta)
        #expect(rows.count == 1)
        #expect(rows.first?.difference == -7.2)
        #expect(rows.first?.metric.adjustedRowCount == 32)
        #expect(rows.first?.explanation.contains("32 nights") == true)
        #expect(MetricHabitAssociation.select(key: .rmssd, definitions: [HabitFixtures.definition],
            estimates: [estimate], through: "2026-10-12", stage: .beta).isEmpty)
    }

    @Test func secondaryUsesItsOwnStatusWhenRecoveryIsAbsent() {
        func estimate(_ status: HabitInsightStatus) -> HabitImpactEstimate {
            let metric = HabitMetricEstimate(metricID: .hrvRMSSD, yesMean: 65, noMean: 55,
                rawDifference: 10, adjustedDifference: 8, intervalLower: 5, intervalUpper: 11,
                adjustedRowCount: 32, isClear: status == .clearAssociation,
                sample: .init(yesCount: 20, noCount: 20, status: status, validThrough: HabitFixtures.day))
            return HabitImpactEstimate(habitID: HabitFixtures.definition.id, status: .collecting,
                yesCount: 0, noCount: 0, eligibleDayCount: 0, excludedDayCount: 40, metrics: [metric],
                windowStart: HabitFixtures.day, windowEnd: HabitFixtures.day, calculatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let visible = MetricHabitAssociation.select(key: .rmssd, definitions: [HabitFixtures.definition],
            estimates: [estimate(.clearAssociation)], through: "2026-10-12", stage: .beta)
        #expect(visible.count == 1)
        let stale = MetricHabitAssociation.select(key: .rmssd, definitions: [HabitFixtures.definition],
            estimates: [estimate(.stale)], through: "2026-10-12", stage: .beta)
        #expect(stale.isEmpty)
    }

    @Test func gateStalenessAndPastDaysDoNotLeakCurrentAssociations() {
        for status in [HabitInsightStatus.stale, .collecting, .cannotSeparate, .unavailable] {
            #expect(MetricHabitAssociation.select(key: .recovery, definitions: [HabitFixtures.definition],
                estimates: [HabitFixtures.estimate(status: status)], through: "2026-10-12", stage: .beta).isEmpty)
        }
        let estimate = HabitFixtures.estimate(status: .clearAssociation)
        #expect(MetricHabitAssociation.select(key: .recovery, definitions: [HabitFixtures.definition],
            estimates: [estimate], through: "2026-10-12", stage: .disabled).isEmpty)
        #expect(MetricHabitAssociation.select(key: .recovery, definitions: [HabitFixtures.definition],
            estimates: [estimate], through: "2026-06-01", stage: .beta).isEmpty)
    }
}
