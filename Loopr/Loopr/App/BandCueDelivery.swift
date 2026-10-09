import Foundation
import ProtocolKit
import SyncKit
import StressKit
import WorkoutKit

nonisolated enum BandCuePattern {
    // OpenStrap edge/guides/BUZZ_MEANINGS.md documents these bounded presets.
    static let single: UInt8 = 0
    static let double: UInt8 = 2
    static func breathing(_ phase: BreathingCuePhase) -> UInt8 { phase == .inhale ? single : double }
    static func interval(_ phase: IntervalPhase) -> UInt8? {
        switch phase { case .work: single; case .rest, .complete: double }
    }
}

nonisolated enum BandCueAvailability {
    static func reason(runtime: (any LooprDeviceCenterRuntime)?) async -> String? {
        guard let runtime else { return "Connect your band to use buzzes." }
        let state = await runtime.runtimeState()
        guard state.acceptsBandCommands else { return "Connect your band to use buzzes." }
        guard state.bandModel == .whoop4 else { return "Band buzzes are unavailable for this band." }
        return nil
    }
}

/// Pins each cue session to the connection that accepted its first cue. An
/// older breathing or timer task cannot buzz a replacement connection.
actor BandCueDelivery {
    private let runtime: (any LooprDeviceCenterRuntime)?
    private var sessionID: UUID?
    private var generation: UInt64?
    private var runtimeIdentity: ObjectIdentifier?
    init(runtime: (any LooprDeviceCenterRuntime)?) { self.runtime = runtime }

    @discardableResult
    func send(effect: UInt8, sessionID: UUID) async -> Bool {
        await send(pattern: [effect], sessionID: sessionID)
    }

    @discardableResult
    func send(pattern: [UInt8], sessionID: UUID, queue: BandCueCommandQueue = .shared) async -> Bool {
        guard !Task.isCancelled, let runtime else { return false }
        let commandRuntime: any LooprDeviceCenterRuntime
        if let handle = runtime as? LooprRuntimeHandle {
            guard let installed = handle.current else { return false }
            commandRuntime = installed
        } else { commandRuntime = runtime }
        let identity = ObjectIdentifier(commandRuntime as AnyObject)
        let state = await commandRuntime.runtimeState()
        guard !Task.isCancelled, state.acceptsBandCommands, state.bandModel == .whoop4,
              let currentGeneration = state.generation else { return false }
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            generation = currentGeneration
            runtimeIdentity = identity
        }
        guard generation == currentGeneration, runtimeIdentity == identity else { return false }
        return await queue.perform(pattern: pattern) { @Sendable [weak self] effect in
            guard let self else { return false }
            return await self.write(effect: effect, sessionID: sessionID, expectedGeneration: currentGeneration, identity: identity)
        }
    }

    func invalidate() { sessionID = nil; generation = nil; runtimeIdentity = nil }

    private func write(effect: UInt8, sessionID: UUID, expectedGeneration: UInt64, identity: ObjectIdentifier) async -> Bool {
        guard !Task.isCancelled, self.sessionID == sessionID, let runtime else { return false }
        let current: any LooprDeviceCenterRuntime
        if let handle = runtime as? LooprRuntimeHandle {
            guard let installed = handle.current else { return false }
            current = installed
        } else { current = runtime }
        guard ObjectIdentifier(current as AnyObject) == identity else { return false }
        let state = await current.runtimeState()
        guard !Task.isCancelled, self.sessionID == sessionID, state.generation == expectedGeneration,
              state.acceptsBandCommands, state.bandModel == .whoop4 else { return false }
        do {
            try await current.buzzBand(effect: effect, expectedGeneration: expectedGeneration)
            return true
        } catch { return false }
    }
}

nonisolated enum WorkoutBandCuePattern {
    static func effects(for event: WorkoutZoneAlertEvent) -> [UInt8] {
        switch event {
        case .tooHigh: [BandCuePattern.double]
        // No bounded long effect is documented. A longer sequence uses only
        // the existing quick single preset. Never use the latched effect 1.
        case .tooLow: [BandCuePattern.single, BandCuePattern.single, BandCuePattern.single]
        case .returned: [BandCuePattern.single]
        }
    }
}

/// Serializes whole cue patterns across workout, breathing and interval
/// callers. Actor isolation alone would allow interleaving across awaits.
actor BandCueCommandQueue {
    static let shared = BandCueCommandQueue()
    private var tail: Task<Bool, Never>?
    private let wait: @Sendable () async throws -> Void
    init(wait: @escaping @Sendable () async throws -> Void = {
        // Application pacing, not a claim about motor duration. Physical
        // separation and the longer cue's feel remain a WHOOP 4 test gate.
        try await Task.sleep(for: .milliseconds(750))
    }) { self.wait = wait }

    func perform(pattern: [UInt8], send: @escaping @Sendable (UInt8) async -> Bool) async -> Bool {
        let previous = tail
        let wait = self.wait
        let job = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            for effect in pattern {
                guard !Task.isCancelled, await send(effect) else { return false }
                do { try await wait() } catch { return false }
            }
            return !pattern.isEmpty
        }
        tail = job
        return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }
}
