import XCTest
import Foundation
import UIKit
import HealthKit
import AnalyticsKit
import HealthKitBridge
import StorageKit
import DomainKit
import ProfileKit
import WorkoutKit
import DesignSystem
import HeartKit
import SleepKit
import TodayKit
import BodyKit
import OnboardingKit
@testable import Loopr

private struct HealthTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

private actor HealthRuntimeClient: HealthSyncClient {
    var granted: Set<ExportMetricKind> = []
    var writes: [HealthSyncSample] = []
    var requests = 0
    func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState { granted.contains(metric) ? .authorized : .notDetermined }
    func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws { requests += 1 }
    func save(_ sample: HealthSyncSample, version: Int) async throws { writes.append(sample) }
    func remove(metric: ExportMetricKind, identifiers: [String]) async throws {}
    func allow(_ metrics: Set<ExportMetricKind>) { granted = metrics }
    func saved() -> [HealthSyncSample] { writes }
    func requestCount() -> Int { requests }
}

/// Records the one sheet `requestPermission()` asks for.
private actor HealthAuthorizationRecorder: HealthSyncClient, HealthHistoryAuthorizing {
    private(set) var sharing: Set<ExportMetricKind>?
    private(set) var reading: Set<HealthHistoryQuantity>?
    private(set) var readSleep: Bool?
    private(set) var sheets = 0
    func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState { .notDetermined }
    func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws {}
    func save(_ sample: HealthSyncSample, version: Int) async throws {}
    func remove(metric: ExportMetricKind, identifiers: [String]) async throws {}
    func requestAuthorization(sharing share: Set<ExportMetricKind>, reading: Set<HealthHistoryQuantity>,
                              readSleep: Bool) async throws {
        sheets += 1
        sharing = share
        self.reading = reading
        self.readSleep = readSleep
    }
}

@MainActor
final class HealthSyncRuntimeTests: XCTestCase {
    /// The onboarding step must name exactly what the sheet asks for, reads
    /// included. The request captured here is the real one, and the step's
    /// lists are compared with it type by type.
    func testOnboardingHealthStepListsExactlyWhatTheSheetRequests() async throws {
        for disabled in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-request-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
            let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
            let dates = HealthTestDate(value: Date(timeIntervalSince1970: Double(start + 120)))
            let analytics = try CanonicalDailyAnalytics(history: history, products: products,
                profile: InMemoryProfileRepository(), dateProvider: dates,
                timeZoneProvider: HealthExportTimeZone(timeZone: .gmt))
            let store = try SQLiteHealthSyncStore(database: products, timeZone: "UTC")
            let client = HealthAuthorizationRecorder()
            let runtime = try LooprHealthSyncRuntime(history: history, analytics: analytics,
                workouts: InMemoryWorkoutStore(), store: store, dates: dates, client: client)
            if disabled {
                // Choices made in Settings narrow the sheet, and the step.
                try await runtime.setWriteEnabled(false, for: .steps)
                try await runtime.setReadEnabled(false, for: .vo2Max)
                try await runtime.setReadEnabled(false, for: nil)
            }

            let readsOxygen = await runtime.allowsRead(.oxygenSaturation)
            let readsVO2Max = await runtime.allowsRead(.vo2Max)
            XCTAssertFalse(readsOxygen)
            XCTAssertEqual(readsVO2Max, !disabled)

            let listed = await runtime.permissionRequest()
            let shown = try XCTUnwrap(listed)
            await runtime.requestPermission()

            let sheets = await client.sheets
            let requestedSharing = await client.sharing
            let requestedReading = await client.reading
            let requestedSleep = await client.readSleep
            let sharing = try XCTUnwrap(requestedSharing)
            let reading = try XCTUnwrap(requestedReading)
            let readSleep = try XCTUnwrap(requestedSleep)
            XCTAssertEqual(sheets, 1)
            XCTAssertEqual(shown, OnboardingHealthRequest(writes: sharing, reads: reading, readsSleep: readSleep))

            let expectedSaves = Set(sharing.map { OnboardingHealthType.write($0).name })
            let expectedReads = Set(reading.map { OnboardingHealthType.read($0).name })
                .union(readSleep ? ["Sleep"] : [])
            XCTAssertEqual(Set(shown.orderedWrites.map(\.name)), expectedSaves)
            XCTAssertEqual(Set(shown.orderedReads.map(\.name)), expectedReads)
            XCTAssertEqual(shown.orderedWrites.count, sharing.count)
            XCTAssertEqual(shown.orderedReads.count, reading.count + (readSleep ? 1 : 0))
            if disabled {
                XCTAssertFalse(sharing.contains(.steps))
                XCTAssertFalse(reading.contains(.vo2Max))
                XCTAssertFalse(readSleep)
                XCTAssertFalse(shown.orderedReads.map(\.name).contains("Cardio fitness"))
            } else {
                // A fresh install asks for every type, and the step says so.
                XCTAssertEqual(shown, OnboardingHealthRequest.freshInstall)
                XCTAssertEqual(sharing, LooprHealthSyncRuntime.metrics)
                XCTAssertFalse(reading.contains(.oxygenSaturation))
                XCTAssertTrue(shown.importsHistory)
                XCTAssertEqual(OnboardingCopy.Health.detail(for: shown), OnboardingCopy.Health.detail)
            }
        }
    }

    func testLegacyOxygenPreferenceCannotReintroduceAnOxygenRead() throws {
        let legacy = HealthSyncPreferences(disabledRead: [.oxygenSaturation], timeZoneIdentifier: "UTC")
        let reopened = try JSONDecoder().decode(HealthSyncPreferences.self, from: JSONEncoder().encode(legacy))
        let request = LooprHealthSyncRuntime.permissionRequest(for: reopened)
        XCTAssertFalse(request.reads.contains(.oxygenSaturation))
        XCTAssertFalse(request.orderedReads.map(\.name).contains("Blood oxygen"))
    }

    func testHealthPurposeStringsNameTheRequestedTypesWithoutOxygen() throws {
        let share = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String)
        let update = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String)
        for name in ["sleep", "heart rate", "resting heart rate", "SDNN", "respiratory rate", "VO₂ max", "steps", "active energy"] {
            XCTAssertTrue(share.localizedCaseInsensitiveContains(name), "Read purpose omits \(name)")
        }
        for name in ["heart rate", "resting heart rate", "SDNN", "respiratory rate", "sleep stages", "steps", "active energy", "workouts"] {
            XCTAssertTrue(update.localizedCaseInsensitiveContains(name), "Write purpose omits \(name)")
        }
        XCTAssertFalse(share.localizedCaseInsensitiveContains("oxygen"))
        XCTAssertFalse(update.localizedCaseInsensitiveContains("oxygen"))
    }

    private let start: Int64 = 1_788_739_200

    func testCategoryChoicesPersistAndBlockExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-categories-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        for second in 0..<60 { try history.replaceHistoricalSecond(record(second, bpm: 60)) }
        let dates = HealthTestDate(value: Date(timeIntervalSince1970: Double(start + 120)))
        let analytics = try CanonicalDailyAnalytics(history: history, products: products,
            profile: InMemoryProfileRepository(), dateProvider: dates,
            timeZoneProvider: HealthExportTimeZone(timeZone: .gmt))
        let store = try SQLiteHealthSyncStore(database: products, timeZone: "UTC")
        let client = HealthRuntimeClient()
        await client.allow([.heartRate])
        let runtime = try LooprHealthSyncRuntime(history: history, analytics: analytics,
            workouts: InMemoryWorkoutStore(), store: store, dates: dates, client: client)

        try await runtime.setWriteEnabled(false, for: .heartRate)
        try await runtime.setReadEnabled(false, for: .steps)
        try await runtime.setReadEnabled(false, for: nil)
        await runtime.synchronizeNow()
        let writesWhileOff = await client.saved()
        XCTAssertTrue(writesWhileOff.isEmpty)

        let reopened = try SQLiteHealthSyncStore(database: StorageDatabase(url: root.appendingPathComponent("products.sqlite")), timeZone: "Asia/Bangkok")
        let preferences = try reopened.preferences()
        XCTAssertTrue(preferences.disabledWrite.contains(.heartRate))
        XCTAssertTrue(preferences.disabledRead.contains(.steps))
        XCTAssertFalse(preferences.sleepReadEnabled)
        XCTAssertEqual(preferences.timeZoneIdentifier, "UTC")

        try await runtime.setWriteEnabled(true, for: .heartRate)
        await runtime.synchronizeNow()
        let writesAfterEnable = await client.saved()
        let permissionRequests = await client.requestCount()
        XCTAssertEqual(writesAfterEnable.map(\.metric), [.heartRate])
        XCTAssertEqual(permissionRequests, 0)
    }

    func testHealthAccessLinkChoosesHealthAndSettingsURLs() {
        var checked: [URL] = []
        var opened: [URL] = []
        AppleHealthAccessLink.open(canOpen: { checked.append($0); return true }, open: { opened.append($0) })
        XCTAssertEqual(checked, [AppleHealthAccessLink.healthURL])
        XCTAssertEqual(opened.map(\.scheme), ["x-apple-health"])

        checked = []
        opened = []
        AppleHealthAccessLink.open(canOpen: { checked.append($0); return false }, open: { opened.append($0) })
        XCTAssertEqual(checked, [AppleHealthAccessLink.healthURL])
        XCTAssertEqual(opened.map(\.absoluteString), [UIApplication.openSettingsURLString])

        let canOpenHealth = UIApplication.shared.canOpenURL(AppleHealthAccessLink.healthURL)
        opened = []
        AppleHealthAccessLink.open(canOpen: { UIApplication.shared.canOpenURL($0) },
                                   open: { opened.append($0) })
        XCTAssertEqual(opened, [AppleHealthAccessLink.destination(canOpenHealthURL: canOpenHealth)])
    }

    func testProductionHistoryReachesClientWithoutDuplicateWritesAndOptOutPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-runtime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        for second in 0..<60 { try history.replaceHistoricalSecond(record(second, bpm: 60)) }
        let dates = HealthTestDate(value: Date(timeIntervalSince1970: Double(start + 120)))
        let analytics = try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: dates, timeZoneProvider: HealthExportTimeZone(timeZone: .gmt))
        let store = try SQLiteHealthSyncStore(database: products, timeZone: "UTC")
        let client = HealthRuntimeClient()
        let runtime = try LooprHealthSyncRuntime(history: history, analytics: analytics, workouts: InMemoryWorkoutStore(), store: store, dates: dates, client: client)
        await runtime.synchronizeNow()
        let initial = await client.saved()
        let requests = await client.requestCount()
        XCTAssertTrue(initial.isEmpty)
        XCTAssertEqual(requests, 0, "Default-on must not present an unsolicited permission sheet")
        await client.allow([.heartRate])
        await runtime.synchronizeNow()
        await runtime.synchronizeNow()
        let saved = await client.saved()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.value, 60)
        XCTAssertEqual(saved.first?.metric, .heartRate)
        try await runtime.setEnabled(false)
        let reopened = try SQLiteHealthSyncStore(database: StorageDatabase(url: root.appendingPathComponent("products.sqlite")), timeZone: "Asia/Bangkok")
        XCTAssertFalse(try reopened.preferences().enabled)
        XCTAssertEqual(try reopened.preferences().timeZoneIdentifier, "UTC")
        for second in 60..<120 { try history.replaceHistoricalSecond(record(second, bpm: 80)) }
        await runtime.synchronizeNow()
        let afterDisable = await client.saved()
        XCTAssertEqual(afterDisable.count, 1)
        try await runtime.setEnabled(true)
        await runtime.synchronizeNow()
        let afterEnable = await client.saved()
        XCTAssertEqual(Set(afterEnable.map(\.identifier)).count, 2)
        try await runtime.deleteAll()
        await runtime.synchronizeNow()
        XCTAssertTrue(try store.documents.keys().isEmpty)
    }

    func testHeartRateMinuteRequiresDistinctValidSecondsAndNeverExportsFutureOrOffWristData() {
        let now = Date(timeIntervalSince1970: Double(start + 120))
        let records = (0..<30).map { record($0, bpm: 70) }
            + (0..<30).map { record($0, bpm: 70) }
            + (60..<90).map { record($0, bpm: 0) }
            + (120..<180).map { record($0, bpm: 80) }
        let samples = LooprHealthSyncRuntime.heartRateSamples(records, before: now, timeZone: "UTC")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 70)
        XCTAssertTrue(LooprHealthSyncRuntime.heartRateSamples(Array(records.prefix(29)), before: now, timeZone: "UTC").isEmpty)
    }

    func testSynchronizeSavesDerivedRespiratoryRateOverTheMainSleepWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("health-respiration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        // The automatic path needs three hours before it calls a window the
        // main sleep, so this fixture seeds a four-hour night.
        try seedRespiratoryNight(history, seconds: 14_401)
        let dates = HealthTestDate(value: Date(timeIntervalSince1970: Double(start + 36_000)))
        let analytics = try CanonicalDailyAnalytics(
            history: history,
            products: products,
            profile: InMemoryProfileRepository(),
            dateProvider: dates,
            timeZoneProvider: HealthExportTimeZone(timeZone: .gmt)
        )
        let store = try SQLiteHealthSyncStore(database: products, timeZone: "UTC")
        let client = HealthRuntimeClient()
        await client.allow([.respiratoryRate])
        let runtime = try LooprHealthSyncRuntime(
            history: history,
            analytics: analytics,
            workouts: InMemoryWorkoutStore(),
            store: store,
            dates: dates,
            client: client
        )

        await runtime.synchronizeNow()

        let saved = await client.saved()
        let sample = try XCTUnwrap(saved.first { $0.metric == .respiratoryRate })
        let savedProjection = try await analytics.read(day: DayIdentity(year: 2026, month: 9, day: 7))
        let projection = try XCTUnwrap(savedProjection)
        XCTAssertGreaterThan(sample.value, 0)
        XCTAssertEqual(sample.start, projection.sleep.mainSleep?.start)
        XCTAssertEqual(sample.end, projection.sleep.mainSleep?.end)
        XCTAssertEqual(sample.algorithm, AnalyticsAlgorithmVersion.respiration)
    }

    func testWorkoutIdentityTypeAndDatesSurviveExportAndImportedOrDiscardedWorkoutsAreExcluded() throws {
        var workout = WorkoutFixtures.completedRun
        let now = try XCTUnwrap(workout.endedAt).addingTimeInterval(60)
        let sample = try XCTUnwrap(LooprHealthSyncRuntime.workoutSample(workout, before: now, timeZone: "UTC"))
        XCTAssertEqual(sample.identifier, "com.loopr.workout.\(workout.id.uuidString)")
        XCTAssertEqual(sample.start, workout.startedAt)
        XCTAssertEqual(sample.end, workout.endedAt)
        XCTAssertEqual(LiveHealthKitClient.workoutActivity(sample.workoutActivity), .running)
        XCTAssertEqual(LiveHealthKitClient.workoutActivity("strength"), .traditionalStrengthTraining)
        XCTAssertEqual(LiveHealthKitClient.workoutActivity("yoga"), .yoga)
        workout.source = .healthKit
        XCTAssertNil(LooprHealthSyncRuntime.workoutSample(workout, before: now, timeZone: "UTC"))
        workout.source = .manual
        workout.state = .discarded
        XCTAssertNil(LooprHealthSyncRuntime.workoutSample(workout, before: now, timeZone: "UTC"))
        workout.state = .active
        XCTAssertNil(LooprHealthSyncRuntime.workoutSample(workout, before: now, timeZone: "UTC"))
    }

    func testNightlyExportUsesSDNNAndAppleSleepStagesWithQualityGates() {
        XCTAssertTrue(LooprHealthSyncRuntime.metrics.contains(.respiratoryRate))
        let beginning = Date(timeIntervalSince1970: Double(start))
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let sleep = SleepDaySnapshot(day: day, state: .partial,
            mainSleep: SleepSessionSummary(id: "night", start: beginning, end: beginning.addingTimeInterval(240),
                durationMinutes: 4, isMainSleep: true, isPartial: false, confidence: 0.8, state: .partial),
            metrics: [], hypnogram: [.init(id: 0, stage: .light, durationMinutes: 1), .init(id: 1, stage: .deep, durationMinutes: 1),
                .init(id: 2, stage: .rem, durationMinutes: 1), .init(id: 3, stage: .awake, durationMinutes: 1)], source: "test")
        let heart = HeartDaySnapshot(day: day, state: .partial, metrics: [
            HeartMetricValue(id: .sdnn, title: "SDNN", value: "45", unit: "ms", state: .partial, source: "test", numericValue: 45),
            HeartMetricValue(id: .rmssd, title: "RMSSD", value: "90", unit: "ms", state: .partial, source: "test", numericValue: 90),
            HeartMetricValue(id: .respiration, title: "Respiratory rate", value: "14", unit: "br/min", state: .partial, confidence: "0.8", source: "test", algorithmVersion: AnalyticsAlgorithmVersion.respiration, numericValue: 14, numericUnit: .breathsPerMinute)
        ], source: "test")
        let projection = CanonicalDailyProjection(revision: 1, movementBaselineRevision: 0, profile: nil,
            timeZoneIdentifier: "UTC", algorithmVersion: "test", latestRecord: beginning.addingTimeInterval(600),
            today: TodayFixtures.populated, sleep: sleep, heart: heart, body: BodyFixtures.populated, strainConfidence: 0.8)
        let samples = LooprHealthSyncRuntime.dailySamples(projection, start: beginning, end: beginning.addingTimeInterval(86_400), timeZone: "UTC")
        XCTAssertEqual(samples.first { $0.metric == .heartRateVariabilitySDNN }?.value, 45)
        let respiration = samples.first { $0.metric == .respiratoryRate }
        XCTAssertEqual(respiration?.value, 14)
        XCTAssertEqual(respiration?.start, sleep.mainSleep?.start)
        XCTAssertEqual(respiration?.end, sleep.mainSleep?.end)
        XCTAssertEqual(samples.filter { $0.metric == .sleepStages }.map(\.value), [3, 4, 5, 2])
        XCTAssertFalse(samples.contains { $0.metric == .activeEnergy })

        let absentProjection = CanonicalDailyProjection(revision: 1, movementBaselineRevision: 0, profile: nil,
            timeZoneIdentifier: "UTC", algorithmVersion: "test", latestRecord: beginning.addingTimeInterval(600),
            today: TodayFixtures.populated, sleep: sleep,
            heart: HeartDaySnapshot(day: day, state: .partial, metrics: heart.metrics.filter { $0.id != .respiration }, source: "test"),
            body: BodyFixtures.populated, strainConfidence: 0.8)
        XCTAssertFalse(LooprHealthSyncRuntime.dailySamples(absentProjection, start: beginning,
            end: beginning.addingTimeInterval(86_400), timeZone: "UTC").contains { $0.metric == .respiratoryRate })
    }

    func testActiveEnergyIsExportedOnlyWhenItCameFromTheUsersOwnAnchors() {
        XCTAssertTrue(LooprHealthSyncRuntime.metrics.contains(.activeEnergy))
        let beginning = Date(timeIntervalSince1970: Double(start))
        let end = beginning.addingTimeInterval(86_400)

        let confident = LooprHealthSyncRuntime.dailySamples(
            energyProjection(value: "430", state: .partial), start: beginning, end: end, timeZone: "UTC"
        ).first { $0.metric == .activeEnergy }
        XCTAssertEqual(confident?.value, 430)
        XCTAssertEqual(confident?.start, beginning)
        XCTAssertEqual(confident?.end, end)
        XCTAssertEqual(confident?.identifier, "com.loopr.day.\(start).activeEnergy")

        // A textbook maximum heart rate rather than the person's own leaves
        // the estimate low confidence, and it stays inside Loopr.
        XCTAssertFalse(LooprHealthSyncRuntime.dailySamples(
            energyProjection(value: "430", state: .lowConfidence), start: beginning, end: end, timeZone: "UTC"
        ).contains { $0.metric == .activeEnergy })
        XCTAssertFalse(LooprHealthSyncRuntime.dailySamples(
            energyProjection(value: nil, state: .absent), start: beginning, end: end, timeZone: "UTC"
        ).contains { $0.metric == .activeEnergy })
    }

    private func energyProjection(value: String?, state: MetricState) -> CanonicalDailyProjection {
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let body = BodyDaySnapshot(day: day, state: .partial, metrics: [
            BodyMetricValue(id: .energy, title: "Active energy", value: value, unit: "kcal",
                            state: state, source: "test", algorithmVersion: "workout.v1")
        ], composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
           cardioAge: nil, looprAge: nil, source: "test")
        return CanonicalDailyProjection(
            revision: 1, movementBaselineRevision: 0, profile: nil, timeZoneIdentifier: "UTC",
            algorithmVersion: "test", latestRecord: Date(timeIntervalSince1970: Double(start + 600)),
            today: TodayFixtures.populated,
            sleep: SleepDaySnapshot(day: day, state: .absent, mainSleep: nil, metrics: [], source: "test"),
            heart: HeartDaySnapshot(day: day, state: .absent, metrics: [], source: "test"),
            body: body, strainConfidence: 0.8
        )
    }

    private func record(_ offset: Int, bpm: UInt8) -> StoredHistoricalRecord {
        StoredHistoricalRecord(physiologicalTimestamp: start + Int64(offset), bandCounter: UInt32(offset),
            absoluteTimestamp: start + Int64(offset), localDay: "2026-09-07", version: 24, heartRate: bpm)
    }

    private func seedRespiratoryNight(_ database: StorageDatabase, seconds: Int) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                let wakeMotion = index >= seconds - 1_800 ? Double(index % 2) : 0
                try db.execute(
                    sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, 55, ?, 0, 1)",
                    arguments: [timestamp, index, timestamp, wakeMotion]
                )
                let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(
                    sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)",
                    arguments: [db.lastInsertedRowID, interval, timestamp * 1_000]
                )
            }
        }
    }
}
