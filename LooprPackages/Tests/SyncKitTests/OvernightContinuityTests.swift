import BluetoothKit
import Foundation
import ProtocolKit
import StorageKit
import SyncKit
import TestSupport
import XCTest

// MARK: - Fakes

/// Advances only when a test asks. Reconnect backoff sleeps are parked on a
/// real, cancellable wall-clock sleep the test never waits out, so a scheduled
/// reconnect cannot race the behaviour under test.
private final class OvernightClock: BluetoothAdoptionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(start: Date = Date(timeIntervalSince1970: 1_750_000_000)) { value = start }

    func now() -> Date { lock.withLock { value } }

    func sleep(for interval: TimeInterval) async throws {
        // 1.5...5 s is exclusively the first two reconnect backoff steps. Every
        // other interval the runtime sleeps on is either sub-second pacing, the
        // 6 s band-command timeout, the 8 s write timeout, or longer.
        if interval >= 1.5, interval <= 5 {
            try await Task.sleep(nanoseconds: 120_000_000_000)
            return
        }
        lock.withLock {
            if interval > 0, interval < SerializedGenerationPinnedWriter.writeTimeout {
                value = value.addingTimeInterval(interval)
            }
        }
        if interval >= SerializedGenerationPinnedWriter.writeTimeout {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } else if interval > 0 {
            await Task.yield()
        }
    }

    func nowNanoseconds() -> UInt64 {
        UInt64(max(0, now().timeIntervalSinceReferenceDate * 1_000_000_000))
    }

    var supportsAutonomousSleep: Bool { false }

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        if nanoseconds > 0 { await Task.yield() }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor OvernightStore: BluetoothAdoptionStore, HistoryBatchAcknowledger {
    private let identifier: UUID?
    private(set) var commitCount = 0
    private(set) var acknowledgedBatchIDs: [String] = []

    init(identifier: UUID?) { self.identifier = identifier }

    func loadBluetoothIdentifier() async -> UUID? { identifier }
    func saveBluetoothIdentifier(_: UUID) async throws {}
    func removeBluetoothIdentifier() async throws {}

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        commitCount += 1
        switch boundary {
        case .tokenized(let token):
            return .ackEligible(CommittedHistoryBatch(
                token: token,
                batchID: diagnostics.batchID,
                recordCount: records.count,
                archivedCount: archived.count
            ))
        case .completionTail:
            return .completionTail(CommittedHistoryTail(
                batchID: diagnostics.batchID,
                recordCount: records.count,
                archivedCount: archived.count
            ))
        }
    }

    func markAcknowledged(batchID: String, updatedAt _: Int64) async throws {
        acknowledgedBatchIDs.append(batchID)
    }

    func recordedCommitCount() -> Int { commitCount }
    func recordedAcknowledgements() -> [String] { acknowledgedBatchIDs }
}

// MARK: - Helpers

private func overnightSetupEvents(for peripheral: UUID) -> [TransportEvent] {
    [
        .connected(peripheral),
        .servicesDiscovered([HarvardBluetoothProfile.service]),
        .characteristicsDiscovered([
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.write]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]),
        .notificationStateChanged(HarvardBluetoothProfile.response, enabled: true),
        .notificationStateChanged(HarvardBluetoothProfile.events, enabled: true),
        .notificationStateChanged(HarvardBluetoothProfile.data, enabled: true)
    ]
}

private func overnightFrame(inner: Data) -> Data {
    var padded = Data(inner)
    let remainder = padded.count % 4
    if remainder != 0 {
        padded.append(contentsOf: repeatElement(UInt8(0), count: 4 - remainder))
    }
    let declared = UInt16(padded.count + 4)
    let length = Data([
        UInt8(truncatingIfNeeded: declared),
        UInt8(truncatingIfNeeded: declared >> 8)
    ])
    var frame = Data([Gen4Frame.marker, length[0], length[1], CRC8.calculate(length)])
    frame.append(padded)
    let crc = CRC32.calculate(padded)
    frame.append(contentsOf: [
        UInt8(truncatingIfNeeded: crc),
        UInt8(truncatingIfNeeded: crc >> 8),
        UInt8(truncatingIfNeeded: crc >> 16),
        UInt8(truncatingIfNeeded: crc >> 24)
    ])
    return frame
}

private func overnightHistoryStartFrame() -> Data {
    overnightFrame(inner: Data([0x31, 0x00, 0x01, 0x00]))
}

private func overnightHistoryCompleteFrame() -> Data {
    overnightFrame(inner: Data([0x31, 0x00, 0x03, 0x00]))
}

private func overnightLiveFrame() -> Data {
    overnightFrame(inner: Data([0x28, 0x10, 0x20, 0x30]))
}

private func waitForOvernightState(
    _ runtime: BluetoothAdoptionRuntime,
    timeout: TimeInterval = 5,
    matching predicate: @escaping @Sendable (BluetoothAdoptionRuntimeState) -> Bool
) async -> Bool {
    let stream = await runtime.stateStream()
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await state in stream where predicate(state) { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func waitForOvernightSetup(_ runtime: BluetoothAdoptionRuntime) async -> Bool {
    await waitForOvernightState(runtime) { $0.setupComplete && $0.lastError == nil }
}

// MARK: - Tests

final class OvernightContinuityTests: XCTestCase {
    /// The runtime is expected to keep the link for weeks. A BGTask running out
    /// of time says nothing about the band, so expiration must leave the
    /// generation, the completed setup, and the native link alone.
    func testBackgroundExpirationKeepsTheBandConnected() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: OvernightClock()
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")

        // Band cues, zone alerts and Device Center gate on the model. The
        // Gen 4 runtime must report it, or every WHOOP 4 cue fails closed.
        let model = await runtime.currentState().bandModel
        XCTAssertEqual(model, .whoop4)
        let generationBeforeExpiry = await runtime.currentState().generation
        let disconnectsBeforeExpiry = transport.recordedDisconnectCount()

        let background = Task { await runtime.runBackgroundSync(maxDuration: 30) }
        for _ in 0..<20 { await Task.yield() }
        let expired = await runtime.expireBackground()
        XCTAssertTrue(expired)
        _ = await background.value

        let state = await runtime.currentState()
        XCTAssertTrue(state.setupComplete, "an expired BGTask must not undo a completed setup")
        XCTAssertEqual(state.generation, generationBeforeExpiry)
        XCTAssertNil(state.lastError, "an expired BGTask is not a connection error")
        XCTAssertEqual(state.connection, .listening(generation: 2, peripheral: peripheral))
        XCTAssertEqual(
            transport.recordedDisconnectCount(),
            disconnectsBeforeExpiry,
            "expiration must not disconnect the band"
        )
        await runtime.stop()
    }

    /// Timers do not fire while iOS has the app suspended, so an inbound packet
    /// is the only chance a background app gets to notice that the fifteen
    /// minute history top-up is due.
    func testInboundPacketRequestsTheHistoryTopUpAfterTheFifteenMinuteFloor() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let clock = OvernightClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")
        await runtime.enterBackground()

        // End the drain that initialization started.
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightHistoryCompleteFrame()),
            generation: 2
        )
        let offloadAfterComplete = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(offloadAfterComplete)

        // A packet inside the floor changes nothing.
        clock.advance(by: 60)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadInsideFloor = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(offloadInsideFloor, "the top-up floor is fifteen minutes, not one")

        clock.advance(by: ReconnectTimingDefaults.periodicHistoryRequest + 60)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadAfterFloor = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(
            offloadAfterFloor,
            "a wake after the floor must request the next history chunk"
        )
        await runtime.stop()
    }

    /// A drain that silently died while the app was asleep would otherwise
    /// block every later top-up, because the offload flag stays set.
    func testStalledOffloadIsAbortedOnTheNextWake() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let clock = OvernightClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")
        await runtime.enterBackground()
        let offloadAfterSetup = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(offloadAfterSetup)

        clock.advance(by: ReconnectTimingDefaults.stalledOffloadDetection + 1)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadAfterWake = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(
            offloadAfterWake,
            "a drain with no activity for a minute is aborted on the next wake"
        )

        // With the flag cleared, the next wake past the floor is free to ask
        // for the following chunk. A stuck flag would block this forever.
        clock.advance(by: ReconnectTimingDefaults.periodicHistoryRequest)
        let performed = await runtime.evaluateEventDrivenMaintenance()
        XCTAssertTrue(performed, "the top-up must resume once the stalled drain is cleared")
        await runtime.stop()
    }

    /// A CoreBluetooth restoration callback used to be rejected by the state
    /// machine and silently dropped. It must be consumed, and it must not
    /// disturb a healthy link.
    func testRestorationIsAcceptedAndLeavesAHealthyLinkAlone() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: OvernightClock()
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")
        let connectsBefore = transport.recordedConnects().count

        let result = await runtime.handle(.restored(RestorationSnapshot(
            managerState: .poweredOn,
            peripherals: [peripheral]
        )))
        guard case .accepted(.listening) = result else {
            return XCTFail("restoration must be consumed, not rejected: \(result)")
        }
        XCTAssertEqual(transport.recordedConnects().count, connectsBefore)
        let stillComplete = await runtime.currentState().setupComplete
        XCTAssertTrue(stillComplete)
        await runtime.stop()
    }

    /// The overnight case that matters: iOS relaunched the app while the link
    /// was down. Restoration outranks the backoff timer and re-adopts at once.
    func testRestorationReAdoptsAParkedConnection() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: OvernightClock()
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")

        _ = await runtime.handle(
            .disconnected(peripheral, error: .outOfRange),
            generation: 2
        )
        let parkedConnection = await runtime.currentState().connection
        XCTAssertEqual(parkedConnection, .outOfRange)
        let connectsBefore = transport.recordedConnects().count

        _ = await runtime.handle(.restored(RestorationSnapshot(
            managerState: .poweredOn,
            peripherals: [peripheral]
        )))

        XCTAssertGreaterThan(
            transport.recordedConnects().count,
            connectsBefore,
            "a restored peripheral must be connected again immediately"
        )
        let pendingAfterRestore = await runtime.currentState().pendingReconnect
        XCTAssertNil(pendingAfterRestore, "restoration supersedes the scheduled backoff")
        await runtime.stop()
    }

    /// A link that drops in the middle of a historical drain must not leave the
    /// offload flag set. While it is set the runtime holds every live stream
    /// step down, so the band keeps streaming raw and IMU packets all night.
    func testOffloadFlagClearsWhenTheLinkDropsMidDrain() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: OvernightClock()
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")

        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightHistoryStartFrame()),
            generation: 2
        )
        let drainActive = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(drainActive)

        _ = await runtime.handle(
            .disconnected(peripheral, error: .disconnected),
            generation: 2
        )
        let drainAfterDrop = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(drainAfterDrop, "a drop mid-drain must clear the drain flag")
        await runtime.stop()
    }

    /// The overnight trace showed Loopr asking for history and then sending
    /// ABORT_HISTORICAL_TRANSMITS about a second later, over and over. The
    /// stall fuse was reading the activity stamp of the *previous* drain, which
    /// is fifteen minutes old by the time the next top-up is due, so every
    /// fresh burst looked stalled on its first inbound packet.
    func testAFreshTopUpIsNotAbortedByTheStallFuse() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: overnightSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let clock = OvernightClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: OvernightStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        let setupComplete = await waitForOvernightSetup(runtime)
        XCTAssertTrue(setupComplete, "setup did not complete")
        await runtime.enterBackground()

        // Finish the drain initialization started. This is the metadata packet
        // that stamps the history activity clock.
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightHistoryCompleteFrame()),
            generation: 2
        )
        let offloadAfterComplete = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(offloadAfterComplete)

        // Fifteen quiet minutes later a wake asks for the next chunk.
        clock.advance(by: ReconnectTimingDefaults.periodicHistoryRequest + 1)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadAfterTopUp = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(offloadAfterTopUp, "the fifteen minute top-up must open a burst")

        // The band has not sent the first record yet. A burst five seconds old
        // is not stalled, on a wake or on a tick.
        clock.advance(by: 5)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadAfterWake = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(
            offloadAfterWake,
            "a burst that is five seconds old must not be aborted as stalled"
        )

        clock.advance(by: 5)
        _ = await runtime.maintenanceTick()
        let offloadAfterTick = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(
            offloadAfterTick,
            "the ten second tick must not abort a ten second old burst either"
        )

        // The fuse still works: a minute of silence on the same burst aborts it.
        clock.advance(by: ReconnectTimingDefaults.stalledOffloadDetection + 1)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, overnightLiveFrame()),
            generation: 2
        )
        let offloadAfterFuse = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(
            offloadAfterFuse,
            "a burst with no records for a minute is still aborted"
        )
        await runtime.stop()
    }
}
