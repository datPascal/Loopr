import Foundation
import HealthKitBridge
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif

/// A fake Apple Health store. It filters sleep by source the way the live
/// client does, and deliberately returns Loopr's own sleep samples when
/// `leakOwnSamples` is set so the importer's own guard is exercised.
private actor FakeHealthHistoryStore: HealthHistoryQueryClient {
    var statistics: [HealthHistoryQuantity: [HealthDailyStatistic]] = [:]
    var sleep: [HealthSleepSample] = []
    var requested = true
    var leakOwnSamples = false
    var failing: Set<HealthHistoryQuantity> = []
    private(set) var statisticRequests: [(HealthHistoryQuantity, Date, Date, [String])] = []
    private(set) var sleepRequests: [(Date, Date)] = []
    private(set) var accessRequests: [(Set<HealthHistoryQuantity>, Bool)] = []

    func set(_ quantity: HealthHistoryQuantity, _ values: [HealthDailyStatistic]) { statistics[quantity] = values }
    func setSleep(_ samples: [HealthSleepSample]) { sleep = samples }
    func setRequested(_ value: Bool) { requested = value }
    func setLeak(_ value: Bool) { leakOwnSamples = value }
    func setFailing(_ value: Set<HealthHistoryQuantity>) { failing = value }

    func dailyStatistics(for quantity: HealthHistoryQuantity, from start: Date, to end: Date,
                         calendar: Calendar, excludingBundlePrefixes: [String]) async throws -> [HealthDailyStatistic] {
        statisticRequests.append((quantity, start, end, excludingBundlePrefixes))
        if failing.contains(quantity) { throw FakeFailure.query }
        return (statistics[quantity] ?? []).filter { $0.dayStart >= calendar.startOfDay(for: start) && $0.dayStart < end }
    }

    func sleepSamples(from start: Date, to end: Date, excludingBundlePrefixes: [String]) async throws -> [HealthSleepSample] {
        sleepRequests.append((start, end))
        return sleep.filter { sample in
            sample.end > start && sample.start < end
                && (leakOwnSamples || !HealthHistorySourceFilter.isExcluded(sample.sourceBundleIdentifier, prefixes: excludingBundlePrefixes))
        }
    }

    func historyReadAccessRequested() async -> Bool { requested }
    func historyReadAccessRequested(reading: Set<HealthHistoryQuantity>, readSleep: Bool) async -> Bool {
        accessRequests.append((reading, readSleep))
        return requested
    }
}

private enum FakeFailure: Error { case query }

private final class MemoryImportStore: HealthHistoryImportStore, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: Date] = [:]
    private var rows: [HealthHistoryMetric: [String: HealthHistoryDayValue]] = [:]

    func importCursor(for key: String) throws -> Date? { lock.withLock { cursors[key] } }
    func setImportCursor(_ date: Date, for key: String) throws { lock.withLock { cursors[key] = date } }
    func replaceDailyValues(_ metric: HealthHistoryMetric, from lowerDay: String, through upperDay: String,
                            values: [HealthHistoryDayValue]) throws {
        lock.withLock {
            var current = rows[metric] ?? [:]
            for day in current.keys where day >= lowerDay && day <= upperDay { current[day] = nil }
            for value in values { current[value.localDay] = value }
            rows[metric] = current
        }
    }
    func values(_ metric: HealthHistoryMetric) -> [HealthHistoryDayValue] {
        lock.withLock { (rows[metric] ?? [:]).values.sorted { $0.localDay < $1.localDay } }
    }
    func cursor(_ key: String) -> Date? { lock.withLock { cursors[key] } }
}

final class HealthHistoryImportTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }()
    private let own = "com.loopr.ios"

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testDisabledReadCategoriesAreNeverQueried() async {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar,
            excludedBundlePrefixes: [], mayRead: { $0 == .steps })
        _ = await importer.importHistory(now: day(2026, 9, 3))
        let requests = await client.statisticRequests
        let quantities = requests.map(\.0)
        let sleep = await client.sleepRequests
        let access = await client.accessRequests
        XCTAssertEqual(quantities, [.steps])
        XCTAssertTrue(sleep.isEmpty)
        XCTAssertEqual(access.count, 1)
        XCTAssertEqual(access.first?.0, [.steps])
        XCTAssertEqual(access.first?.1, false)

        let blockedClient = FakeHealthHistoryStore()
        let blocked = HealthHistoryImporter(client: blockedClient, store: store, calendar: calendar,
            excludedBundlePrefixes: [], mayImport: { false })
        _ = await blocked.importHistory(now: day(2026, 9, 3))
        let blockedQueries = await blockedClient.statisticRequests
        let blockedAccess = await blockedClient.accessRequests
        XCTAssertTrue(blockedQueries.isEmpty)
        XCTAssertTrue(blockedAccess.isEmpty)
    }

    func testPartialHealthReadTreatsEmptyTypesAsMissingAndImportsOtherTypes() async throws {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        let date = day(2026, 9, 23, hour: 9)
        await client.set(.steps, [HealthDailyStatistic(dayStart: day(2026, 9, 22), sum: 8_000)])
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar,
            excludedBundlePrefixes: [own], mayRead: { $0 == .steps || $0 == .restingHeartRate })

        let imported = await importer.importHistory(now: date)
        let report = try XCTUnwrap(imported)

        XCTAssertFalse(report.skippedForAccess)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(store.values(.steps).map(\.value), [8_000])
        XCTAssertTrue(store.values(.restingHeartRate).isEmpty)
        XCTAssertEqual(report.importedDays[.restingHeartRate], 0)
        XCTAssertNotNil(store.cursor("apple_health.daily.restingHeartRate"))
    }

    func testNoReadableHistorySkipsQueriesWithoutStoringZero() async {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar,
            excludedBundlePrefixes: [own], mayRead: { _ in false })

        let report = await importer.importHistory(now: day(2026, 9, 23))

        XCTAssertEqual(report?.skippedForAccess, true)
        let statisticRequests = await client.statisticRequests
        let sleepRequests = await client.sleepRequests
        XCTAssertTrue(statisticRequests.isEmpty)
        XCTAssertTrue(sleepRequests.isEmpty)
        XCTAssertTrue(store.values(.steps).isEmpty)
        XCTAssertNil(store.cursor("apple_health.daily.steps"))
    }

    #if canImport(HealthKit)
    func testAuthorizationScopeContainsOnlyEnabledReadTypes() {
        let types = LiveHealthHistoryClient.readTypes(for: [.steps], readSleep: false)
        XCTAssertEqual(types.count, 1)
        XCTAssertTrue(types.contains { $0.identifier == HKQuantityTypeIdentifier.stepCount.rawValue })
        XCTAssertFalse(types.contains { $0.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue })
        XCTAssertTrue(LiveHealthHistoryClient.readTypes(for: [.oxygenSaturation], readSleep: false).isEmpty)
    }
    #endif

    func testHealthMetricKeysAreStable() {
        XCTAssertEqual(HealthHistoryMetric.allCases.map(\.rawValue).sorted(), [
            "active_energy", "deep_sleep", "max_heart_rate", "oxygen_saturation", "rem_sleep", "respiratory_rate",
            "resting_heart_rate", "sdnn", "sleep_duration", "sleep_efficiency", "steps", "vo2_max"
        ])
        XCTAssertFalse(HealthHistoryMetric.allCases.map(\.rawValue).contains("rmssd"))
    }

    func testQuantityMappingKeepsUnitsAndNeverMapsSDNNToRMSSD() {
        let start = day(2026, 9, 1)
        let statistic = HealthDailyStatistic(dayStart: start, average: 0.965, minimum: 0.91, maximum: 0.99, sum: nil)
        let oxygen = HealthHistoryMapping.values(for: .oxygenSaturation, statistics: [statistic], calendar: calendar)
        XCTAssertEqual(oxygen.first?.metric, .oxygenSaturation)
        XCTAssertEqual(oxygen.first?.localDay, "2026-09-01")
        XCTAssertEqual(oxygen.first?.value ?? 0, 96.5, accuracy: 0.0001)
        XCTAssertEqual(oxygen.first?.low ?? 0, 91, accuracy: 0.0001)
        XCTAssertEqual(oxygen.first?.high ?? 0, 99, accuracy: 0.0001)

        let hrv = HealthHistoryMapping.values(for: .heartRateVariabilitySDNN,
            statistics: [HealthDailyStatistic(dayStart: start, average: 48, minimum: 30, maximum: 70)], calendar: calendar)
        XCTAssertEqual(hrv, [HealthHistoryDayValue(metric: .sdnn, localDay: "2026-09-01", value: 48, low: 30, high: 70)])
        XCTAssertEqual(HealthHistoryMapping.metric(for: .heartRateVariabilitySDNN), .sdnn)

        let maxHR = HealthHistoryMapping.values(for: .heartRate,
            statistics: [HealthDailyStatistic(dayStart: start, average: 70, minimum: 48, maximum: 171)], calendar: calendar)
        XCTAssertEqual(maxHR, [HealthHistoryDayValue(metric: .maxHeartRate, localDay: "2026-09-01", value: 171)])

        let steps = HealthHistoryMapping.values(for: .steps, statistics: [
            HealthDailyStatistic(dayStart: start, sum: 8_412),
            HealthDailyStatistic(dayStart: day(2026, 9, 2), sum: nil),
            HealthDailyStatistic(dayStart: day(2026, 9, 3), sum: .nan)
        ], calendar: calendar)
        XCTAssertEqual(steps, [HealthHistoryDayValue(metric: .steps, localDay: "2026-09-01", value: 8_412)],
                       "A day without a sum is absent, never zero")

        let mapped = Set(HealthHistoryQuantity.allCases.map(HealthHistoryMapping.metric(for:)))
        XCTAssertEqual(mapped, [.restingHeartRate, .sdnn, .respiratoryRate, .vo2Max,
                                .maxHeartRate, .steps, .activeEnergy])
    }

    func testSleepAggregationUsesTheWakeDayAndDoesNotDoubleCountOverlappingSources() {
        let watch = "com.apple.health.watch"
        let phone = "com.apple.health.phone"
        let samples = [
            // iPhone in-bed window and an unstaged asleep block.
            HealthSleepSample(start: day(2026, 9, 1, hour: 22, minute: 45), end: day(2026, 9, 2, hour: 7), stage: .inBed, sourceBundleIdentifier: phone),
            HealthSleepSample(start: day(2026, 9, 1, hour: 23), end: day(2026, 9, 2, hour: 6, minute: 30), stage: .asleepUnspecified, sourceBundleIdentifier: phone),
            // Watch stages for the same night.
            HealthSleepSample(start: day(2026, 9, 1, hour: 23), end: day(2026, 9, 2, hour: 1), stage: .asleepCore, sourceBundleIdentifier: watch),
            HealthSleepSample(start: day(2026, 9, 2, hour: 1), end: day(2026, 9, 2, hour: 2), stage: .asleepDeep, sourceBundleIdentifier: watch),
            HealthSleepSample(start: day(2026, 9, 2, hour: 2), end: day(2026, 9, 2, hour: 2, minute: 15), stage: .awake, sourceBundleIdentifier: watch),
            HealthSleepSample(start: day(2026, 9, 2, hour: 2, minute: 15), end: day(2026, 9, 2, hour: 5), stage: .asleepCore, sourceBundleIdentifier: watch),
            HealthSleepSample(start: day(2026, 9, 2, hour: 5), end: day(2026, 9, 2, hour: 6, minute: 30), stage: .asleepREM, sourceBundleIdentifier: watch),
            // An afternoon nap on the same wake day is not the main sleep.
            HealthSleepSample(start: day(2026, 9, 2, hour: 14), end: day(2026, 9, 2, hour: 14, minute: 40), stage: .asleepUnspecified, sourceBundleIdentifier: phone)
        ]
        let nights = HealthSleepAggregation.nights(samples, calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        let night = try? XCTUnwrap(nights.first)
        XCTAssertEqual(night?.wakeDay, "2026-09-02")
        XCTAssertEqual(night?.asleepMinutes ?? 0, 450, accuracy: 0.01, "23:00 to 06:30 counted once across both sources")
        XCTAssertEqual(night?.deepMinutes ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(night?.remMinutes ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(night?.efficiencyPercent ?? 0, 450.0 / 495.0 * 100, accuracy: 0.01)
    }

    func testUnstagedSleepWithoutBedTimeLeavesStagesAndEfficiencyAbsent() {
        let samples = [
            HealthSleepSample(start: day(2026, 9, 3, hour: 0), end: day(2026, 9, 3, hour: 7), stage: .asleepUnspecified)
        ]
        let values = HealthSleepAggregation.values(HealthSleepAggregation.nights(samples, calendar: calendar))
        XCTAssertEqual(values, [HealthHistoryDayValue(metric: .sleepDuration, localDay: "2026-09-03", value: 420)])
    }

    func testFirstImportReadsAYearAndExcludesLooprOwnSamples() async throws {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        let now = day(2026, 9, 23, hour: 9)
        await client.set(.restingHeartRate, [
            HealthDailyStatistic(dayStart: day(2025, 9, 23), average: 60),
            HealthDailyStatistic(dayStart: day(2025, 9, 24), average: 59),
            HealthDailyStatistic(dayStart: day(2026, 9, 22), average: 55)
        ])
        await client.set(.heartRateVariabilitySDNN, [HealthDailyStatistic(dayStart: day(2026, 9, 22), average: 51)])
        await client.setLeak(true)
        await client.setSleep([
            HealthSleepSample(start: day(2026, 9, 21, hour: 23), end: day(2026, 9, 22, hour: 7), stage: .asleepUnspecified,
                              sourceBundleIdentifier: "com.apple.health.watch"),
            // Loopr's own export of the next night must never come back in.
            HealthSleepSample(start: day(2026, 9, 22, hour: 23), end: day(2026, 9, 23, hour: 7), stage: .asleepCore,
                              sourceBundleIdentifier: own)
        ])
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar, excludedBundlePrefixes: [own])
        let report = await importer.importHistory(now: now)
        XCTAssertEqual(report?.failures, [:])

        XCTAssertEqual(store.values(.restingHeartRate).map(\.localDay), ["2025-09-24", "2026-09-22"],
                       "365 days back ends at 2025-09-24; older days are outside the window")
        XCTAssertEqual(store.values(.sdnn).map(\.value), [51])
        XCTAssertEqual(store.values(.sleepDuration).map(\.localDay), ["2026-09-22"])
        XCTAssertTrue(store.values(.deepSleep).isEmpty)

        let requests = await client.statisticRequests
        XCTAssertEqual(requests.count, HealthHistoryQuantity.allCases.count)
        XCTAssertTrue(requests.allSatisfy { $0.1 == self.day(2025, 9, 24) && $0.3 == [self.own] })
        XCTAssertNotNil(store.cursor("apple_health.daily.restingHeartRate"))
        XCTAssertNotNil(store.cursor("apple_health.daily.sleep"))
    }

    func testLaterImportsReReadOnlyRecentDaysAndReflectDeletions() async throws {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        await client.set(.steps, [
            HealthDailyStatistic(dayStart: day(2026, 9, 1), sum: 5_000),
            HealthDailyStatistic(dayStart: day(2026, 9, 20), sum: 6_000),
            HealthDailyStatistic(dayStart: day(2026, 9, 21), sum: 7_000)
        ])
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar, excludedBundlePrefixes: [own])
        await importer.importHistory(now: day(2026, 9, 21, hour: 20))
        XCTAssertEqual(store.values(.steps).map(\.value), [5_000, 6_000, 7_000])

        // Two days later the 20th was deleted in Apple Health and the 22nd
        // arrived. The old 1st is outside the overlap and stays.
        await client.set(.steps, [
            HealthDailyStatistic(dayStart: day(2026, 9, 1), sum: 5_000),
            HealthDailyStatistic(dayStart: day(2026, 9, 21), sum: 7_500),
            HealthDailyStatistic(dayStart: day(2026, 9, 22), sum: 3_000)
        ])
        await importer.importHistory(now: day(2026, 9, 23, hour: 8))
        XCTAssertEqual(store.values(.steps).map(\.localDay), ["2026-09-01", "2026-09-21", "2026-09-22"])
        XCTAssertEqual(store.values(.steps).map(\.value), [5_000, 7_500, 3_000])
        let second = await client.statisticRequests.filter { $0.0 == .steps }.last
        XCTAssertEqual(second?.1, day(2026, 9, 18), "Resumes three days before the last import")
    }

    func testImportWaitsForTheReadRequestAndSurvivesOneFailingType() async throws {
        let client = FakeHealthHistoryStore()
        let store = MemoryImportStore()
        await client.setRequested(false)
        await client.set(.vo2Max, [HealthDailyStatistic(dayStart: day(2026, 9, 10), average: 44.2)])
        let importer = HealthHistoryImporter(client: client, store: store, calendar: calendar, excludedBundlePrefixes: [own])
        let skipped = await importer.importHistory(now: day(2026, 9, 23))
        XCTAssertEqual(skipped?.skippedForAccess, true)
        let untouched = await client.statisticRequests
        XCTAssertTrue(untouched.isEmpty, "No Health query runs before the person answered the request")

        await client.setRequested(true)
        await client.setFailing([.restingHeartRate])
        let report = await importer.importHistory(now: day(2026, 9, 23))
        XCTAssertNotNil(report?.failures["restingHeartRate"])
        XCTAssertEqual(store.values(.vo2Max).map(\.value), [44.2])
        XCTAssertNil(store.cursor("apple_health.daily.restingHeartRate"), "A failed type is retried in full next time")
    }

    func testSourceFilterMatchesTheAppAndItsExtensionsOnly() {
        XCTAssertTrue(HealthHistorySourceFilter.isExcluded("com.loopr.ios", prefixes: [own]))
        XCTAssertTrue(HealthHistorySourceFilter.isExcluded("com.loopr.ios.watchkitapp", prefixes: [own]))
        XCTAssertFalse(HealthHistorySourceFilter.isExcluded("com.loopr.iosother", prefixes: [own]))
        XCTAssertFalse(HealthHistorySourceFilter.isExcluded("com.apple.health.1234", prefixes: [own]))
        XCTAssertFalse(HealthHistorySourceFilter.isExcluded(nil, prefixes: [own]))
        XCTAssertEqual(HealthSleepStage(healthKitValue: 4), .asleepDeep)
        XCTAssertNil(HealthSleepStage(healthKitValue: 9))
    }
}
