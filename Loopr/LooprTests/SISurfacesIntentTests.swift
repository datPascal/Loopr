import DesignSystem
import Foundation
import SharedSurfaceKit
import SettingsKit
import XCTest
@testable import Loopr

final class SISurfacesIntentTests: XCTestCase {
    private var now: Date { Date() }
    private func snapshot(recovery: Double? = 74, day: String? = nil, insight: SurfaceDayInsight? = nil) -> SurfaceSnapshot {
        let date = now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let label = day ?? String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        return .init(generation: 1, createdAt: date, sourceDay: label, syncDate: date,
            metrics: .init(recovery: recovery, strain: 10.2, sleepMinutes: 462), battery: nil,
            activeWorkout: nil, staleReasons: [], insight: insight ?? .init(headline: "Your overnight heart rate is close to usual.",
                recoveryStyle: LooprDerivedDataPublisher.recoveryStyle(score: recovery), sleepNeedMinutes: 480))
    }
    func testRecoveryIntentUsesVerdictAndTheSameHeadlineAsToday() {
        let value = snapshot()
        let dialog = LooprRecoveryIntent.dialog(snapshot: value, now: now)
        XCTAssertTrue(dialog.contains("74 · Ready"))
        XCTAssertTrue(dialog.contains(value.insight!.headline!))
    }
    func testSleepAndStrainUseAppUnitsAndNeed() {
        XCTAssertEqual(LooprSleepIntent.dialog(snapshot: snapshot(), now: now), "Sleep 7 hours, 42 minutes. -18 min vs need.")
        XCTAssertEqual(LooprStrainIntent.dialog(snapshot: snapshot(), now: now), "Strain 10.2 out of 21.")
        XCTAssertEqual(SurfaceMetricFormatting.duration(minutes: 462), LooprUnitFormatter.duration(minutes: 462))
    }
    func testUnavailableRecoveryExplainsLearningRatherThanThrowing() {
        let value = snapshot(recovery: nil, insight: .init(nightsRecorded: 1, nightsNeeded: 3))
        XCTAssertTrue(LooprRecoveryIntent.dialog(snapshot: value, now: now).contains("1 of 3 nights"))
        XCTAssertTrue(LooprRecoveryIntent.dialog(snapshot: nil, now: now).contains("Open Loopr to sync"))
    }
    func testYesterdayIsNeverSpokenAsTodaysScoreOrSleep() {
        let value = snapshot(day: "2020-01-01")
        XCTAssertFalse(LooprRecoveryIntent.dialog(snapshot: value, now: now).contains("74"))
        XCTAssertFalse(LooprSleepIntent.dialog(snapshot: value, now: now).contains("7 hours, 42 minutes"))
    }
    func testPrivacySwitchRemovesTheHeadlineAndStyleAlongWithMetrics() {
        let value = LooprSurfaceSnapshotWriter.applying(
            .init(todayWidget: false, batteryWidget: true, watchSnapshot: true, liveActivity: true), to: snapshot())
        XCTAssertEqual(value.metrics, SurfaceMetrics())
        XCTAssertNil(value.insight)
    }

    func testHeartMetricsAreCalculatedAndNegativeDipsRemainOnChart() {
        for key in [MetricKey.heartRateDip, .sleepingHeartRate, .maxHeartRate] {
            if case .calculated = key.presentation.availability {} else { XCTFail(key.rawValue) }
        }
        XCTAssertNil(MetricDetailRules.scale(for: .heartRateDip).bounds)
        XCTAssertEqual(MetricKey.steps.presentation.title, "Estimated steps")
    }
}
