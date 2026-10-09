import BluetoothKit
import Foundation
import ProtocolKit
import StorageKit
import SyncKit
import TestSupport
import XCTest

private struct RuntimeTestClock: BluetoothAdoptionClock {
    static let value = Date(timeIntervalSince1970: 1_750_000_000.125)

    func now() -> Date { Self.value }

    func sleep(for interval: TimeInterval) async throws {
        // Preserve the writer's real timeout interval. Successful fake writes
        // cancel this child immediately; compressing the timeout to a tiny
        // wall-clock window lets the timeout win before the transport task is
        // scheduled when the full package suite is instrumented.
        if interval >= SerializedGenerationPinnedWriter.writeTimeout {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } else if interval > 0 {
            await Task.yield()
        }
    }

    func nowNanoseconds() -> UInt64 {
        UInt64(Self.value.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    var supportsAutonomousSleep: Bool { false }

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        if nanoseconds > 0 { await Task.yield() }
    }
}

/// A wall-clock/monotonic clock that advances only when a test asks it to.
/// Sub-second sleeps are recorded as pacing evidence and advance logical time;
/// the writer's timeout child retains its real interval so an immediately
/// completed fake write cannot lose a scheduling race under instrumentation.
private final class RuntimeAdvancingClock: BluetoothAdoptionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private var intervals: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        value = start
    }

    func now() -> Date { lock.withLock { value } }

    func sleep(for interval: TimeInterval) async throws {
        lock.withLock {
            intervals.append(interval)
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

    func recordedIntervals() -> [TimeInterval] { lock.withLock { intervals } }
}

private actor RuntimeHistoryStore: BluetoothAdoptionStore, HistoryBatchAcknowledger {
    struct Commit: Equatable, Sendable {
        let recordCount: Int
        let archiveCount: Int
        let boundary: String
        let batchID: String
    }

    private let identifier: UUID?
    private(set) var commits: [Commit] = []
    private(set) var order: [String] = []
    private(set) var records: [StoredHistoricalRecord] = []
    private(set) var archives: [ArchivedHistoricalRecord] = []

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
        self.records.append(contentsOf: records)
        self.archives.append(contentsOf: archived)
        let boundaryName: String
        switch boundary {
        case .tokenized(let token):
            boundaryName = "tokenized"
            commits.append(Commit(
                recordCount: records.count,
                archiveCount: archived.count,
                boundary: boundaryName,
                batchID: diagnostics.batchID
            ))
            order.append("commit")
            return .ackEligible(CommittedHistoryBatch(
                token: token,
                batchID: diagnostics.batchID,
                recordCount: records.count,
                archivedCount: archived.count
            ))
        case .completionTail:
            boundaryName = "tail"
            commits.append(Commit(
                recordCount: records.count,
                archiveCount: archived.count,
                boundary: boundaryName,
                batchID: diagnostics.batchID
            ))
            order.append("commit")
            return .completionTail(CommittedHistoryTail(
                batchID: diagnostics.batchID,
                recordCount: records.count,
                archivedCount: archived.count
            ))
        }
    }

    func markAcknowledged(batchID: String, updatedAt _: Int64) async throws {
        order.append("ack:\(batchID)")
    }

    func recordedCommits() -> [Commit] { commits }
    func recordedOrder() -> [String] { order }
    func recordedRecordCount() -> Int { records.count }
    func recordedArchiveCount() -> Int { archives.count }
}

/// A clock that singles out the band-command timeout so a test can decide
/// whether an exchange gets its answer or its timeout. Every other interval
/// keeps `RuntimeTestClock`'s behaviour.
private final class BandCommandTestClock: BluetoothAdoptionClock, @unchecked Sendable {
    static let value = Date(timeIntervalSince1970: 1_750_000_000.125)

    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func now() -> Date { Self.value }

    func sleep(for interval: TimeInterval) async throws {
        if interval == BluetoothAdoptionRuntime.bandCommandTimeout {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return
        }
        if interval >= SerializedGenerationPinnedWriter.writeTimeout {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } else if interval > 0 {
            await Task.yield()
        }
    }

    func nowNanoseconds() -> UInt64 {
        UInt64(Self.value.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    var supportsAutonomousSleep: Bool { false }

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        if nanoseconds > 0 { await Task.yield() }
    }

    /// Lets every outstanding and future band-command timeout fire.
    func fireBandCommandTimeouts() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

/// Collects the result of a band action started on a detached task.
private actor BandActionProbe<Value: Sendable> {
    private var value: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) { self.value = value }
    func result() -> Result<Value, Error>? { value }
}

private actor BackgroundResultProbe {
    private var value: Bool?

    func finish(_ value: Bool) { self.value = value }
    func result() -> Bool? { value }
}

private func runtimeSetupEvents(for peripheral: UUID) -> [TransportEvent] {
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

private func runtimeFrame(inner: Data) -> Data {
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

private func runtimeHistoryStartFrame() -> Data {
    runtimeFrame(inner: Data([0x31, 0x00, 0x01, 0x00]))
}

private func runtimeHistoryEndFrame(token: Data) -> Data {
    precondition(token.count == HistoryToken.byteCount)
    var inner = Data(repeating: 0, count: 21)
    inner[0] = 0x31
    inner[2] = 0x02
    inner.replaceSubrange(13..<21, with: token)
    return runtimeFrame(inner: inner)
}

private func runtimeHistoryCompleteFrame() -> Data {
    runtimeFrame(inner: Data([0x31, 0x00, 0x03, 0x00]))
}

private func runtimeLiveFrame() -> Data {
    runtimeFrame(inner: Data([0x28, 0x10, 0x20, 0x30]))
}

/// Builds a GET_CLOCK reply in the layout a real WHOOP 4.0 sends. The byte
/// after the packet type is the band's own rolling packet counter; the echo of
/// the sequence we sent is two bytes further on, followed by a status byte.
/// Captured on 2026-09-21: `24 d6 0b 61 01 a952b16a 0046 0000000000`.
private func runtimeCommandResponseInner(
    opcode: UInt8,
    sequenceEcho: UInt8,
    body: [UInt8],
    bandCounter: UInt8 = 0xD6,
    status: UInt8 = 0x01
) -> Data {
    Data([0x24, bandCounter, opcode, sequenceEcho, status] + body)
}

private func runtimeLittleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24)
    ]
}

private func runtimeClockResponseInner(
    sequence: UInt8 = 0xA1,
    timestamp: UInt32 = 1_750_000_000,
    subsecondTicks: UInt16 = 0
) -> Data {
    runtimeCommandResponseInner(
        opcode: 0x0B,
        sequenceEcho: sequence,
        body: runtimeLittleEndian(timestamp) + [
            UInt8(truncatingIfNeeded: subsecondTicks),
            UInt8(truncatingIfNeeded: subsecondTicks >> 8)
        ]
    )
}

private func runtimeClockResponseFrame(
    sequence: UInt8 = 0xA1,
    timestamp: UInt32 = 1_750_000_000
) -> Data {
    runtimeFrame(inner: runtimeClockResponseInner(sequence: sequence, timestamp: timestamp))
}

private func runtimeBandEventFrame(
    eventID: UInt16,
    sequence: UInt8 = 0x01,
    epochSeconds: UInt32 = 1_750_000_000
) -> Data {
    let inner = Data([
        0x30, sequence,
        UInt8(truncatingIfNeeded: eventID),
        UInt8(truncatingIfNeeded: eventID >> 8),
        UInt8(truncatingIfNeeded: epochSeconds),
        UInt8(truncatingIfNeeded: epochSeconds >> 8),
        UInt8(truncatingIfNeeded: epochSeconds >> 16),
        UInt8(truncatingIfNeeded: epochSeconds >> 24),
        0x00, 0x00
    ])
    return runtimeFrame(inner: inner)
}

/// A historical record that names a supported version but is far shorter than
/// its layout, which is the shape the packet decoder rejects.
private func runtimeCorruptFrame() -> Data {
    runtimeFrame(inner: Data([0x2F, 0x07, 0x00, 0x00]))
}

private func runtimeHex(_ value: String) -> Data {
    let bytes = Array(value)
    precondition(bytes.count.isMultiple(of: 2))
    var result = Data(capacity: bytes.count / 2)
    var index = 0
    while index < bytes.count {
        result.append(UInt8(String(bytes[index...index + 1]), radix: 16)!)
        index += 2
    }
    return result
}

private func runtimeInner(_ frame: Data) throws -> [UInt8] {
    Array(try FrameDecoder().decode(frame).paddedInner)
}

private let runtimeHistoricalInner = runtimeHex(
    "2f07000d0c0b0a44332211020100000000000000000000000000003c000000000000000000000000000000000000803f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
)

@discardableResult
private func waitForRuntime(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    // Writer/setup tasks contain multiple actor and task-group hops. A pure
    // yield loop can exhaust itself before those executors run under Xcode's
    // instrumented test process, producing false timeouts while the runtime
    // is still making progress.
    for _ in 0..<2_000 {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

/// Waits for a state transition emitted by the runtime actor instead of
/// repeatedly reading a snapshot.  Tests that send a follow-up event must
/// observe the corresponding state emission so setup and frame processing
/// cannot race the assertion under a fully instrumented package run.
private func waitForRuntimeState(
    _ runtime: BluetoothAdoptionRuntime,
    timeout: TimeInterval = 5,
    matching predicate: @escaping @Sendable (BluetoothAdoptionRuntimeState) -> Bool
) async -> Bool {
    let stream = await runtime.stateStream()
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await state in stream {
                if predicate(state) { return true }
            }
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

private func waitForRuntimeSetup(
    _ runtime: BluetoothAdoptionRuntime,
    timeout: TimeInterval = 5
) async -> Bool {
    await waitForRuntimeState(runtime, timeout: timeout) {
        $0.setupComplete && $0.lastError == nil
    }
}

private actor FailFirstSetupWriteTransport: BLETransport, BLEPeripheralRetriever {
    let base: ScriptedTransport
    private var shouldFail = true

    init(peripheral: UUID) {
        base = ScriptedTransport(events: [], retrievalResult: [peripheral])
    }

    nonisolated func events() -> AsyncStream<TransportEvent> { base.events() }
    func retrieve(_ identifiers: [PeripheralID]) async -> [PeripheralID] { await base.retrieve(identifiers) }
    func connect(_ peripheral: PeripheralID) async { await base.connect(peripheral) }
    func discoverServices(_ ids: [ServiceID]) async { await base.discoverServices(ids) }
    func setNotify(_ char: CharacteristicID, enabled: Bool) async { await base.setNotify(char, enabled: enabled) }
    func disconnect() async { await base.disconnect() }
    func write(_ data: Data, to char: CharacteristicID) async throws {
        if shouldFail {
            shouldFail = false
            throw TransportError.disconnected
        }
        try await base.write(data, to: char)
    }
}

/// Writes throw `.disconnected` while the link is marked down, which is what
/// CoreBluetoothTransport does once the peripheral has dropped. ScriptedTransport
/// accepts every write, so it could never reproduce a teardown on a dead link.
private actor DroppableLinkTransport: BLETransport, BLEPeripheralRetriever {
    let base: ScriptedTransport
    private var linkDown = false

    init(peripheral: UUID) {
        base = ScriptedTransport(events: [], retrievalResult: [peripheral])
    }

    func setLinkDown(_ value: Bool) { linkDown = value }
    func writeCount() -> Int { base.recordedWrites().count }

    nonisolated func events() -> AsyncStream<TransportEvent> { base.events() }
    func retrieve(_ identifiers: [PeripheralID]) async -> [PeripheralID] { await base.retrieve(identifiers) }
    func connect(_ peripheral: PeripheralID) async { await base.connect(peripheral) }
    func discoverServices(_ ids: [ServiceID]) async { await base.discoverServices(ids) }
    func setNotify(_ char: CharacteristicID, enabled: Bool) async { await base.setNotify(char, enabled: enabled) }
    func disconnect() async { await base.disconnect() }
    func write(_ data: Data, to char: CharacteristicID) async throws {
        if linkDown { throw TransportError.disconnected }
        try await base.write(data, to: char)
    }
}

private enum RuntimeFirstWriteFailure: Sendable {
    case timeout
    case insufficientEncryption
}

private actor RuntimeBondFailureTransport: BLETransport, BLEPeripheralRetriever {
    let base: ScriptedTransport
    private let failure: RuntimeFirstWriteFailure
    private var setupWriteAttempts = 0

    init(peripheral: UUID, failure: RuntimeFirstWriteFailure) {
        base = ScriptedTransport(events: [], retrievalResult: [peripheral])
        self.failure = failure
    }

    nonisolated func events() -> AsyncStream<TransportEvent> { base.events() }
    func retrieve(_ identifiers: [PeripheralID]) async -> [PeripheralID] { await base.retrieve(identifiers) }
    func connect(_ peripheral: PeripheralID) async { await base.connect(peripheral) }
    func discoverServices(_ ids: [ServiceID]) async { await base.discoverServices(ids) }
    func setNotify(_ char: CharacteristicID, enabled: Bool) async { await base.setNotify(char, enabled: enabled) }
    func disconnect() async { await base.disconnect() }

    func write(_ data: Data, to char: CharacteristicID) async throws {
        setupWriteAttempts += 1
        switch failure {
        case .timeout:
            try await Task.sleep(nanoseconds: 60_000_000_000)
        case .insufficientEncryption:
            throw TransportError.insufficientEncryption
        }
        try await base.write(data, to: char)
    }

    func recordedSetupWriteAttempts() -> Int { setupWriteAttempts }
}

private struct RuntimeFirstWriteTimeoutClock: BluetoothAdoptionClock {
    func now() -> Date { RuntimeTestClock.value }

    func sleep(for interval: TimeInterval) async throws {
        if interval == SerializedGenerationPinnedWriter.firstSetupWriteTimeout {
            throw SerializedWriterError.timedOut(seconds: Int(interval))
        }
        if interval > 0 { await Task.yield() }
    }

    func nowNanoseconds() -> UInt64 {
        UInt64(RuntimeTestClock.value.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    var supportsAutonomousSleep: Bool { false }

    func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        if nanoseconds > 0 { await Task.yield() }
    }
}

final class BluetoothAdoptionRuntimeTests: XCTestCase {
    func testBackgroundSyncDoesNotRestartTheInitialHistoryTransfer() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = RuntimeAdvancingClock()
        let runtime = BluetoothAdoptionRuntime(transport: transport, store: RuntimeHistoryStore(identifier: peripheral), clock: clock)
        _ = await runtime.start()
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready)
        let completed = await runtime.runBackgroundSync(maxDuration: 1)
        XCTAssertFalse(completed, "An unfinished history transfer must not report a completed sync")
        let requests = try transport.recordedWrites().map { try runtimeInner($0.0)[2] }.filter { $0 == 0x16 }
        XCTAssertEqual(requests.count, 1, "Background sync must join the initial transfer instead of sending another history request")
        await runtime.stop()
    }

    func testScanTimeoutPublishesStateAndRetriesThePairedBand() async throws {
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let clock = RuntimeAdvancingClock()
        let peripheral = UUID()
        let runtime = BluetoothAdoptionRuntime(transport: transport, store: RuntimeHistoryStore(identifier: peripheral), clock: clock)
        guard case .scan(let firstGeneration, _) = await runtime.start() else {
            return XCTFail("Expected fallback scan")
        }
        clock.advance(by: 12)
        let expired = await runtime.expireConnectionWatchdogIfNeeded()
        XCTAssertTrue(expired)
        let retried = await waitForRuntime {
            (await runtime.currentState()).generation.map { $0 > firstGeneration } ?? false
        }
        XCTAssertTrue(retried, "A scan timeout must not leave the application stuck scanning")
        XCTAssertEqual(transport.recordedScans().count, 2)
        _ = await runtime.handle(.discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]))
        for event in runtimeSetupEvents(for: peripheral) { _ = await runtime.handle(event) }
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready)
        let recovered = await runtime.currentState()
        XCTAssertEqual(recovered.radioState, .poweredOn, "A successful reconnect must clear the out-of-range state")
        await runtime.stop()
    }

    func testSetupWriteFailureDoesNotBlockInitializationOnReconnect() async throws {
        let peripheral = UUID()
        let transport = FailFirstSetupWriteTransport(peripheral: peripheral)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        guard case .connect(let generation, _) = await runtime.start() else {
            return XCTFail("Expected saved accessory connection")
        }
        for event in runtimeSetupEvents(for: peripheral) {
            _ = await runtime.handle(event, generation: generation)
        }
        let reconnected = await waitForRuntime {
            let state = await runtime.currentState()
            return (state.generation ?? 0) > generation
        }
        XCTAssertTrue(reconnected)
        let nextGeneration = (await runtime.currentState()).generation
        for event in runtimeSetupEvents(for: peripheral) {
            _ = await runtime.handle(event, generation: nextGeneration)
        }
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready, "A failed setup must not leave the next connection stuck at the notification barrier")
        await runtime.stop()
    }

    func testThreeConsecutiveFirstWriteTimeoutsPauseAutomaticReconnect() async throws {
        let peripheral = UUID()
        let transport = RuntimeBondFailureTransport(peripheral: peripheral, failure: .timeout)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeFirstWriteTimeoutClock()
        )
        guard case .connect(var generation, _) = await runtime.start() else {
            return XCTFail("Expected saved accessory connection")
        }

        for attempt in 1...3 {
            for event in runtimeSetupEvents(for: peripheral) {
                _ = await runtime.handle(event, generation: generation)
            }
            if attempt < 3 {
                let previousGeneration = generation
                let reconnected = await waitForRuntime {
                    (await runtime.currentState()).generation.map { $0 > previousGeneration } ?? false
                }
                XCTAssertTrue(reconnected, "Timeout \(attempt) should schedule the next attempt")
                guard let next = (await runtime.currentState()).generation else {
                    await runtime.stop()
                    return XCTFail("Expected a new generation after timeout \(attempt)")
                }
                generation = next
            }
        }

        let paused = await waitForRuntime {
            let state = await runtime.currentState()
            return state.bondRepairRequired == .firstWriteTimeoutLoop
                && state.autoReconnectPaused
                && state.pendingReconnect == nil
        }
        XCTAssertTrue(paused)
        let timeoutAttempts = await transport.recordedSetupWriteAttempts()
        XCTAssertEqual(timeoutAttempts, 3)
        await runtime.stop()
    }

    func testInsufficientEncryptionPausesReconnectAndSurfacesTypedRepairState() async throws {
        let peripheral = UUID()
        let transport = RuntimeBondFailureTransport(
            peripheral: peripheral,
            failure: .insufficientEncryption
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        guard case .connect(let generation, _) = await runtime.start() else {
            return XCTFail("Expected saved accessory connection")
        }
        for event in runtimeSetupEvents(for: peripheral) {
            _ = await runtime.handle(event, generation: generation)
        }

        let repairRequired = await waitForRuntime {
            let state = await runtime.currentState()
            return state.bondRepairRequired == .insufficientEncryption
                && state.autoReconnectPaused
                && state.pendingReconnect == nil
        }
        XCTAssertTrue(repairRequired)
        let encryptionAttempts = await transport.recordedSetupWriteAttempts()
        XCTAssertEqual(encryptionAttempts, 1)
        await runtime.stop()
    }

    func testBatteryAndNameRepliesReachRuntimeStateWithoutFailingClockExchange() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(transport: transport, store: RuntimeHistoryStore(identifier: peripheral), clock: RuntimeTestClock())
        _ = await runtime.start()
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready)
        // 780 tenths. The body starts after the band counter, opcode,
        // sequence echo and status bytes.
        let battery = runtimeCommandResponseInner(
            opcode: 0x1A,
            sequenceEcho: 0x62,
            body: [0x0C, 3]
        )
        let name = runtimeCommandResponseInner(
            opcode: 0x4C,
            sequenceEcho: 0x63,
            body: [0x01, 0x01, 5] + Array("WHOOP".utf8)
        )
        for response in [battery, name] {
            _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: response)))
        }
        let state = await runtime.currentState()
        XCTAssertEqual(state.batteryPercentage, 78)
        XCTAssertEqual(state.advertisingName, "WHOOP")
        XCTAssertEqual(state.lastPacketAt, RuntimeTestClock.value)
        XCTAssertNil(state.lastError)
        XCTAssertTrue(state.historyOffloadActive)
        await runtime.stop()
    }

    func testUnrelatedCommandRepliesDoNotFailPendingClockExchange() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(transport: transport, store: RuntimeHistoryStore(identifier: peripheral), clock: RuntimeTestClock())
        _ = await runtime.start()
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready)
        let unrelated = [
            runtimeCommandResponseInner(opcode: 0x0A, sequenceEcho: 0xA0, body: []),
            runtimeCommandResponseInner(opcode: 0x16, sequenceEcho: 0x00, body: []),
            runtimeCommandResponseInner(opcode: 0x1A, sequenceEcho: 0x00, body: [80])
        ]
        for response in unrelated {
            _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: response)))
            let state = await runtime.currentState()
            XCTAssertNil(state.lastError)
            XCTAssertTrue(state.setupComplete)
        }
        _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeClockResponseFrame()))
        let finalState = await runtime.currentState()
        XCTAssertNil(finalState.lastError)
        await runtime.stop()
    }

    func testSetupWritesClockThenTheFivePinnedInitializationCommands() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let store = RuntimeHistoryStore(identifier: peripheral)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store,
            clock: RuntimeTestClock()
        )

        let plan = await runtime.start()
        XCTAssertEqual(plan, .connect(generation: 2, peripheral: peripheral))
        await waitForRuntime {
            transport.recordedWrites().count == 7
        }

        let writes = transport.recordedWrites().map(\.0)
        let clock = try ClockCommandSequence(
            wallDate: RuntimeTestClock.value,
            setSequence: 0xA0,
            getSequence: 0xA1
        )
        let expected = [
            clock.setClock,
            clock.getClock,
            try CommandBuilder.hello(),
            try CommandBuilder.advertisingName(),
            try CommandBuilder.dataRange(),
            try CommandBuilder.alarmTime(),
            try CommandBuilder.startHistoricalData()
        ]
        XCTAssertEqual(writes, expected)
        XCTAssertTrue(writes.allSatisfy { (try? FrameDecoder().decode($0).paddedInner[2]) != 0x19 })

        let state = await runtime.currentState()
        XCTAssertTrue(state.setupReady)
        XCTAssertTrue(state.setupComplete)
        XCTAssertEqual(state.connection.generation, 2)
        let setupDiagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(setupDiagnostics.isSafe)
        await runtime.stop()
    }

    func testScopedSessionFenceRejectsStaleCallbacksAndUnscopedInbound() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()

        let current = TransportSessionIdentity(peripheral: peripheral, token: UUID())
        let connectedResult = await runtime.handle(.connectedInSession(current), generation: 2)
        XCTAssertEqual(
            connectedResult,
            .accepted(.discovering(generation: 2, peripheral: peripheral))
        )
        let stale = TransportSessionIdentity(peripheral: peripheral, token: UUID())
        let staleResult = await runtime.handle(
            .valueInSession(stale, characteristic: HarvardBluetoothProfile.data, Data([0xAA])),
            generation: 2
        )
        guard case .rejected(.staleSession) = staleResult else {
            return XCTFail("stale session callback was not rejected: \(staleResult)")
        }
        let unscoped = await runtime.handle(
            .value(HarvardBluetoothProfile.data, Data([0xAA])),
            generation: 2
        )
        guard case .rejected(.staleSession) = unscoped else {
            return XCTFail("unscoped callback weakened the active session fence")
        }
        let staleDiagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(staleDiagnostics.events.contains { $0.kind == .staleConnection })
        await runtime.stop()
    }

    func testClockReadbackCorrelatesAndCorrectionUsesNextLiveSequences() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        let setupComplete = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(setupComplete, "runtime setup did not reach the actor-signaled ready state")
        guard setupComplete else {
            await runtime.stop()
            return
        }

        // Setup state is emitted by the runtime actor before the write task's
        // final hop necessarily registers the initial GET_CLOCK.  Synchronize
        // on that exact command before injecting a response; a write count is
        // not a correlation signal.
        let initialClockGet = await transport.waitForWrite(at: 1)
        let initialClockGetInner = try runtimeInner(initialClockGet)
        XCTAssertEqual(initialClockGetInner[1], 0xA1)
        XCTAssertEqual(initialClockGetInner[2], 0x0B)

        // A response for a different live sequence must not authorize a
        // correction or consume the active GET_CLOCK correlation.
        _ = await runtime.handle(
            .value(
                HarvardBluetoothProfile.response,
                runtimeClockResponseFrame(sequence: 0xA0, timestamp: 1_700_086_400)
            ),
            generation: 2
        )
        XCTAssertEqual(transport.recordedWrites().count, 7)
        let mismatchedState = await runtime.currentState()
        XCTAssertNil(mismatchedState.lastError)
        let mismatchedDiagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(mismatchedDiagnostics.events.contains { $0.kind == .staleConnection })

        // The correlated but badly-drifted readback is corrected with A2/A3;
        // A0/A1 remain reserved for the initial SET_CLOCK/GET_CLOCK pair.
        _ = await runtime.handle(
            .value(
                HarvardBluetoothProfile.response,
                runtimeClockResponseFrame(timestamp: 1_700_086_400)
            ),
            generation: 2
        )
        // Correction writes are issued by a child task after `handle` returns;
        // await both exact registrations before asserting their bytes.
        let correctionSet = try runtimeInner(await transport.waitForWrite(at: 7))
        let correctionGet = try runtimeInner(await transport.waitForWrite(at: 8))
        XCTAssertEqual(correctionSet[1], 0xA2)
        XCTAssertEqual(correctionSet[2], 0x0A)
        XCTAssertEqual(correctionGet[1], 0xA3)
        XCTAssertEqual(correctionGet[2], 0x0B)
        XCTAssertEqual(transport.recordedWrites().count, 9)

        _ = await runtime.handle(
            .value(
                HarvardBluetoothProfile.response,
                runtimeClockResponseFrame(sequence: 0xA3, timestamp: 1_750_008_000)
            ),
            generation: 2
        )
        let correctedState = await runtime.currentState()
        XCTAssertNil(correctedState.lastError)
        let recheckScheduled = await runtime.checkClockRecheck()
        XCTAssertFalse(recheckScheduled)
        await runtime.stop()
    }

    func testLiveHeartRateIsReenabledOnTheSessionAfterALinkDrop() async throws {
        let peripheral = UUID()
        let transport = DroppableLinkTransport(peripheral: peripheral)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        guard case .connect(let generation, _) = await runtime.start() else {
            return XCTFail("Expected saved accessory connection")
        }
        for event in runtimeSetupEvents(for: peripheral) {
            _ = await runtime.handle(event, generation: generation)
        }
        let firstReady = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(firstReady)
        _ = try await runtime.acquireLiveStream(kind: .compactHeartRateRR, consumer: .activeWorkout)
        let writesWithLiveEnabled = await transport.writeCount()

        // The band drops. Teardown then tries its disable writes on a dead link.
        await transport.setLinkDown(true)
        _ = await runtime.handle(.disconnected(peripheral, error: .disconnected), generation: generation)
        let reconnected = await waitForRuntime {
            ((await runtime.currentState()).generation ?? 0) > generation
        }
        XCTAssertTrue(reconnected)
        await transport.setLinkDown(false)

        let nextGeneration = (await runtime.currentState()).generation
        for event in runtimeSetupEvents(for: peripheral) {
            _ = await runtime.handle(event, generation: nextGeneration)
        }
        let secondReady = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(secondReady, "The second session must complete setup")
        let writesAfterSecondSetup = await transport.writeCount()
        XCTAssertGreaterThan(writesAfterSecondSetup, writesWithLiveEnabled)

        _ = try await runtime.acquireLiveStream(kind: .compactHeartRateRR, consumer: .activeWorkout)
        let writesAfterReacquire = await transport.writeCount()
        XCTAssertGreaterThan(
            writesAfterReacquire,
            writesAfterSecondSetup,
            "Re-acquiring live heart rate on a new session must send the enable commands again"
        )
        await runtime.stop()
    }

    func testDisconnectSchedulesOneReconnectAndAllocatesFreshGeneration() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        _ = await runtime.handle(.connected(peripheral), generation: 2)
        _ = await runtime.handle(
            .disconnected(peripheral, error: .disconnected),
            generation: 2
        )

        await waitForRuntime {
            guard let generation = (await runtime.currentState()).generation else { return false }
            return generation >= 4
        }
        let state = await runtime.currentState()
        XCTAssertGreaterThanOrEqual(state.generation ?? 0, 4)
        XCTAssertNil(state.pendingReconnect)
        await runtime.stop()
    }

    func testStopDoesNotIssueDuplicateNativeDisconnects() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        await runtime.stop()
        let firstStopDisconnects = transport.recordedDisconnectCount()
        await runtime.stop()
        XCTAssertEqual(firstStopDisconnects, 1)
        XCTAssertEqual(transport.recordedDisconnectCount(), firstStopDisconnects)
    }

    func testNewGenerationResetsLinkHealthCountersButKeepsRuntimeTruthful() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        let setupReady = await waitForRuntimeState(runtime) {
            $0.generation == 2 && $0.setupReady && $0.setupComplete && $0.lastError == nil
        }
        XCTAssertTrue(setupReady, "runtime setup state was not emitted as ready")
        guard setupReady else {
            await runtime.stop()
            return
        }

        let liveResult = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeLiveFrame()),
            generation: 2
        )
        guard case .accepted = liveResult else {
            await runtime.stop()
            return XCTFail("live frame callback was not accepted: \(liveResult)")
        }
        let liveFrameProcessed = await waitForRuntimeState(runtime) {
            $0.generation == 2 && $0.validFrameCount == 1 && $0.lastError == nil
        }
        XCTAssertTrue(liveFrameProcessed, "runtime did not emit the accepted live frame state")
        let beforeDisconnect = await runtime.currentState()
        XCTAssertEqual(beforeDisconnect.validFrameCount, 1)

        _ = await runtime.handle(
            .disconnected(peripheral, error: .disconnected),
            generation: 2
        )
        let freshGeneration = await waitForRuntime {
            guard let generation = (await runtime.currentState()).generation else { return false }
            return generation >= 4
        }
        XCTAssertTrue(freshGeneration, "runtime did not reach the fresh generation state")
        let afterReconnect = await runtime.currentState()
        XCTAssertEqual(afterReconnect.validFrameCount, 0)
        XCTAssertEqual(afterReconnect.corruptFrameCount, 0)
        XCTAssertEqual(afterReconnect.writeTimeoutCount, 0)
        XCTAssertFalse(afterReconnect.setupComplete)
        await runtime.stop()
    }

    func testHistoryCommitPrecedesTokenAckAndLivePacketsNeverEnterLedger() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let store = RuntimeHistoryStore(identifier: peripheral)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store,
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        let setupReady = await waitForRuntimeSetup(runtime, timeout: 15)
        guard setupReady else {
            let timedOutState = await runtime.currentState()
            XCTFail(
                "runtime setup timed out: state=\(timedOutState), "
                    + "emitted=\(transport.emittedEventCount()), "
                    + "writes=\(transport.recordedWrites().count), "
                    + "disconnects=\(transport.recordedDisconnectCount())"
            )
            await runtime.stop()
            return
        }
        let handle = try await runtime.acquireLiveStream(
            kind: .compactHeartRateRR,
            consumer: .activeWorkout
        )
        let stateBeforeClockResponse = await runtime.currentState()
        XCTAssertTrue(stateBeforeClockResponse.setupComplete)
        XCTAssertEqual(stateBeforeClockResponse.generation, 2)
        XCTAssertNil(stateBeforeClockResponse.lastError)
        XCTAssertEqual(transport.recordedDisconnectCount(), 0)
        XCTAssertTrue(stateBeforeClockResponse.setupReady)
        let clockResult = await runtime.handle(
            .value(HarvardBluetoothProfile.response, runtimeClockResponseFrame()),
            generation: 2
        )
        XCTAssertEqual(clockResult, .accepted(.listening(generation: 2, peripheral: peripheral)))
        let tokenBytes = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        let startResult = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()),
            generation: 2
        )
        XCTAssertEqual(startResult, .accepted(.listening(generation: 2, peripheral: peripheral)))
        let recordResult = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner)),
            generation: 2
        )
        XCTAssertEqual(recordResult, .accepted(.listening(generation: 2, peripheral: peripheral)))
        let endResult = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryEndFrame(token: tokenBytes)),
            generation: 2
        )
        XCTAssertEqual(endResult, .accepted(.listening(generation: 2, peripheral: peripheral)))
        let liveResult = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeLiveFrame()),
            generation: 2
        )
        XCTAssertEqual(liveResult, .accepted(.listening(generation: 2, peripheral: peripheral)))

        let effectsReady = await waitForRuntime {
            let order = await store.recordedOrder()
            let liveSamples = await runtime.bufferedLiveSamples(for: .compactHeartRateRR)
            return order.count == 2 && liveSamples.count == 1 && transport.recordedWrites().count >= 9
        }
        XCTAssertTrue(effectsReady, "history commit, ACK, and live delivery did not all complete")
        guard effectsReady else {
            await handle.release()
            await runtime.stop()
            return
        }

        let commits = await store.recordedCommits()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.boundary, "tokenized")
        let order = await store.recordedOrder()
        let recordCount = await store.recordedRecordCount()
        let archiveCount = await store.recordedArchiveCount()
        XCTAssertEqual(order.count, 2)
        XCTAssertEqual(order.first, "commit")
        XCTAssertTrue(order.last?.hasPrefix("ack:") == true)
        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(archiveCount, 0)
        let liveSamples = await runtime.bufferedLiveSamples(for: .compactHeartRateRR)
        XCTAssertEqual(liveSamples.count, 1)

        let writes = transport.recordedWrites().map(\.0)
        let liveInner = try FrameDecoder().decode(writes[7]).paddedInner
        XCTAssertEqual(liveInner[1], 0xA2)
        XCTAssertEqual(liveInner[2], 0x03)
        let ackInner = try FrameDecoder().decode(try XCTUnwrap(writes.last)).paddedInner
        XCTAssertEqual(ackInner[2], 0x17)
        XCTAssertEqual(Data(ackInner[4..<12]), tokenBytes)
        let historyDiagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(historyDiagnostics.isSafe)
        await handle.release()
        await runtime.stop()
    }

    func testMultiChunkHistoryStaysOpenUntilCompleteAndSuppressesMaintenance() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let store = RuntimeHistoryStore(identifier: peripheral)
        let clock = RuntimeAdvancingClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store,
            clock: clock
        )
        _ = await runtime.start()
        let setupCompleted = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(setupCompleted)

        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner)),
            generation: 2
        )
        let firstToken = Data([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryEndFrame(token: firstToken)),
            generation: 2
        )
        let firstChunkCommitted = await waitForRuntime {
            await store.recordedCommits().count == 1
        }
        XCTAssertTrue(firstChunkCommitted, "first tokenized history chunk was not committed")

        let writesAfterFirstACK = transport.recordedWrites().count
        clock.advance(by: 30)
        let maintenanceDidWork = await runtime.maintenanceTick()
        XCTAssertFalse(maintenanceDidWork)
        XCTAssertEqual(transport.recordedWrites().count, writesAfterFirstACK)

        // Edge does not require another HISTORY_START between tokenized
        // chunks. The next record must enter a fresh open chunk and remain
        // commit/ACK eligible.
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner)),
            generation: 2
        )
        let secondToken = Data([0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28])
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryEndFrame(token: secondToken)),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()),
            generation: 2
        )
        let drainCommitted = await waitForRuntime {
            await store.recordedCommits().count == 3
        }
        XCTAssertTrue(drainCommitted, "multi-chunk history drain did not reach its durable tail commit")

        let commits = await store.recordedCommits()
        XCTAssertEqual(commits.map(\.boundary), ["tokenized", "tokenized", "tail"])
        XCTAssertEqual(commits.map(\.recordCount), [1, 1, 0])
        let recordCount = await store.recordedRecordCount()
        let state = await runtime.currentState()
        XCTAssertEqual(recordCount, 2)
        XCTAssertNil(state.lastError)
        await runtime.stop()
    }

    func testHealthStalenessAndDiagnosticsRemainBounded() async throws {
        let recorder = ConnectionDiagnosticsRecorder(capacity: 3)
        for generation in 1...10 {
            await recorder.record(ConnectionDiagnosticsEvent(
                kind: .validFrame,
                timestamp: RuntimeTestClock.value,
                generation: UInt64(generation)
            ))
        }
        let boundedEvents = await recorder.events()
        XCTAssertEqual(boundedEvents.count, 3)

        let peripheral = UUID()
        let runtime = BluetoothAdoptionRuntime(
            transport: ScriptedTransport(events: [], retrievalResult: [peripheral]),
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock(),
            diagnostics: recorder
        )
        _ = await runtime.start()
        let state = await runtime.currentState()
        XCTAssertFalse(state.health.healthy)
        XCTAssertTrue(state.health.reasons.contains(.noValidFrame))
        let boundedDiagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(boundedDiagnostics.events.count <= 3)
        await runtime.stop()
    }

    func testFirstSessionDiagnosticsCoverEveryMilestoneWithoutRawPayloads() async throws {
        let peripheral = UUID()
        let events: [TransportEvent] = [
            .discoveredWithAdvertisement(
                peripheral,
                advertisedName: "WHOOP 4A0B",
                advertisedServices: []
            ),
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
        let transport = ScriptedTransport(events: events)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: nil),
            clock: RuntimeTestClock()
        )

        _ = await runtime.start()
        let setupCompleted = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(setupCompleted)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.response, runtimeClockResponseFrame())
        )
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()))
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner))
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryEndFrame(token: token))
        )
        for marker in 0..<6 {
            _ = await runtime.handle(
                .value(
                    HarvardBluetoothProfile.data,
                    runtimeFrame(inner: Data([0xFF, UInt8(marker)]))
                )
            )
        }

        let snapshot = await runtime.diagnosticsSnapshot()
        let kinds = Set(snapshot.events.map(\.kind))
        XCTAssertTrue(kinds.contains(.advertisementSeen))
        XCTAssertTrue(kinds.contains(.gattDiscovery))
        XCTAssertEqual(snapshot.events.filter { $0.kind == .notificationSubscription }.count, 3)
        XCTAssertTrue(kinds.contains(.clockSet))
        XCTAssertTrue(kinds.contains(.clockGet))
        XCTAssertEqual(snapshot.events.filter { $0.kind == .initializationWriteResponse }.count, 5)
        XCTAssertTrue(kinds.contains(.historyMetadataReceived))
        XCTAssertTrue(kinds.contains(.historyCommitted))
        XCTAssertTrue(kinds.contains(.acknowledgementEmitted))
        XCTAssertGreaterThanOrEqual(snapshot.events.filter { $0.kind == .error }.count, 6)
        let rawToken = token.map { String(format: "%02X", $0) }.joined()
        XCTAssertFalse(snapshot.events.compactMap(\.detail).joined().contains(rawToken))
        await runtime.stop()
    }

    func testPoweredOnAfterRadioOffRestartsExactlyOneHarvardScan() async throws {
        let transport = ScriptedTransport(events: [])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: nil),
            clock: RuntimeTestClock()
        )

        guard case .scan(let firstGeneration, service: let service) = await runtime.start() else {
            return XCTFail("an unpaired runtime must start one Harvard service scan")
        }
        XCTAssertEqual(service, HarvardBluetoothProfile.service)

        let poweredOff = await runtime.handle(
            .managerState(.poweredOff),
            generation: firstGeneration
        )
        XCTAssertEqual(poweredOff, .accepted(.bluetoothOff))

        let poweredOn = await runtime.handle(
            .managerState(.poweredOn),
            generation: firstGeneration
        )
        XCTAssertEqual(poweredOn, .accepted(.idle))
        XCTAssertEqual(
            transport.recordedScans(),
            [HarvardBluetoothProfile.service, HarvardBluetoothProfile.service]
        )
        let state = await runtime.currentState()
        XCTAssertEqual(state.radioState, .poweredOn)
        if case .scanning = state.connection {
            // Expected: the powered-on edge re-arms exactly one new scan.
        } else {
            XCTFail("powered-on recovery must leave the runtime scanning")
        }
        await runtime.stop()
    }

    func testGATTValidationFailureSchedulesReconnectAfterSessionCleanup() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: RuntimeTestClock()
        )

        guard case .connect(let generation, peripheral: peripheral) = await runtime.start() else {
            return XCTFail("persisted accessory must enter the retrieval/connect path")
        }
        _ = await runtime.handle(.connected(peripheral), generation: generation)
        _ = await runtime.handle(
            .servicesDiscovered(HarvardBluetoothProfile.requiredServices),
            generation: generation
        )
        let invalid = [
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]
        let result = await runtime.handle(
            .characteristicsDiscovered(invalid),
            generation: generation
        )
        guard case .rejected(.gattValidationFailed(.propertyMismatch)) = result else {
            return XCTFail("invalid GATT setup was not rejected: \(result)")
        }

        // A validation failure must tear down the failed session and feed the
        // same reconnect ladder as a native disconnect. Do not stop waiting at
        // the pending-request phase: the scheduler can consume that request
        // between this predicate and the following state read, briefly leaving
        // neither a pending request nor the replacement generation observable.
        // Waiting for the replacement generation proves the terminal behavior
        // and removes that observation race without retrying the test.
        await waitForRuntime {
            let state = await runtime.currentState()
            return (state.generation ?? 0) > generation
        }
        let state = await runtime.currentState()
        XCTAssertGreaterThan(
            state.generation ?? 0,
            generation,
            "GATT failure must start a fresh generation after cleanup"
        )
        XCTAssertEqual(transport.recordedDisconnectCount(), 1)
        await runtime.stop()
    }

    func testActiveBackgroundSyncCompletesOnlyAfterAcknowledgedHistoryCommit() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let store = RuntimeHistoryStore(identifier: peripheral)
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store,
            clock: RuntimeTestClock()
        )
        _ = await runtime.start()
        await waitForRuntime { (await runtime.currentState()).setupComplete }

        let background = Task {
            await runtime.runBackgroundSync(maxDuration: 2)
        }
        // Let the BG owner install its active request before injecting the
        // history boundary. The fixed test clock keeps the request alive until
        // the commit barrier below is observed.
        for _ in 0..<20 { await Task.yield() }

        let token = Data([0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88])
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner)),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryEndFrame(token: token)),
            generation: 2
        )

        let backgroundSucceeded = await background.value
        XCTAssertTrue(backgroundSucceeded)
        let commits = await store.recordedCommits()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.boundary, "tokenized")
        await runtime.stop()
    }

    func testBackgroundSyncDoesNotSucceedForCompletionTailWithoutAcknowledgement() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let store = RuntimeHistoryStore(identifier: peripheral)
        let clock = RuntimeTestClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: store,
            clock: clock
        )
        _ = await runtime.start()
        let setupComplete = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(setupComplete)

        let probe = BackgroundResultProbe()
        let background = Task {
            let result = await runtime.runBackgroundSync(maxDuration: 2)
            await probe.finish(result)
            return result
        }
        for _ in 0..<20 { await Task.yield() }

        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeFrame(inner: runtimeHistoricalInner)),
            generation: 2
        )
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()),
            generation: 2
        )

        let commits = await store.recordedCommits()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.boundary, "tail")
        let order = await store.recordedOrder()
        XCTAssertFalse(order.contains { $0.hasPrefix("ack:") })
        let completedBeforeExpiration = await waitForRuntime { await probe.result() != nil }
        XCTAssertFalse(completedBeforeExpiration, "A durable completion tail has no band ACK and must not complete background sync")
        if !completedBeforeExpiration { _ = await runtime.expireBackground() }
        let backgroundSucceeded = await background.value
        XCTAssertFalse(backgroundSucceeded)
        await runtime.stop()
    }

    func testEdgeLiveOrchestrationUsesExactOrderAndPacingForEveryPolicyTransition() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let clock = RuntimeAdvancingClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        let setupComplete = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(setupComplete, "runtime setup did not reach live-stream safety")
        guard setupComplete else {
            await runtime.stop()
            return
        }
        // Step downs are held while a historical drain runs, so end it.
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()), generation: 2)

        // Foreground uses Edge's complete sequence once a feature actually
        // holds a raw lease. The compact HR lease acquired afterwards changes
        // nothing on the wire because the full set already covers it.
        _ = try await runtime.acquireLiveStream(
            kind: .realtimeRaw,
            consumer: .activeWorkout
        )
        _ = try await runtime.acquireLiveStream(
            kind: .compactHeartRateRR,
            consumer: .activeWorkout
        )
        await runtime.enterBackground()
        await runtime.enterForeground()
        // Leave the lease active so stop() itself must perform the aggregate
        // disable while the generation is still pinned to the writer.
        await runtime.stop()

        let allWrites = transport.recordedWrites()
        XCTAssertTrue(allWrites.allSatisfy { $0.1 == HarvardBluetoothProfile.command })
        let liveWrites = Array(allWrites.dropFirst(7))
        let inners = try liveWrites.map { try runtimeInner($0.0) }
        XCTAssertEqual(
            inners.map { $0[2] },
            [
                0x03, 0x3F, 0x6A, 0x6B, // full foreground enable
                0x03, 0x6C, 0x6B, 0x3F, 0x6A, // ordinary background HR-only
                0x03, 0x3F, 0x6A, 0x6B, // foreground re-arm
                0x6C, 0x6B, 0x3F, 0x6A, 0x03 // full disable, HR last
            ]
        )

        XCTAssertEqual(inners[0][3], 0x01)
        XCTAssertEqual(inners[1][3], 0x01)
        XCTAssertEqual(inners[2][3], 0x01)
        XCTAssertEqual(inners[3][3], 0x01)
        XCTAssertEqual(inners[3][4], 0x01)

        // Background explicitly turns optical mode/data, R10, and IMU off;
        // the HR command remains on and is the only useful background stream.
        XCTAssertEqual(inners[4][3], 0x01)
        XCTAssertEqual(Array(inners[5][3...4]), [0x01, 0x00])
        XCTAssertEqual(Array(inners[6][3...4]), [0x01, 0x00])
        XCTAssertEqual(inners[7][3], 0x00)
        XCTAssertEqual(inners[8][3], 0x00)

        // Every inter-command pause is the Edge value: 100 ms in full mode,
        // and 60 ms for background/disable transitions.
        let pacing = clock.recordedIntervals().filter {
            abs($0 - 0.100) < 0.000_001 || abs($0 - 0.060) < 0.000_001
        }
        XCTAssertEqual(
            pacing.map { Int(($0 * 1_000).rounded()) },
            [100, 100, 100, 60, 60, 60, 60, 100, 100, 100, 60, 60, 60, 60]
        )
    }

    func testEdgeMaintenanceCadenceEmitsLinkBatteryAndHistoryRefreshAt10_30_900() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(
            events: runtimeSetupEvents(for: peripheral),
            retrievalResult: [peripheral]
        )
        let clock = RuntimeAdvancingClock()
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        await waitForRuntime { (await runtime.currentState()).setupComplete }

        func opcodes(after count: Int) throws -> [UInt8] {
            try transport.recordedWrites().dropFirst(count).map { try runtimeInner($0.0)[2] }
        }

        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()), generation: 2)
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()), generation: 2)
        let setupCount = transport.recordedWrites().count
        clock.advance(by: 10)
        let didTenSecondMaintenance = await runtime.maintenanceTick()
        XCTAssertTrue(didTenSecondMaintenance)
        XCTAssertEqual(try opcodes(after: setupCount), [0x01])

        clock.advance(by: 20)
        let didThirtySecondMaintenance = await runtime.maintenanceTick()
        XCTAssertTrue(didThirtySecondMaintenance)
        XCTAssertEqual(
            try opcodes(after: setupCount),
            [0x01, 0x01, 0x1A]
        )

        // Keep the link-freshness fuse alive while crossing the 900-second
        // history cadence. The maintenance request itself must be active
        // transport traffic, not a passive poll of a future callback.
        clock.advance(by: 860)
        _ = await runtime.handle(
            .value(HarvardBluetoothProfile.data, runtimeLiveFrame()),
            generation: 2
        )
        clock.advance(by: 10)
        let didNineHundredSecondMaintenance = await runtime.maintenanceTick()
        XCTAssertTrue(didNineHundredSecondMaintenance)
        XCTAssertEqual(
            try opcodes(after: setupCount),
            [0x01, 0x01, 0x1A, 0x01, 0x1A, 0x22, 0x16]
        )
        await runtime.stop()
    }

    // MARK: - Band actions

    private func bandReadyRuntime(
        peripheral: UUID,
        transport: ScriptedTransport,
        clock: any BluetoothAdoptionClock
    ) async -> BluetoothAdoptionRuntime {
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: clock
        )
        _ = await runtime.start()
        let ready = await waitForRuntimeSetup(runtime)
        XCTAssertTrue(ready)
        return runtime
    }

    /// The sequence the runtime allocated for the write at `index`, so a test
    /// can answer the exact exchange the runtime is waiting on.
    private func writeSequence(
        _ transport: ScriptedTransport,
        at index: Int
    ) throws -> UInt8 {
        try runtimeInner(transport.recordedWrites()[index].0)[1]
    }

    func testBandExchangeResolvesWhenTheMatchingCommandResponseArrives() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = BandCommandTestClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count

        let probe = BandActionProbe<Date?>()
        Task {
            do { await probe.finish(.success(try await runtime.readBandAlarm())) }
            catch { await probe.finish(.failure(error)) }
        }
        // The readback correlates the band clock first so the answer can be
        // shifted back into wall time.
        let wroteClockRequest = await waitForRuntime { transport.recordedWrites().count > setupCount }
        XCTAssertTrue(wroteClockRequest)
        let clockSequence = try writeSequence(transport, at: setupCount)
        XCTAssertEqual(try runtimeInner(transport.recordedWrites()[setupCount].0)[2], 0x0B)
        let clockResponse = runtimeClockResponseInner(
            sequence: clockSequence,
            timestamp: UInt32(BandCommandTestClock.value.timeIntervalSince1970)
        )
        _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: clockResponse)))

        let wroteRequest = await waitForRuntime { transport.recordedWrites().count > setupCount + 1 }
        XCTAssertTrue(wroteRequest)

        let request = try runtimeInner(transport.recordedWrites()[setupCount + 1].0)
        XCTAssertEqual(request[2], 0x43)
        // The band range must not collide with the live allocator's 0xA0...0xFF.
        XCTAssertTrue((0x60...0x7F).contains(request[1]))

        // The bytes a real band sent on 2026-09-21 for an armed alarm, with
        // the band counter and this run's sequence echo substituted in. The
        // sequence we sent comes back at payload offset 2, never offset 0.
        let response = runtimeCommandResponseInner(
            opcode: 0x43,
            sequenceEcho: request[1],
            body: [0x01, 0x01, 0x00]
                + runtimeLittleEndian(1_790_031_600)
                + [0x00, 0x04, 0x00, 0x20],
            bandCounter: 0xE2
        )
        _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: response)))

        let resolved = await waitForRuntime { await probe.result() != nil }
        XCTAssertTrue(resolved)
        switch await probe.result() {
        case .success(let date):
            XCTAssertEqual(
                date?.timeIntervalSince1970 ?? 0,
                TimeInterval(1_790_031_600),
                accuracy: 0.001
            )
        default:
            XCTFail("expected the alarm readback to resolve from the matching response")
        }
        await runtime.stop()
    }

    func testBandExchangeTimesOutOnTheInjectedClock() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = BandCommandTestClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count

        let probe = BandActionProbe<Date?>()
        Task {
            do { await probe.finish(.success(try await runtime.readBandAlarm())) }
            catch { await probe.finish(.failure(error)) }
        }
        let wroteRequest = await waitForRuntime { transport.recordedWrites().count > setupCount }
        XCTAssertTrue(wroteRequest)
        clock.fireBandCommandTimeouts()

        let settled = await waitForRuntime { await probe.result() != nil }
        XCTAssertTrue(settled)
        switch await probe.result() {
        case .failure(let error):
            XCTAssertEqual(error as? BandCommandError, .timedOut)
        default:
            XCTFail("expected the alarm readback to time out")
        }
        await runtime.stop()
    }

    func testBandExchangeFailsWhenTheLinkDropsInsteadOfHangingTheCaller() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = BandCommandTestClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count
        let generation = await runtime.currentState().generation ?? 0

        let probe = BandActionProbe<Date?>()
        Task {
            do { await probe.finish(.success(try await runtime.readBandAlarm())) }
            catch { await probe.finish(.failure(error)) }
        }
        let wroteRequest = await waitForRuntime { transport.recordedWrites().count > setupCount }
        XCTAssertTrue(wroteRequest)

        _ = await runtime.handle(
            .disconnected(peripheral, error: .disconnected),
            generation: generation
        )

        let settled = await waitForRuntime { await probe.result() != nil }
        XCTAssertTrue(settled)
        switch await probe.result() {
        case .failure(let error):
            XCTAssertEqual(error as? BandCommandError, .notReady)
        default:
            XCTFail("expected the pending exchange to fail on disconnect")
        }
        await runtime.stop()
    }

    func testEveryBandActionIsNotReadyBeforeSetupCompletes() async throws {
        let peripheral = UUID()
        // No setup script, so the runtime never reaches setupComplete.
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let runtime = BluetoothAdoptionRuntime(
            transport: transport,
            store: RuntimeHistoryStore(identifier: peripheral),
            clock: BandCommandTestClock()
        )
        _ = await runtime.start()

        let actions: [(String, () async throws -> Void)] = [
            ("rename", { try await runtime.renameBand(to: "Loopr") }),
            ("buzz", { try await runtime.buzzBand(effect: 2) }),
            ("setAlarm", {
                try await runtime.setBandAlarm(
                    fireDate: Date(timeIntervalSince1970: 1_760_000_000)
                )
            }),
            ("readAlarm", { _ = try await runtime.readBandAlarm() }),
            ("testAlarm", { try await runtime.testBandAlarm() }),
            ("disableAlarm", { try await runtime.disableBandAlarm() })
        ]
        for (name, action) in actions {
            do {
                try await action()
                XCTFail("\(name) must report notReady before setup completes")
            } catch {
                XCTAssertEqual(error as? BandCommandError, .notReady, name)
            }
        }

        // An unusable name is reported as such even on a dead link, because
        // the validation runs before the readiness gate.
        do {
            try await runtime.renameBand(to: "")
            XCTFail("expected an invalid name to be rejected")
        } catch {
            XCTAssertEqual(error as? BandCommandError, .invalidName)
        }
        XCTAssertTrue(transport.recordedWrites().isEmpty)
        await runtime.stop()
    }

    func testRenameWritesTheNameThenReReadsTheAdvertisingName() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = BandCommandTestClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count

        let probe = BandActionProbe<Bool>()
        Task {
            do {
                try await runtime.renameBand(to: "Loopr")
                await probe.finish(.success(true))
            } catch {
                await probe.finish(.failure(error))
            }
        }
        let wroteRenameAndReadback = await waitForRuntime { transport.recordedWrites().count >= setupCount + 2 }
        XCTAssertTrue(wroteRenameAndReadback)

        let renameInner = try runtimeInner(transport.recordedWrites()[setupCount].0)
        XCTAssertEqual(renameInner[2], 0x4D)
        XCTAssertEqual(Array(renameInner[3...4]), [0x01, 0x05])
        XCTAssertEqual(Data(renameInner[5..<10]), Data("Loopr".utf8))
        XCTAssertEqual(Array(renameInner[10...13]), [0, 0, 0, 0])

        let readSequence = try writeSequence(transport, at: setupCount + 1)
        let readInner = try runtimeInner(transport.recordedWrites()[setupCount + 1].0)
        XCTAssertEqual(readInner[2], 0x4C)

        let response = runtimeCommandResponseInner(
            opcode: 0x4C,
            sequenceEcho: readSequence,
            body: [0x01, 0x01, 5] + Array("Loopr".utf8)
        )
        _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: response)))

        let settled = await waitForRuntime { await probe.result() != nil }
        XCTAssertTrue(settled)
        let observedName = await runtime.currentState().advertisingName
        XCTAssertEqual(observedName, "Loopr")
        await runtime.stop()
    }

    func testHapticTreatsACompletedWriteAsSuccessAndNeverUsesTheLatchingPattern() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(
            peripheral: peripheral,
            transport: transport,
            clock: BandCommandTestClock()
        )
        let setupCount = transport.recordedWrites().count

        // No command response is injected: 0x4F has none in the reference.
        try await runtime.buzzBand()
        let inner = try runtimeInner(transport.recordedWrites()[setupCount].0)
        XCTAssertEqual(inner[2], 0x4F)
        XCTAssertEqual(inner[3], 2)
        XCTAssertNotEqual(inner[3], 1, "pattern 1 latches until the user taps the band")
        XCTAssertEqual(Array(inner[4...7]), [0, 0, 0, 0])
        await runtime.stop()
    }

    func testSessionCueRejectsOldGenerationBeforeWriting() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: BandCommandTestClock())
        let state = await runtime.currentState()
        let generation = try XCTUnwrap(state.generation)
        let setupCount = transport.recordedWrites().count
        do {
            try await runtime.buzzBand(effect: 0, expectedGeneration: generation + 1)
            XCTFail("A cue from another connection must not write")
        } catch { XCTAssertEqual(error as? BandCommandError, .notReady) }
        XCTAssertEqual(transport.recordedWrites().count, setupCount)
        try await runtime.buzzBand(effect: 0, expectedGeneration: generation)
        let inner = try runtimeInner(transport.recordedWrites()[setupCount].0)
        XCTAssertEqual(inner, [0x23, inner[1], 0x4F, 0, 0, 0, 0, 0])
        await runtime.stop()
    }

    func testSetAlarmSendsTheRichFormShiftedIntoTheBandClockFrame() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = BandCommandTestClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count

        let fireDate = BandCommandTestClock.value.addingTimeInterval(3_600)
        let probe = BandActionProbe<Bool>()
        Task {
            do {
                try await runtime.setBandAlarm(fireDate: fireDate)
                await probe.finish(.success(true))
            } catch {
                await probe.finish(.failure(error))
            }
        }

        // The alarm path correlates the band clock first.
        let wroteClockRequest = await waitForRuntime { transport.recordedWrites().count > setupCount }
        XCTAssertTrue(wroteClockRequest)
        let clockSequence = try writeSequence(transport, at: setupCount)
        XCTAssertEqual(try runtimeInner(transport.recordedWrites()[setupCount].0)[2], 0x0B)

        // The band RTC reads 120 s behind wall time, so drift is +120 and the
        // armed epoch must move back by the same 120 s.
        let bandSeconds = UInt32(BandCommandTestClock.value.timeIntervalSince1970) - 120
        let clockResponse = runtimeClockResponseInner(
            sequence: clockSequence,
            timestamp: bandSeconds
        )
        _ = await runtime.handle(.value(HarvardBluetoothProfile.response, runtimeFrame(inner: clockResponse)))

        // The slot is cleared before it is written; a band already holding an
        // alarm ACKed later writes and never buzzed.
        let wroteAlarm = await waitForRuntime { transport.recordedWrites().count > setupCount + 2 }
        XCTAssertTrue(wroteAlarm)
        let clearInner = try runtimeInner(transport.recordedWrites()[setupCount + 1].0)
        XCTAssertEqual(clearInner[2], 0x45)
        XCTAssertEqual(clearInner[3], 0x01)
        let setInner = try runtimeInner(transport.recordedWrites()[setupCount + 2].0)
        XCTAssertEqual(setInner[2], 0x42)
        XCTAssertEqual(setInner[3], 0x04, "the rich form is the only form that fires")
        XCTAssertEqual(setInner[4], 0x00)
        let armed = UInt32(setInner[5])
            | (UInt32(setInner[6]) << 8)
            | (UInt32(setInner[7]) << 16)
            | (UInt32(setInner[8]) << 24)
        XCTAssertEqual(armed, UInt32(fireDate.timeIntervalSince1970) - 120)
        XCTAssertEqual(Array(setInner[11..<23]), [47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30])
        // The 32-byte frame is the one write that exceeds a default MTU's
        // 20-byte ATT payload; nothing in the writer truncates it.
        XCTAssertEqual(transport.recordedWrites()[setupCount + 2].0.count, 32)

        // The readback that follows is unconfirmed on real firmware, so its
        // timeout must not fail the set.
        clock.fireBandCommandTimeouts()
        let settled = await waitForRuntime { await probe.result() != nil }
        XCTAssertTrue(settled)
        switch await probe.result() {
        case .success: break
        default: XCTFail("an unanswered readback must not fail the alarm set")
        }
        await runtime.stop()
    }

    func testAlarmTestAndDisableUseTheRevisionOneBodies() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(
            peripheral: peripheral,
            transport: transport,
            clock: BandCommandTestClock()
        )
        let setupCount = transport.recordedWrites().count

        try await runtime.testBandAlarm()
        try await runtime.disableBandAlarm()

        let test = try runtimeInner(transport.recordedWrites()[setupCount].0)
        XCTAssertEqual(Array(test[2...3]), [0x44, 0x01])
        let disable = try runtimeInner(transport.recordedWrites()[setupCount + 1].0)
        XCTAssertEqual(Array(disable[2...3]), [0x45, 0x01])
        XCTAssertNotEqual(disable[3], 0x00, "a 0x00 body is ACKed but does not clear the alarm")
        await runtime.stop()
    }

    func testSharingUsesWriteOnlyCommandAndStateEventsReachRuntime() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: BandCommandTestClock())
        let setupCount = transport.recordedWrites().count
        let confirmed = try await runtime.setHeartRateSharing(enabled: true)
        XCTAssertNil(confirmed)
        let sharingInner = try runtimeInner(transport.recordedWrites()[setupCount].0)
        XCTAssertEqual(Array(sharingInner.suffix(2)), [UInt8(14), 1])
        for (id, charging, worn) in [(UInt16(7), Optional(true), Optional<Bool>.none),
                                    (9, true, true), (8, false, true), (10, false, false)] {
            _ = await runtime.handle(.value(HarvardBluetoothProfile.events, runtimeBandEventFrame(eventID: id)))
            let state = await runtime.currentState()
            XCTAssertEqual(state.charging, charging)
            XCTAssertEqual(state.onWrist, worn)
        }
        _ = await runtime.handle(.value(HarvardBluetoothProfile.events, runtimeBandEventFrame(eventID: 56)))
        let state = await runtime.currentState()
        XCTAssertEqual(state.charging, false)
        XCTAssertEqual(state.onWrist, false)
        await runtime.stop()
        let stopped = await runtime.currentState()
        XCTAssertNil(stopped.charging)
        XCTAssertNil(stopped.onWrist)
    }

    func testBandEventsDeliverDoubleTapToEverySubscriber() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(
            peripheral: peripheral,
            transport: transport,
            clock: BandCommandTestClock()
        )
        let generation = await runtime.currentState().generation ?? 0

        let first = await runtime.bandEvents()
        let second = await runtime.bandEvents()

        _ = await runtime.handle(.value(
            HarvardBluetoothProfile.events,
            runtimeBandEventFrame(eventID: 14, epochSeconds: 1_750_000_123)
        ))
        _ = await runtime.handle(.value(
            HarvardBluetoothProfile.events,
            runtimeBandEventFrame(eventID: 56)
        ))

        for stream in [first, second] {
            var iterator = stream.makeAsyncIterator()
            let doubleTap = await iterator.next()
            XCTAssertEqual(doubleTap?.eventID, 14)
            XCTAssertEqual(doubleTap?.generation, generation)
            XCTAssertEqual(doubleTap?.receivedAt, BandCommandTestClock.value)
            XCTAssertEqual(doubleTap?.bandEpochSeconds, 1_750_000_123)
            let latched = await iterator.next()
            XCTAssertEqual(latched?.eventID, 56)
        }

        // Event bytes never reach diagnostics.
        let snapshot = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(snapshot.isSafe)
        await runtime.stop()
    }

    func testForegroundCompactHeartRateLeaseNeverArmsTheRawAndIMUFlood() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let runtime = await bandReadyRuntime(
            peripheral: peripheral,
            transport: transport,
            clock: RuntimeAdvancingClock()
        )
        let setupCount = transport.recordedWrites().count

        _ = try await runtime.acquireLiveStream(
            kind: .compactHeartRateRR,
            consumer: .activeWorkout
        )
        let wroteLiveCommands = await waitForRuntime { transport.recordedWrites().count > setupCount }
        XCTAssertTrue(wroteLiveCommands)

        let inners = try transport.recordedWrites().dropFirst(setupCount).map { try runtimeInner($0.0) }
        // Only heart rate is armed. On a fresh link nothing else is on, and
        // on a real WHOOP 4.0 the four "off" toggles stopped the historical
        // drain that INIT had just started, so no wear data ever arrived.
        XCTAssertEqual(inners.map { $0[2] }, [0x03])
        XCTAssertEqual(inners[0][3], 0x01)
        await runtime.stop()
    }

    func testCorruptionLatchesDegradedLiveModeUntilAnExplicitRestart() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = RuntimeAdvancingClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)
        let setupCount = transport.recordedWrites().count

        _ = try await runtime.acquireLiveStream(kind: .realtimeRaw, consumer: .activeWorkout)
        let armedFullMode = await waitForRuntime { transport.recordedWrites().count >= setupCount + 4 }
        XCTAssertTrue(armedFullMode)
        let fullMode = try transport.recordedWrites()
            .dropFirst(setupCount)
            .map { try runtimeInner($0.0) }
        XCTAssertEqual(fullMode.map { $0[2] }, [0x03, 0x3F, 0x6A, 0x6B])
        XCTAssertEqual(fullMode[1][3], 0x01)
        // The step down is held while a historical drain runs, so end it.
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()), generation: 2)
        let beforeCorruption = transport.recordedWrites().count

        // The detector needs twenty samples before it can exceed a 20 percent
        // corruption rate.
        for _ in 0..<20 {
            _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeCorruptFrame()))
        }
        let reconciled = await waitForRuntime { transport.recordedWrites().count > beforeCorruption }
        XCTAssertTrue(reconciled)
        let corruptCount = await runtime.currentState().corruptFrameCount
        XCTAssertGreaterThan(corruptCount, 0)

        let afterCorruption = try transport.recordedWrites()
            .dropFirst(beforeCorruption)
            .map { try runtimeInner($0.0) }
        XCTAssertEqual(afterCorruption.map { $0[2] }, [0x03, 0x6C, 0x6B, 0x3F, 0x6A])
        XCTAssertEqual(afterCorruption[3][3], 0x00)

        // The latch survives a lease change: the raw stream is never re-armed
        // on this session, and the 30 s rearm does not re-assert it either.
        let beforeRearm = transport.recordedWrites().count
        clock.advance(by: 60)
        _ = await runtime.maintenanceTick()
        let rearm = try transport.recordedWrites()
            .dropFirst(beforeRearm)
            .map { try runtimeInner($0.0) }
        XCTAssertFalse(
            rearm.contains { $0[2] == 0x3F && $0[3] == 0x01 },
            "a degraded link must never re-assert the raw stream"
        )
        await runtime.stop()
    }

    func testStalledOffloadAbortsTheTransferBeforeClearingTheFlag() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = RuntimeAdvancingClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)

        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()), generation: 2)
        let offloadActive = await runtime.currentState().historyOffloadActive
        XCTAssertTrue(offloadActive)
        let beforeTick = transport.recordedWrites().count

        // Push past the stalled-offload window while the link stays fresh.
        clock.advance(by: 90)
        _ = await runtime.maintenanceTick()

        let opcodes = try transport.recordedWrites()
            .dropFirst(beforeTick)
            .map { try runtimeInner($0.0)[2] }
        XCTAssertEqual(opcodes.first, 0x14, "a stalled offload is aborted, not just forgotten")
        let offloadCleared = await runtime.currentState().historyOffloadActive
        XCTAssertFalse(offloadCleared)
        await runtime.stop()
    }

    func testHistoryRefreshStampsItsOwnCadenceSoAManualSyncIsNotDoubled() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: runtimeSetupEvents(for: peripheral), retrievalResult: [peripheral])
        let clock = RuntimeAdvancingClock()
        let runtime = await bandReadyRuntime(peripheral: peripheral, transport: transport, clock: clock)

        // Close the setup-time offload so the cadence check is the only gate.
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryStartFrame()), generation: 2)
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()), generation: 2)
        let afterSetup = transport.recordedWrites().count

        // One second after a manual sync the maintenance boundary must not
        // send a second SEND_HISTORICAL_DATA.
        _ = await runtime.runBackgroundSync(maxDuration: 0.01)
        let afterManualSync = transport.recordedWrites().count
        XCTAssertGreaterThan(afterManualSync, afterSetup)
        _ = await runtime.handle(.value(HarvardBluetoothProfile.data, runtimeHistoryCompleteFrame()), generation: 2)

        clock.advance(by: 30)
        _ = await runtime.maintenanceTick()
        let opcodes = try transport.recordedWrites()
            .dropFirst(afterManualSync)
            .map { try runtimeInner($0.0)[2] }
        XCTAssertFalse(opcodes.contains(0x16), "the 900 s history cadence was stamped by the manual sync")
        await runtime.stop()
    }
}
