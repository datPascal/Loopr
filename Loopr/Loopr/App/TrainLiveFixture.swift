#if DEBUG
import AnalyticsKit
import SwiftUI
import TrainKit
import WorkoutKit

/// `--loopr-train-fixture=live` opens the live set screen on a frozen clock, for the screen 12 capture.
///
/// Launch with `--loopr-launch-mode=populated --loopr-train-fixture=live`. The shell selects the Train tab and
/// pushes `.train(.live)`, and `TrainDestinationRoots` shows `TrainLiveFixtureRoot` instead of the real session.
/// Nothing here starts a recording, saves a session or schedules a cue, so the screen never changes between
/// captures. The clock is injected as `now: () -> Date` and never moves.
///
/// What it shows, for Alex in Australia/Perth on Tuesday 2023-11-14: Upper A, 24:10 elapsed, 142 bpm in zone 3
/// stamped at the frozen time, strain 7.9 of about 11, bench press on set 3 of 4 after 80 kg × 8 at RPE 7 and
/// RPE 8, and 1:45 left of a 2:30 rest.
///
/// Three variants open the other kinds of set, each with one set logged that beats a best (a PR row) and the
/// rest card with its RPE chips:
/// - `--loopr-train-fixture=live-assist`: Upper A on the band-assisted pull-up, set 1 at BW −17.5 kg × 7.
/// - `--loopr-train-fixture=live-hold`: Lower A on the plank, set 1 held for 0:55, with the hold timer.
/// - `--loopr-train-fixture=live-carry`: Lower A on the farmer's walk, set 1 for 45 m at 32 kg.
///
/// Finish, then Finish and save, closes the frozen session in memory and shows its summary in place. Nothing is saved.
nonisolated extension AppTrainFixtures {
    static let liveArgument = argument + "=live"

    /// Which set the live fixture opens on.
    enum LiveVariant: String, CaseIterable {
        case bench = "live", assist = "live-assist", hold = "live-hold", carry = "live-carry"
    }

    static func liveVariant(arguments: [String] = ProcessInfo.processInfo.arguments) -> LiveVariant? {
        LiveVariant.allCases.first { arguments.contains(argument + "=" + $0.rawValue) }
    }

    static func isLiveRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        liveVariant(arguments: arguments) != nil
    }

    /// Tuesday 2023-11-14, 18:55 in Perth. Upper A is planned for 18:30, after Zone 2, so the session started at 18:30:50.
    static let liveNow: Date = {
        calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 18, minute: 55)) ?? now
    }()

    static let liveElapsedSeconds: TimeInterval = 24 * 60 + 10
    static let liveRestRemainingSeconds: TimeInterval = 105
    static let liveSessionID = UUID(uuidString: "7A0460FE-0000-4000-8000-000000000031") ?? UUID()
    static let liveWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000731") ?? UUID()

    /// 190 bpm maximum. 142 bpm sits in zone 3.
    static let liveZones = HeartRateZoneSet(
        zones: [
            HeartRateZone(number: 1, lowerBPM: 95, upperBPM: 114, lowerPercent: 0.50, upperPercent: 0.60),
            HeartRateZone(number: 2, lowerBPM: 114, upperBPM: 133, lowerPercent: 0.60, upperPercent: 0.70),
            HeartRateZone(number: 3, lowerBPM: 133, upperBPM: 152, lowerPercent: 0.70, upperPercent: 0.80),
            HeartRateZone(number: 4, lowerBPM: 152, upperBPM: 171, lowerPercent: 0.80, upperPercent: 0.90),
            HeartRateZone(number: 5, lowerBPM: 171, upperBPM: 190, lowerPercent: 0.90, upperPercent: 1.00)
        ],
        maxHR: 190, source: .manual, restingHR: 52)

    /// The recording behind the hero. The last heart-rate sample is stamped at the frozen time, so it counts as fresh.
    static var liveWorkout: WorkoutRecord {
        let start = liveNow.addingTimeInterval(-liveElapsedSeconds)
        return WorkoutRecord(
            id: liveWorkoutID,
            identity: WorkoutIdentity.make(activity: .strength, sourceKey: "fixture-train-live", startedAt: start, endedAt: nil),
            activity: .strength, source: .live, state: .active, createdAt: start, startedAt: start,
            samples: [
                WorkoutSample(timestamp: start.addingTimeInterval(600), heartRate: 121, zone: 2, strain: 3.1),
                WorkoutSample(timestamp: start.addingTimeInterval(1_200), heartRate: 133, zone: 3, strain: 5.8),
                WorkoutSample(timestamp: liveNow, heartRate: 142, zone: 3, strain: 7.9)
            ])
    }

    /// Upper A with bench press on set 3 of 4. Sets 1 and 2 are logged at 80 kg × 8, RPE 7 and RPE 8, and the
    /// second one 45 seconds before the frozen time, which leaves 1:45 of the 2:30 rest.
    @MainActor
    static func makeLiveSession(_ variant: LiveVariant = liveVariant() ?? .bench) -> TrainLiveSession {
        let frozen = liveNow
        do {
            let start = frozen.addingTimeInterval(-liveElapsedSeconds)
            let lower = variant == .hold || variant == .carry
            let setup = TrainLiveSetup(
                template: lower ? lowerA : upperA, recoveryScore: 79, programID: strengthBlockID, programWeek: 3,
                history: lower ? [try lowerASession(), try firstLowerASession()] : [try priorUpperASession()],
                expectedStrain: 11, swapPool: [],
                timeZoneIdentifier: zone.identifier, sessionID: liveSessionID, workoutID: liveWorkoutID)
            var model = try TrainLiveModel(setup: setup, now: start)
            // The last set lands so that 1:45 of its rest is left at the frozen time.
            func restLeft(_ rest: Int) -> Date { frozen.addingTimeInterval(-(Double(rest) - liveRestRemainingSeconds)) }
            switch variant {
            case .bench:
                try model.logSet(loadKg: 80, reps: 8, rpe: 7, now: start.addingTimeInterval(600))
                try model.logSet(loadKg: 80, reps: 8, rpe: 8, now: restLeft(150))
            case .assist:
                for (index, reps) in [8, 8, 7, 7].enumerated() {
                    try model.logSet(loadKg: 80, reps: reps, rpe: 7 + Double(index) * 0.5, now: start.addingTimeInterval(Double(index) * 200))
                }
                try model.focus(exerciseAt: 1)
                try model.logSet(TrainSetValues(reps: 7, assistKg: 17.5), now: restLeft(150))
            case .hold:
                try model.focus(exerciseAt: 3)
                // Plank rest is 1:00, so 0:45 of it is left.
                try model.logSet(TrainSetValues(seconds: 55), now: frozen.addingTimeInterval(-15))
            case .carry:
                try model.focus(exerciseAt: 4)
                // Carry rest is 1:30, so 1:00 of it is left.
                try model.logSet(TrainSetValues(loadKg: 32, metres: 45), now: frozen.addingTimeInterval(-30))
            }
            return TrainLiveSession(model: model, clock: { frozen })
        } catch {
            preconditionFailure("The live Train fixture does not build: \(error)")
        }
    }
}

/// The live screen with the frozen session. Finish closes the session in memory and shows its summary in place;
/// nothing is saved and no recording is touched, so a capture can reach `train-summary-screen` from here.
struct TrainLiveFixtureRoot: View {
    @StateObject private var session = AppTrainFixtures.makeLiveSession()
    @State private var summary: TrainSessionDetail?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let summary {
            TrainSummaryScreen(detail: summary, mode: .finished) { dismiss() }
        } else {
            TrainLiveScreen(session: session, workout: AppTrainFixtures.liveWorkout, zones: AppTrainFixtures.liveZones,
                            bandCueAvailable: true, onFinish: { @MainActor @Sendable in
                                summary = TrainSessionDetail(session: try session.finish())
                            })
        }
    }
}
#endif
