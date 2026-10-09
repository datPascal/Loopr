#if DEBUG
import AnalyticsKit
import DeviceCenterKit
import DesignSystem
import Foundation
import DomainKit
import ImportKit
import RouteKit
import StressKit
import WorkoutKit

/// DEBUG-only launch arguments that let UI capture runs reach states the
/// fixture composition does not produce on its own: hourly stress, band
/// charging and wrist state, a recorded GPX route and a finished account
/// import. None of this is compiled into release builds.
///
///   --loopr-hourly-stress-fixture=scored|learning
///   --loopr-band-state-fixture=charging,off-wrist,sharing
///   --loopr-band-connected-fixture
///   --loopr-gpx-route-fixture
///   --loopr-whoop-import-result-fixture
nonisolated enum DebugCaptureFixtures {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(_ prefix: String) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    static var siBodyMode: String? { value("--loopr-si-body-fixture=") ?? (siPolishState == "good" ? "ready" : nil) }

    static var zoneMode: String? { value("--loopr-zone-fixture=") }
    static var zoneContext: WorkoutZoneContext? {
        guard zoneMode != nil else { return nil }
        let resolved = HeartRateZoneSettings().resolved(age: 34, restingNights: [51])!
        return .init(zones: ActivityAnalytics.zones(resolved, source: .agePredicted).value,
                     zoneTwo: ZoneTwoRange.resolve(zones: resolved), usesPhoneCues: false)
    }

    static var hourlyStress: String? { value("--loopr-hourly-stress-fixture=") }

    private static var bandState: Set<String> {
        Set((value("--loopr-band-state-fixture=") ?? "").split(separator: ",").map(String.init))
    }

    static var bandStateEnabled: Bool { value("--loopr-band-state-fixture=") != nil }
    static var charging: Bool { bandState.contains("charging") }
    static var offWrist: Bool { bandState.contains("off-wrist") }
    static var sharing: Bool { bandState.contains("sharing") }
    static var bandConnected: Bool { arguments.contains("--loopr-band-connected-fixture") }
    static var intervalLiveSource: (any WorkoutLiveSampleSource)? {
        arguments.contains("--loopr-interval-live-fixture") ? DebugIntervalLiveSource() : nil
    }
    static var gpxRoute: Bool { arguments.contains("--loopr-gpx-route-fixture") }

    static var whoopImportResult: WHOOPImportResult? {
        guard arguments.contains("--loopr-whoop-import-result-fixture") else { return nil }
        var result = WHOOPImportResult()
        result.days = 412
        result.sleeps = 398
        result.workouts = 87
        result.journalAnswers = 1_204
        result.unchanged = 12
        result.missingDate = 3
        return result
    }

    static func deviceStatus(_ base: DeviceStatusSnapshot) -> DeviceStatusSnapshot {
        guard bandStateEnabled else { return base }
        return DeviceStatusSnapshot(
            connection: base.connection,
            bluetooth: base.bluetooth,
            restorationDescription: base.restorationDescription,
            batteryPercent: base.batteryPercent,
            charging: charging,
            batteryForecast: charging ? .absent : base.batteryForecast,
            wristState: offWrist ? .notWorn : .worn,
            freshness: base.freshness,
            lastPacketAt: base.lastPacketAt,
            historyCommitAt: base.historyCommitAt,
            completedSyncAt: base.completedSyncAt,
            storedAt: base.storedAt,
            bondRepairRequired: base.bondRepairRequired
        )
    }

    static func indicator(_ indicator: LooprBandIndicator) -> LooprBandIndicator {
        guard bandStateEnabled else { return indicator }
        var indicator = indicator
        indicator.charging = charging
        indicator.onWrist = !offWrist
        return indicator
    }

    /// Wraps the fixture stress store when a capture run asks for hourly
    /// stress; otherwise returns it unchanged.
    static func stressStore(_ base: InMemoryStressStore) -> any StressStore {
        guard let mode = hourlyStress else { return base }
        return DebugHourlyStressStore(base: base, day: hourlyStressDay(learning: mode == "learning"))
    }

    /// A synthetic waking day for today, resolved by the real HourlyStress
    /// method against a synthetic baseline. "learning" keeps the baseline
    /// below the minimum, so no hour gets a score.
    static func hourlyStressDay(learning: Bool, now: Date = Date()) -> HourlyStressDay {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let hours = Array(7...20)
        func feature(day: Date, hour: Int, state: StressHourFeature.State, hr: Double?, rmssd: Double?) -> StressHourFeature {
            let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
            return StressHourFeature(start: start, end: start.addingTimeInterval(3_600), state: state, heartRate: hr, rmssd: rmssd)
        }
        let baselineDays = learning ? 9 : 20
        var baseline: [StressHourFeature] = []
        for offset in 1...baselineDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            for hour in hours {
                let wobble = sin(Double(offset * 7 + hour))
                baseline.append(feature(day: day, hour: hour, state: .quiet, hr: 64 + 3 * wobble, rmssd: 46 - 4 * wobble))
            }
        }
        let current = hours.map { hour -> StressHourFeature in
            switch hour {
            case 9: return feature(day: today, hour: hour, state: .missing, hr: nil, rmssd: nil)
            case 12: return feature(day: today, hour: hour, state: .active, hr: nil, rmssd: nil)
            case 14, 15, 16: return feature(day: today, hour: hour, state: .quiet, hr: 79 + Double(hour - 14), rmssd: 27)
            case 8, 18: return feature(day: today, hour: hour, state: .quiet, hr: 58, rmssd: 58)
            default:
                let wobble = cos(Double(hour))
                return feature(day: today, hour: hour, state: .quiet, hr: 65 + 2 * wobble, rmssd: 45 - 3 * wobble)
            }
        }
        return HourlyStress.resolve(current, baseline: baseline, calendar: calendar)
    }
}

/// Forwards everything to the fixture store and adds a fixed hourly day.
actor DebugHourlyStressStore: StressStore {
    private let base: InMemoryStressStore
    private let day: HourlyStressDay

    init(base: InMemoryStressStore, day: HourlyStressDay) {
        self.base = base
        self.day = day
    }

    func hourlyStress() async throws -> HourlyStressDay? { day }
    func latestObservation() async -> StressObservation? { await base.latestObservation() }
    func saveObservation(_ observation: StressObservation) async throws { await base.saveObservation(observation) }
    func spotChecks() async -> [SpotCheckResult] { await base.spotChecks() }
    func saveSpotCheck(_ result: SpotCheckResult) async throws { await base.saveSpotCheck(result) }
    func breathingHistory() async -> [BreathingResult] { await base.breathingHistory() }
    func saveBreathingResult(_ result: BreathingResult) async throws { await base.saveBreathingResult(result) }
    func deleteAll() async { await base.deleteAll() }
}

/// Emits one heart-rate sample a second, easing from 74 to 62 bpm, so a
/// fixture breathing session can start and finish with measured values.
nonisolated struct DebugFixtureLiveConsumer: LiveConsumer {
    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> {
        AsyncStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    let rate = max(62, 74 - tick)
                    continuation.yield(LiveCardiacSample(timestamp: Date(), heartRate: rate, rrMilliseconds: [60_000 / Double(rate)]))
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func release(generation: UUID) async {}
}

extension DebugCaptureFixtures {
    static let breathingController = BreathingSessionController(consumer: DebugFixtureLiveConsumer())
    static var fixtureRoute: RouteRecord { RouteFixtures.completedWalk }
}
#endif

#if DEBUG
/// Capture-only interval samples travel through the same lease as production.
nonisolated private struct DebugIntervalLiveSource: WorkoutLiveSampleSource {
    func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease {
        let pair = AsyncStream<WorkoutSample>.makeStream()
        let task = Task {
            while !Task.isCancelled {
                pair.continuation.yield(WorkoutSample(timestamp: Date(), heartRate: 128))
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            pair.continuation.finish()
        }
        return WorkoutLiveSampleLease(generation: generation, stream: pair.stream) { @Sendable [task, continuation = pair.continuation] in
            task.cancel()
            continuation.finish()
        }
    }
}
#endif

#if DEBUG
import SwiftUI
import Combine

/// Owns one fixture session for the lifetime of its sheet. SwiftUI may
/// reconstruct the view as the shell updates; the record identity stays put.
@MainActor
private final class DebugZoneCaptureData: ObservableObject {
    let mode: String
    let workout: WorkoutRecord
    let session: WorkoutSessionController
    let preferenceStore: WorkoutZoneAlertPreferenceStore
    let context: WorkoutZoneContext

    init(mode: String) {
        self.mode = mode
        context = DebugCaptureFixtures.zoneContext!
        let defaults = UserDefaults(suiteName: "loopr.zone.capture")!
        defaults.removePersistentDomain(forName: "loopr.zone.capture")
        preferenceStore = WorkoutZoneAlertPreferenceStore(defaults: defaults)
        let preference = WorkoutZoneAlertPreference(target: .zoneTwo)
        preferenceStore.set(preference, for: .run)
        let now = Date()
        let duration: TimeInterval = mode == "warm-up" ? 288 : 1200
        let start = now.addingTimeInterval(mode == "summary" ? -3000 : -duration)
        let target = WorkoutZoneTarget(preference: preference, zones: context.zones, zoneTwo: context.zoneTwo)!
        let samples: [WorkoutSample]
        if mode == "summary" {
            samples = (0..<3000).map { second in
                let bpm = second < 240 ? 124 : second >= 2700 ? 153 : 138
                return .init(timestamp: start.addingTimeInterval(Double(second)), heartRate: bpm)
            }
        } else {
            samples = [.init(timestamp: now, heartRate: mode == "above" ? 156 : mode == "below" ? 122 : 138)]
        }
        workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "debug-zone-\(mode)"), activity: .run,
            source: .manual, state: mode == "summary" ? .completed : .active,
            createdAt: start, startedAt: start, endedAt: mode == "summary" ? now : nil,
            samples: samples, finalizationStage: mode == "summary" ? .activeStateCleared : .none,
            zoneAlertPreference: preference, zoneTargetChanges: [.init(at: start, target: target)])
        session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
    }

}

struct DebugZoneCaptureScreen: View {
    @StateObject private var fixture: DebugZoneCaptureData
    init(mode: String) { _fixture = StateObject(wrappedValue: DebugZoneCaptureData(mode: mode)) }
    var body: some View {
        let mode = fixture.mode
        let workout = fixture.workout
        let session = fixture.session
        let preferenceStore = fixture.preferenceStore
        let context = fixture.context
        Group {
            if mode == "start" {
                WorkoutStartPickerScreen(preferenceStore: preferenceStore, loadZoneContext: { @Sendable [context] in context })
            } else if mode == "summary" {
                WorkoutFinishScreen(session: session, workoutID: workout.id)
            } else {
                WorkoutLiveScreen(activity: .run, session: session, workoutID: workout.id,
                    zones: context.zones, zoneTwo: context.zoneTwo, preferenceStore: preferenceStore)
            }
        }
        .task {
            var design = DesignSystemRuntime.state()
            design.reduceMotion = true
            DesignSystemRuntime.apply(design)
            guard mode != "start", mode != "summary" else { return }
            _ = try? await session.select(id: workout.id)
            while !Task.isCancelled {
                try? await session.append(.init(timestamp: Date(), heartRate: mode == "above" ? 156 : mode == "below" ? 122 : 138))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
#endif
