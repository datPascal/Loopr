import BluetoothKit
import Foundation
import ProtocolKit
import StorageKit
import SyncKit
import XCTest

private struct ImmediateSyncClock: BLEClock {
    let value = Date(timeIntervalSince1970: 1_750_000_000)
    func now() -> Date { value }
    func sleep(for _: TimeInterval) async throws {}
}

private actor SleepIntervalRecorder {
    private var values: [TimeInterval] = []

    func append(_ value: TimeInterval) { values.append(value) }
    func recorded() -> [TimeInterval] { values }
}

private struct PacingSyncClock: BLEClock {
    let value: Date
    let recorder: SleepIntervalRecorder

    func now() -> Date { value }

    func sleep(for interval: TimeInterval) async throws {
        await recorder.append(interval)
    }
}

private final class AdvancingSyncClock: BLEClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(value: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        self.value = value
    }

    func now() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }

    func sleep(for _: TimeInterval) async throws {}
}

private actor ShadowArchiveRecorder: ShadowArchiveSink {
    private(set) var values: [(Data, ShadowPacketClass)] = []

    func archive(frame: Data, packetClass: ShadowPacketClass) async throws {
        values.append((Data(frame), packetClass))
    }

    func recorded() -> [(Data, ShadowPacketClass)] { values }
}

private actor SyncTransportSpy: CommandWriteTransport {
    private(set) var writes: [Data] = []
    private(set) var disconnectCount = 0
    private(set) var attemptCount = 0
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) { self.failuresRemaining = failuresRemaining }

    func writeCommand(_ data: Data) async throws {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw SyncTestError.transport
        }
        writes.append(Data(data))
    }

    func disconnect() async { disconnectCount += 1 }
    func recordedWrites() -> [Data] { writes }
    func recordedAttemptCount() -> Int { attemptCount }
}

private actor FakeHistoryStore: HistoryBatchStore, HistoryBatchAcknowledger {
    struct Call: Equatable, Sendable {
        let records: Int
        let archived: Int
        let boundary: String
        let batchID: String
    }

    private(set) var calls: [Call] = []
    private(set) var acknowledged: [String] = []
    private var canonicalTimestamps: Set<Int64> = []
    var failCommits = false
    var returnTailForTokenized = false

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        if failCommits { throw SyncTestError.commit }
        canonicalTimestamps.formUnion(records.map(\.physiologicalTimestamp))
        let boundaryName: String
        switch boundary {
        case .tokenized: boundaryName = "tokenized"
        case .completionTail: boundaryName = "tail"
        }
        calls.append(Call(
            records: records.count,
            archived: archived.count,
            boundary: boundaryName,
            batchID: diagnostics.batchID
        ))
        switch boundary {
        case .tokenized(let token):
            if returnTailForTokenized {
                return .completionTail(CommittedHistoryTail(
                    batchID: diagnostics.batchID,
                    recordCount: records.count,
                    archivedCount: archived.count
                ))
            }
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
        acknowledged.append(batchID)
    }

    func recordedCalls() -> [Call] { calls }
    func recordedAcknowledgements() -> [String] { acknowledged }
    func canonicalTimestampCount() -> Int { canonicalTimestamps.count }
}

private actor CommitGate {
    private var hasEntered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<5_000 {
            if hasEntered { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return hasEntered
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }
}

private actor SuspendingHistoryStore: HistoryBatchStore, HistoryBatchAcknowledger {
    private let gate: CommitGate
    private(set) var commitCount = 0
    private(set) var acknowledged: [String] = []

    init(gate: CommitGate) { self.gate = gate }

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        commitCount += 1
        await gate.wait()
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
        acknowledged.append(batchID)
    }
}

private enum SyncTestError: Error {
    case commit
    case transport
}

private func testRecord(timestamp: Int64 = 1_750_000_000) -> StoredHistoricalRecord {
    StoredHistoricalRecord(
        physiologicalTimestamp: timestamp,
        bandCounter: 4,
        absoluteTimestamp: timestamp,
        localDay: "2026-08-17",
        version: 12,
        heartRate: 78,
        rawPayload: Data([0x2F, 0x0C, 0x04])
    )
}

private func testArchive() -> ArchivedHistoricalRecord {
    ArchivedHistoricalRecord(
        rawPayload: Data([0x2F, 0xFE, 0xCA, 0xFE]),
        packetType: 0x2F,
        version: 0xFE,
        bandCounter: 9,
        physiologicalTimestamp: 1_750_000_001,
        capturedAt: 1_750_000_000,
        reason: "unsupported test version"
    )
}

private func testToken() throws -> HistoryToken {
    try HistoryToken(bytes: [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44])
}

private func testData(hex: String) -> Data {
    let characters = Array(hex)
    precondition(characters.count.isMultiple(of: 2))
    var result = Data(capacity: characters.count / 2)
    var index = 0
    while index < characters.count {
        result.append(UInt8(String(characters[index...index + 1]), radix: 16)!)
        index += 2
    }
    return result
}

private func makeTestFrame(inner: Data) -> Data {
    var padded = Data(inner)
    let remainder = padded.count % 4
    if remainder != 0 {
        padded.append(contentsOf: repeatElement(UInt8(0), count: 4 - remainder))
    }
    let declaredLength = UInt16(padded.count + 4)
    let lengthBytes = Data([
        UInt8(truncatingIfNeeded: declaredLength),
        UInt8(truncatingIfNeeded: declaredLength >> 8)
    ])
    var frame = Data([0xAA, lengthBytes[0], lengthBytes[1], CRC8.calculate(lengthBytes)])
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

private let syntheticHistoricalInner = testData(
    hex: "2f07000d0c0b0a44332211020100000000000000000000000000003c000000000000000000000000000000000000803f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
)

final class InitializationShadowModeTests: XCTestCase {
    func testInitializationIsBlockedUntilAllThreeInboundSubscriptionsConfirm() async throws {
        let transport = SyncTransportSpy()
        let session = InitializationShadowSession(
            transport: transport,
            clock: ImmediateSyncClock()
        )

        await session.confirmSubscription(.response)
        await session.confirmSubscription(.events)
        do {
            _ = try await session.start(generation: 1)
            XCTFail("initialization must wait for data subscription")
        } catch let error as ShadowInitializationError {
            XCTAssertEqual(error, .subscriptionsIncomplete(missing: [.data]))
        }

        await session.confirmSubscription(.data)
        let result = try await session.start(generation: 1)
        XCTAssertEqual(result.commands.count, 5)
        XCTAssertEqual(
            result.commands.compactMap { try? FrameDecoder().decode($0).paddedInner[1] },
            [0, 1, 2, 3, 4]
        )
        let initWrites = await transport.recordedWrites()
        XCTAssertEqual(initWrites.count, 5)
        XCTAssertTrue(initWrites.allSatisfy { frame in
            (try? FrameDecoder().decode(frame).paddedInner[2]) != 0x17
        })
    }

    func testFiveInitializationCommandsMatchFixturesAnd120MillisecondPacing() async throws {
        let transport = SyncTransportSpy()
        let recorder = SleepIntervalRecorder()
        let session = InitializationShadowSession(
            transport: transport,
            clock: PacingSyncClock(
                value: Date(timeIntervalSince1970: 1_750_000_000),
                recorder: recorder
            )
        )
        for characteristic in ShadowInboundCharacteristic.allCases {
            await session.confirmSubscription(characteristic)
        }

        let result = try await session.start(generation: 7)
        let expected = [
            testData(hex: "aa0800a823002300ada86a2d"),
            testData(hex: "aa0800a823014c00f2b5cdce"),
            testData(hex: "aa0800a823022200824df537"),
            testData(hex: "aa0800a823034301c54dd63d"),
            testData(hex: "aa0800a823041600c7c25288")
        ]
        XCTAssertEqual(result.commands, expected)
        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes, expected)
        let intervals = await recorder.recorded()
        XCTAssertEqual(
            intervals,
            [0.120, 0.120, 0.120, 0.120]
        )
    }

    func testShadowReplayOrdersMixedCharacteristicsArchivesExactTokenAndNeverACKs() async throws {
        let transport = SyncTransportSpy()
        let archive = ShadowArchiveRecorder()
        let session = InitializationShadowSession(
            transport: transport,
            clock: ImmediateSyncClock(),
            archive: archive
        )
        for characteristic in ShadowInboundCharacteristic.allCases {
            await session.confirmSubscription(characteristic)
        }
        _ = try await session.start(generation: 1)

        let historyStart = makeTestFrame(inner: Data([0x31, 0x00, 0x01, 0x00]))
        let historicalRecord = makeTestFrame(inner: syntheticHistoricalInner)
        let historyEnd = testData(
            hex: "aa1c00ab3100020000000000002a0000001122334455667788000000f2d42730"
        )
        let historyComplete = makeTestFrame(inner: Data([0x31, 0x00, 0x03, 0x00]))

        let startClass = try await session.receive(historyStart, characteristic: .response)
        let recordClass = try await session.receive(historicalRecord, characteristic: .events)
        let endClass = try await session.receive(historyEnd, characteristic: .data)
        let completeClass = try await session.receive(historyComplete, characteristic: .response)
        XCTAssertEqual(startClass, .historyStart)
        XCTAssertEqual(recordClass, .historicalRecord)
        XCTAssertEqual(endClass, .historyEnd)
        XCTAssertEqual(completeClass, .historyComplete)

        let queue = await session.orderedQueue.drain()
        XCTAssertEqual(queue.map(\.packetClass), [.historyStart, .historicalRecord, .historyEnd, .historyComplete])
        XCTAssertEqual(queue.map(\.characteristic), [.response, .events, .data, .response])
        XCTAssertEqual(queue.map(\.sequence), [0, 1, 2, 3])

        let tokens = await session.capturedHistoryEndTokens()
        XCTAssertEqual(tokens.map(\.persistedBytes), [testData(hex: "1122334455667788")])
        let archived = await archive.recorded()
        XCTAssertEqual(
            archived.map { $0.1 },
            [.historyStart, .historicalRecord, .historyEnd, .historyComplete]
        )

        // Shadow mode emits only the five initialization commands.  In
        // particular, no history ACK (opcode 0x17) can be produced here.
        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes.count, 5)
        XCTAssertTrue(writes.allSatisfy { frame in
            (try? FrameDecoder().decode(frame).paddedInner[2]) != 0x17
        })
    }

    func testShadowSessionDisconnectsWhenConfiguredDurationBoundIsReached() async throws {
        let transport = SyncTransportSpy()
        let clock = AdvancingSyncClock()
        let session = InitializationShadowSession(
            transport: transport,
            clock: clock,
            maxDuration: 1
        )
        for characteristic in ShadowInboundCharacteristic.allCases {
            await session.confirmSubscription(characteristic)
        }
        _ = try await session.start(generation: 1)
        clock.advance(by: 1)

        do {
            _ = try await session.receive(
                try CommandBuilder.hello(sequence: 0),
                characteristic: .response
            )
            XCTFail("duration-bound session must stop before processing late traffic")
        } catch let error as ShadowInitializationError {
            XCTAssertEqual(error, .sessionBoundReached)
        }
        let disconnectCount = await transport.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }
}

@available(*, deprecated, message: "Exercises the legacy explicit-sequence compatibility boundary.")
final class HistoryCoordinatorTests: XCTestCase {
    func testHappyPathCommitsBeforeExactTokenACKAndMarksLedgerAfterWrite() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(
            store: store,
            transport: transport,
            clock: ImmediateSyncClock()
        )
        try await coordinator.beginBurst(generation: 1, batchID: "batch-1", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)
        let token = try testToken()
        let outcome = await coordinator.receiveHistoryEnd(token: token, sequence: 5, generation: 1)

        guard case .acknowledged(let attempts, let bytes) = outcome else {
            return XCTFail("expected durable ACK, got \(outcome)")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(bytes, try CommandBuilder.historyAcknowledgement(sequence: 5, token: token))
        let calls = await store.recordedCalls()
        let acknowledgements = await store.recordedAcknowledgements()
        let writes = await transport.recordedWrites()
        XCTAssertEqual(calls.map(\.boundary), ["tokenized"])
        XCTAssertEqual(acknowledgements, ["batch-1"])
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first, bytes)
    }

    func testCommitFailureRequeuesSnapshotDisconnectsAndNeverACKs() async throws {
        let store = FakeHistoryStore()
        await store.setFailCommits(true)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "failed", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(
            token: try testToken(),
            sequence: 5,
            generation: 1
        )
        guard case .rejected(.commitFailed) = outcome else {
            return XCTFail("commit failure must block ACK, got \(outcome)")
        }
        let pendingReplay = await coordinator.pendingReplayCount()
        let writes = await transport.recordedWrites()
        let disconnectCount = await transport.disconnectCount
        XCTAssertEqual(pendingReplay, 1)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testACKWriteRetriesAtMostThreeTimesAtThePinnedDelaysThenDisconnects() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy(failuresRemaining: 3)
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "ack-fails", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(
            token: try testToken(),
            sequence: 5,
            generation: 1
        )
        XCTAssertEqual(outcome, .ackExhausted)
        let writes = await transport.recordedWrites()
        let disconnectCount = await transport.disconnectCount
        let acknowledgements = await store.recordedAcknowledgements()
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(acknowledgements, [])
    }

    func testHistoryCompleteCommitsTailWithoutProducingAnACK() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "tail", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let tailOutcome = await coordinator.receiveHistoryComplete(generation: 1)
        XCTAssertEqual(tailOutcome, .completionTailCommitted)
        let writes = await transport.recordedWrites()
        let calls = await store.recordedCalls()
        let acknowledgements = await store.recordedAcknowledgements()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(calls.map(\.boundary), ["tail"])
        XCTAssertEqual(acknowledgements, [])
    }

    func testLateHistoryEndAfterDiscardIsRejectedWithoutACK() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "discarded", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)
        try await coordinator.discardBurst(generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(
            token: try testToken(),
            sequence: 5,
            generation: 1
        )
        XCTAssertEqual(outcome, .rejected(.burstDiscarded))
        let writes = await transport.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testStaleGenerationAfterDurableCommitKeepsDataButSuppressesACK() async throws {
        let gate = CommitGate()
        let store = SuspendingHistoryStore(gate: gate)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "stale", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let token = try testToken()
        let endTask = Task {
            await coordinator.receiveHistoryEnd(
                token: token,
                sequence: 5,
                generation: 1
            )
        }

        let commitEntered = await gate.waitUntilEntered()
        XCTAssertTrue(commitEntered, "commit must suspend before session replacement")
        try await coordinator.replaceGeneration(2)

        await gate.release()
        let result = await endTask.value
        XCTAssertEqual(result, .committedWithoutAck)
        let commitCount = await store.commitCount
        let acknowledgements = await store.acknowledged
        let writes = await transport.recordedWrites()
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(acknowledgements, [])
        XCTAssertTrue(writes.isEmpty)
    }
}

/// Each test below names one destructive boundary from Gate F.  The fake
/// store/transport are actor-isolated proxies for process death, radio loss,
/// and replay; every assertion keeps the no-ACK-without-durable-commit rule
/// visible at the test boundary.
@available(*, deprecated, message: "Exercises the legacy explicit-sequence compatibility boundary.")
final class AckBoundaryChaosTests: XCTestCase {
    func testBoundary01ProcessDeathBeforeTransactionStartRequeuesAndReconnects() async throws {
        let store = FakeHistoryStore()
        await store.setFailCommits(true)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "kill-before-start", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(token: try testToken(), sequence: 5, generation: 1)
        guard case .rejected(.commitFailed) = outcome else {
            return XCTFail("pre-transaction process death must fail closed")
        }
        let pending = await coordinator.pendingReplayCount()
        let writes = await transport.recordedWrites()
        let disconnectCount = await transport.disconnectCount
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testBoundary02ProcessDeathDuringTransactionCancelsWithoutACK() async throws {
        let gate = CommitGate()
        let store = SuspendingHistoryStore(gate: gate)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "kill-during", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let task = Task {
            await coordinator.receiveHistoryEnd(token: try! testToken(), sequence: 5, generation: 1)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        task.cancel()
        await gate.release()
        let result = await task.value
        let writes = await transport.recordedWrites()
        XCTAssertEqual(result, .committedWithoutAck)
        XCTAssertTrue(writes.isEmpty)
    }

    func testBoundary03InjectedCommitFailureNeverACKs() async throws {
        let store = FakeHistoryStore()
        await store.setFailCommits(true)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "injected-commit", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(token: try testToken(), sequence: 5, generation: 1)
        guard case .rejected(.commitFailed) = outcome else {
            return XCTFail("injected commit failure must not authorize ACK")
        }
        let writes = await transport.recordedWrites()
        let attempts = await transport.recordedAttemptCount()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(attempts, 0)
    }

    func testBoundary04ProcessDeathAfterCommitBeforeACKSuppressesExactACK() async throws {
        let gate = CommitGate()
        let store = SuspendingHistoryStore(gate: gate)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "kill-after-commit", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let task = Task {
            await coordinator.receiveHistoryEnd(token: try! testToken(), sequence: 5, generation: 1)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        try await coordinator.replaceGeneration(2)
        await gate.release()
        let result = await task.value
        let commitCount = await store.commitCount
        let writes = await transport.recordedWrites()
        XCTAssertEqual(result, .committedWithoutAck)
        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(writes.isEmpty)
    }

    func testBoundary05DisconnectDuringCommitSuppressesACK() async throws {
        let gate = CommitGate()
        let store = SuspendingHistoryStore(gate: gate)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "disconnect-during", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let task = Task {
            await coordinator.receiveHistoryEnd(token: try! testToken(), sequence: 5, generation: 1)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        await transport.disconnect()
        try await coordinator.replaceGeneration(2)
        await gate.release()
        let result = await task.value
        let disconnectCount = await transport.disconnectCount
        let writes = await transport.recordedWrites()
        XCTAssertEqual(result, .committedWithoutAck)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertTrue(writes.isEmpty)
    }

    func testBoundary06SessionReplacementWhileCommitSuspendedNeverACKsOldGeneration() async throws {
        let gate = CommitGate()
        let store = SuspendingHistoryStore(gate: gate)
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 10, batchID: "replace-suspended", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 10)

        let task = Task {
            await coordinator.receiveHistoryEnd(token: try! testToken(), sequence: 5, generation: 10)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        try await coordinator.replaceGeneration(11)
        await gate.release()
        let result = await task.value
        let commitCount = await store.commitCount
        let writes = await transport.recordedWrites()
        XCTAssertEqual(result, .committedWithoutAck)
        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(writes.isEmpty)
    }

    func testBoundary07ACKTimeoutRetriesExactlyThreeAttemptsThenDisconnects() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy(failuresRemaining: 3)
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "ack-timeout", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(token: try testToken(), sequence: 5, generation: 1)
        let attempts = await transport.recordedAttemptCount()
        let disconnectCount = await transport.disconnectCount
        let writes = await transport.recordedWrites()
        XCTAssertEqual(outcome, .ackExhausted)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertTrue(writes.isEmpty)
    }

    func testBoundary08DuplicateChunkAfterReconnectConvergesWithoutDuplicateCanonicalRows() async throws {
        let store = FakeHistoryStore()
        let firstTransport = SyncTransportSpy(failuresRemaining: 3)
        let first = HistoryCoordinator(store: store, transport: firstTransport, clock: ImmediateSyncClock())
        let token = try testToken()
        try await first.beginBurst(generation: 1, batchID: "redelivered", receivedAt: 10)
        try await first.receive(record: testRecord(), generation: 1)
        let firstOutcome = await first.receiveHistoryEnd(token: token, sequence: 5, generation: 1)
        XCTAssertEqual(firstOutcome, .ackExhausted)

        let secondTransport = SyncTransportSpy()
        let second = HistoryCoordinator(store: store, transport: secondTransport, clock: ImmediateSyncClock())
        try await second.beginBurst(generation: 2, batchID: "redelivered", receivedAt: 20)
        try await second.receive(record: testRecord(), generation: 2)
        let outcome = await second.receiveHistoryEnd(token: token, sequence: 5, generation: 2)
        guard case .acknowledged(let attempts, let bytes) = outcome else {
            return XCTFail("redelivered chunk must converge to one durable ACK")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(bytes, try CommandBuilder.historyAcknowledgement(sequence: 5, token: token))
        let canonicalCount = await store.canonicalTimestampCount()
        let secondWrites = await secondTransport.recordedWrites()
        XCTAssertEqual(canonicalCount, 1)
        XCTAssertEqual(secondWrites, [bytes])
    }

    func testBoundary09UnsupportedRecordIsArchivedInSameTransactionBeforeACK() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        let token = try testToken()
        try await coordinator.beginBurst(generation: 1, batchID: "unsupported", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)
        try await coordinator.receive(archived: testArchive(), generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(token: token, sequence: 5, generation: 1)
        guard case .acknowledged(_, let bytes) = outcome else {
            return XCTFail("unsupported data must not block the tokenized ACK")
        }
        let calls = await store.recordedCalls()
        let writes = await transport.recordedWrites()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.archived, 1)
        XCTAssertEqual(writes, [bytes])
    }

    func testBoundary10LateHistoryEndAfterBurstDiscardIsRejected() async throws {
        let store = FakeHistoryStore()
        let transport = SyncTransportSpy()
        let coordinator = HistoryCoordinator(store: store, transport: transport, clock: ImmediateSyncClock())
        try await coordinator.beginBurst(generation: 1, batchID: "late-end", receivedAt: 10)
        try await coordinator.receive(record: testRecord(), generation: 1)
        try await coordinator.discardBurst(generation: 1)

        let outcome = await coordinator.receiveHistoryEnd(token: try testToken(), sequence: 5, generation: 1)
        let writes = await transport.recordedWrites()
        XCTAssertEqual(outcome, .rejected(.burstDiscarded))
        XCTAssertTrue(writes.isEmpty)
    }
}

private extension FakeHistoryStore {
    func setFailCommits(_ value: Bool) { failCommits = value }
}
