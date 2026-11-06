import DomainKit
import AnalyticsKit
import BodyKit
import DataKit
import DesignSystem
import DeviceCenterKit
import FoodKit
import ProfileKit
import RoutineKit
import SettingsKit
import Foundation
import SharedSurfaceKit
import HealthKitBridge
import HeartKit
import SleepKit
import Testing
import TodayKit
import TrainKit
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

    /// ICP R1-OPT-2: the Data tab's day block reads the history Today reads, so a fixture day never says "No records
    /// yet" on Data while Today shows recovery for it.
    @Test @MainActor func dataReadsTheSameHistoryAsTodayForTheSameDay() async throws {
        let populated = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let today = try #require(TodayFixtureHistorySeam.history(environment: populated, repositories: nil))
        let data = DataTabHistory.provider(environment: populated, repositories: nil, fallback: EmptyMetricHistoryProvider())
        for key in [MetricKey.recovery, .sleepDuration, .strain, .rmssd] {
            let onToday = try await today.series(for: key, days: 7, endingOn: end).last?.value
            let onData = try await data.series(for: key, days: 7, endingOn: end).last?.value
            #expect(onToday != nil, "\(key)")
            #expect(onToday == onData, "\(key)")
        }
        // Outside the populated fixture the Data tab keeps the app's own history.
        let empty = AppEnvironment.make(arguments: ["--loopr-launch-mode=empty"], environment: [:])
        #expect(DataTabHistory.provider(environment: empty, repositories: nil, fallback: EmptyMetricHistoryProvider())
            is EmptyMetricHistoryProvider)
        // ICP R2-LAB-22: the absent Data fixture says "No data yet", so its day tiles have no readings either.
        let absent = DataTabHistory.provider(environment: populated, repositories: nil, fallback: EmptyMetricHistoryProvider(),
                                             arguments: ["--loopr-launch-mode=populated", DataOverviewFixtures.absentArgument])
        #expect(try await absent.series(for: .recovery, days: 7, endingOn: end).isEmpty)
    }

    /// R2-UPG-1: one populated fixture day tells Today, Food and Fitness one story. Fitness's dose reads the band minutes
    /// Today's dial and Zone 2 rule read, its plan card plans the session Food's allowance names, its recovery chip
    /// reads Today's recovery, and its age bar reads the launch's profile. A daily protocol rule is not a weekly target.
    @Test @MainActor func fitnessReadsTheDayTodayAndFoodRead() async throws {
        let populated = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let repositories = ProductRepositoryContainer(environment: populated)
        #expect(FitnessFixtureDaySeam.applies(environment: populated, repositories: repositories, arguments: []))
        #expect(!FitnessFixtureDaySeam.applies(environment: populated, repositories: repositories,
                                               arguments: ["--loopr-train-fixture"]))
        let day = FitnessFixtureDaySeam.day(environment: populated)
        #expect(day == TodayFixtures.day)
        let clock = FitnessFixtureDaySeam.clock(environment: populated, repositories: repositories)
        let todayClock = TodayDialLoader(environment: populated, repositories: repositories, history: EmptyMetricHistoryProvider())
            .clock(for: day)
        #expect(clock.now == todayClock.now)

        // Zone 2: Fitness reads the minutes Today's rail reads from the band for the same day and time.
        let rail = ProtocolTabFixture.snapshots(day: day, timeZone: clock.calendar.timeZone, now: clock.now)
        guard case .measured(let railZone2)? = rail.band.readings[.zone2Minutes] else {
            Issue.record("the rail has no measured zone 2 minutes on the fixture day")
            return
        }
        let sources = FitnessFixtureDaySeam.sources(environment: populated, repositories: repositories, arguments: [])
        let input = await FitnessInputMapping.input(sources: sources, now: clock.now, calendar: clock.calendar, train: [], workouts: [])
        let fixtureDay = try #require(input.doseDays.first { $0.day == day })
        #expect(fixtureDay.zones?.zone2 == railZone2)
        let overview = try #require(FitnessOverview.make(input))
        #expect(overview.dose.bandAbsence == nil)
        #expect(overview.dose.zone2.minutes == Int(input.doseDays.compactMap { $0.zones?.zone2 }.reduce(0, +)))
        // The protocol's version 3 asks for "Zone 2, 150 min a week", so the week asks for 150 (ICP R3-VET-05).
        #expect(input.targets.zone2Minutes == 150)
        #expect(input.age == 38)

        // The plan: Fitness plans Upper A on the fixture day, the session Food's allowance names.
        let train = TrainOverviewLoader(repository: repositories.fixtureTrainRepository, workouts: InMemoryWorkoutStore(workouts: []))
        let history = try #require(FitnessFixtureDaySeam.history(environment: populated, repositories: repositories))
        await train.load(now: clock.now, calendar: clock.calendar, history: history)
        guard case .plan(let plan) = train.overview?.today else {
            Issue.record("Fitness plans nothing on the fixture day")
            return
        }
        #expect(plan.name == "Upper A")
        #expect(plan.recoveryShown == TodayFixtures.populated.metric(.readiness)?.numericValue.map { Int($0) })
        let key = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        let food = try await repositories.fixtureFoodRepository.overview(from: key, through: key)
        #expect(food.days.first { $0.localDay == key }?.allowance?.title == plan.name)
    }

    /// R2-OPT-23: the Fitness Ages bar and the Data age ruler read one age source: the same birth year and sex, and
    /// under the Train fixture the same VO₂max readings.
    @Test @MainActor func dataAndFitnessReadOneAgeSource() async throws {
        let populated = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let repositories = ProductRepositoryContainer(environment: populated)
        let fitness = try #require(LooprAgeSource.fitnessProfile(repositories))
        let data = try #require(LooprAgeSource.dataProfile(repositories))
        let onFitness = await fitness(), onData = await data()
        #expect(onFitness?.birthYear == ProductFixtureProfile.populatedBirthYear)
        #expect(onFitness?.birthYear == onData?.birthYear && onFitness?.biologicalSex == onData?.biologicalSex)
        let vo2 = try #require(LooprAgeSource.vo2Max(repositories, arguments: ["--loopr-train-fixture"]))
        guard case .values(let samples) = await vo2(.distantPast, .distantFuture) else {
            Issue.record("Expected the Train fixture's VO2max readings")
            return
        }
        #expect(samples.count == FitnessFixtures.vo2MaxSamples.count)
        #expect(LooprAgeSource.vo2Max(repositories, arguments: []) == nil)
    }

    /// R2-UPG-2: a birth year saved in Profile is the one Data and Fitness read, in a fixture launch as in production.
    @Test @MainActor func profileSavesIntoTheProfileTheRulersRead() async throws {
        let empty = AppEnvironment.make(arguments: ["--loopr-launch-mode=empty"], environment: [:])
        let repositories = ProductRepositoryContainer(environment: empty)
        #expect(try await repositories.fixtureProfile.readProfile() == nil)
        let settings = ProfileBackedSettingsRepository(settings: InMemorySettingsRepository(initial: SettingsSnapshot()),
                                                       profile: repositories.fixtureProfile)
        var snapshot = await settings.snapshot()
        snapshot.profile.birthYear = 1990
        try await settings.update(snapshot)
        #expect(try await repositories.fixtureProfile.readProfile()?.birthYear == 1990)
        #expect(await settings.snapshot().profile.birthYear == 1990)

        let populated = ProductRepositoryContainer(environment: AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"],
                                                                                    environment: [:]))
        #expect(try await populated.fixtureProfile.readProfile()?.birthYear == ProductFixtureProfile.populatedBirthYear)
    }

    @Test @MainActor func populatedAndGoodMorningFixturesAgreeOnRecoveryAndTheOvernightCheck() async throws {
        let environment = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])
        let repository = try #require(TodayContextSourceFactory.make(environment: environment, repositories: nil))
        let summary = TodayFixtures.populated
        let context = try #require(try await repository.context(for: summary.day, summary: summary))
        let shared = TodayDashboard(summary: summary, context: context, isToday: true)
        let goodSummary = SIPolishFixtureWorld.summary
        let goodContext = try #require(DebugCaptureFixtures.siMorningContext(day: goodSummary.day, summary: goodSummary, mode: "good"))
        let good = TodayDashboard(summary: goodSummary, context: goodContext, isToday: true)
        #expect(shared.hero.reading?.score == 79)
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
