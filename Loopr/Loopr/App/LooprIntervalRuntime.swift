import ActivityKit
import AudioToolbox
import Foundation
import UIKit
import WorkoutKit

@MainActor
final class LooprIntervalRuntime {
    static let shared = LooprIntervalRuntime()
    let model = IntervalTimerModel()

    func reconcileOnWake() async {
        if !model.isRunning { await IntervalActivityRuntime.shared.endOrphans() }
    }

    func endAll() async {
        await model.stop()
        await IntervalActivityRuntime.shared.endOrphans()
    }

    func hooks(runtime: (any LooprDeviceCenterRuntime)?) -> IntervalTimerHooks {
        let activity = IntervalActivityRuntime.shared
        let bandCueDelivery = BandCueDelivery(runtime: runtime)
        return .init(
            started: { @Sendable [activity] id, schedule in await activity.start(id: id, schedule: schedule) },
            changed: { @Sendable [activity, bandCueDelivery] id, progress in
                guard !Task.isCancelled else { return }
                await activity.update(id: id, progress: progress)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    UINotificationFeedbackGenerator().notificationOccurred(progress.phase == .work ? .success : .warning)
                }
                if let effect = BandCuePattern.interval(progress.phase), !Task.isCancelled {
                    await bandCueDelivery.send(effect: effect, sessionID: id)
                }
            },
            ended: { @Sendable [activity] id in await activity.end(id: id) }
        )
    }
}

private actor IntervalActivityRuntime {
    static let shared = IntervalActivityRuntime()
    private var sessionID: UUID?
    private var activity: Activity<LooprIntervalActivityAttributes>?

    func start(id: UUID, schedule: IntervalSchedule) async {
        sessionID = id
        for old in Activity<LooprIntervalActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        let allowed = await LooprLiveActivityRuntime.shared.allowsLiveActivities()
        guard sessionID == id, allowed, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let progress = schedule.progress(at: Date())
        activity = try? Activity.request(
            attributes: LooprIntervalActivityAttributes(sessionID: id, rounds: schedule.configuration.rounds, endsAt: schedule.endsAt),
            content: content(progress), pushType: nil
        )
    }

    func update(id: UUID, progress: IntervalProgress) async {
        guard sessionID == id else { return }
        let allowed = await LooprLiveActivityRuntime.shared.allowsLiveActivities()
        guard sessionID == id else { return }
        guard allowed else { await end(id: id); return }
        await activity?.update(content(progress))
    }

    func end(id: UUID) async {
        guard sessionID == id else { return }
        let old = activity
        activity = nil; sessionID = nil
        await old?.end(nil, dismissalPolicy: .immediate)
    }

    func endOrphans() async {
        sessionID = nil; activity = nil
        for old in Activity<LooprIntervalActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func content(_ progress: IntervalProgress) -> ActivityContent<LooprIntervalActivityAttributes.ContentState> {
        .init(state: .init(phase: progress.phase == .work ? "Work" : progress.phase == .rest ? "Rest" : "Complete",
                           round: progress.round, phaseStartedAt: progress.phaseStartedAt, phaseEndsAt: progress.phaseEndsAt),
              staleDate: progress.phaseEndsAt)
    }
}
