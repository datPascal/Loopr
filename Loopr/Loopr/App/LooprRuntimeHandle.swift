import BluetoothKit
import Foundation
import ProtocolKit
import SyncKit

/// The one runtime reference the shell and its repositories hold.
///
/// Re-pairing, removing a pairing and switching experimental support all stop
/// one Bluetooth runtime and may start another. The shell used to be keyed on
/// that swap, so each of them destroyed every tab, closed the Settings sheet
/// the person started from and reopened storage behind a blank screen. This
/// handle stays put for the life of the model and forwards to whichever runtime
/// is installed. With none installed it answers like a band that is not
/// connected: commands throw `.unavailable` and the state is a stopped session.
nonisolated final class LooprRuntimeHandle: LooprDeviceCenterRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: (any LooprDeviceCenterRuntime)?

    init() {}

    /// Called by `BluetoothApplicationModel` whenever the bound runtime changes.
    func bind(_ runtime: (any LooprDeviceCenterRuntime)?) {
        lock.withLock { installed = runtime }
    }

    var current: (any LooprDeviceCenterRuntime)? {
        lock.withLock { installed }
    }

    func hasBoundRuntime() async -> Bool { current != nil }

    // MARK: Heart live

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        guard let current else { throw HeartLiveStreamAdapterError.unavailable }
        return try await current.acquireLiveStream(kind: kind, consumer: consumer)
    }

    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        guard let current else { throw HeartLiveStreamAdapterError.unavailable }
        return try await current.acquireLiveEventStream(kind: kind, consumer: consumer)
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        await current?.bufferedLiveSamples(for: kind) ?? []
    }

    // MARK: Device Center

    func runtimeState() async -> BluetoothAdoptionRuntimeState {
        guard let current else { return Self.unboundState }
        return await current.runtimeState()
    }

    func performManualSync(maxDuration: TimeInterval) async -> Bool {
        await current?.performManualSync(maxDuration: maxDuration) ?? false
    }

    func diagnosticsSnapshot() async -> ConnectionDiagnosticsSnapshot {
        guard let current else { return ConnectionDiagnosticsSnapshot(events: [], violations: []) }
        return await current.diagnosticsSnapshot()
    }

    func readHeartRateSharing() async throws -> Bool? {
        try await require().readHeartRateSharing()
    }

    func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        try await require().setHeartRateSharing(enabled: enabled)
    }

    func renameBand(to name: String) async throws {
        try await require().renameBand(to: name)
    }

    func buzzBand(effect: UInt8) async throws {
        try await require().buzzBand(effect: effect)
    }

    func buzzBand(effect: UInt8, expectedGeneration: UInt64) async throws {
        try await require().buzzBand(effect: effect, expectedGeneration: expectedGeneration)
    }

    func setBandAlarm(fireDate: Date) async throws {
        try await require().setBandAlarm(fireDate: fireDate)
    }

    func readBandAlarm() async throws -> Date? {
        try await require().readBandAlarm()
    }

    func testBandAlarm() async throws {
        try await require().testBandAlarm()
    }

    func disableBandAlarm() async throws {
        try await require().disableBandAlarm()
    }

    func readSignalStrength() async -> Int? {
        await current?.readSignalStrength()
    }

    #if DEBUG
    @discardableResult
    func sendDebugRawBandCommand(body: Data, expectingOpcode: UInt8?) async throws -> Data {
        try await require().sendDebugRawBandCommand(body: body, expectingOpcode: expectingOpcode)
    }
    #endif

    /// One stream for the life of the shell. When a runtime is replaced its
    /// stream ends; this one waits for the next runtime and carries on, so the
    /// double-tap reader does not go deaf after a re-pair.
    func bandEvents() async -> AsyncStream<BandEventEnvelope> {
        let (stream, continuation) = AsyncStream<BandEventEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if let runtime = self.current {
                    for await event in await runtime.bandEvents() {
                        guard !Task.isCancelled else { break }
                        continuation.yield(event)
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func require() throws -> any LooprDeviceCenterRuntime {
        guard let current else { throw LooprDeviceRuntimeCommandError.unavailable }
        return current
    }

    /// A stopped session with nothing connected.
    static let unboundState = BluetoothAdoptionRuntimeState(
        running: false, generation: nil, connection: .idle,
        setupReady: false, setupComplete: false, radioState: .unknown,
        health: ConnectionHealthReport(healthy: false, stale: false, shouldBounce: false,
                                       ageOfLatestObservation: nil, corruptionRate: 0, reasons: []),
        pendingReconnect: nil, liveConsumerCount: 0, pendingHistoryReplayCount: 0,
        validFrameCount: 0, corruptFrameCount: 0, writeTimeoutCount: 0, lastError: nil
    )
}
