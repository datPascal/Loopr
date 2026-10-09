import Foundation
import ProtocolKit

/// The clock seam used by connection code.  Production uses
/// `SystemBLEClock`; simulator tests inject a manually-controlled clock so
/// timeout and pacing behavior never depends on wall-clock scheduling.
public protocol BLEClock: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemBLEClock: BLEClock, Sendable {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for interval: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// A narrow transport seam for the command characteristic.  CoreBluetooth
/// adapters can conform without leaking CoreBluetooth into writer logic.
public protocol CommandWriteTransport: Sendable {
    func writeCommand(_ data: Data) async throws
    func disconnect() async
}

/// Adapts the transport seam's characteristic-addressed write to the writer's
/// command-only boundary.  The adapter contains no retry/firewall policy; it
/// only pins writes to the Harvard command characteristic.
public struct BLECommandTransportAdapter: CommandWriteTransport, Sendable {
    private let transport: any BLETransport
    private let commandCharacteristic: CharacteristicID

    public init(
        transport: any BLETransport,
        commandCharacteristic: CharacteristicID = HarvardBluetoothProfile.command
    ) {
        self.transport = transport
        self.commandCharacteristic = commandCharacteristic
    }

    public func writeCommand(_ data: Data) async throws {
        // The adapter is the last public boundary before bytes reach the
        // command characteristic. Validate the complete envelope here even
        // when a caller did not use SerializedGenerationPinnedWriter.
        try CommandFirewall.validateEncodedFrame(data)
        try await transport.write(data, to: commandCharacteristic)
    }

    public func disconnect() async {
        await transport.disconnect()
    }
}

/// Session-local sequence allocator matching Edge's wire split: live-control
/// commands occupy the high range while history ACKs stay in the low range.
/// It resets for every connection generation and deliberately has no raw
/// sequence setter, preventing an accidental collision with an in-flight
/// command. (Pinned Edge source: `edge/lib/ble/ble_state.dart`, `SeqAllocator`.)
public struct SeqAllocator: Equatable, Sendable {
    public static let firstLive: UInt8 = 0xA0
    public static let lastLive: UInt8 = 0xFF
    public static let firstSyncACK: UInt8 = 5

    private var nextLiveValue: UInt8
    private var nextSyncValue: UInt8

    public init() {
        nextLiveValue = Self.firstLive
        nextSyncValue = Self.firstSyncACK
    }

    public mutating func nextLive() -> UInt8 {
        let result = nextLiveValue
        nextLiveValue = nextLiveValue == Self.lastLive ? Self.firstLive : nextLiveValue &+ 1
        return result
    }

    public mutating func nextSync() -> UInt8 {
        let result = nextSyncValue
        // Edge's sync counter consumes the low range starting at 5 and wraps
        // after UInt8.max. Keep this exact source behavior; normal sessions
        // remain in the low range while long-lived sessions retain parity.
        nextSyncValue = nextSyncValue == UInt8.max ? Self.firstSyncACK : nextSyncValue &+ 1
        return result
    }

    public mutating func reset() {
        nextLiveValue = Self.firstLive
        nextSyncValue = Self.firstSyncACK
    }
}

/// Descriptive alias used by connection/session integrations.
public typealias BLESequenceAllocator = SeqAllocator

public enum SerializedWriterError: Error, Equatable, Sendable, LocalizedError {
    case queueFull(limit: Int)
    case staleGeneration(expected: UInt64, actual: UInt64?)
    case disconnected
    case timedOut(seconds: Int)
    case noActiveGeneration
    case cancelled
    case bondFailure(TransportError)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .queueFull(let limit): return "BLE command queue is full (limit \(limit))"
        case .staleGeneration(let expected, let actual):
            return "BLE command belongs to generation \(expected), current generation is \(actual.map(String.init) ?? "none")"
        case .disconnected: return "BLE command writer is disconnected"
        case .timedOut(let seconds): return "BLE command write timed out after \(seconds)s"
        case .noActiveGeneration: return "BLE command writer has no active session generation"
        case .cancelled: return "BLE command write was cancelled"
        case .bondFailure(let error): return "Bluetooth pairing is required: \(error.localizedDescription)"
        case .transport(let reason): return "BLE command transport failed: \(reason)"
        }
    }
}

public enum SerializedWriterDiagnostic: Equatable, Sendable {
    case overflow(limit: Int, generation: UInt64)
    case rejectedStale(expected: UInt64, actual: UInt64?)
    case timeout(generation: UInt64)
    case cancelled(generation: UInt64)
    case disconnected(generation: UInt64?)
}

/// Bounded, actor-isolated diagnostics for writer behavior.  Payload bytes
/// are intentionally never retained.
public actor SerializedWriterDiagnostics {
    private var values: [SerializedWriterDiagnostic] = []
    private let capacity: Int

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    public func append(_ value: SerializedWriterDiagnostic) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public func events() -> [SerializedWriterDiagnostic] { values }
}

private struct PendingCommand: Sendable {
    let id: UInt64
    let command: ProductionCommand
    let generation: UInt64
    let timeout: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
}

/// A single session-pinned command writer.
///
/// The actor owns queue order and makes the one-write-in-flight invariant
/// explicit.  A request is checked against the active generation immediately
/// before the transport call and again after every await.  Replacing a
/// generation invalidates queued work; a disconnect cancels the drain and
/// tears down the transport.
public actor SerializedGenerationPinnedWriter {
    public static let defaultQueueLimit = 32
    public static let writeTimeout: TimeInterval = 8
    public static let firstSetupWriteTimeout: TimeInterval = 30

    private let transport: any CommandWriteTransport
    private let clock: any BLEClock
    private let commandWriter: ProductionCommandWriter
    public let diagnostics: SerializedWriterDiagnostics
    private let queueLimit: Int
    private var queue: [PendingCommand] = []
    private var currentGeneration: UInt64?
    private var connected = false
    private var drainTask: Task<Void, Never>?
    private var activeRequestID: UInt64?
    private var nextRequestID: UInt64 = 0

    public init(
        transport: any CommandWriteTransport,
        clock: any BLEClock = SystemBLEClock(),
        queueLimit: Int = defaultQueueLimit,
        commandWriter: ProductionCommandWriter = ProductionCommandWriter(),
        diagnostics: SerializedWriterDiagnostics = SerializedWriterDiagnostics()
    ) {
        self.transport = transport
        self.clock = clock
        self.queueLimit = max(1, queueLimit)
        self.commandWriter = commandWriter
        self.diagnostics = diagnostics
    }

    /// Starts (or replaces) the active session.  Generations must increase;
    /// accepting a reused value would permit stale callbacks to write.
    public func begin(generation: UInt64) throws {
        if let currentGeneration, generation <= currentGeneration {
            throw SerializedWriterError.staleGeneration(
                expected: generation,
                actual: currentGeneration
            )
        }

        // A replacement invalidates an in-flight operation as well as queued
        // work.  CoreBluetooth may still finish a write that already reached
        // the radio, but cancelling the actor task prevents its completion
        // from authorizing the old request or holding the sole drain open.
        let replacing = currentGeneration != nil
        connected = true
        currentGeneration = generation
        invalidateQueuedWork(except: generation)
        if replacing {
            drainTask?.cancel()
        }
    }

    /// Alias used by connection/session coordinators.
    public func replaceGeneration(_ generation: UInt64) throws {
        try begin(generation: generation)
    }

    public func activeGeneration() -> UInt64? { currentGeneration }

    public func pendingCount() -> Int { queue.count }

    public func isConnected() -> Bool { connected }

    /// Enqueues one closed, typed production command.  Dangerous commands are
    /// rejected by `ProductionCommandWriter` before they can occupy the queue.
    public func write(
        _ command: ProductionCommand,
        generation: UInt64,
        timeout: TimeInterval = SerializedGenerationPinnedWriter.writeTimeout
    ) async throws {
        // Once a caller supplies a generation, a closed writer is a
        // disconnected session even if `disconnect()` won the actor hop just
        // before this request arrived. Reporting `noActiveGeneration` for
        // that race leaks scheduling order and makes cancellation handling
        // nondeterministic to callers.
        guard connected else { throw SerializedWriterError.disconnected }
        guard let currentGeneration else { throw SerializedWriterError.noActiveGeneration }
        guard currentGeneration == generation else {
            await diagnostics.append(.rejectedStale(expected: generation, actual: currentGeneration))
            throw SerializedWriterError.staleGeneration(expected: generation, actual: currentGeneration)
        }

        // Encode before enqueueing, so malformed/dangerous commands never
        // count against the bounded transport queue.
        _ = try commandWriter.encode(command)

        guard queue.count < queueLimit else {
            await diagnostics.append(.overflow(limit: queueLimit, generation: generation))
            throw SerializedWriterError.queueFull(limit: queueLimit)
        }

        guard !Task.isCancelled else { throw SerializedWriterError.cancelled }
        let requestID = nextRequestID
        nextRequestID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(PendingCommand(
                    id: requestID,
                    command: command,
                    generation: generation,
                    timeout: timeout,
                    continuation: continuation
                ))
                startDrainIfNeeded()
            }
        } onCancel: { [weak self] in
            // Cancellation must wake a queued continuation; leaving it in the
            // queue would wedge every later write behind an abandoned task.
            Task { [weak self] in
                await self?.cancel(requestID: requestID)
            }
        }
    }

    /// A convenience spelling that makes the final writer boundary visible at
    /// call sites.
    public func writeProductionCommand(
        _ command: ProductionCommand,
        generation: UInt64
    ) async throws {
        try await write(command, generation: generation)
    }

    /// Sends Edge's exact five-command initialization sequence through the
    /// serialized writer. Every command waits for the transport's
    /// write-with-response completion before the 120 ms inter-command pacing
    /// begins, and all commands remain pinned to the requested generation.
    /// (Pinned Edge source: `edge/lib/ble/ble_engine.dart`, `sendInit`, and
    /// protocol source `lib/src/commands.dart`, init sequence 0...4.)
    @discardableResult
    public func runInitialization(
        generation: UInt64,
        onWriteCompleted: (@Sendable (ProductionCommand) async -> Void)? = nil
    ) async throws -> [Data] {
        let commands: [ProductionCommand] = [
            .hello(sequence: 0),
            .advertisingName(sequence: 1),
            .dataRange(sequence: 2),
            .alarmTime(sequence: 3),
            .startHistoricalData(sequence: 4)
        ]
        var encoded: [Data] = []
        encoded.reserveCapacity(commands.count)
        for (index, command) in commands.enumerated() {
            let bytes = try commandWriter.encode(command)
            try await write(command, generation: generation)
            await onWriteCompleted?(command)
            encoded.append(bytes)
            if index < commands.count - 1 {
                try await clock.sleep(for: InitializationCommandSequence.spacing)
            }
        }
        return encoded
    }

    /// Source-compatible spelling for session coordinators.
    @discardableResult
    public func sendInitialization(generation: UInt64) async throws -> [Data] {
        try await runInitialization(generation: generation)
    }

    /// Marks the generation disconnected and cancels any pending transport
    /// operation.  The underlying adapter is asked to disconnect exactly once.
    public func disconnect() async {
        let oldGeneration = currentGeneration
        connected = false
        currentGeneration = nil
        await diagnostics.append(.disconnected(generation: oldGeneration))
        failQueued(with: .disconnected)
        drainTask?.cancel()
        drainTask = nil
        await transport.disconnect()
    }

    private func invalidateQueuedWork(except generation: UInt64) {
        let stale = queue.filter { $0.generation != generation }
        queue.removeAll { $0.generation != generation }
        for request in stale {
            request.continuation.resume(throwing: SerializedWriterError.staleGeneration(
                expected: request.generation,
                actual: generation
            ))
        }
    }

    private func failQueued(with error: SerializedWriterError) {
        let pending = queue
        queue.removeAll(keepingCapacity: true)
        for request in pending {
            request.continuation.resume(throwing: error)
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            if Task.isCancelled { break }
            guard let request = queue.first else { break }
            queue.removeFirst()
            activeRequestID = request.id

            do {
                try Task.checkCancellation()
                guard connected, let currentGeneration else {
                    throw SerializedWriterError.disconnected
                }
                guard currentGeneration == request.generation else {
                    await diagnostics.append(.rejectedStale(
                        expected: request.generation,
                        actual: currentGeneration
                    ))
                    throw SerializedWriterError.staleGeneration(
                        expected: request.generation,
                        actual: currentGeneration
                    )
                }

                let encoded = try commandWriter.encode(request.command)
                try await performWrite(
                    encoded,
                    generation: request.generation,
                    timeout: request.timeout
                )

                // `performWrite` checks after its transport and timeout awaits;
                // this final actor-local check protects a generation replacement
                // that occurs immediately after the transport returns.
                guard connected, currentGeneration == request.generation else {
                    throw SerializedWriterError.staleGeneration(
                        expected: request.generation,
                        actual: currentGeneration
                    )
                }
                request.continuation.resume()
            } catch is CancellationError {
                if let actual = currentGeneration, actual != request.generation {
                    await diagnostics.append(.rejectedStale(
                        expected: request.generation,
                        actual: actual
                    ))
                    request.continuation.resume(throwing: SerializedWriterError.staleGeneration(
                        expected: request.generation,
                        actual: actual
                    ))
                } else if !connected {
                    request.continuation.resume(throwing: SerializedWriterError.disconnected)
                } else {
                    await diagnostics.append(.cancelled(generation: request.generation))
                    request.continuation.resume(throwing: SerializedWriterError.cancelled)
                }
            } catch let error as SerializedWriterError {
                request.continuation.resume(throwing: error)
            } catch {
                request.continuation.resume(throwing: SerializedWriterError.transport(String(describing: error)))
            }
            activeRequestID = nil
        }

        // Do not clear a newer task that has been installed while this task
        // was suspended.  In normal actor use this is the only drain task.
        drainTask = nil
        if !queue.isEmpty, connected {
            startDrainIfNeeded()
        }
    }

    private func cancel(requestID: UInt64) {
        if let index = queue.firstIndex(where: { $0.id == requestID }) {
            let request = queue.remove(at: index)
            request.continuation.resume(throwing: SerializedWriterError.cancelled)
            return
        }
        if activeRequestID == requestID {
            drainTask?.cancel()
        }
    }

    private func performWrite(_ bytes: Data, generation: UInt64, timeout: TimeInterval) async throws {
        guard connected, currentGeneration == generation else {
            throw SerializedWriterError.staleGeneration(
                expected: generation,
                actual: currentGeneration
            )
        }

        let transport = self.transport
        let clock = self.clock
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await transport.writeCommand(bytes)
                }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    throw SerializedWriterError.timedOut(seconds: Int(timeout))
                }

                guard let first = await group.nextResult() else {
                    throw SerializedWriterError.cancelled
                }
                group.cancelAll()
                // A successful native write cancels the timeout child. Drain
                // that expected CancellationError so task-group scope exit
                // cannot turn a confirmed write into a spurious failure.
                while await group.nextResult() != nil {}
                try first.get()
            }
        } catch let error as SerializedWriterError {
            if case .timedOut = error {
                await diagnostics.append(.timeout(generation: generation))
            }
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let transportError = error as? TransportError, transportError.isBondFailure {
                throw SerializedWriterError.bondFailure(transportError)
            }
            throw SerializedWriterError.transport(String(describing: error))
        }

        guard connected, currentGeneration == generation else {
            throw SerializedWriterError.staleGeneration(
                expected: generation,
                actual: currentGeneration
            )
        }
    }
}

public enum InitializationCommandSequence {
    public static let spacing: TimeInterval = 0.120
}

/// Clock decisions are kept separate from transport and persistence.  The
/// values are the Edge parity defaults named by Gate D; no unpinned tolerance
/// or fabricated timestamp is introduced here.
public enum ClockDisciplineDecision: Equatable, Sendable {
    case accepted(ClockCorrelation)
    case requiresCorrection(ClockCorrelation)
    case rejectedFuture
    case rejectedPreEpoch
    case correctionLimitReached
}

public struct ClockCorrelation: Equatable, Sendable {
    public let bandDate: Date
    public let wallDate: Date
    public let offsetSeconds: TimeInterval

    public init(bandDate: Date, wallDate: Date) {
        self.bandDate = bandDate
        self.wallDate = wallDate
        self.offsetSeconds = wallDate.timeIntervalSince(bandDate)
    }
}

/// The exact two-command clock exchange used by Gate D. Whole Unix seconds
/// are encoded as u32 little-endian and the fractional millisecond is floored
/// into the pinned 32,768 Hz u16 tick unit.
public struct ClockCommandSequence: Equatable, Sendable {
    public let setClock: Data
    public let getClock: Data
    public let unixSeconds: UInt32
    public let subsecondTicks: UInt16

    public init(
        wallDate: Date,
        setSequence: UInt8,
        getSequence: UInt8
    ) throws {
        let milliseconds = Int64((wallDate.timeIntervalSince1970 * 1_000).rounded(.down))
        let seconds = milliseconds.dividedReportingOverflow(by: 1_000)
        guard !seconds.overflow, seconds.partialValue >= 0,
              seconds.partialValue <= Int64(UInt32.max) else {
            throw ClockSequenceError.unrepresentableDate
        }
        let millisRemainder = milliseconds - (seconds.partialValue * 1_000)
        let ticks = (millisRemainder * 32_768) / 1_000
        guard ticks >= 0, ticks <= Int64(UInt16.max) else {
            throw ClockSequenceError.unrepresentableDate
        }

        unixSeconds = UInt32(seconds.partialValue)
        subsecondTicks = UInt16(ticks)
        setClock = try CommandBuilder.setClock(
            sequence: setSequence,
            unixSeconds: unixSeconds,
            subsecondTicks: subsecondTicks
        )
        getClock = try CommandBuilder.getClock(sequence: getSequence)
    }
}

/// A parsed GET_CLOCK response. The response payload layout has varied across
/// firmware revisions, so parsing is intentionally conservative: only a
/// plausible little-endian Unix timestamp is accepted, while the command
/// opcode and the echo of our sequence byte are retained for correlation.
public struct ClockResponse: Equatable, Sendable {
    /// The echo of the sequence byte we sent, not the band's own counter.
    public let sequence: UInt8?
    public let opcode: UInt8?
    public let bandDate: Date
    /// The band RTC's subsecond remainder in 1/32768 s units, when the reply
    /// carries one.  `bandDate` stays on the whole second so every existing
    /// correlation keeps its meaning.
    public let subsecondTicks: UInt16?
    public let payload: Data

    public init(
        sequence: UInt8?,
        opcode: UInt8?,
        bandDate: Date,
        subsecondTicks: UInt16? = nil,
        payload: Data
    ) {
        self.sequence = sequence
        self.opcode = opcode
        self.bandDate = bandDate
        self.subsecondTicks = subsecondTicks
        self.payload = Data(payload)
    }

    public static let minimumUnixSeconds: UInt32 = 1_700_000_000
    public static let maximumUnixSeconds: UInt32 = 4_102_444_800 // 2100-01-01

    /// Parses either a complete Gen 4 frame, a command-response inner packet,
    /// or the response payload after its 0x24 discriminator.
    public static func parse(_ raw: Data, wallDate: Date = Date()) throws -> Self {
        let payload: Data
        if raw.first == Gen4Frame.marker {
            payload = try PacketDecoder().decode(try FrameDecoder().decode(raw)).payload
        } else if raw.first == PacketType.commandResponse.rawValue {
            payload = try PacketDecoder().decode(raw).payload
        } else {
            payload = Data(raw)
        }
        guard payload.count >= 4 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: payload.count,
                reason: "truncated GET_CLOCK response"
            )
        }

        // The command-response payload after the 0x24 discriminator is
        // [band counter, opcode, sequence echo, status, u32 seconds,
        // u16 subsecond ticks, ...]. Captured on a real WHOOP 4.0 on
        // 2026-09-21: GET_CLOCK sent with sequence 0x61 answered
        // `d6 0b 61 01 a9 52 b1 6a 00 46 00 00 00 00 00`, where 0x6ab152a9 is
        // the correct wall-clock second and 0x4600 is 0.547 s of RTC ticks.
        //
        // Byte 0 is the band's own rolling packet counter, not our sequence;
        // the reference labels it `seq` and reads the timestamp two bytes too
        // early, which decodes header bytes as the top of the epoch.
        //
        // Do not scan overlapping four-byte windows: adjacent header bytes can
        // accidentally form a different but plausible Unix timestamp one byte
        // before the real field. Only the two non-overlapping layouts below
        // are tried, the full response first.
        let timestampOffset: Int
        let sequence: UInt8?
        let opcode: UInt8?
        if payload.count >= 8, isPlausible(payload, offset: 4) {
            timestampOffset = 4
            sequence = payload[2]
            opcode = payload[1]
        } else if isPlausible(payload, offset: 0) {
            // Bare payload fallback: callers that hand over just the timestamp
            // field, and replay fixtures that predate the hardware capture.
            timestampOffset = 0
            sequence = nil
            opcode = nil
        } else {
            throw ProtocolDecodeError.invalidValue(
                offset: payload.count >= 8 ? 4 : 0,
                reason: "GET_CLOCK response contains an invalid Unix timestamp"
            )
        }
        let timestamp = readUInt32LE(payload, offset: timestampOffset)
        // Ticks are only claimed for the full response layout. A bare payload
        // carries no header, so there is nothing to say the bytes after the
        // timestamp are the RTC remainder.
        let ticksOffset = timestampOffset + 4
        let subsecondTicks: UInt16? = timestampOffset == 4 && payload.count >= ticksOffset + 2
            ? UInt16(payload[ticksOffset]) | (UInt16(payload[ticksOffset + 1]) << 8)
            : nil
        return Self(
            sequence: sequence,
            opcode: opcode,
            bandDate: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            subsecondTicks: subsecondTicks,
            payload: payload
        )
    }

    private static func readUInt32LE(_ payload: Data, offset: Int) -> UInt32 {
        UInt32(payload[offset])
            | (UInt32(payload[offset + 1]) << 8)
            | (UInt32(payload[offset + 2]) << 16)
            | (UInt32(payload[offset + 3]) << 24)
    }

    private static func isPlausible(_ payload: Data, offset: Int) -> Bool {
        guard payload.count >= offset + 4 else { return false }
        return (minimumUnixSeconds...maximumUnixSeconds).contains(
            readUInt32LE(payload, offset: offset)
        )
    }
}

public enum ClockSequenceError: Error, Equatable, Sendable {
    case unrepresentableDate
}

/// Sends SET_CLOCK followed by GET_CLOCK through the serialized writer. The
/// writer remains the final generation/firewall boundary for both commands.
public actor ClockExchange {
    private let writer: SerializedGenerationPinnedWriter

    public init(writer: SerializedGenerationPinnedWriter) {
        self.writer = writer
    }

    public func send(
        wallDate: Date,
        generation: UInt64,
        setSequence: UInt8 = 0xA0,
        getSequence: UInt8 = 0xA1,
        setupFirstWrite: Bool = false,
        onSetClockWritten: (@Sendable () async -> Void)? = nil
    ) async throws -> ClockCommandSequence {
        let sequence = try ClockCommandSequence(
            wallDate: wallDate,
            setSequence: setSequence,
            getSequence: getSequence
        )
        try await writer.write(
            .setClock(
                sequence: setSequence,
                unixSeconds: sequence.unixSeconds,
                subsecondTicks: sequence.subsecondTicks
            ),
            generation: generation,
            timeout: setupFirstWrite ? SerializedGenerationPinnedWriter.firstSetupWriteTimeout : SerializedGenerationPinnedWriter.writeTimeout
        )
        await onSetClockWritten?()
        try await writer.write(
            .getClock(sequence: getSequence),
            generation: generation
        )
        return sequence
    }
}

/// Stateful clock policy used by the session coordinator.  `evaluate` never
/// sends a correction itself; the caller must explicitly choose to issue the
/// typed SET_CLOCK command through the final writer.
public struct ClockDiscipline: Equatable, Sendable {
    public static let minimumBandDate = Date(timeIntervalSince1970: 1_700_000_000)
    public static let maximumFutureSkew: TimeInterval = 86_400
    public static let maximumCorrectionsPerConnection = 3
    public static let recheckInterval: TimeInterval = 6 * 60 * 60

    public private(set) var correlation: ClockCorrelation?
    public private(set) var correctionCount: Int = 0

    public init() {}

    public mutating func evaluate(
        bandDate: Date,
        wallDate: Date
    ) -> ClockDisciplineDecision {
        if bandDate < Self.minimumBandDate {
            correlation = ClockCorrelation(bandDate: bandDate, wallDate: wallDate)
            guard correctionCount < Self.maximumCorrectionsPerConnection else {
                return .correctionLimitReached
            }
            correctionCount += 1
            return .requiresCorrection(correlation!)
        }
        if bandDate.timeIntervalSince(wallDate) > Self.maximumFutureSkew {
            return .rejectedFuture
        }

        let next = ClockCorrelation(bandDate: bandDate, wallDate: wallDate)
        correlation = next
        let drift = abs(next.offsetSeconds)
        if drift > Self.maximumFutureSkew {
            guard correctionCount < Self.maximumCorrectionsPerConnection else {
                return .correctionLimitReached
            }
            correctionCount += 1
            return .requiresCorrection(next)
        }
        // A stable read starts a fresh correction budget for this connection.
        // This matches Edge's stable-read reset and prevents an earlier stale
        // clock from permanently suppressing later legitimate correction.
        correctionCount = 0
        return .accepted(next)
    }

    public mutating func evaluate(
        response: ClockResponse,
        wallDate: Date
    ) -> ClockDisciplineDecision {
        evaluate(bandDate: response.bandDate, wallDate: wallDate)
    }

    public mutating func evaluate(
        responseData: Data,
        wallDate: Date
    ) throws -> ClockDisciplineDecision {
        evaluate(response: try ClockResponse.parse(responseData, wallDate: wallDate), wallDate: wallDate)
    }

    /// Confirms that the current correction decision may be sent as SET_CLOCK.
    /// The budget is consumed when `evaluate` returns
    /// `.requiresCorrection`, so repeated readbacks cannot exceed the cap.
    public mutating func recordCorrection() -> Bool {
        correctionCount <= Self.maximumCorrectionsPerConnection
    }

    public func shouldRecheck(now: Date) -> Bool {
        guard let correlation else { return false }
        return now.timeIntervalSince(correlation.wallDate) >= Self.recheckInterval
    }

    public func recheckDue(now: Date) -> Bool {
        shouldRecheck(now: now)
    }

    public mutating func disconnect() {
        correlation = nil
        correctionCount = 0
    }
}
