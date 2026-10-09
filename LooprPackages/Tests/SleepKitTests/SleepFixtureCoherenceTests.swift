import Foundation
import Testing
import DesignSystem
@testable import SleepKit

/// The Sleep fixture's night, rows and chart data must add up and agree with
/// the metric pages' fixture history.
struct SleepFixtureCoherenceTests {
    private let snapshot = SleepFixtures.snapshot(for: .partial)

    @Test func rowsMatchTheSharedFixtureTruth() {
        #expect(snapshot.metric("duration")?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration))
        #expect(snapshot.metric("deep")?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.deepSleep))
        #expect(snapshot.metric("rem")?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.remSleep))
        #expect(snapshot.metric("efficiency")?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.sleepEfficiency))
        #expect(snapshot.metric("regularity")?.numericValue == LooprFixtureMetrics.today(LooprMetricLinkID.sleepConsistency))
        #expect(snapshot.needHours == LooprFixtureMetrics.sleepNeedMinutes / 60)
    }

    @Test func theNightAddsUp() throws {
        let main = try #require(snapshot.mainSleep)
        let asleep = snapshot.hypnogram.filter { $0.stage != .awake }.reduce(0) { $0 + $1.durationMinutes }
        let inBed = snapshot.hypnogram.reduce(0) { $0 + $1.durationMinutes }
        #expect(main.durationMinutes == asleep)
        #expect(Int(main.end.timeIntervalSince(main.start) / 60) == inBed)
        let stages = ["deep", "rem", "light"].compactMap { snapshot.metric($0)?.numericValue }.reduce(0, +)
        #expect(Int(stages) == asleep)
        let efficiency = Double(asleep) / Double(inBed) * 100
        #expect(abs(efficiency - (snapshot.metric("efficiency")?.numericValue ?? 0)) < 1)
        #expect(main.isPartial == false, "The populated night is finished")
    }

    @Test func trendEndsOnLastNight() {
        let last = snapshot.trend.last?.value
        #expect(last.map { $0 * 60 } == LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration))
        // Thirty nights, as the derivation folds them, less the nights the
        // shared history leaves out. Every night carries its times and stages.
        #expect(snapshot.trend.count > 20 && snapshot.trend.count <= SleepFixtures.trendNights)
        #expect(snapshot.trend.allSatisfy { $0.start != nil && $0.end != nil && $0.values["deep"] != nil })
    }

    @Test func trendNightsAreLabelledWithTheirOwnDayAndAddUp() throws {
        let last = try #require(snapshot.trend.last)
        #expect(last.localDay == "2023-11-14")
        #expect(last.start == snapshot.mainSleep?.start)
        #expect(last.end == snapshot.mainSleep?.end)
        for point in snapshot.trend.dropLast() {
            let asleep = (point.value ?? 0) * 60
            let stages = ["deep", "rem", "light"].compactMap { point.values[$0] }.reduce(0, +)
            #expect(abs(stages - asleep) < 1)
            let inBed = (point.end ?? .distantPast).timeIntervalSince(point.start ?? .distantPast) / 60
            #expect(abs(inBed - asleep - (point.values["awake"] ?? 0)) < 2)
        }
    }

    @Test func theFixtureNightHasAHeartLineAndOneCorrection() async {
        let samples = await SleepFixtures.DetailSource().overnightHeartRate(from: SleepFixtures.nightStart, to: SleepFixtures.nightEnd)
        let line = SleepOvernightHeartRate.make(samples: samples, start: SleepFixtures.nightStart, end: SleepFixtures.nightEnd)
        #expect(line != nil)
        #expect((line?.lowest?.bpm ?? 0) > 40)
        #expect((line?.highest?.bpm ?? 100) < 80)
        #expect(SleepFixtures.corrections.count == 1)
        #expect(SleepFixtures.corrections.first?.day == SleepFixtures.day)
    }

    @Test func noRowSaysHighConfidence() {
        #expect(snapshot.metrics.allSatisfy { $0.confidence == nil })
    }
}
