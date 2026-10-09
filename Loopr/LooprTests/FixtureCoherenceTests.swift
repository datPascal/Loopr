import DomainKit
import AnalyticsKit
import BodyKit
import DataKit
import DesignSystem
import DeviceCenterKit
import Foundation
import SharedSurfaceKit
import HeartKit
import SleepKit
import Testing
import TodayKit
import WorkoutKit
@testable import Loopr

#if DEBUG
/// The populated fixture tabs and the metric pages' fixture history are one
/// story: a value on a tab is the value its page ends on, and every metric has
/// enough history for a usual range.
struct FixtureCoherenceTests {
    private let end = Date(timeIntervalSince1970: 1_790_000_000)

    private func latest(_ key: MetricKey) -> Double? {
        FixtureMetricHistoryProvider.points(for: key, days: 60, endingOn: end).last?.value
    }

    @Test func everyPageEndsOnTheSharedFixtureValue() {
        for key in MetricKey.allCases {
            #expect(latest(key) == LooprFixtureMetrics.today(key.rawValue), "\(key)")
        }
    }

    @Test func everyCalculatedMetricHasAUsualRange() {
        for key in MetricKey.allCases where !FixtureMetricHistoryProvider.emptyKeys.contains(key) {
            let points = FixtureMetricHistoryProvider.points(for: key, days: 60, endingOn: end)
                .map { LooprChartPoint(date: $0.day, value: $0.value) }
            #expect(LooprBaselineBand.trailing(points, before: end) != nil, "\(key)")
        }
    }

    @Test func todayAgreesWithItsMetricPages() {
        let today = TodayFixtures.populated
        #expect(today.metric(.readiness)?.numericValue == latest(.recovery))
        #expect(today.metric(.hrv)?.numericValue == latest(.rmssd))
        #expect(today.metric(.heart)?.numericValue == latest(.restingHeartRate))
        #expect(today.metric(.sleep)?.numericValue == latest(.sleepDuration))
        #expect(today.metric(.strain)?.numericValue == latest(.strain))
        #expect(today.metric(.steps)?.numericValue == latest(.steps))
        #expect(today.metric(.calories)?.numericValue == latest(.activeEnergy))
    }

    @Test @MainActor func populatedRecoveryAndLearningCaptionCannotAppearTogether() async throws {
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let repository = try #require(TodayContextSourceFactory.make(environment: environment, repositories: nil))
        let summary = TodayFixtures.populated
        let context = try #require(try await repository.context(for: summary.day, summary: summary))
        let shared = TodayDashboard(summary: summary, context: context, pinned: [], isToday: true)
        let goodSummary = SIPolishFixtureWorld.summary
        let goodContext = try #require(DebugCaptureFixtures.siMorningContext(day: goodSummary.day, summary: goodSummary, mode: "good"))
        let good = TodayDashboard(summary: goodSummary, context: goodContext, pinned: [], isToday: true)
        #expect(shared.hero.reading?.score == 79)
        #expect(shared.morningSignalsSubtitle == nil)
        #expect(shared.contributors.allSatisfy { $0.learning == nil })
        #expect(shared.contributors == good.contributors)
        #expect(shared.hero.reading == good.hero.reading)
        #expect(shared.headsUp?.signals.count == 2)
        #expect(shared.headsUp == good.headsUp)
    }

    @Test func sleepHeartAndBodyAgreeWithTheirMetricPages() {
        let sleep = SleepFixtures.snapshot(for: ProductFixture.metricState(for: .populated))
        #expect(sleep.metric("duration")?.numericValue == latest(.sleepDuration))
        #expect(sleep.metric("deep")?.numericValue == latest(.deepSleep))
        #expect(sleep.metric("rem")?.numericValue == latest(.remSleep))

        let heart = HeartFixtures.snapshot(for: ProductFixture.metricState(for: .populated))
        #expect(heart.metric(.restingHeartRate)?.numericValue == latest(.restingHeartRate))
        #expect(heart.metric(.rmssd)?.numericValue == latest(.rmssd))
        #expect(heart.metric(.sdnn)?.numericValue == latest(.sdnn))
        #expect(heart.metric(.respiration)?.numericValue == latest(.respiratoryRate))

        let body = BodyFixtures.snapshot(for: ProductFixture.metricState(for: .populated))
        #expect(body.metric(.strain)?.value == latest(.strain).map { String(format: "%.1f", $0) })
    }

    @Test @MainActor func surfaceRowsMatchTheirHistoryPages() async throws {
        for state in ["ready", "learning", "empty", "flagged"] {
            let snapshot = DebugCaptureFixtures.siPolishSurfaceSnapshot(HeartFixtures.populated, state: state)
            let provider = SISurfacesMetricHistoryProvider(state: state)
            for (id, key) in [(HeartMetricID.heartRateDip, MetricKey.heartRateDip),
                (.sleepingHeartRate, .sleepingHeartRate), (.maxHeartRate, .maxHeartRate)] {
                let row = try #require(snapshot.metric(id))
                let history = try await provider.series(for: key, days: 35, endingOn: end)
                #expect(row.numericValue == history.last?.value)
                #expect((row.value == nil) == (state == "empty"))
            }
        }
    }

    @Test @MainActor func smartInsightsGoodScenarioUsesOneRecoveryAndTarget() async throws {
        let world = SIPolishFixtureWorld.summary
        let recovery = try #require(world.metric(.readiness)?.numericValue)
        #expect(recovery == LooprFixtureMetrics.today(LooprMetricLinkID.recovery))
        let context = try #require(DebugCaptureFixtures.siMorningContext(day: world.day, summary: world, mode: "good"))
        #expect(context.recovery?.explains(recovery) == true)
        let surface = try #require(DebugCaptureFixtures.siSurfacesSnapshot(state: "ready", now: end))
        #expect(TodaySleepNeed.minutes(from: world.goals) == world.sleepNeedMinutes)
        #expect(surface.insight?.sleepNeedMinutes == world.sleepNeedMinutes)
        #expect(surface.metrics.recovery == recovery)
        #expect(surface.metrics.strain == world.metric(.strain)?.numericValue)
        let points = try #require(DebugCaptureFixtures.siBodyMetricPoints(key: .recovery, days: 60,
            endingOn: end, calendar: .current, mode: "ready"))
        #expect(points.last?.value == recovery)
        let history = await DebugCaptureFixtures.siBodyHistory(mode: "ready", anchor: world.day)
        #expect(history.days.last?.recovery == recovery)
        let load = BodyTrainingLoad.compute(history: history, endingOn: world.day.bodyAdding(days: -1))
        if case .ready(let ready) = load {
            let bodyTarget = StrainTarget(recovery: recovery, trainingLoad: ready.model)
            #expect(bodyTarget?.range == SIPolishFixtureWorld.target?.range)
            #expect(bodyTarget?.reason == SIPolishFixtureWorld.target?.reason)
        } else { Issue.record("Expected established synthetic training history") }
        #expect(SIPolishFixtureWorld.target?.range == 14...18)
        #expect(SIPolishFixtureWorld.target?.reason == nil)
        let beats = SIPolishFixtureWorld.beats
        #expect(beats.beatCount % 100 != 0)
        #expect(Set(beats.points.map { $0.current - $0.next }).count > 30)
        let heavy = try #require(DebugCaptureFixtures.siBodyMetricPoints(key: .strain, days: 30,
            endingOn: end, calendar: .current, mode: "flagged"))
        #expect(Set(heavy.suffix(8).map(\.value)).count == 8)
    }

    @Test func todayRingsAndTabsTellTheSameStory() {
        let today = TodayFixtures.populated
        let sleep = SleepFixtures.snapshot(for: ProductFixture.metricState(for: .populated))
        #expect(today.metric(.sleep)?.numericValue == sleep.metric("duration")?.numericValue)
        #expect(today.sleepNeedMinutes == sleep.needHours.map { $0 * 60 })
        let heart = HeartFixtures.snapshot(for: ProductFixture.metricState(for: .populated))
        #expect(today.metric(.heart)?.value == heart.metric(.restingHeartRate)?.value)
    }

    @Test func storeFramesShareTheSameLocalDayAndCompleteBandStatus() async throws {
        #expect(SIPolishFixtureWorld.dayString == "2023-11-14")
        #expect(SIPolishFixtureWorld.dataRecord.day == SIPolishFixtureWorld.dayString)
        let status = SIPolishFixtureWorld.deviceStatus
        let view = try await DeviceCenterViewStateLoader.load(from: InMemoryDeviceCenterRepository(
            identity: SIPolishFixtureWorld.device, status: status))
        #expect(view.universalState == .ready)
        #expect(SIPolishFixtureWorld.device.serialNumber == "4B7C2D9A6F31")
        #expect(SIPolishFixtureWorld.device.modelName == "Gen 4 band")
        #expect(DeviceGeneration.stableGen4.displayName == "WHOOP 4.0")
        for timestamp in [status.lastPacketAt, status.historyCommitAt, status.completedSyncAt, status.storedAt] {
            let date = try #require(timestamp)
            #expect(Calendar.current.isDate(date, inSameDayAs: SIPolishFixtureWorld.captureNow))
            #expect(date <= SIPolishFixtureWorld.captureNow)
        }
        for workout in SIPolishFixtureWorld.workouts {
            #expect(workout.state == .completed)
            let endedAt = try #require(workout.endedAt)
            #expect(endedAt < SIPolishFixtureWorld.captureNow)
            #expect(workout.samples.count > 50)
            #expect(Set(workout.samples.compactMap(\.heartRate)).count > 8)
        }
        let startedAt = try #require(SIPolishFixtureWorld.workouts.first?.startedAt)
        #expect(Calendar.current.isDate(startedAt, inSameDayAs: SIPolishFixtureWorld.captureNow))
    }
}
#endif
