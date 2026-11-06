import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import RouteKit
import StorageKit
import WorkoutKit

/// Gathers what the workout page reads from outside the record. Every source is optional: what cannot be read
/// is left off the page.
nonisolated struct AppWorkoutPageProvider: WorkoutPageProviding {
    /// Band heart rate between two dates, for a session with no samples of its own.
    var readHistory: (@Sendable (Date, Date) async -> [WorkoutHeartSample])?
    var readRoute: (@Sendable (UUID) async -> RouteRecord?)?
    /// Earlier sessions as list rows, and the full record of one of them.
    var readRows: (@Sendable () async -> [WorkoutRecord])?
    var readWorkout: (@Sendable (UUID) async -> WorkoutRecord?)?
    var fallbackZones: HeartRateZones?
    var usesMiles = false

    /// A longer window is not one session, and reading it would stall the page.
    static let longestHistoryWindow: TimeInterval = 8 * 3_600

    func context(for workout: WorkoutRecord) async -> WorkoutPageContext {
        var context = WorkoutPageContext(fallbackZones: fallbackZones)
        let ownReadings = workout.samples.lazy.filter { $0.heartRate != nil }.prefix(2).count
        if ownReadings < 2, workout.source != .healthKit, workout.source != .imported,
           let start = workout.startedAt, let end = workout.endedAt, end > start,
           end.timeIntervalSince(start) <= Self.longestHistoryWindow, let readHistory {
            let samples = await readHistory(start, end)
            if !samples.isEmpty { context.history = WorkoutHeartSeries(samples: samples, source: .bandHistory) }
        }
        let heart = WorkoutSessionAnalysis(workout: workout, history: context.history).samples
        if workout.activity.recordsRoute, let route = await readRoute?(workout.id) {
            context.route = WorkoutPageRoute(route: route, heart: heart, usesMiles: usesMiles)
        }
        if let rows = await readRows?(), let previous = WorkoutComparison.similar(to: workout, in: rows) {
            let full = await readWorkout?(previous.id)
            var moving: TimeInterval?
            if previous.activity.recordsRoute, let route = await readRoute?(previous.id) {
                moving = RouteAnalysis.movingSeconds(route: route)
            }
            context.comparison = WorkoutComparison.line(previous: previous, averageBPM: full.flatMap { WorkoutSessionAnalysis(workout: $0).averageBPM },
                                                        movingSeconds: moving, system: usesMiles ? .imperial : .metric)
        }
        return context
    }
}

extension AppWorkoutPageProvider {
    /// The real sources, or the fixture's in a debug fixture launch.
    @MainActor
    static func make(repositories: ProductRepositoryContainer?, usesMiles: Bool) -> AppWorkoutPageProvider? {
        guard let repositories else { return nil }
        #if DEBUG
        if repositories.isFixtureComposition { return WorkoutPageFixtures.provider(repositories: repositories) }
        #endif
        guard let persistent = repositories.persistent else { return nil }
        let history = persistent.historyDatabase
        let routes = persistent.routes
        let workouts = persistent.workouts
        return AppWorkoutPageProvider(
            readHistory: { @Sendable start, end in
                guard let snapshot = try? history.historicalAnalyticsSnapshot(from: Int64(start.timeIntervalSince1970),
                                                                              to: Int64(end.timeIntervalSince1970)) else { return [] }
                return snapshot.records.compactMap { record in
                    guard let bpm = record.heartRate, bpm > 0, record.skinContact != 0 else { return nil }
                    return WorkoutHeartSample(date: Date(timeIntervalSince1970: TimeInterval(record.absoluteTimestamp)), bpm: Double(bpm))
                }
            },
            readRoute: { @Sendable id in try? await routes.route(workoutID: id.uuidString) },
            readRows: { @Sendable in await workouts.listingRows(WorkoutLogQuery(range: .all, now: Date())) },
            readWorkout: { @Sendable id in await workouts.workout(id: id) },
            usesMiles: usesMiles
        )
    }
}

#if DEBUG
/// `--loopr-workout-page-fixture`: one believable session of every type, for capturing the workout page.
/// Launch with `--loopr-launch-mode=populated --loopr-train-fixture` and open
/// `--loopr-deep-link=workouts/page/<id>`. The ids run from `...0730` in `Kind` order. Every fixture launch reads
/// this provider, so the fixture run keeps its route rows.
enum WorkoutPageFixtures {
    static let argument = "--loopr-workout-page-fixture"
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    enum Kind: Int, CaseIterable {
        case run, runEarlier, ride, walk, hike, swim, hiit, intervals, cardio, yoga, other, loggedNoBand, gpsGap
    }

    static func id(_ kind: Kind) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 730 + kind.rawValue)) ?? UUID()
    }

    /// The fixture's week, in step with the Train fixture's day.
    private static let base = Date(timeIntervalSince1970: 1_699_920_000)

    /// Age 31 or so, with a resting heart rate.
    static let zones = HeartRateZones(maximum: 186, source: .estimated, boundaries: [60, 70, 80, 90], restingHeartRate: 52)

    private static func wave(_ second: Double, _ period: Double, _ amount: Double) -> Double {
        sin(second / period * 2 * .pi) * amount
    }

    private static func samples(start: Date, minutes: Int, bpm: (Double) -> Double, distance: Double? = nil) -> [WorkoutSample] {
        stride(from: 0.0, to: Double(minutes) * 60, by: 5).map { second in
            WorkoutSample(timestamp: start.addingTimeInterval(second), heartRate: Int(bpm(second).rounded()))
        } + (distance.map { [WorkoutSample(timestamp: start.addingTimeInterval(Double(minutes) * 60), distanceMeters: $0)] } ?? [])
    }

    private static func record(_ kind: Kind, _ activity: ActivityType, dayOffset: Double, minutes: Int, source: WorkoutSource = .live,
                               samples: [WorkoutSample], title: String? = nil, effort: Int? = nil, notes: String? = nil, typedMeters: Double? = nil,
                               lengths: Int? = nil, calories: Int? = nil, windows: [WorkoutEffortWindow]? = nil,
                               target: WorkoutZoneTarget? = nil, start: Date? = nil) -> WorkoutRecord {
        let start = start ?? base.addingTimeInterval(dayOffset * 86_400)
        return WorkoutRecord(id: id(kind), identity: WorkoutIdentity(canonicalKey: "fixture-page-\(kind)"), activity: activity, source: source,
                             state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(Double(minutes) * 60),
                             samples: samples, finalizationStage: .activeStateCleared,
                             zoneTargetChanges: target.map { [.init(at: start, target: $0)] }, title: title, effort: effort,
                             loggedDistanceMeters: typedMeters, notes: notes, lengths: lengths, poolLengthMeters: lengths == nil ? nil : 25,
                             loggedCalories: calories, effortWindows: windows)
    }

    static var records: [WorkoutRecord] {
        let start = { (day: Double) in base.addingTimeInterval(day * 86_400) }
        let zoneSet = ActivityAnalytics.zones(zones, source: .agePredicted).value
        let zoneTwo = WorkoutZoneTarget(preference: WorkoutZoneAlertPreference(target: .zoneTwo), zones: zoneSet,
                                        zoneTwo: ZoneTwoRange(lower: 111, upper: 130, source: .maximumHeartRate))
        let intervalStart = start(-1)
        let windows = (0..<4).map { round -> WorkoutEffortWindow in
            let begin = intervalStart.addingTimeInterval(600 + Double(round) * 420)
            return WorkoutEffortWindow(round: round + 1, start: begin, end: begin.addingTimeInterval(240))
        }
        return [
            record(.run, .run, dayOffset: 0, minutes: 42, samples: samples(start: start(0), minutes: 42, bpm: { 128 + min($0 / 60, 10) * 2 + wave($0, 500, 4) + $0 / 300 }, distance: 7_460)),
            record(.runEarlier, .run, dayOffset: -9, minutes: 44, samples: samples(start: start(-9), minutes: 44, bpm: { 132 + min($0 / 60, 10) * 2 + wave($0, 500, 4) + $0 / 280 }, distance: 7_300)),
            record(.ride, .cycle, dayOffset: -2, minutes: 95, samples: samples(start: start(-2), minutes: 95, bpm: { 104 + min($0 / 60, 12) * 1.3 + wave($0, 900, 5) + $0 / 1_000 }, distance: 38_400), target: zoneTwo),
            record(.walk, .walk, dayOffset: -3, minutes: 38, samples: samples(start: start(-3), minutes: 38, bpm: { 92 + wave($0, 400, 5) + min($0 / 60, 8) }, distance: 3_250)),
            record(.hike, .hike, dayOffset: -5, minutes: 190, samples: samples(start: start(-5), minutes: 190, bpm: { 112 + wave($0, 1_800, 18) + wave($0, 300, 3) }, distance: 12_400)),
            record(.swim, .swim, dayOffset: -1.2, minutes: 36, source: .manual, samples: [], effort: 6, lengths: 48),
            record(.hiit, .hiit, dayOffset: -4, minutes: 28, samples: samples(start: start(-4), minutes: 28, bpm: { second in
                let phase = second.truncatingRemainder(dividingBy: 240)
                return second < 180 ? 100 + second / 6 : phase < 90 ? 128 + phase * 0.55 : 178 - (phase - 90) * 0.33
            }), title: "Friday HIIT class"),
            record(.intervals, .hiit, dayOffset: -1, minutes: 42, samples: samples(start: intervalStart, minutes: 42, bpm: { second in
                if let window = windows.first(where: { second >= $0.start.timeIntervalSince(intervalStart) && second < $0.end.timeIntervalSince(intervalStart) + 180 }) {
                    let into = second - window.start.timeIntervalSince(intervalStart)
                    return into < 240 ? 135 + min(into / 240, 1) * 37 : 172 - (into - 240) * 0.24
                }
                return 112 + min(second / 60, 10)
            }), title: "Norwegian 4x4", windows: windows, start: intervalStart),
            record(.cardio, .rowing, dayOffset: -6, minutes: 30, source: .manual, samples: samples(start: start(-6), minutes: 30, bpm: { 118 + min($0 / 60, 8) * 2 + wave($0, 300, 3) }),
                   effort: 5, typedMeters: 6_200, calories: 310),
            record(.yoga, .yoga, dayOffset: -7, minutes: 60, samples: samples(start: start(-7), minutes: 60, bpm: { 74 + wave($0, 700, 6) }), notes: "Studio class, hips"),
            record(.other, .other, dayOffset: -8, minutes: 50, samples: samples(start: start(-8), minutes: 50, bpm: { 110 + wave($0, 420, 16) }), title: "Aqua class"),
            record(.loggedNoBand, .other, dayOffset: -10, minutes: 25, source: .manual, samples: []),
            record(.gpsGap, .run, dayOffset: -12, minutes: 30, samples: samples(start: start(-12), minutes: 30, bpm: { 136 + wave($0, 400, 5) }, distance: 3_900))
        ]
    }

    /// A band trace for the swim, which has no samples of its own. The session logged with no band has none at all.
    private static func bandHistory(from start: Date, to end: Date) -> [WorkoutHeartSample] {
        guard end.timeIntervalSince(start) > 0, start != records.first(where: { $0.id == id(.loggedNoBand) })?.startedAt else { return [] }
        return stride(from: 0.0, to: end.timeIntervalSince(start), by: 5).map { second in
            WorkoutHeartSample(date: start.addingTimeInterval(second), bpm: 112 + min(second / 60, 8) * 2 + wave(second, 180, 14))
        }
    }

    /// A loop around a park, with a climb in the middle.
    static func route(for workoutID: UUID) -> RouteRecord? {
        func make(_ activity: RouteActivity, start: Date, minutes: Int, meters: Double, climb: Double, gap: ClosedRange<Double>? = nil) -> RouteRecord {
            let seconds = Double(minutes) * 60
            let radius = meters / (2 * .pi)
            var points: [RoutePoint] = []
            var gaps: [Int] = []
            var skipping = false
            for second in stride(from: 0.0, to: seconds, by: 5) {
                let share = second / seconds
                if let gap, gap.contains(share) { skipping = true; continue }
                if skipping { gaps.append(points.count); skipping = false }
                let angle = share * 2 * .pi
                let latitude = 52.5163 + (cos(angle) * 0.9 + cos(angle * 3) * 0.1) * radius / 111_320
                let longitude = 13.3777 + (sin(angle) + sin(angle * 2) * 0.25) * radius / (111_320 * cos(52.5163 * .pi / 180))
                points.append(RoutePoint(timestamp: start.addingTimeInterval(second), latitude: latitude, longitude: longitude, horizontalAccuracy: 5,
                                         altitude: 40 + sin(share * .pi) * climb + wave(second, 90, 0.6), speedMetersPerSecond: meters / seconds))
            }
            return RouteRecord(workoutID: workoutID.uuidString, activity: activity, points: points, completed: true, gapStartIndices: gaps)
        }
        let start = { (day: Double) in base.addingTimeInterval(day * 86_400) }
        switch workoutID {
        case id(.run): return make(.run, start: start(0), minutes: 42, meters: 7_460, climb: 38)
        case id(.runEarlier): return make(.run, start: start(-9), minutes: 44, meters: 7_300, climb: 38)
        case id(.ride): return make(.cycle, start: start(-2), minutes: 95, meters: 38_400, climb: 210)
        case id(.walk): return make(.walk, start: start(-3), minutes: 38, meters: 3_250, climb: 9)
        case id(.hike): return make(.hike, start: start(-5), minutes: 190, meters: 12_400, climb: 620)
        case id(.gpsGap): return make(.run, start: start(-12), minutes: 30, meters: 5_200, climb: 12, gap: 0.45...0.7)
        case WorkoutFixtures.completedRun.id:
            return make(.run, start: WorkoutFixtures.completedRun.startedAt ?? base, minutes: 30, meters: 5_200, climb: 20)
        default: return nil
        }
    }

    @MainActor
    static func provider(repositories: ProductRepositoryContainer) -> AppWorkoutPageProvider {
        let store = repositories.workoutStore
        return AppWorkoutPageProvider(
            readHistory: { @Sendable start, end in bandHistory(from: start, to: end) },
            readRoute: { @Sendable id in route(for: id) },
            readRows: { @Sendable in await store?.all().map(\.listingRow) ?? [] },
            readWorkout: { @Sendable id in await store?.workout(id: id) },
            fallbackZones: zones
        )
    }
}
#endif
