import AnalyticsKit
import BodyKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import Foundation
import HeartKit
import JournalKit
import SettingsKit
import SharedSurfaceKit
import SleepKit
import StorageKit
import Testing
import TodayKit

@testable import Loopr

// MARK: - Fixtures

private struct FrozenDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

private enum CrossOwnerFixture {
    static func heartSnapshot(day: DayIdentity, resting: Double?, rmssd: Double?) -> HeartDaySnapshot {
        var metrics: [HeartMetricValue] = []
        if let resting {
            metrics.append(HeartMetricValue(id: .restingHeartRate, title: "Resting heart rate",
                value: String(format: "%.0f", resting), unit: "bpm", state: .partial,
                source: "test", algorithmVersion: "v1", numericValue: resting, numericUnit: .beatsPerMinute))
        }
        if let rmssd {
            metrics.append(HeartMetricValue(id: .rmssd, title: "HRV", value: String(format: "%.0f", rmssd),
                unit: "ms", state: .partial, source: "test", algorithmVersion: "v1",
                numericValue: rmssd, numericUnit: .milliseconds))
        }
        return HeartDaySnapshot(day: day, state: .partial, metrics: metrics, source: "test", algorithmVersion: "v1")
    }

    static func sleepSnapshot(day: DayIdentity, minutes: Int?) -> SleepDaySnapshot {
        let main = minutes.map {
            SleepSessionSummary(id: "night", start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: Double($0) * 60), durationMinutes: $0,
                isMainSleep: true, isPartial: false, confidence: 0.9, state: .partial)
        }
        return SleepDaySnapshot(day: day, state: .partial, mainSleep: main, metrics: [], source: "test")
    }

    static func projection(day: DayIdentity, resting: Double? = nil, rmssd: Double? = nil,
                           sleepMinutes: Int? = nil) -> CanonicalDailyProjection {
        CanonicalDailyProjection(
            revision: 1, movementBaselineRevision: 0, profile: nil, timeZoneIdentifier: "UTC",
            algorithmVersion: "test.1", latestRecord: nil,
            today: TodaySummary(day: day, overallState: .partial,
                freshness: TodayFreshness(state: .partial, updatedAt: nil, ageMinutes: nil, detail: "test"),
                device: TodayDeviceSnapshot(model: "band", generation: "4", connection: .unknown, status: .partial),
                metrics: []),
            sleep: sleepSnapshot(day: day, minutes: sleepMinutes),
            heart: heartSnapshot(day: day, resting: resting, rmssd: rmssd),
            body: BodyDaySnapshot(day: day, state: .partial, metrics: [],
                composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
                cardioAge: nil, looprAge: nil, source: "test"),
            strainConfidence: 0)
    }

    static func day(_ offset: Int) -> DayIdentity {
        DayIdentity(year: 2026, month: 9, day: 21 - offset)
    }
}

// MARK: - Heart trends (analytics request 1)

struct HeartTrendEnrichmentTests {
    @Test
    func trendPointsComeFromTheDaysTheSamePassAlreadyRead() {
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0), resting: 54, rmssd: 60)
        let prior = (1...3).map {
            CrossOwnerFixture.projection(day: CrossOwnerFixture.day($0), resting: 56, rmssd: 52)
        }
        let snapshot = CanonicalDailyAnalytics.heartWithHistory(today, priorDays: prior)

        #expect(snapshot.trend.count == 8)
        #expect(Set(snapshot.trend.map(\.metric)) == [.restingHeartRate, .rmssd])
        #expect(snapshot.trend.first?.localDay == "2026-09-18")
        #expect(snapshot.trend.last?.localDay == "2026-09-21")
        #expect(snapshot.metrics.count == today.heart.metrics.count)
    }

    @Test
    func trendFilterCanReadThePointsThatWereProduced() {
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0), resting: 54, rmssd: 60)
        let prior = (1...6).map {
            CrossOwnerFixture.projection(day: CrossOwnerFixture.day($0), resting: 56, rmssd: 52)
        }
        let snapshot = CanonicalDailyAnalytics.heartWithHistory(today, priorDays: prior)
        let week = HeartTrendFilter.points(snapshot.trend, range: .week)
        #expect(!week.isEmpty)
        #expect(week.allSatisfy { $0.value != nil })
    }

    @Test
    func aDayWithNoHeartMetricsProducesNoPoints() {
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0))
        let snapshot = CanonicalDailyAnalytics.heartWithHistory(today, priorDays: [])
        #expect(snapshot.trend.isEmpty)
    }
}

// MARK: - Daily time in zones (analytics request 3)

struct DailyZoneMinutesTests {
    @Test
    func secondsBecomeMinutesPerZone() {
        let zones = TimeInHeartRateZones(seconds: [600, 300, 120, 0, 0], belowZone1Seconds: 40_000)
        let minutes = CanonicalDailyAnalytics.zoneMinutes(zones)
        #expect(minutes.count == 5)
        #expect(minutes[0].minutes == 10)
        #expect(minutes[1].minutes == 5)
        #expect(minutes[2].minutes == 2)
        #expect(minutes.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test
    func aDayWithNothingAboveZoneOneHasNothingToChart() {
        let zones = TimeInHeartRateZones(seconds: [0, 0, 0, 0, 0], belowZone1Seconds: 86_400)
        #expect(CanonicalDailyAnalytics.zoneMinutes(zones).isEmpty)
        #expect(CanonicalDailyAnalytics.zoneMinutes(nil).isEmpty)
    }

    @Test
    func theBodySnapshotCarriesZonesThroughItsCoding() throws {
        let snapshot = BodyDaySnapshot(
            day: CrossOwnerFixture.day(0), state: .partial, metrics: [],
            composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
            cardioAge: nil, looprAge: nil, source: "test",
            zoneMinutes: [BodyZoneMinutes(id: 1, name: "Recovery", minutes: 12)])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BodyDaySnapshot.self, from: data)
        #expect(decoded.zoneMinutes.map(\.minutes) == [12])
    }
}

// MARK: - Notable changes (features request A2)

struct NotableChangeTests {
    @Test
    func anOrdinaryDaySaysNothing() {
        let prior = (1...10).map {
            CrossOwnerFixture.projection(day: CrossOwnerFixture.day($0), resting: 55, rmssd: 50, sleepMinutes: 420)
        }
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0), resting: 55, rmssd: 50, sleepMinutes: 421)
        #expect(CanonicalDailyAnalytics.notableChanges(current: today, prior: prior).isEmpty)
    }

    @Test
    func aDayOutsideTheTrailingSpreadProducesALine() {
        let prior = (1...10).map { offset -> CanonicalDailyProjection in
            let jitter = Double(offset % 3) - 1
            return CrossOwnerFixture.projection(day: CrossOwnerFixture.day(offset),
                resting: 55 + jitter, rmssd: 50 + jitter, sleepMinutes: 420)
        }
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0), resting: 55, rmssd: 90, sleepMinutes: 420)
        let lines = CanonicalDailyAnalytics.notableChanges(current: today, prior: prior)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("HRV is "))
        #expect(lines[0].hasSuffix("above your recent days."))
    }

    @Test
    func tooFewDaysNeverProducesALine() {
        let prior = (1...3).map {
            CrossOwnerFixture.projection(day: CrossOwnerFixture.day($0), resting: 55, rmssd: 50)
        }
        let today = CrossOwnerFixture.projection(day: CrossOwnerFixture.day(0), resting: 80, rmssd: 90)
        #expect(CanonicalDailyAnalytics.notableChanges(current: today, prior: prior).isEmpty)
    }
}

// MARK: - Surface privacy (features request P8)

struct SurfacePrivacyRedactionTests {
    private static func snapshot() -> SurfaceSnapshot {
        SurfaceSnapshot(
            generation: 1, createdAt: Date(timeIntervalSince1970: 1_000), sourceDay: "2026-09-21",
            syncDate: Date(timeIntervalSince1970: 900),
            metrics: SurfaceMetrics(recovery: 71, sleep: 88, strain: 9.2, heartRate: 54, hrv: 61, steps: 8_200),
            battery: SurfaceBatteryObservation(level: 0.8, observedAt: Date(timeIntervalSince1970: 900)),
            activeWorkout: nil, staleReasons: [])
    }

    @Test
    func everythingOnPublishesTheSnapshotUnchanged() {
        let value = Self.snapshot()
        let published = LooprSurfaceSnapshotWriter.applying(SurfacePrivacySettings(), to: value)
        #expect(published == value)
    }

    @Test
    func theTodayWidgetSwitchClearsTheHealthMetrics() {
        let published = LooprSurfaceSnapshotWriter.applying(
            SurfacePrivacySettings(todayWidget: false), to: Self.snapshot())
        #expect(published.metrics == SurfaceMetrics())
        #expect(published.battery != nil)
        #expect(published.sourceDay == "2026-09-21")
    }

    @Test
    func theBatteryWidgetSwitchClearsOnlyTheBattery() {
        let published = LooprSurfaceSnapshotWriter.applying(
            SurfacePrivacySettings(batteryWidget: false), to: Self.snapshot())
        #expect(published.battery == nil)
        #expect(published.metrics.recovery == 71)
    }

    @Test
    func aMissingSettingsOwnerPublishesNothing() async {
        let denied = await LooprDeniedSurfacePrivacyReader().currentSurfacePrivacy()
        #expect(denied.todayWidget == false)
        #expect(denied.batteryWidget == false)
        #expect(denied.watchSnapshot == false)
        #expect(denied.liveActivity == false)
    }

    @Test
    func theReaderTakesTheSwitchesFromSettings() async throws {
        var stored = SettingsSnapshot()
        stored.surfacePrivacy = SurfacePrivacySettings(
            todayWidget: false, batteryWidget: true, watchSnapshot: false, liveActivity: true)
        let repository = InMemorySettingsRepository(initial: stored)
        let reader = LooprSettingsSurfacePrivacyReader(repository: repository)
        let value = await reader.currentSurfacePrivacy()
        #expect(value.todayWidget == false)
        #expect(value.batteryWidget)
        #expect(value.watchSnapshot == false)
        #expect(value.liveActivity)
    }
}

// MARK: - Units reach the design system (features request P8)

struct MeasurementSystemBridgeTests {
    @Test
    func theTokenBridgeCarriesUnitsAndHintsIntoTheDesignSystem() async throws {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        var stored = SettingsSnapshot()
        stored.units = .imperial
        stored.accessibility = AccessibilitySettings(voiceOverHints: false)
        let repository = InMemorySettingsRepository(initial: stored)
        let bridge = LooprDesignSystemTokenBridge()
        let viewModel = await SettingsScreenViewModel(repository: repository, tokenBridge: bridge)
        await viewModel.load()
        #expect(DesignSystemRuntime.state().measurementSystem == .imperial)
        #expect(DesignSystemRuntime.state().voiceOverHints == false)
    }

    @Test
    func storedUnitEnumsMapOntoTheRenderingEnum() {
        #expect(SettingsKit.UnitSystem.imperial.looprMeasurementSystem == .imperial)
        #expect(SettingsKit.UnitSystem.metric.looprMeasurementSystem == .metric)
    }
}

// MARK: - Find my strap guidance (cpu request C1)

/// The Find screen keeps two readings: the newest and the one before it. This
/// is the shift the screen performs on every emitted value, checked against
/// the guidance the person actually sees.
struct FindMyStrapGuidanceWiringTests {
    private func guidance(for readings: [Int?]) -> [RSSIGuidance] {
        var current: Int?
        var previous: Int?
        return readings.map { value in
            previous = current
            current = value
            return FindMyStrapGuidanceCalculator.feedback(
                currentRSSI: current, previousRSSI: previous).guidance
        }
    }

    @Test
    func theFirstReadingHasNothingToCompareAgainstYet() {
        let values = guidance(for: [-70])
        #expect(values.count == 1)
        #expect(values[0] != .unavailable)
    }

    @Test
    func walkingTowardsTheBandReadsAsWarmer() {
        let values = guidance(for: [-80, -60])
        #expect(values.last == .warmer)
    }

    @Test
    func walkingAwayReadsAsColder() {
        let values = guidance(for: [-60, -85])
        #expect(values.last == .colder)
    }

    @Test
    func aDroppedLinkStopsGuidingRatherThanKeepingTheLastArrow() {
        let values = guidance(for: [-60, -55, nil])
        #expect(values.last == .unavailable)
    }
}
