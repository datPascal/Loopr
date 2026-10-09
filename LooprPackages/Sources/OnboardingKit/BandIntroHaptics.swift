#if os(iOS)
import AVFoundation
import CoreHaptics
import Foundation

public extension BandIntroHapticPlan {
    /// The Core Haptics pattern for this plan. A sound cue plays only when its
    /// resource is in `audioResources`; without it the haptics play alone.
    func makePattern(audioResources: [BandIntroSound: CHHapticAudioResourceID] = [:]) throws -> CHHapticPattern {
        var events = events.map { event -> CHHapticEvent in
            var parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness))
            ]
            if let decayTime = event.decayTime {
                parameters += [
                    CHHapticEventParameter(parameterID: .sustained, value: 0),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0),
                    CHHapticEventParameter(parameterID: .decayTime, value: Float(decayTime))
                ]
            }
            switch event.kind {
            case .transient:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: event.time)
            case .continuous(let duration):
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters,
                    relativeTime: event.time,
                    duration: duration
                )
            }
        }
        events += sounds.compactMap { cue -> CHHapticEvent? in
            guard let resource = audioResources[cue.sound] else { return nil }
            return CHHapticEvent(
                audioResourceID: resource,
                parameters: [CHHapticEventParameter(parameterID: .audioVolume, value: Float(cue.volume))],
                relativeTime: cue.time
            )
        }
        let curves = curves.map { curve in
            CHHapticParameterCurve(
                parameterID: curve.parameter == .intensityControl ? .hapticIntensityControl : .hapticSharpnessControl,
                controlPoints: curve.points.map {
                    CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: Float($0.value))
                },
                relativeTime: curve.time
            )
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
}

/// Owns the `CHHapticEngine` for the intro and the sounds that play on it.
/// Sounds and haptics share one pattern, so they share one clock. On a phone
/// without haptics every call is a no-op and the rest of the intro behaves the
/// same.
@MainActor
final class BandIntroHaptics {
    let isSupported: Bool
    private let soundURLs: [BandIntroSound: URL]
    private var audioResources: [BandIntroSound: CHHapticAudioResourceID] = [:]
    /// Called on the main actor after the system reset the engine and it was
    /// restarted. Scheduled players do not survive a reset, so the owner
    /// reschedules from the current video time.
    var onEngineReset: (() -> Void)?

    private var engine: CHHapticEngine?
    private var engineRunning = false
    private var player: (any CHHapticPatternPlayer)?

    init(
        isSupported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics,
        soundURLs: [BandIntroSound: URL] = [:]
    ) {
        self.isSupported = isSupported
        self.soundURLs = soundURLs
    }

    /// Creates and starts the engine ahead of the first event so the first
    /// pattern is not delayed by engine start-up.
    func prepare() {
        guard isSupported else { return }
        if engine == nil {
            // The sounds go through the app's session in the ambient category:
            // they mix with the user's music instead of stopping it, and the
            // ring/silent switch mutes them.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient)
            guard let created = try? CHHapticEngine(audioSession: session) else { return }
            created.playsHapticsOnly = soundURLs.isEmpty
            created.isAutoShutdownEnabled = false
            Self.installHandlers(on: created, owner: self)
            engine = created
            registerSounds()
        }
        startEngineIfNeeded()
    }

    /// Plays `plan` so that its time zero lands `lead` seconds from now on the
    /// engine clock. Any earlier pattern is stopped first.
    func play(_ plan: BandIntroHapticPlan, lead: TimeInterval = 0) {
        stop()
        guard isSupported, !plan.isEmpty else { return }
        prepare()
        guard let engine, engineRunning else { return }
        do {
            let player = try engine.makePlayer(with: plan.makePattern(audioResources: audioResources))
            let startTime = lead > 0 ? engine.currentTime + lead : CHHapticTimeImmediate
            try player.start(atTime: startTime)
            self.player = player
        } catch {
            player = nil
        }
    }

    /// Cancels the scheduled pattern immediately, including events still in the future.
    func stop() {
        guard let player else { return }
        try? player.stop(atTime: CHHapticTimeImmediate)
        self.player = nil
    }

    /// Stops everything and releases the actuator.
    func shutdown() {
        stop()
        engine?.stop(completionHandler: nil)
        engineRunning = false
    }

    /// Registers each sound once per engine. A reset drops the registrations,
    /// so it runs again after one.
    private func registerSounds() {
        guard let engine else { return }
        audioResources = [:]
        for (sound, url) in soundURLs {
            if let resource = try? engine.registerAudioResource(url, options: [:]) {
                audioResources[sound] = resource
            }
        }
    }

    private func startEngineIfNeeded() {
        guard let engine, !engineRunning else { return }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            engineRunning = false
        }
    }

    /// Core Haptics calls these handlers on its own queue. They are built
    /// outside the main actor so the closures carry no main-actor isolation,
    /// and they hop back before touching state.
    private nonisolated static func installHandlers(on engine: CHHapticEngine, owner: BandIntroHaptics) {
        engine.stoppedHandler = { [weak owner] _ in
            Task { @MainActor [owner] in owner?.engineDidStop() }
        }
        engine.resetHandler = { [weak owner] in
            Task { @MainActor [owner] in owner?.engineDidReset() }
        }
    }

    private func engineDidStop() {
        // The system stopped the engine (audio interruption, app suspension,
        // idle). Its players are gone; the next play restarts it.
        engineRunning = false
        player = nil
    }

    private func engineDidReset() {
        engineRunning = false
        player = nil
        registerSounds()
        startEngineIfNeeded()
        if engineRunning { onEngineReset?() }
    }
}
#endif
