import Combine
import Foundation
import SwiftUI
import DesignSystem
import DomainKit
import HeartKit
import StorageKit
import WorkoutKit
import BluetoothKit
import SleepKit
import AnalyticsKit
import ProfileKit

/// Reads the per-second heart rate the Heart tab's day timeline draws, and
/// the newest stored reading. Only the two columns it needs, on the caller's
/// executor (never the main actor: `LooprHeartTabSource` is an actor).
nonisolated enum HeartDayTimelineReader {
    /// Heart-rate seconds in the half-open absolute range, with gravity and
    /// beat intervals for the timeline's beat-to-beat check.
    static func samples(_ database: StorageDatabase, from start: Int64, to end: Int64, includingBeats: Bool = true) throws -> [HeartRateSample] {
        try database.read { db in
            var beats: [Int64: [Double]] = [:]
            if includingBeats {
                let rr = try Row.fetchCursor(db, sql: """
                    SELECT r.decoded_second_id, r.rr_milliseconds
                    FROM rr_beat r JOIN decoded_second d ON r.decoded_second_id = d.id
                    WHERE d.absolute_timestamp >= ? AND d.absolute_timestamp < ?
                    ORDER BY d.absolute_timestamp, r.beat_index
                    """, arguments: [start, end])
                while let row = try rr.next() {
                    let id: Int64 = row[0]
                    let interval: Int64 = row[1]
                    beats[id, default: []].append(Double(interval))
                }
            }
            var output: [HeartRateSample] = []
            output.reserveCapacity(Int(max(0, min(end - start, 90_000))))
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, absolute_timestamp, heart_rate, gravity_x, gravity_y, gravity_z FROM decoded_second
                WHERE absolute_timestamp >= ? AND absolute_timestamp < ? AND heart_rate > 0
                ORDER BY absolute_timestamp
                """, arguments: [start, end])
            while let row = try rows.next() {
                let id: Int64 = row[0]
                let time: Int64 = row[1]
                let rate: Int64 = row[2]
                let x: Double? = row[3]
                let y: Double? = row[4]
                let z: Double? = row[5]
                let gravity: SIMD3<Double>? = if let x, let y, let z { SIMD3(x, y, z) } else { nil }
                output.append(HeartRateSample(time: TimeInterval(time), bpm: Double(rate), gravity: gravity,
                                              rrMilliseconds: beats[id] ?? []))
            }
            return output
        }
    }

    /// The newest second with a plausible heart rate.
    static func latest(_ database: StorageDatabase) throws -> HeartLastReading? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT absolute_timestamp, heart_rate FROM decoded_second
                WHERE heart_rate BETWEEN 25 AND 240
                ORDER BY absolute_timestamp DESC LIMIT 1
                """) else { return nil }
            let time: Int64 = row[0]
            let rate: Int64 = row[1]
            return HeartLastReading(bpm: Double(rate), at: Date(timeIntervalSince1970: TimeInterval(time)))
        }
    }
}

/// Builds the Heart tab's day timeline from storage: seconds from the history
/// database, sleep from the day's saved analytics, workouts from the workout
/// store. Runs off the main actor.
actor LooprHeartTabSource {
    private let history: StorageDatabase
    private let analytics: CanonicalDailyAnalytics
    private let workouts: SQLiteWorkoutStore
    private let timeZone: @Sendable () -> TimeZone
    private var workoutCache: (read: Date, spans: [HeartTimelineWorkout])?

    init(history: StorageDatabase, analytics: CanonicalDailyAnalytics, workouts: SQLiteWorkoutStore,
         timeZone: @escaping @Sendable () -> TimeZone) {
        self.history = history
        self.analytics = analytics
        self.workouts = workouts
        self.timeZone = timeZone
    }

    func timeline(for day: LooprDay) async -> HeartDayTimeline? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone()
        guard let start = day.start(in: calendar),
              let end = day.adding(days: 1, calendar: calendar)?.start(in: calendar) else { return nil }
        let samples = (try? HeartDayTimelineReader.samples(history, from: Int64(start.timeIntervalSince1970),
                                                           to: Int64(end.timeIntervalSince1970))) ?? []
        guard !samples.isEmpty, !Task.isCancelled else { return nil }

        let identity = DayIdentity(year: day.year, month: day.month, day: day.day)
        var sleep: [DateInterval] = []
        var detected: [HeartTimelineWorkout] = []
        if let display = try? await analytics.readDisplay(day: identity, reason: "heart-timeline") {
            let snapshot = display.projection.sleep
            if let main = snapshot.mainSleep { sleep.append(DateInterval(start: main.start, end: max(main.start, main.end))) }
            sleep += snapshot.naps.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            detected = display.projection.detectedWorkouts.map {
                HeartTimelineWorkout(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end),
                                     title: Self.sportTitle($0.sport))
            }
        }
        // The night that starts this evening belongs to tomorrow's
        // analytics. Read it only when tomorrow was already derived, so
        // looking at a day never starts deriving the next one.
        if let next = day.adding(days: 1, calendar: calendar) {
            let nextIdentity = DayIdentity(year: next.year, month: next.month, day: next.day)
            if await analytics.hasSavedDisplay(day: nextIdentity),
               let display = try? await analytics.readDisplay(day: nextIdentity, reason: "heart-timeline"),
               let main = display.projection.sleep.mainSleep, main.start < end {
                sleep.append(DateInterval(start: main.start, end: max(main.start, main.end)))
            }
        }
        let recorded = await recordedWorkouts().filter { $0.end > start && $0.start < end }
        guard !Task.isCancelled else { return nil }
        return HeartTimelineBuilder.build(samples: samples, dayStart: start, dayEnd: end,
                                          sleep: sleep, workouts: recorded + detected)
    }

    func range(_ request: HeartTimelineRangeRequest) throws -> [HeartRateSample] {
        // The actor and indexed half-open query keep range reads off MainActor.
        try HeartDayTimelineReader.samples(history, from: Int64(request.start.timeIntervalSince1970.rounded(.down)),
            to: Int64(request.end.timeIntervalSince1970.rounded(.up)), includingBeats: false)
    }

    func lastReading() -> HeartLastReading? {
        try? HeartDayTimelineReader.latest(history)
    }

    /// Finished workouts and pending detections. Reading every record decodes
    /// their samples, so the list is kept for a minute.
    private func recordedWorkouts() async -> [HeartTimelineWorkout] {
        if let cache = workoutCache, Date().timeIntervalSince(cache.read) < 60 { return cache.spans }
        let records = await workouts.all().compactMap { record -> HeartTimelineWorkout? in
            guard record.state == .completed, let start = record.startedAt, let end = record.endedAt, end > start else { return nil }
            return HeartTimelineWorkout(start: start, end: end, title: record.activity.displayName)
        }
        let detections = await workouts.allDetections().map {
            HeartTimelineWorkout(start: $0.startedAt, end: $0.endedAt, title: $0.activity.displayName)
        }
        let spans = records + detections
        workoutCache = (Date(), spans)
        return spans
    }

    /// The detector names sports in lower case ("running", "detected").
    static func sportTitle(_ sport: String) -> String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "detected" else { return "Workout" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

/// Hands the Heart tab its services: production reads storage, fixture
/// launch modes read `HeartFixtures`, anything else gets none and the tab
/// leaves those sections out.
struct HeartTabServicesModifier: ViewModifier {
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    /// Streams the DEBUG live fixture into the tab when it was asked for.
    let viewModel: HeartViewModel
    @Environment(\.metricHistoryProvider) private var historyProvider
    @State private var source: LooprHeartTabSource?
    @State private var zones: HeartZoneScale?
    @State private var zoneSettings = HeartRateZoneSettings()
    @State private var age: Int?
    /// Moves when a day generation was saved, so the cards pick up nights
    /// the launch backfill writes after the tab opened.
    @State private var revision = 0

    func body(content: Content) -> some View {
        content
            .environment(\.heartTabServices, services)
            .onReceive(NotificationCenter.default.publisher(for: looprDerivedGenerationUpdated)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
                guard environment.composition == .production || DebugLivePerformance.enabled else { return }
                Task { await reloadZones() }
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHeartZonesChanged).receive(on: RunLoop.main)) { _ in
                Task { await reloadZones() }
            }
            .task(id: repositories?.persistent != nil) {
                guard let persistent = repositories?.persistent else { return }
                if source == nil {
                    let timeZone = environment.timeZoneProvider
                    source = LooprHeartTabSource(history: persistent.historyDatabase, analytics: persistent.analytics,
                                                 workouts: persistent.workouts, timeZone: { @Sendable [timeZone] in timeZone.timeZone })
                }
                await reloadZones()
            }
            .task {
                #if DEBUG
                guard environment.composition != .production, FixtureHeartLiveEventClient.requested != nil else { return }
                await viewModel.runLive()
                #endif
            }
    }

    private func reloadZones() async {
        if let persistent = repositories?.persistent {
            let profile = try? await persistent.profile.readProfile()
            let year = Calendar(identifier: .gregorian).component(.year, from: environment.dateProvider.now())
            age = profile?.birthYear.map { year - $0 }
        }
        zoneSettings = await HeartZonePreferences.shared.load()
        let nights = (try? await historyProvider.series(for: .restingHeartRate, days: 14, endingOn: environment.dateProvider.now())) ?? []
        let resting = nights.filter { $0.source == .band }.sorted { $0.day < $1.day }.map(\.value)
        zones = zoneSettings.resolved(age: age, restingNights: resting).map(HeartZoneScale.init(zones:))
        revision += 1
    }

    /// The live client a fixture Heart root gets: the DEBUG streaming
    /// fixture when asked for, otherwise none.
    static var fixtureLiveClient: (any HeartLiveEventStreamClient)? {
        #if DEBUG
        FixtureHeartLiveEventClient.requested
        #else
        nil
        #endif
    }

    private var services: HeartTabServices? {
        switch environment.composition {
        case .production:
            guard let source else { return nil }
            let provider = historyProvider
            return HeartTabServices(
                history: { @Sendable [provider] id, days, end in
                    guard let key = MetricKey(linkID: id) else { return [] }
                    let points = (try? await provider.series(for: key, days: days, endingOn: end)) ?? []
                    return MetricTrendNarrative.chartPoints(points)
                },
                timeline: { @Sendable [source] day in await source.timeline(for: day) },
                timelineRange: { @Sendable [source] request in try await source.range(request) },
                lastReading: { @Sendable [source] in await source.lastReading() },
                zones: zones,
                age: age,
                zoneSettings: zoneSettings,
                saveZoneSettings: { @Sendable settings in await HeartZonePreferences.shared.save(settings) },
                revision: revision
            )
        case .populated, .activeWorkout, .connectedMixedCapabilities, .stale:
            return HeartFixtures.tabServices()
        case .onboarding, .pairing, .empty, .disconnected:
            return nil
        }
    }
}

#if DEBUG
/// A band that streams a calm, slightly wandering heart rate once a second,
/// for screenshots of the live card. Only with `--loopr-heart-live-fixture`
/// in a fixture launch mode.
nonisolated struct FixtureHeartLiveEventClient: HeartLiveEventStreamClient {
    static let launchArgument = "--loopr-heart-live-fixture"

    @MainActor static var requested: FixtureHeartLiveEventClient? {
        (ProcessInfo.processInfo.arguments.contains(launchArgument) || DebugLivePerformance.enabled) ? FixtureHeartLiveEventClient() : nil
    }

    func acquireEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveEventSubscription {
        let (stream, continuation) = AsyncStream<HeartLiveDecodedSample>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task {
            // Three minutes of history first, so the line is full at once.
            let start = Date()
            for second in stride(from: -179, through: 0, by: 1) {
                continuation.yield(Self.sample(at: start.addingTimeInterval(TimeInterval(second)), kind: kind))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                continuation.yield(Self.sample(at: Date(), kind: kind))
            }
        }
        return HeartLiveEventSubscription(generation: 1, stream: stream) {
            task.cancel()
            continuation.finish()
            return true
        }
    }

    private static func sample(at date: Date, kind: LiveStreamKind) -> HeartLiveDecodedSample {
        let t = date.timeIntervalSince1970
        let bpm = (DebugCaptureFixtures.siStoreFixture ? 74 + 2 * sin(t / 23) + sin(t / 7) : 112 + 6 * sin(t / 23) + 3 * sin(t / 7)).rounded()
        return HeartLiveDecodedSample(kind: kind, generation: 1, deviceTimestampSeconds: UInt32(truncatingIfNeeded: Int(t)),
                                      heartRateBPM: bpm, rrIntervalsMilliseconds: [60_000 / bpm], wearing: true,
                                      receivedAt: date, rawPayload: Data())
    }
}
#endif
