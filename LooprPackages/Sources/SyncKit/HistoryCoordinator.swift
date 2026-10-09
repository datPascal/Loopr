import Foundation
import BluetoothKit
import ProtocolKit
import StorageKit

public enum HistoryCoordinatorError: Error, Equatable, Sendable, LocalizedError {
    case noOpenBurst
    case staleGeneration(expected: UInt64, actual: UInt64?)
    case burstDiscarded
    case duplicateTerminal
    case commitFailed(String)
    case ackFailed(String)
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .noOpenBurst: return "history event arrived without an open burst"
        case .staleGeneration(let expected, let actual):
            return "history event generation \(expected) is stale (current \(actual.map(String.init) ?? "none"))"
        case .burstDiscarded: return "history burst was discarded; terminal marker is rejected"
        case .duplicateTerminal: return "history burst already has a terminal marker"
        case .commitFailed(let reason): return "history commit failed: \(reason)"
        case .ackFailed(let reason): return "history ACK failed: \(reason)"
        case .invalidState: return "history coordinator state is invalid"
        }
    }
}

public enum HistoryCoordinatorDiagnosticKind: String, Equatable, Sendable {
    case burstOpened
    case recordBuffered
    case metadataBuffered
    case burstDiscarded
    case commitStarted
    case commitFailed
    case committed
    case staleAfterCommit
    case ackAttempt
    case ackSucceeded
    case ackFailed
    case ackExhausted
    case tailCommitted
    case lateTerminalRejected
    case reconnectRequested
}

/// Correlation metadata intentionally contains no health payload.  The batch
/// id is also the storage transaction/batch identity because the StorageKit
/// commit seam makes the SQLite commit durable before it returns.
public struct HistoryCoordinatorDiagnostic: Equatable, Sendable {
    public let kind: HistoryCoordinatorDiagnosticKind
    public let batchID: String?
    /// Correlates a coordinator event with the durable commit seam. StorageKit
    /// exposes the batch identity (rather than a SQLite connection handle), so
    /// this is intentionally the same stable value as `batchID`.
    public let transactionID: String?
    public let token: HistoryToken?
    public let generation: UInt64?
    public let burstID: UInt64?
    public let attempt: Int?
    public let timestamp: Date

    public init(
        kind: HistoryCoordinatorDiagnosticKind,
        batchID: String? = nil,
        transactionID: String? = nil,
        token: HistoryToken? = nil,
        generation: UInt64? = nil,
        burstID: UInt64? = nil,
        attempt: Int? = nil,
        timestamp: Date
    ) {
        self.kind = kind
        self.batchID = batchID
        self.transactionID = transactionID ?? batchID
        self.token = token
        self.generation = generation
        self.burstID = burstID
        self.attempt = attempt
        self.timestamp = timestamp
    }
}

public actor HistoryCoordinatorDiagnostics {
    private let capacity: Int
    private var values: [HistoryCoordinatorDiagnostic] = []

    public init(capacity: Int = 1_024) { self.capacity = max(1, capacity) }

    public func append(_ value: HistoryCoordinatorDiagnostic) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public func events() -> [HistoryCoordinatorDiagnostic] { values }
}

public enum HistoryCoordinatorOutcome: Equatable, Sendable {
    case burstOpened
    case buffered
    case rejected(HistoryCoordinatorError)
    case committedWithoutAck
    case acknowledged(attempts: Int, bytes: Data)
    case ackExhausted
    case completionTailCommitted
}

private enum BurstStatus: Equatable, Sendable {
    case open
    case committing
    case poisoned
    case terminal
}

private struct HistoryBurst: Sendable {
    let burstID: UInt64
    let generation: UInt64
    let batchID: String
    let receivedAt: Int64
    var records: [StoredHistoricalRecord] = []
    var archived: [ArchivedHistoricalRecord] = []
    var status: BurstStatus = .open
    var token: HistoryToken?
}

private struct PendingSnapshot: Sendable {
    let burstID: UInt64
    let batchID: String
    let generation: UInt64
    let receivedAt: Int64
    let records: [StoredHistoricalRecord]
    let archived: [ArchivedHistoricalRecord]
}

/// The sole history commit and ACK authority.  It never exposes a token from
/// completion-tail outcomes, and it performs generation/burst checks on both
/// sides of every suspension in the destructive boundary.
public actor HistoryCoordinator {
    public static let ackRetryDelays: [TimeInterval] = [0, 0.200, 0.400]
    public static let maximumACKAttempts = 3
    public static let ackWriteTimeout: TimeInterval = 8
    public static let maximumPendingReplays = 8
    public static let provisionalBatchPrefix = "history-provisional-"

    /// Optional generation-pinned ACK path used by the composed production
    /// runtime.  Keeping this as an additive seam preserves the transport
    /// fallback used by protocol/unit tests while ensuring a live runtime can
    /// put terminal ACKs through its one SerializedGenerationPinnedWriter.
    public typealias GenerationPinnedACKWriter = @Sendable (
        _ sequence: UInt8,
        _ token: HistoryToken,
        _ generation: UInt64
    ) async throws -> Void

    private let store: any HistoryBatchStore
    private let transport: any CommandWriteTransport
    private let clock: any BLEClock
    private let acknowledger: (any HistoryBatchAcknowledger)?
    private let generationPinnedACKWriter: GenerationPinnedACKWriter?
    public let diagnostics: HistoryCoordinatorDiagnostics
    public let orderedQueue: OrderedHistoryQueue

    private var currentGeneration: UInt64?
    private var burst: HistoryBurst?
    private var snapshots: [PendingSnapshot] = []
    private var nextBurstID: UInt64 = 0
    private var sequenceAllocator = SeqAllocator()

    public init(
        store: any HistoryBatchStore,
        transport: any CommandWriteTransport,
        clock: any BLEClock = SystemBLEClock(),
        acknowledger: (any HistoryBatchAcknowledger)?,
        diagnostics: HistoryCoordinatorDiagnostics = HistoryCoordinatorDiagnostics(),
        orderedQueue: OrderedHistoryQueue = OrderedHistoryQueue(),
        generationPinnedACKWriter: GenerationPinnedACKWriter? = nil
    ) {
        self.store = store
        self.transport = transport
        self.clock = clock
        self.acknowledger = acknowledger
        self.generationPinnedACKWriter = generationPinnedACKWriter
        self.diagnostics = diagnostics
        self.orderedQueue = orderedQueue
    }

    /// Convenience for the production SQLite implementation.  The optional
    /// protocol remains injectable for deterministic fake stores.
    public init(
        store: any HistoryBatchStore,
        transport: any CommandWriteTransport,
        clock: any BLEClock = SystemBLEClock(),
        diagnostics: HistoryCoordinatorDiagnostics = HistoryCoordinatorDiagnostics(),
        orderedQueue: OrderedHistoryQueue = OrderedHistoryQueue(),
        generationPinnedACKWriter: GenerationPinnedACKWriter? = nil
    ) {
        self.init(
            store: store,
            transport: transport,
            clock: clock,
            acknowledger: store as? any HistoryBatchAcknowledger,
            diagnostics: diagnostics,
            orderedQueue: orderedQueue,
            generationPinnedACKWriter: generationPinnedACKWriter
        )
    }

    @discardableResult
    public func beginBurst(
        generation: UInt64,
        batchID: String,
        receivedAt: Int64
    ) async throws -> HistoryCoordinatorOutcome {
        let previousGeneration = currentGeneration
        try ensureGeneration(generation)
        if let previousGeneration, generation > previousGeneration {
            sequenceAllocator.reset()
        }
        let replay = snapshots
        snapshots.removeAll(keepingCapacity: true)
        if let existing = burst {
            // A fresh HISTORY_START poisons the incomplete old burst.  Its
            // partial records are not ACK eligible and are intentionally
            // discarded; the band will redeliver them from its unadvanced
            // cursor.
            if existing.status == .open || existing.status == .committing {
                nextBurstID &+= 1
                burst = HistoryBurst(
                    burstID: nextBurstID,
                    generation: generation,
                    batchID: batchID,
                    receivedAt: receivedAt,
                    records: replay.flatMap(\.records),
                    archived: replay.flatMap(\.archived)
                )
                await orderedQueue.reset()
                for record in replay.flatMap(\.records) { await orderedQueue.append(.record(record)) }
                for archived in replay.flatMap(\.archived) { await orderedQueue.append(.archived(archived)) }
                await diagnostics.append(HistoryCoordinatorDiagnostic(
                    kind: .burstOpened,
                    batchID: batchID,
                    generation: generation,
                    burstID: nextBurstID,
                    timestamp: clock.now()
                ))
                return .burstOpened
            }
        }
        currentGeneration = generation
        nextBurstID &+= 1
        burst = HistoryBurst(
            burstID: nextBurstID,
            generation: generation,
            batchID: batchID,
            receivedAt: receivedAt,
            records: replay.flatMap(\.records),
            archived: replay.flatMap(\.archived)
        )
        await orderedQueue.reset()
        for record in replay.flatMap(\.records) { await orderedQueue.append(.record(record)) }
        for archived in replay.flatMap(\.archived) { await orderedQueue.append(.archived(archived)) }
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .burstOpened,
            batchID: batchID,
            generation: generation,
            burstID: nextBurstID,
            timestamp: clock.now()
        ))
        return .burstOpened
    }

    /// Opens a burst with the protocol-derived identity used by Edge when the
    /// terminal token is already known (for replay/import paths).
    @discardableResult
    public func beginBurst(
        generation: UInt64,
        token: HistoryToken,
        receivedAt: Int64
    ) async throws -> HistoryCoordinatorOutcome {
        try await beginBurst(
            generation: generation,
            batchID: token.derivedBatchID,
            receivedAt: receivedAt
        )
    }

    /// Opens HISTORY_START with an internal provisional identity. The exact
    /// token-derived identity replaces this value at HISTORY_END before the
    /// StorageKit transaction begins, so runtime callers never invent a batch
    /// ID for a live band session.
    @discardableResult
    public func beginBurst(
        generation: UInt64,
        receivedAt: Int64
    ) async throws -> HistoryCoordinatorOutcome {
        let provisional = "\(Self.provisionalBatchPrefix)\(generation)-\(nextBurstID &+ 1)"
        return try await beginBurst(
            generation: generation,
            batchID: provisional,
            receivedAt: receivedAt
        )
    }

    public static func batchID(for token: HistoryToken) -> String {
        token.derivedBatchID
    }

    public func replaceGeneration(_ generation: UInt64) throws {
        if let currentGeneration, generation <= currentGeneration {
            throw HistoryCoordinatorError.staleGeneration(
                expected: generation,
                actual: currentGeneration
            )
        }
        currentGeneration = generation
        sequenceAllocator.reset()
        // A commit already in flight may still finish on SQLite.  We leave
        // its data alone and only suppress the post-commit ACK check.
    }

    public func activeGeneration() -> UInt64? { currentGeneration }

    @discardableResult
    public func receive(
        record: StoredHistoricalRecord,
        generation: UInt64
    ) async throws -> HistoryCoordinatorOutcome {
        guard var burst else { throw HistoryCoordinatorError.noOpenBurst }
        try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        guard burst.status == .open else {
            throw burst.status == .poisoned
                ? HistoryCoordinatorError.burstDiscarded
                : HistoryCoordinatorError.duplicateTerminal
        }
        burst.records.append(record)
        self.burst = burst
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .recordBuffered,
            batchID: burst.batchID,
            generation: generation,
            burstID: burst.burstID,
            timestamp: clock.now()
        ))
        await orderedQueue.append(.record(record))
        return .buffered
    }

    @discardableResult
    public func receive(
        archived: ArchivedHistoricalRecord,
        generation: UInt64
    ) async throws -> HistoryCoordinatorOutcome {
        guard var burst else { throw HistoryCoordinatorError.noOpenBurst }
        try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        guard burst.status == .open else {
            throw burst.status == .poisoned
                ? HistoryCoordinatorError.burstDiscarded
                : HistoryCoordinatorError.duplicateTerminal
        }
        burst.archived.append(archived)
        self.burst = burst
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .metadataBuffered,
            batchID: burst.batchID,
            generation: generation,
            burstID: burst.burstID,
            timestamp: clock.now()
        ))
        await orderedQueue.append(.archived(archived))
        return .buffered
    }

    /// Records metadata in the same ordered queue.  Packet-count semantics are
    /// advisory only; no mismatch can block a durable commit.
    public func receiveMetadata(
        _ metadata: Data,
        generation: UInt64
    ) async throws -> HistoryCoordinatorOutcome {
        guard let burst else { throw HistoryCoordinatorError.noOpenBurst }
        try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        guard burst.status == .open else {
            throw burst.status == .poisoned
                ? HistoryCoordinatorError.burstDiscarded
                : HistoryCoordinatorError.duplicateTerminal
        }
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .metadataBuffered,
            batchID: burst.batchID,
            generation: generation,
            burstID: burst.burstID,
            timestamp: clock.now()
        ))
        await orderedQueue.append(.metadata(Data(metadata)))
        return .buffered
    }

    public func discardBurst(generation: UInt64) async throws {
        guard var burst else { throw HistoryCoordinatorError.noOpenBurst }
        try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        burst.status = .poisoned
        burst.records.removeAll(keepingCapacity: false)
        burst.archived.removeAll(keepingCapacity: false)
        self.burst = burst
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .burstDiscarded,
            batchID: burst.batchID,
            generation: generation,
            burstID: burst.burstID,
            timestamp: clock.now()
        ))
        await orderedQueue.reset()
    }

    /// Commits the tokenized chunk first, then emits the exact token ACK only
    /// if the session and burst still match.  On commit failure the snapshot
    /// is put back at the front and the link is disconnected to force a clean
    /// redelivery.
    private func receiveHistoryEndInternal(
        token: HistoryToken,
        sequence: UInt8,
        generation: UInt64
    ) async -> HistoryCoordinatorOutcome {
        guard var burst else { return .rejected(.noOpenBurst) }
        let burstID = burst.burstID
        // ACKs stay in Edge's low sync range. Legacy callers may still pass a
        // reserved setup sequence; replace those values with the allocator's
        // next low sequence rather than risking a command collision.
        let ackSequence = sequence < SeqAllocator.firstSyncACK
            ? sequenceAllocator.nextSync()
            : sequence
        do {
            try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        } catch let error as HistoryCoordinatorError {
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .lateTerminalRejected,
                batchID: burst.batchID,
                token: token,
                generation: generation,
                burstID: burstID,
                timestamp: clock.now()
            ))
            return .rejected(error)
        } catch {
            return .rejected(.invalidState)
        }
        guard burst.status == .open else {
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .lateTerminalRejected,
                batchID: burst.batchID,
                token: token,
                generation: generation,
                burstID: burstID,
                timestamp: clock.now()
            ))
            return .rejected(burst.status == .poisoned ? .burstDiscarded : .duplicateTerminal)
        }

        burst.status = .committing
        burst.token = token
        if burst.batchID.isEmpty || burst.batchID.hasPrefix(Self.provisionalBatchPrefix) {
            burst = HistoryBurst(
                burstID: burst.burstID,
                generation: burst.generation,
                batchID: token.derivedBatchID,
                receivedAt: burst.receivedAt,
                records: burst.records,
                archived: burst.archived,
                status: burst.status,
                token: burst.token
            )
        }
        self.burst = burst
        let snapshot = PendingSnapshot(
            burstID: burstID,
            batchID: burst.batchID,
            generation: generation,
            receivedAt: burst.receivedAt,
            records: burst.records,
            archived: burst.archived
        )
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .commitStarted,
            batchID: snapshot.batchID,
            token: token,
            generation: generation,
            burstID: burstID,
            timestamp: clock.now()
        ))

        let committed: DurableHistoryCommit
        do {
            committed = try await store.commit(
                records: snapshot.records,
                archived: snapshot.archived,
                boundary: .tokenized(token),
                diagnostics: HistoryBatchDiagnostics(
                    batchID: snapshot.batchID,
                    receivedAt: snapshot.receivedAt,
                    recordCount: snapshot.records.count,
                    archivedCount: snapshot.archived.count
                )
            )
        } catch {
            enqueueReplay(snapshot)
            if self.burst?.burstID == burstID { self.burst = nil }
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .commitFailed,
                batchID: snapshot.batchID,
                token: token,
                generation: generation,
                burstID: burstID,
                timestamp: clock.now()
            ))
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .reconnectRequested,
                batchID: snapshot.batchID,
                token: token,
                generation: generation,
                burstID: burstID,
                timestamp: clock.now()
            ))
            await transport.disconnect()
            return .rejected(.commitFailed(String(describing: error)))
        }

        guard !Task.isCancelled else {
            if self.burst?.burstID == burstID { self.burst = nil }
            return .committedWithoutAck
        }

        guard case .ackEligible(let committedBatch) = committed else {
            // A tokenized boundary must never return a completion-tail result.
            enqueueReplay(snapshot)
            if self.burst?.burstID == burstID { self.burst = nil }
            return .rejected(.invalidState)
        }
        guard committedBatch.token == token,
              committedBatch.batchID == snapshot.batchID else {
            enqueueReplay(snapshot)
            if self.burst?.burstID == burstID { self.burst = nil }
            return .rejected(.invalidState)
        }
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .committed,
            batchID: committedBatch.batchID,
            token: committedBatch.token,
            generation: generation,
            burstID: burstID,
            timestamp: clock.now()
        ))

        // The durable commit may finish after a replacement session begins.
        // The old burst identity must never authorize an ACK or clear the new
        // burst's state.
        guard currentGeneration == generation,
              self.burst?.generation == generation,
              self.burst?.burstID == burstID,
              self.burst?.status == .committing else {
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .staleAfterCommit,
                batchID: committedBatch.batchID,
                token: committedBatch.token,
                generation: generation,
                burstID: burstID,
                timestamp: clock.now()
            ))
            return .committedWithoutAck
        }

        let ackBytes: Data
        do {
            ackBytes = try CommandBuilder.historyAcknowledgement(
                sequence: ackSequence,
                token: committedBatch.token
            )
        } catch {
            if self.burst?.burstID == burstID { self.burst = nil }
            return .rejected(.ackFailed(String(describing: error)))
        }

        for (offset, delay) in Self.ackRetryDelays.enumerated() {
            let attempt = offset + 1
            guard !Task.isCancelled else {
                if self.burst?.burstID == burstID { self.burst = nil }
                return .committedWithoutAck
            }
            guard currentGeneration == generation,
                  self.burst?.generation == generation,
                  self.burst?.burstID == burstID,
                  self.burst?.status == .committing else {
                return .committedWithoutAck
            }
            if delay > 0 {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return .committedWithoutAck
                }
                guard currentGeneration == generation,
                      self.burst?.burstID == burstID,
                      self.burst?.status == .committing else {
                    return .committedWithoutAck
                }
            }

            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .ackAttempt,
                batchID: committedBatch.batchID,
                token: committedBatch.token,
                generation: generation,
                burstID: burstID,
                attempt: attempt,
                timestamp: clock.now()
            ))
            do {
                try await writeACKWithTimeout(
                    ackBytes,
                    sequence: ackSequence,
                    token: committedBatch.token,
                    generation: generation
                )
                guard !Task.isCancelled else {
                    if self.burst?.burstID == burstID { self.burst = nil }
                    return .committedWithoutAck
                }
                guard currentGeneration == generation,
                      self.burst?.generation == generation,
                      self.burst?.burstID == burstID,
                      self.burst?.status == .committing else {
                    await diagnostics.append(HistoryCoordinatorDiagnostic(
                        kind: .staleAfterCommit,
                        batchID: committedBatch.batchID,
                        token: committedBatch.token,
                        generation: generation,
                        burstID: burstID,
                        attempt: attempt,
                        timestamp: clock.now()
                    ))
                    return .committedWithoutAck
                }

                if let acknowledger {
                    try? await acknowledger.markAcknowledged(
                        batchID: committedBatch.batchID,
                        updatedAt: Int64(clock.now().timeIntervalSince1970)
                    )
                }
                guard currentGeneration == generation,
                      self.burst?.burstID == burstID,
                      self.burst?.status == .committing else {
                    return .committedWithoutAck
                }
                self.burst = nil
                await diagnostics.append(HistoryCoordinatorDiagnostic(
                    kind: .ackSucceeded,
                    batchID: committedBatch.batchID,
                    token: committedBatch.token,
                    generation: generation,
                    burstID: burstID,
                    attempt: attempt,
                    timestamp: clock.now()
                ))
                return .acknowledged(attempts: attempt, bytes: ackBytes)
            } catch {
                await diagnostics.append(HistoryCoordinatorDiagnostic(
                    kind: .ackFailed,
                    batchID: committedBatch.batchID,
                    token: committedBatch.token,
                    generation: generation,
                    burstID: burstID,
                    attempt: attempt,
                    timestamp: clock.now()
                ))
            }
        }

        let stillCurrent = currentGeneration == generation
            && self.burst?.burstID == burstID
            && self.burst?.status == .committing
        if stillCurrent { self.burst = nil }
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .ackExhausted,
            batchID: committedBatch.batchID,
            token: committedBatch.token,
            generation: generation,
            burstID: burstID,
            timestamp: clock.now()
        ))
        await diagnostics.append(HistoryCoordinatorDiagnostic(
            kind: .reconnectRequested,
            batchID: committedBatch.batchID,
            token: committedBatch.token,
            generation: generation,
            burstID: burstID,
            timestamp: clock.now()
        ))
        if stillCurrent { await transport.disconnect() }
        return .ackExhausted
    }

    /// Compatibility seam for deterministic protocol tests. Production code
    /// should call the overload without `sequence`; it allocates from the
    /// session-local low sync range.
    @available(*, deprecated, message: "Use receiveHistoryEnd(token:generation:) so ACK sequence allocation stays internal")
    public func receiveHistoryEnd(
        token: HistoryToken,
        sequence: UInt8,
        generation: UInt64
    ) async -> HistoryCoordinatorOutcome {
        await receiveHistoryEndInternal(token: token, sequence: sequence, generation: generation)
    }

    /// Allocates the low sync range (starting at 5) for a terminal ACK.
    public func receiveHistoryEnd(
        token: HistoryToken,
        generation: UInt64
    ) async -> HistoryCoordinatorOutcome {
        let sequence = sequenceAllocator.nextSync()
        return await receiveHistoryEndInternal(token: token, sequence: sequence, generation: generation)
    }

    /// A HISTORY_COMPLETE tail is durable but intentionally tokenless and
    /// cannot produce an ACK.  The coordinator remains listening after this
    /// method returns; the caller may open the next burst.
    public func receiveHistoryComplete(generation: UInt64) async -> HistoryCoordinatorOutcome {
        guard let burst else { return .rejected(.noOpenBurst) }
        do {
            try ensureCurrent(burstGeneration: burst.generation, eventGeneration: generation)
        } catch let error as HistoryCoordinatorError {
            return .rejected(error)
        } catch {
            return .rejected(.invalidState)
        }
        guard burst.status == .open else {
            return .rejected(burst.status == .poisoned ? .burstDiscarded : .duplicateTerminal)
        }

        let snapshot = PendingSnapshot(
            burstID: burst.burstID,
            batchID: burst.batchID,
            generation: generation,
            receivedAt: burst.receivedAt,
            records: burst.records,
            archived: burst.archived
        )
        self.burst?.status = .committing

        do {
            let result = try await store.commit(
                records: snapshot.records,
                archived: snapshot.archived,
                boundary: .completionTail,
                diagnostics: HistoryBatchDiagnostics(
                    batchID: snapshot.batchID,
                    receivedAt: snapshot.receivedAt,
                    recordCount: snapshot.records.count,
                    archivedCount: snapshot.archived.count
                )
            )
            guard !Task.isCancelled else {
                if self.burst?.burstID == snapshot.burstID { self.burst = nil }
                return .committedWithoutAck
            }
            guard case .completionTail = result else {
                if self.burst?.burstID == snapshot.burstID { self.burst = nil }
                return .rejected(.invalidState)
            }
            guard currentGeneration == generation,
                  self.burst?.burstID == snapshot.burstID,
                  self.burst?.status == .committing else {
                await diagnostics.append(HistoryCoordinatorDiagnostic(
                    kind: .staleAfterCommit,
                    batchID: snapshot.batchID,
                    generation: generation,
                    burstID: snapshot.burstID,
                    timestamp: clock.now()
                ))
                return .committedWithoutAck
            }
            self.burst = nil
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .tailCommitted,
                batchID: snapshot.batchID,
                generation: generation,
                burstID: snapshot.burstID,
                timestamp: clock.now()
            ))
            return .completionTailCommitted
        } catch {
            enqueueReplay(snapshot)
            if self.burst?.burstID == snapshot.burstID { self.burst = nil }
            await diagnostics.append(HistoryCoordinatorDiagnostic(
                kind: .commitFailed,
                batchID: snapshot.batchID,
                generation: generation,
                burstID: snapshot.burstID,
                timestamp: clock.now()
            ))
            // No ACK exists for this boundary; remain listening after the
            // failure so a later terminal chunk can retry the durable tail.
            return .rejected(.commitFailed(String(describing: error)))
        }
    }

    /// Snapshots restored to the front after a commit failure.  The caller may
    /// reinsert these records when the replacement generation opens.
    public func pendingReplayCount() -> Int { snapshots.count }

    public func takePendingReplay() -> [PendingSnapshotView] {
        let result = snapshots.map {
            PendingSnapshotView(
                burstID: $0.burstID,
                batchID: $0.batchID,
                generation: $0.generation,
                receivedAt: $0.receivedAt,
                records: $0.records,
                archived: $0.archived
            )
        }
        snapshots.removeAll(keepingCapacity: true)
        return result
    }

    private func enqueueReplay(_ snapshot: PendingSnapshot) {
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > Self.maximumPendingReplays {
            snapshots.removeLast(snapshots.count - Self.maximumPendingReplays)
        }
    }

    private func writeACKWithTimeout(
        _ bytes: Data,
        sequence: UInt8,
        token: HistoryToken,
        generation: UInt64
    ) async throws {
        let transport = self.transport
        let generationPinnedACKWriter = self.generationPinnedACKWriter
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                if let generationPinnedACKWriter {
                    try await generationPinnedACKWriter(sequence, token, generation)
                } else {
                    try await transport.writeCommand(bytes)
                }
            }
            group.addTask {
                // ACK write deadlines are wall-clock I/O safety boundaries,
                // not domain time. Using the injected deterministic BLE clock
                // here lets a no-op test clock win the race against a
                // successful actor hop and can issue the same ACK twice. Keep
                // retry pacing injectable, but measure the write deadline on
                // Swift's cancellation-aware monotonic sleep.
                try await Task.sleep(
                    nanoseconds: UInt64(Self.ackWriteTimeout * 1_000_000_000)
                )
                throw HistoryCoordinatorError.ackFailed("ACK write timed out after 8s")
            }
            defer { group.cancelAll() }
            guard (try await group.next()) != nil else {
                throw HistoryCoordinatorError.ackFailed("ACK write cancelled")
            }
        }
    }

    private func ensureGeneration(_ generation: UInt64) throws {
        if let currentGeneration {
            guard generation >= currentGeneration else {
                throw HistoryCoordinatorError.staleGeneration(
                    expected: generation,
                    actual: currentGeneration
                )
            }
        }
        currentGeneration = generation
    }

    private func ensureCurrent(
        burstGeneration: UInt64,
        eventGeneration: UInt64
    ) throws {
        guard currentGeneration == eventGeneration,
              burstGeneration == eventGeneration else {
            throw HistoryCoordinatorError.staleGeneration(
                expected: eventGeneration,
                actual: currentGeneration
            )
        }
    }
}

public struct PendingSnapshotView: Equatable, Sendable {
    public let burstID: UInt64
    public let batchID: String
    public let generation: UInt64
    public let receivedAt: Int64
    public let records: [StoredHistoricalRecord]
    public let archived: [ArchivedHistoricalRecord]

    public init(
        burstID: UInt64 = 0,
        batchID: String,
        generation: UInt64,
        receivedAt: Int64,
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord]
    ) {
        self.burstID = burstID
        self.batchID = batchID
        self.generation = generation
        self.receivedAt = receivedAt
        self.records = records
        self.archived = archived
    }
}

/// A type-safe ordered queue item.  The `metadata` case intentionally stores
/// only a copy for parser/ordering tests; coordinator diagnostics never expose
/// those bytes.
public actor OrderedHistoryQueue {
    public enum Item: Equatable, Sendable {
        case record(StoredHistoricalRecord)
        case archived(ArchivedHistoricalRecord)
        case metadata(Data)
    }

    private let capacity: Int
    private var values: [Item] = []

    public init(capacity: Int = 10_000) { self.capacity = max(1, capacity) }

    public func append(_ item: Item) {
        if values.count >= capacity { values.removeFirst() }
        values.append(item)
    }
    public func count() -> Int { values.count }
    public func isAtCapacity() -> Bool { values.count >= capacity }
    public func drain() -> [Item] {
        let result = values
        values.removeAll(keepingCapacity: true)
        return result
    }
    public func reset() { values.removeAll(keepingCapacity: true) }
}
