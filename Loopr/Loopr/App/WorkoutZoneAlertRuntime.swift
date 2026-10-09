import AnalyticsKit
import AudioToolbox
import Foundation
import UIKit
import WorkoutKit

/// Observes the durable workout stream, so alerts continue when the live
/// screen is covered. The existing SyncKit owner remains the only BLE writer.
actor WorkoutZoneAlertRuntime {
    static let shared = WorkoutZoneAlertRuntime()

    private var task: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var workoutID: UUID?
    private var preference = WorkoutZoneAlertPreference()
    private var zones: HeartRateZoneSet?
    private var delivery: BandCueDelivery?
    private var cueSessionID = UUID()
    private var revision = UUID()
    private var machine = WorkoutZoneAlertMachine()
    private var lastSampleTime: Date?
    private let now: @Sendable () -> Date
    private let cueQueue: BandCueCommandQueue
    private let phone: @Sendable (WorkoutZoneAlertEvent, Bool, Bool) async -> Void

    init(now: @escaping @Sendable () -> Date = Date.init,
         cueQueue: BandCueCommandQueue = .shared,
         phone: @escaping @Sendable (WorkoutZoneAlertEvent, Bool, Bool) async -> Void = { event, vibrate, sound in
             await WorkoutZoneAlertRuntime.phoneCue(event, vibrate: vibrate, sound: sound)
         }) {
        self.now = now; self.cueQueue = cueQueue; self.phone = phone
    }

    func start(
        workoutID: UUID,
        session: WorkoutSessionController,
        zones: HeartRateZoneSet?,
        preference: WorkoutZoneAlertPreference,
        band: (any LooprDeviceCenterRuntime)?
    ) {
        task?.cancel()
        cueTask?.cancel()
        cueTask = nil
        self.workoutID = workoutID
        self.zones = zones
        self.preference = preference
        self.delivery = BandCueDelivery(runtime: band)
        cueSessionID = UUID()
        revision = UUID()
        machine.reset()
        lastSampleTime = nil
        task = Task { [weak self] in
            let updates = await session.updates(for: workoutID)
            for await workout in updates {
                guard !Task.isCancelled else { break }
                _ = await self?.receive(workout)
            }
        }
    }

    func configure(_ preference: WorkoutZoneAlertPreference) async {
        cueTask?.cancel()
        cueTask = nil
        await delivery?.invalidate()
        cueSessionID = UUID()
        self.preference = preference
        revision = UUID()
        machine.reset()
        lastSampleTime = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        cueTask?.cancel()
        cueTask = nil
        workoutID = nil
        let previousDelivery = delivery
        delivery = nil
        revision = UUID()
        Task { await previousDelivery?.invalidate() }
        machine.reset()
        lastSampleTime = nil
    }

    @discardableResult
    func receive(_ workout: WorkoutRecord) async -> Task<Void, Never>? {
        guard workout.id == workoutID else { return nil }
        if let saved = workout.zoneAlertPreference, saved != preference { await configure(saved) }
        guard workout.state == .active || workout.state == .paused else {
            stop()
            return nil
        }
        if workout.state == .paused {
            cueTask?.cancel()
            cueTask = nil
            await delivery?.invalidate()
            cueSessionID = UUID()
            revision = UUID()
            machine.reset()
            lastSampleTime = workout.samples.last?.timestamp
            return nil
        }
        guard workout.state == .active,
              let sample = workout.samples.last else { return nil }
        if let lastSampleTime {
            let gap = sample.timestamp.timeIntervalSince(lastSampleTime)
            guard gap > 0 else { return nil }
            if gap > machine.configuration.maximumSampleGapSeconds { machine.interrupt() }
        }
        lastSampleTime = sample.timestamp
        let fresh = now().timeIntervalSince(sample.timestamp)
        let bpm = fresh >= 0 && fresh <= WorkoutLiveMetrics.heartRateFreshness ? sample.heartRate : nil
        let target = workout.currentZoneTarget?.range ?? preference.target.range(in: zones)
        guard let event = machine.observe(bpm: bpm, at: sample.timestamp, target: target,
                                          activeElapsed: workout.activeElapsed(at: sample.timestamp) ?? 0, preference: preference) else { return nil }
        // Delivery must not block the durable stream. A pause or preference
        // change cancels a multi-pulse cue before its remaining commands.
        cueTask = Task { [weak self] in
            guard let self else { return }
            await self.deliver(event, workoutID: workout.id)
        }
        return cueTask
    }

    private func deliver(_ event: WorkoutZoneAlertEvent, workoutID: UUID) async {
        guard self.workoutID == workoutID else { return }
        let revision = self.revision
        let sent = await delivery?.send(pattern: WorkoutBandCuePattern.effects(for: event), sessionID: cueSessionID, queue: cueQueue) ?? false
        guard self.workoutID == workoutID, self.revision == revision, !Task.isCancelled else { return }
        await phone(event, !sent, preference.playSound)
    }

    @MainActor
    private static func phoneCue(_ event: WorkoutZoneAlertEvent, vibrate: Bool, sound: Bool) async {
        if vibrate {
            // Match the band vocabulary with short, double and longer cues.
            switch event {
            case .tooHigh:
                let feedback = UIImpactFeedbackGenerator(style: .medium)
                feedback.impactOccurred()
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                feedback.impactOccurred()
            case .tooLow:
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            case .returned:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        if sound { AudioServicesPlaySystemSound(SystemSoundID(1005)) }
    }
}
