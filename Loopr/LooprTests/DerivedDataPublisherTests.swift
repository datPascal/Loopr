import AnalyticsKit
import DesignSystem
import DeviceCenterKit
import DomainKit
import Foundation
import HeartKit
import ProfileKit
import RecordsKit
import SharedSurfaceKit
import SleepKit
import StorageKit
import StressKit
import Testing
import TodayKit
import WorkoutKit

@testable import Loopr

// MARK: - Fixtures

private struct FixedDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

private actor RecordingSurfaceSink: LooprSurfaceSnapshotSink {
    private(set) var published: [SurfaceSnapshot] = []
    func publish(_ snapshot: SurfaceSnapshot) { published.append(snapshot) }
    func snapshots() -> [SurfaceSnapshot] { published }
}

private actor RecordingNotifier: LooprDetectedWorkoutNotifying {
    private(set) var notified: [String] = []
    func detected(detectionID: String, at _: Date) { notified.append(detectionID) }
    func identifiers() -> [String] { notified }
}

private actor RecordingMorningNotifier: LooprMorningRecapNotifying {
    private var summaries: [TodaySummary] = []
    func morning(summary: TodaySummary, sleep: SleepSessionSummary?, syncedAt: Date?, now: Date, calendar: Calendar) {
        summaries.append(summary)
    }
    func received() -> [TodaySummary] { summaries }
}

private actor StubWorkoutLedger: LooprDetectedWorkoutLedger {
    private var rows: [String: WorkoutKit.DetectedWorkout] = [:]
    private var answered: Set<String>

    init(answered: Set<String> = []) { self.answered = answered }

    func save(_ detection: WorkoutKit.DetectedWorkout) { rows[detection.detectionID] = detection }
    func detection(id: String) -> WorkoutKit.DetectedWorkout? { rows[id] }
    func resolvedDetectionIDs() -> Set<String> { answered }
    func markDetectionResolved(id: String) { answered.insert(id) }
    func saved() -> [WorkoutKit.DetectedWorkout] { rows.values.sorted { $0.detectionID < $1.detectionID } }
}

/// One saved night, the same shape `CanonicalDailyAnalyticsTests` uses.
private enum DerivedDataFixture {
    static let nightStart: Int64 = 1_788_739_200 // 2026-09-07 00:00 UTC
    static let day = DayIdentity(year: 2026, month: 9, day: 7)
    static var now: Date { Date(timeIntervalSince1970: Double(nightStart + 20_000)) }

    static func databases() throws -> (history: StorageDatabase, products: StorageDatabase, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (
            try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
            try StorageDatabase(url: root.appendingPathComponent("products.sqlite")),
            root
        )
    }

    static func seedNight(_ database: StorageDatabase, seconds: Int = 14_401, heartRate: Int = 55, start: Int64 = nightStart, amplitude: Double = 80) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = start + Int64(index)
                try db.execute(
                    sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, ?, 24, ?, 0, 0, 1)",
                    arguments: [timestamp, index, timestamp, LooprDerivedDataPublisher.dayLabel(MetricHistoryDays.identity(Date(timeIntervalSince1970: Double(start)), calendar: MetricHistoryDays.calendar(TimeZone(secondsFromGMT: 0)!))), heartRate]
                )
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + amplitude * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(
                    sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)",
                    arguments: [id, interval, timestamp * 1_000]
                )
            }
        }
    }

    static func analytics(history: StorageDatabase, products: StorageDatabase, now: Date) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(
            history: history,
            products: products,
            profile: InMemoryProfileRepository(),
            dateProvider: FixedDate(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )
    }

    static func session(startingAt start: TimeInterval, minutes: Double, sport: String = "detected") -> ExerciseSession {
        ExerciseSession(
            start: start, end: start + minutes * 60, averageBPM: 142, peakBPM: 168,
            strain: 9.4, durationSeconds: minutes * 60, zones: nil, hrMax: 186,
            hrMaxSource: "tanaka", caloriesKcal: 310, sport: sport
        )
    }
}

// MARK: - Item 1: stress reads through the derivation

struct StressReadThroughTests {
    @Test
    func stressComesFromTheDerivationRatherThanAStoredRowThatIsNeverWritten() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        let analytics = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let reading = try await analytics.readStress(day: DerivedDataFixture.day)
        try #require(reading != nil)

        let repository = try SQLiteStressRepository(
            database: products,
            analytics: analytics,
            dateProvider: FixedDate(value: DerivedDataFixture.now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )
        let observation = try #require(await repository.latestObservation())
        #expect(observation.day == "2026-09-07")
        #expect(observation.value == reading?.score)
        #expect(observation.coverage == reading?.coverage)
        #expect(observation.confidence == reading?.confidence)
    }

    @Test
    func aSavedObservationStillAnswersWhenTheDerivationHasNothing() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        let analytics = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let repository = try SQLiteStressRepository(
            database: products,
            analytics: analytics,
            dateProvider: FixedDate(value: DerivedDataFixture.now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )
        #expect(await repository.latestObservation() == nil)

        let saved = StressObservation(day: "2026-09-05", value: 31, coverage: 0.82, confidence: 0.7)
        try await repository.saveObservation(saved)
        #expect(await repository.latestObservation() == saved)
    }
}

// MARK: - Item 2: detected workouts reach the review flow

struct DetectedWorkoutPublishingTests {
    @Test
    func theSameBoutKeepsOneIdentityAcrossRederivations() {
        let session = DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 42)
        let first = LooprDerivedDataPublisher.detectedWorkout(session)
        let second = LooprDerivedDataPublisher.detectedWorkout(session)
        #expect(first == second)
        #expect(first.detectionID == "loopr.detected.1788800000")
        #expect(first.startedAt == Date(timeIntervalSince1970: 1_788_800_000))
        #expect(first.endedAt == Date(timeIntervalSince1970: 1_788_800_000 + 42 * 60))
        // The detector reports a bout, not a sport, so the review screen asks.
        #expect(first.activity == .other)
        #expect(LooprDerivedDataPublisher.activity(for: "cycle") == .cycle)
    }

    @Test
    func aBoutTheUserAlreadyAnsweredIsNotOfferedAgain() {
        let confirmed = DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        let fresh = DerivedDataFixture.session(startingAt: 1_788_900_000, minutes: 25)
        let answered = Set([LooprDerivedDataPublisher.detectedWorkout(confirmed).detectionID])

        let offered = LooprDerivedDataPublisher.detectionsToSave([confirmed, fresh], answered: answered)
        #expect(offered.map(\.detectionID) == [LooprDerivedDataPublisher.detectedWorkout(fresh).detectionID])
    }

    @Test
    func anAnsweredFragmentDoesNotReappearAfterTheDetectorBridgesItsGap() {
        let merged = DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        let answered = Set(["loopr.detected.1788800900"])
        #expect(LooprDerivedDataPublisher.detectionsToSave([merged], answered: answered).isEmpty)
    }

    @Test
    func completedManualAndImportedWorkoutsExcludeOverlappingSuggestions() {
        let first = DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        let second = DerivedDataFixture.session(startingAt: 1_788_900_000, minutes: 25)
        let third = DerivedDataFixture.session(startingAt: 1_789_000_000, minutes: 20)
        func saved(_ session: ExerciseSession, source: WorkoutSource) -> WorkoutRecord {
            let start = Date(timeIntervalSince1970: session.start)
            let end = Date(timeIntervalSince1970: session.end)
            return WorkoutRecord(id: UUID(), identity: WorkoutIdentity.make(activity: .run, sourceKey: nil, startedAt: start, endedAt: end),
                                 activity: .run, source: source, state: .completed, createdAt: start,
                                 startedAt: start, endedAt: end)
        }
        let offered = LooprDerivedDataPublisher.detectionsToSave(
            [first, second, third], answered: [], saved: [saved(first, source: .manual), saved(second, source: .imported)]
        )
        #expect(offered.map(\.detectionID) == [LooprDerivedDataPublisher.detectedWorkout(third).detectionID])
    }

    @Test
    func activeAndPausedLiveRecordingsExcludeSuggestions() {
        let session = DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        let detection = LooprDerivedDataPublisher.detectedWorkout(session)
        let start = detection.startedAt.addingTimeInterval(-60)
        let states: [WorkoutLifecycleState] = [
            .active, .paused, .interruptedAndRecoverable, .finishing, .discarded
        ]
        for state in states {
            let workout = WorkoutRecord(
                id: UUID(), identity: .init(canonicalKey: "live-\(state)"),
                activity: .run, source: .live, state: state,
                createdAt: start, startedAt: start,
                endedAt: state == .discarded ? detection.endedAt : nil
            )
            #expect(LooprDerivedDataPublisher.detectionsToSave(
                [session], answered: [], saved: [workout]
            ).isEmpty)
        }
    }

    @Test
    func onlyRecentBoutsInterruptTheUser() {
        let detection = LooprDerivedDataPublisher.detectedWorkout(
            DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        )
        let justFinished = detection.endedAt.addingTimeInterval(10 * 60)
        let yesterday = detection.endedAt.addingTimeInterval(26 * 60 * 60)
        #expect(LooprDerivedDataPublisher.deservesNotification(detection, now: justFinished))
        #expect(!LooprDerivedDataPublisher.deservesNotification(detection, now: yesterday))
    }

    @Test
    func answeringADetectionSurvivesTheRowBeingRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let store = try SQLiteWorkoutStore(database: database)
        let detection = LooprDerivedDataPublisher.detectedWorkout(
            DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        )

        try await store.save(detection)
        #expect(await store.allDetections() == [detection])
        try await store.remove(id: detection.detectionID)

        #expect(await store.allDetections().isEmpty)
        #expect(await store.resolvedDetectionIDs() == [detection.detectionID])
    }

    @Test
    func aSavedWorkoutHidesAnOlderPendingSuggestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let store = try SQLiteWorkoutStore(database: database)
        let detection = LooprDerivedDataPublisher.detectedWorkout(
            DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30)
        )
        try await store.save(detection)
        let workout = WorkoutRecord(
            id: UUID(), identity: WorkoutIdentity.make(activity: .run, sourceKey: nil,
                startedAt: detection.startedAt, endedAt: detection.endedAt),
            activity: .run, source: .manual, state: .completed,
            createdAt: detection.startedAt, startedAt: detection.startedAt,
            endedAt: detection.endedAt
        )
        try await store.save(workout)
        #expect(await store.allDetections().isEmpty)
        #expect(await store.detection(id: detection.detectionID) == nil)
    }

    @Test
    func savedDetectionsAndNotificationsGoThroughTheLedger() async throws {
        let ledger = StubWorkoutLedger()
        let notifier = RecordingNotifier()
        let sessions = [
            DerivedDataFixture.session(startingAt: 1_788_800_000, minutes: 30),
            DerivedDataFixture.session(startingAt: 1_788_900_000, minutes: 25)
        ]
        let now = Date(timeIntervalSince1970: 1_788_900_000 + 25 * 60 + 600)
        for detection in LooprDerivedDataPublisher.detectionsToSave(sessions, answered: []) {
            try await ledger.save(detection)
            if LooprDerivedDataPublisher.deservesNotification(detection, now: now) {
                await notifier.detected(detectionID: detection.detectionID, at: detection.endedAt)
            }
        }
        #expect(await ledger.saved().count == 2)
        // The older bout finished more than two hours ago and stays quiet.
        #expect(await notifier.identifiers() == ["loopr.detected.1788900000"])
    }
}

// MARK: - Item 3: the shared snapshot carries real values

struct SurfaceSnapshotPublishingTests {
    @Test
    func theSnapshotCarriesDerivedMetricsAndTheBandBattery() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        let analytics = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let projection = try #require(try await analytics.read(day: DerivedDataFixture.day))

        let status = DeviceStatusSnapshot(
            connection: .connected,
            bluetooth: .poweredOn,
            batteryPercent: .measured(74),
            storedAt: DerivedDataFixture.now
        )
        let snapshot = LooprDerivedDataPublisher.snapshot(
            projection, day: DerivedDataFixture.day, status: status, now: DerivedDataFixture.now
        )

        #expect(snapshot.sourceDay == "2026-09-07")
        #expect(snapshot.metrics.heartRate == projection.heart.metric(.restingHeartRate)?.numericValue)
        #expect(snapshot.metrics.hrv == projection.today.metric(.hrv)?.numericValue)
        #expect(snapshot.metrics.heartRate != nil)
        #expect(snapshot.battery?.level == 0.74)
        #expect(snapshot.syncDate == projection.latestRecord)
        #expect(snapshot.staleReasons.isEmpty)
    }

    @Test
    func sleepWithoutWakingCoverageHasNoDipButKeepsTheSleepingAverage() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        try history.write { db in
            try db.execute(sql: "UPDATE decoded_second SET heart_rate = 220, skin_contact = 0 WHERE absolute_timestamp = ?",
                           arguments: [DerivedDataFixture.nightStart + 7_200])
        }
        let engine = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let projection = try #require(try await engine.read(day: DerivedDataFixture.day))
        #expect(projection.heart.metric(.heartRateDip)?.numericValue == nil)
        #expect(projection.heart.metric(.heartRateDip)?.state == .absent)
        #expect(projection.heart.metric(.sleepingHeartRate)?.numericValue == 55)
        #expect(projection.heart.metric(.maxHeartRate)?.numericValue == 55)
    }

    @Test
    func anEmptyDayAndADisconnectedBandSayWhyTheSurfaceIsStale() {
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let status = DeviceStatusSnapshot(
            connection: .disconnected,
            bluetooth: .poweredOn,
            batteryPercent: .absent,
            storedAt: now
        )
        let snapshot = LooprDerivedDataPublisher.snapshot(
            nil, day: DerivedDataFixture.day, status: status, now: now
        )
        #expect(snapshot.staleReasons == [.noRecentSync, .disconnected])
        #expect(snapshot.battery == nil)
        #expect(snapshot.metrics == SurfaceMetrics())
    }

    @Test
    func aSnapshotWrittenBeforeStepsAndHRVExistedStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"generation":7,"createdAt":0,"sourceDay":"2026-09-07",\
        "metrics":{"recovery":80,"sleep":92,"strain":10.3,"heartRate":62},"staleReasons":[]}
        """
        let snapshot = try SurfaceSnapshotCodec.decode(Data(json.utf8))
        #expect(snapshot.metrics.recovery == 80)
        #expect(snapshot.metrics.steps == nil)
        #expect(snapshot.metrics.hrv == nil)
    }

    @Test
    func onePassPublishesOneSnapshotBuiltFromTheDerivedDay() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        let sink = RecordingSurfaceSink()
        let publisher = try makePublisher(history: history, products: products, sink: sink)

        await publisher.publishNow()

        let published = await sink.snapshots()
        #expect(published.count == 1)
        #expect(published.first?.sourceDay == "2026-09-07")
        #expect(published.first?.metrics.heartRate == 55)
    }

    @Test
    func finishedTodayRecoveryReachesTheActualPublisherAndSnapshotCodec() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        for back in 0...5 {
            let start = DerivedDataFixture.nightStart - Int64(back) * 86_400
            try DerivedDataFixture.seedNight(history, heartRate: 55 + back, start: start, amplitude: Double(70 + 8 * back))
            // Motion after the night makes the sleep complete and supplies waking HR.
            try history.write { db in
                for second in 0..<600 {
                    let stamp = start + 16_000 + Int64(second)
                    try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, ?, 24, 80, ?, 0, 1)",
                        arguments: [stamp, 20_000 + second, stamp, LooprDerivedDataPublisher.dayLabel(MetricHistoryDays.identity(Date(timeIntervalSince1970: Double(start)), calendar: MetricHistoryDays.calendar(TimeZone(secondsFromGMT: 0)!))), second.isMultiple(of: 2) ? 0.3 : 0])
                }
            }
        }
        let engine = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let today = try #require(try await engine.readToday(day: DerivedDataFixture.day))
        let score = try #require(today.metric(.recovery)?.numericValue)
        let projection = try #require(try await engine.read(day: DerivedDataFixture.day))
        #expect(projection.today == today)
        let sink = RecordingSurfaceSink()
        let morning = RecordingMorningNotifier()
        let device = InMemoryDeviceCenterRepository(status: .init(connection: .synchronizing,
            bluetooth: .poweredOn, batteryPercent: .absent, completedSyncAt: DerivedDataFixture.now))
        let publisher = LooprDerivedDataPublisher(analytics: engine,
            records: try SQLiteRecordsRepository(database: products), workouts: StubWorkoutLedger(), device: device,
            sink: sink, notifier: RecordingNotifier(), dateProvider: FixedDate(value: DerivedDataFixture.now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!), morningRecap: morning)
        await publisher.publishNow()
        #expect(await morning.received().isEmpty)
        try await device.saveStatus(.init(connection: .connected, bluetooth: .poweredOn,
            batteryPercent: .absent, completedSyncAt: DerivedDataFixture.now))
        await publisher.publishNow()
        let recaps = await morning.received()
        #expect(recaps.count == 1)
        #expect(recaps.first?.headline == today.headline)
        #expect(recaps.first?.metric(.recovery)?.numericValue == score)
        let published = try #require(await sink.snapshots().last)
        let snapshot = try SurfaceSnapshotCodec.decode(JSONEncoder().encode(published))
        #expect(snapshot.metrics.recovery == score)
        #expect(snapshot.metrics.sleep == nil)
        #expect(snapshot.metrics.sleepMinutes == today.metric(.sleep)?.numericValue)
        #expect(snapshot.insight?.headline == today.headline)
        #expect(snapshot.insight?.headline != nil)
        #expect(snapshot.insight?.recoveryStyle?.verdict == LooprRecoveryBand(score: score)?.verdict)
        // The detector trims the edges of the still stretch. Its main-sleep
        // bounds, rather than the raw fixture duration, define which of the
        // synthetic 55 bpm seconds belong to sleep and which belong to the day.
        let main = try #require(projection.sleep.mainSleep)
        let sleepingSeconds = (0..<14_401).filter { index in
            let stamp = Date(timeIntervalSince1970: Double(DerivedDataFixture.nightStart + Int64(index)))
            return stamp >= main.start && stamp < main.end
        }.count
        let wakingStillSeconds = 14_401 - sleepingSeconds
        let expectedWakingMean = (Double(wakingStillSeconds) * 55 + 600 * 80) / Double(wakingStillSeconds + 600)
        let expectedDip = (expectedWakingMean - 55) / expectedWakingMean * 100
        #expect(projection.heart.metric(.heartRateDip)?.numericValue == expectedDip)
        #expect(projection.heart.metric(.sleepingHeartRate)?.numericValue == 55)
        #expect(projection.heart.metric(.maxHeartRate)?.numericValue == 80)
        let mapped = BandMetricSeriesMapping.values(projection: projection, today: today)
        #expect(mapped[.heartRateDip] == projection.heart.metric(.heartRateDip)?.numericValue)
        #expect(mapped[.sleepingHeartRate] == 55)
        #expect(mapped[.maxHeartRate] == 80)
        let reopened = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let restored = try #require(try await reopened.read(day: DerivedDataFixture.day))
        #expect(restored.today.metric(.recovery)?.numericValue == score)
        #expect(restored.today.headline == snapshot.insight?.headline)
        #expect(restored.heart.metric(.heartRateDip)?.numericValue == expectedDip)

    }

    private func makePublisher(
        history: StorageDatabase,
        products: StorageDatabase,
        sink: RecordingSurfaceSink
    ) throws -> LooprDerivedDataPublisher {
        LooprDerivedDataPublisher(
            analytics: try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now),
            records: try SQLiteRecordsRepository(database: products),
            workouts: StubWorkoutLedger(),
            device: nil,
            sink: sink,
            notifier: RecordingNotifier(),
            dateProvider: FixedDate(value: DerivedDataFixture.now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )
    }
}

// MARK: - Item 5: records, streaks, timeline and recap get real rows

struct DerivedRecordRowTests {
    @Test
    func aDerivedDayProducesRecordRowsForTheMetricsItActuallyMeasured() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        let analytics = try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now)
        let projection = try #require(try await analytics.read(day: DerivedDataFixture.day))

        let rows = LooprDerivedDataPublisher.metricSnapshots(projection, day: "2026-09-07", algorithmVersion: 6)
        let names = Set(rows.map(\.metric))
        #expect(names.contains("resting heart rate"))
        #expect(names.contains("sleep hours"))
        #expect(names.contains("hrv"))
        #expect(rows.allSatisfy { $0.day == "2026-09-07" && $0.algorithmVersion == 6 })
        #expect(rows.first { $0.metric == "resting heart rate" }?.value == 55)
        // Strain needs a birth year, and this fixture profile has none, so no
        // strain row is invented for the day.
        #expect(!names.contains("strain"))
    }

    @Test
    func theAlgorithmVersionComesFromTheCanonicalGeneration() {
        #expect(LooprDerivedDataPublisher.recordAlgorithmVersion("loopr.daily.6") == 6)
        #expect(LooprDerivedDataPublisher.recordAlgorithmVersion("loopr.daily.11") == 11)
        #expect(LooprDerivedDataPublisher.recordAlgorithmVersion("unnumbered") == 1)
    }

    @Test
    func rederivingADayCorrectsItsRowsInsteadOfDuplicatingThem() async throws {
        let (history, products, root) = try DerivedDataFixture.databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try DerivedDataFixture.seedNight(history)
        let records = try SQLiteRecordsRepository(database: products)
        let sink = RecordingSurfaceSink()
        let publisher = LooprDerivedDataPublisher(
            analytics: try DerivedDataFixture.analytics(history: history, products: products, now: DerivedDataFixture.now),
            records: records,
            workouts: StubWorkoutLedger(),
            device: nil,
            sink: sink,
            notifier: RecordingNotifier(),
            dateProvider: FixedDate(value: DerivedDataFixture.now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!)
        )

        await publisher.publishNow()
        let first = await records.metrics()
        #expect(!first.isEmpty)

        await publisher.publishNow()
        let second = await records.metrics()
        #expect(second.count == first.count)
        #expect(Set(second.map { "\($0.day)/\($0.metric)" }).count == second.count)

        let recap = await records.recap(period: .week, startDay: "2026-09-01", endDay: "2026-09-30")
        #expect(!recap.metrics.isEmpty)
        // This fixture's night runs to the last saved record, so it is still
        // in progress and the timeline correctly stays empty.
        #expect(await records.timeline().isEmpty)
    }

    @Test
    func onlyAFinishedNightReachesTheTimeline() {
        let start = Date(timeIntervalSince1970: 1_788_739_200)
        func night(partial: Bool, minutes: Int = 462) -> SleepSessionSummary {
            SleepSessionSummary(
                id: "night", start: start, end: start.addingTimeInterval(Double(minutes) * 60),
                durationMinutes: minutes, isMainSleep: true, isPartial: partial,
                confidence: 0.9, state: .partial
            )
        }
        let event = try? #require(LooprDerivedDataPublisher.timelineEvent(for: night(partial: false), day: "2026-09-07"))
        #expect(event?.title == "Slept 7h 42m")
        #expect(event?.id == "sleep:sleep.2026-09-07")
        #expect(LooprDerivedDataPublisher.timelineEvent(for: night(partial: true), day: "2026-09-07") == nil)
        #expect(LooprDerivedDataPublisher.timelineEvent(for: nil, day: "2026-09-07") == nil)
    }
}
