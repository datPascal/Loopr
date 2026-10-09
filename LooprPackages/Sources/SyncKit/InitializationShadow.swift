import Foundation
import BluetoothKit
import ProtocolKit

/// The three inbound characteristics that must be confirmed before Gate E
/// initialization is allowed to write.
public enum ShadowInboundCharacteristic: String, CaseIterable, Hashable, Sendable {
    case response
    case events
    case data
}

public enum ShadowInitializationError: Error, Equatable, Sendable, LocalizedError {
    case subscriptionsIncomplete(missing: Set<ShadowInboundCharacteristic>)
    case alreadyStarted
    case sessionBoundReached
    case staleGeneration(expected: UInt64, actual: UInt64?)
    case disconnected
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .subscriptionsIncomplete(let missing):
            return "initialization blocked until inbound subscriptions confirm: \(missing.map(\.rawValue).sorted().joined(separator: ","))"
        case .alreadyStarted: return "shadow initialization already started"
        case .sessionBoundReached: return "shadow initialization session bound reached"
        case .staleGeneration(let expected, let actual):
            return "shadow generation \(expected) is stale (current \(actual.map(String.init) ?? "none"))"
        case .disconnected: return "shadow initialization transport is disconnected"
        case .archiveFailed(let reason): return "shadow archive failed: \(reason)"
        }
    }
}

/// No health payload is retained by diagnostics.  The archive sink receives
/// the raw frame separately so a controlled replay can persist evidence while
/// logs remain metadata-only.
public enum ShadowPacketClass: String, Equatable, Sendable {
    case historyStart
    case historicalRecord
    case historyEnd
    case historyComplete
    case historyMetadata
    case commandResponse
    case event
    case live
    case unknown
    case malformed
}

/// The marker fields that are safe to expose from shadow mode.  The token is
/// retained as an opaque value in source order; packet-count metadata remains
/// diagnostic and never participates in ACK authorization.
public struct ShadowHistoryMarker: Equatable, Sendable {
    public let packetClass: ShadowPacketClass
    public let expectedPacketCount: UInt32?
    public let token: HistoryToken?

    public init(
        packetClass: ShadowPacketClass,
        expectedPacketCount: UInt32? = nil,
        token: HistoryToken? = nil
    ) {
        self.packetClass = packetClass
        self.expectedPacketCount = expectedPacketCount
        self.token = token
    }
}

public struct ShadowDiagnostic: Equatable, Sendable {
    public let characteristic: ShadowInboundCharacteristic
    public let packetClass: ShadowPacketClass
    public let crcValid: Bool
    public let sequence: UInt8?
    public let receivedAt: Date

    public init(
        characteristic: ShadowInboundCharacteristic,
        packetClass: ShadowPacketClass,
        crcValid: Bool,
        sequence: UInt8? = nil,
        receivedAt: Date
    ) {
        self.characteristic = characteristic
        self.packetClass = packetClass
        self.crcValid = crcValid
        self.sequence = sequence
        self.receivedAt = receivedAt
    }
}

public actor ShadowDiagnostics {
    private let capacity: Int
    private var eventsStorage: [ShadowDiagnostic] = []

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    public func append(_ event: ShadowDiagnostic) {
        eventsStorage.append(event)
        if eventsStorage.count > capacity {
            eventsStorage.removeFirst(eventsStorage.count - capacity)
        }
    }

    public func events() -> [ShadowDiagnostic] { eventsStorage }
}

/// The archive seam is deliberately separate from diagnostics.  A production
/// implementation can write the frame into a redacted/replay ledger; the
/// diagnostic stream never receives the payload bytes.
public protocol ShadowArchiveSink: Sendable {
    func archive(frame: Data, packetClass: ShadowPacketClass) async throws
}

public struct NullShadowArchive: ShadowArchiveSink, Sendable {
    public init() {}
    public func archive(frame: Data, packetClass: ShadowPacketClass) async throws {}
}

/// A single ordered queue for all inbound characteristics.  Metadata and
/// records are appended by the same actor, preserving delivery order across
/// response/events/data notifications.
public actor OrderedShadowHistoryQueue {
    public struct Item: Equatable, Sendable {
        public let characteristic: ShadowInboundCharacteristic
        public let packetClass: ShadowPacketClass
        public let sequence: UInt64

        public init(
            characteristic: ShadowInboundCharacteristic,
            packetClass: ShadowPacketClass,
            sequence: UInt64
        ) {
            self.characteristic = characteristic
            self.packetClass = packetClass
            self.sequence = sequence
        }
    }

    private var items: [Item] = []
    private var nextSequence: UInt64 = 0

    public init() {}

    @discardableResult
    public func append(
        characteristic: ShadowInboundCharacteristic,
        packetClass: ShadowPacketClass
    ) -> Item {
        let item = Item(
            characteristic: characteristic,
            packetClass: packetClass,
            sequence: nextSequence
        )
        nextSequence &+= 1
        items.append(item)
        return item
    }

    public func drain() -> [Item] {
        let result = items
        items.removeAll(keepingCapacity: true)
        return result
    }

    public func count() -> Int { items.count }

    public func reset() {
        items.removeAll(keepingCapacity: true)
        nextSequence = 0
    }
}

public struct ShadowInitializationResult: Equatable, Sendable {
    public let generation: UInt64
    public let commands: [Data]
    public let disconnectRequested: Bool

    public init(generation: UInt64, commands: [Data], disconnectRequested: Bool) {
        self.generation = generation
        self.commands = commands
        self.disconnectRequested = disconnectRequested
    }
}

/// Gate E's no-ACK initialization/session coordinator.  It emits only the
/// five pinned setup commands; history ACK construction is intentionally not a
/// capability of this type.
public actor InitializationShadowSession {
    public static let commandSpacing: TimeInterval = 0.120

    private let sendCommand: @Sendable (ProductionCommand) async throws -> Void
    private let disconnectTransport: @Sendable () async -> Void
    private let beginWriter: (@Sendable (UInt64) async throws -> Void)?
    private let generationWriter: SerializedGenerationPinnedWriter?
    private let clock: any BLEClock
    public let diagnostics: ShadowDiagnostics
    public let orderedQueue: OrderedShadowHistoryQueue
    private let archive: any ShadowArchiveSink
    private let maxRecords: Int
    private let maxDuration: TimeInterval
    private var confirmed: Set<ShadowInboundCharacteristic> = []
    private var started = false
    private var disconnected = false
    private var stoppedForBound = false
    private var generation: UInt64?
    private var startedAt: Date?
    private var recordsSeen = 0
    private var historyEndTokens: [HistoryToken] = []
    private var boundTask: Task<Void, Never>?

    public init(
        transport: any CommandWriteTransport,
        clock: any BLEClock = SystemBLEClock(),
        diagnostics: ShadowDiagnostics = ShadowDiagnostics(),
        orderedQueue: OrderedShadowHistoryQueue = OrderedShadowHistoryQueue(),
        archive: any ShadowArchiveSink = NullShadowArchive(),
        maxRecords: Int = 10_000,
        maxDuration: TimeInterval = 600
    ) {
        let writer = ProductionCommandWriter()
        self.sendCommand = { command in
            try await transport.writeCommand(try writer.encode(command))
        }
        self.disconnectTransport = {
            await transport.disconnect()
        }
        self.beginWriter = nil
        self.generationWriter = nil
        self.clock = clock
        self.diagnostics = diagnostics
        self.orderedQueue = orderedQueue
        self.archive = archive
        self.maxRecords = max(1, maxRecords)
        self.maxDuration = max(0, maxDuration)
    }

    /// Production overload that routes every setup write through the
    /// generation-pinned serialized writer. The writer owns the final command
    /// encoding/firewall and waits for write-with-response before the next
    /// command is emitted. (Pinned Edge source: `ble_engine.dart`, `_write`.)
    public init(
        writer: SerializedGenerationPinnedWriter,
        clock: any BLEClock = SystemBLEClock(),
        diagnostics: ShadowDiagnostics = ShadowDiagnostics(),
        orderedQueue: OrderedShadowHistoryQueue = OrderedShadowHistoryQueue(),
        archive: any ShadowArchiveSink = NullShadowArchive(),
        maxRecords: Int = 10_000,
        maxDuration: TimeInterval = 600
    ) {
        self.sendCommand = { command in
            // The generation-pinned branch below is selected for this
            // initializer. Keep the fallback closed rather than ever sending
            // a command with an invented generation.
            _ = command
            throw ShadowInitializationError.disconnected
        }
        self.disconnectTransport = {
            await writer.disconnect()
        }
        self.beginWriter = { generation in
            try await writer.begin(generation: generation)
        }
        self.generationWriter = writer
        self.clock = clock
        self.diagnostics = diagnostics
        self.orderedQueue = orderedQueue
        self.archive = archive
        self.maxRecords = max(1, maxRecords)
        self.maxDuration = max(0, maxDuration)
    }

    public func confirmSubscription(_ characteristic: ShadowInboundCharacteristic) {
        confirmed.insert(characteristic)
    }

    public func confirmedSubscriptions() -> Set<ShadowInboundCharacteristic> { confirmed }

    public func missingSubscriptions() -> Set<ShadowInboundCharacteristic> {
        Set(ShadowInboundCharacteristic.allCases).subtracting(confirmed)
    }

    public func isStarted() -> Bool { started }

    /// Exact end tokens observed during this shadow session.  Returning value
    /// types prevents a caller from mutating any parser/storage state.
    public func capturedHistoryEndTokens() -> [HistoryToken] { historyEndTokens }

    public func start(generation: UInt64) async throws -> ShadowInitializationResult {
        guard !started else { throw ShadowInitializationError.alreadyStarted }
        let missing = missingSubscriptions()
        guard missing.isEmpty else {
            throw ShadowInitializationError.subscriptionsIncomplete(missing: missing)
        }
        guard !disconnected else {
            throw stoppedForBound
                ? ShadowInitializationError.sessionBoundReached
                : ShadowInitializationError.disconnected
        }

        if let beginWriter {
            do {
                try await beginWriter(generation)
            } catch {
                throw ShadowInitializationError.staleGeneration(
                    expected: generation,
                    actual: nil
                )
            }
        }

        self.generation = generation
        started = true
        startedAt = clock.now()
        scheduleBoundMonitor()

        let writer = ProductionCommandWriter()
        let commands: [ProductionCommand] = [
            .hello(sequence: 0),
            .advertisingName(sequence: 1),
            .dataRange(sequence: 2),
            .alarmTime(sequence: 3),
            .startHistoricalData(sequence: 4)
        ]
        var bytes: [Data] = []
        for (index, command) in commands.enumerated() {
            guard self.generation == generation else {
                throw ShadowInitializationError.staleGeneration(
                    expected: generation,
                    actual: self.generation
                )
            }
            guard !disconnected else {
                throw stoppedForBound
                    ? ShadowInitializationError.sessionBoundReached
                    : ShadowInitializationError.disconnected
            }
            guard !boundReached(now: clock.now()) else {
                try await stopForBound()
                throw ShadowInitializationError.sessionBoundReached
            }

            let encoded = try writer.encode(command)
            if let generationWriter {
                try await generationWriter.write(command, generation: generation)
            } else {
                try await sendCommand(command)
            }
            guard self.generation == generation else {
                throw ShadowInitializationError.staleGeneration(
                    expected: generation,
                    actual: self.generation
                )
            }
            guard !disconnected else {
                throw stoppedForBound
                    ? ShadowInitializationError.sessionBoundReached
                    : ShadowInitializationError.disconnected
            }
            bytes.append(encoded)

            if index < commands.count - 1 {
                try await clock.sleep(for: Self.commandSpacing)
                guard self.generation == generation else {
                    throw ShadowInitializationError.staleGeneration(
                        expected: generation,
                        actual: self.generation
                    )
                }
                guard !disconnected else {
                    throw stoppedForBound
                        ? ShadowInitializationError.sessionBoundReached
                        : ShadowInitializationError.disconnected
                }
            }
        }
        return ShadowInitializationResult(
            generation: generation,
            commands: bytes,
            disconnectRequested: false
        )
    }

    /// Feeds one complete Gen 4 frame.  The frame is archived through the
    /// explicit sink, while only packet class/CRC/sequence enter diagnostics.
    @discardableResult
    public func receive(
        _ frame: Data,
        characteristic: ShadowInboundCharacteristic,
        receivedAt: Date = Date()
    ) async throws -> ShadowPacketClass {
        guard started, let generation else { throw ShadowInitializationError.alreadyStarted }
        guard !stoppedForBound else { throw ShadowInitializationError.sessionBoundReached }
        guard !disconnected else { throw ShadowInitializationError.disconnected }
        guard !boundReached(now: clock.now()) else {
            try await stopForBound()
            throw ShadowInitializationError.sessionBoundReached
        }

        let decoder = FrameDecoder()
        let decodedFrame: Frame
        do {
            decodedFrame = try decoder.decode(frame)
        } catch {
            let event = ShadowDiagnostic(
                characteristic: characteristic,
                packetClass: .malformed,
                crcValid: false,
                receivedAt: receivedAt
            )
            await diagnostics.append(event)
            await orderedQueue.append(characteristic: characteristic, packetClass: .malformed)
            try await archive.archive(frame: Data(frame), packetClass: .malformed)
            return .malformed
        }

        let packet: DecodedPacket
        do {
            packet = try PacketDecoder.decode(decodedFrame.paddedInner)
        } catch {
            let event = ShadowDiagnostic(
                characteristic: characteristic,
                packetClass: .malformed,
                crcValid: true,
                receivedAt: receivedAt
            )
            await diagnostics.append(event)
            await orderedQueue.append(characteristic: characteristic, packetClass: .malformed)
            try await archive.archive(frame: Data(frame), packetClass: .malformed)
            return .malformed
        }

        let classification = Self.classify(packet)
        let sequence = Self.commandSequence(packet)
        await diagnostics.append(ShadowDiagnostic(
            characteristic: characteristic,
            packetClass: classification,
            crcValid: true,
            sequence: sequence,
            receivedAt: receivedAt
        ))
        await orderedQueue.append(characteristic: characteristic, packetClass: classification)
        try await archive.archive(frame: Data(frame), packetClass: classification)

        if let marker = Self.historyMarker(in: packet), let token = marker.token {
            historyEndTokens.append(token)
        }

        if classification == .historicalRecord { recordsSeen += 1 }
        if boundReached(now: clock.now()) {
            try await stopForBound()
        }
        _ = generation // explicitly keep the current session pinned across awaits
        return classification
    }

    public func disconnect() async {
        guard !disconnected else { return }
        disconnected = true
        boundTask?.cancel()
        boundTask = nil
        await disconnectTransport()
    }

    /// Explicitly evaluates the injected clock bound. Production also has an
    /// autonomous wall-clock watchdog; this method keeps deterministic replay
    /// clocks able to force the same boundary without delivering another frame.
    public func checkBounds() async throws {
        guard started, !disconnected else { return }
        guard boundReached(now: clock.now()) else { return }
        try await stopForBound()
    }

    private func boundReached(now: Date) -> Bool {
        if recordsSeen >= maxRecords { return true }
        guard let startedAt else { return false }
        guard maxDuration > 0 else { return false }
        return now.timeIntervalSince(startedAt) >= maxDuration
    }

    private func stopForBound() async throws {
        if !disconnected {
            stoppedForBound = true
            disconnected = true
            boundTask?.cancel()
            boundTask = nil
            await disconnectTransport()
        }
    }

    private func scheduleBoundMonitor() {
        guard maxDuration > 0 else { return }
        boundTask?.cancel()
        let nanoseconds = UInt64(maxDuration * 1_000_000_000)
        boundTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireWallClockBound()
        }
    }

    private func expireWallClockBound() async {
        guard started, !disconnected else { return }
        // The watchdog elapsed the configured wall-clock duration. It is
        // intentionally independent of an injected/frozen BLEClock so a live
        // shadow session cannot remain unbounded when notifications stop.
        stoppedForBound = true
        disconnected = true
        boundTask = nil
        await disconnectTransport()
    }


    private static func classify(_ packet: DecodedPacket) -> ShadowPacketClass {
        switch packet {
        case .historyMetadata(let payload):
            // Payload is the bytes following 0x31.  The pinned metadata
            // layout carries subtype at payload[1]: 1=start, 2=end, 3=complete.
            guard payload.count > 1 else { return .historyMetadata }
            switch payload[1] {
            case 1: return .historyStart
            case 2: return .historyEnd
            case 3: return .historyComplete
            default: return .historyMetadata
            }
        case .historicalRecord: return .historicalRecord
        case .commandResponse: return .commandResponse
        case .event: return .event
        case .compactLiveHeartRate, .realtimeRaw, .realtimeIMU: return .live
        case .console: return .unknown
        case .unknown: return .unknown
        }
    }

    /// Parses only the pinned marker envelope.  For HISTORY_END, the token is
    /// exactly payload[12..<20] (inner[13..<21]) and is never normalized.
    public static func historyMarker(in packet: DecodedPacket) -> ShadowHistoryMarker? {
        guard case .historyMetadata(let payload) = packet,
              payload.count > 1 else { return nil }
        let packetClass: ShadowPacketClass
        switch payload[1] {
        case 1: packetClass = .historyStart
        case 2: packetClass = .historyEnd
        case 3: packetClass = .historyComplete
        default: return ShadowHistoryMarker(packetClass: .historyMetadata)
        }

        // The expected packet count is the u32 little-endian field at inner
        // offset 9, i.e. payload offset 8.  It is optional metadata only.
        let expectedPacketCount: UInt32? = payload.count >= 12
            ? UInt32(payload[8])
                | (UInt32(payload[9]) << 8)
                | (UInt32(payload[10]) << 16)
                | (UInt32(payload[11]) << 24)
            : nil
        let token: HistoryToken?
        if packetClass == .historyEnd, payload.count >= 20 {
            token = try? HistoryToken(bytes: Data(payload[12..<20]))
        } else {
            token = nil
        }
        return ShadowHistoryMarker(
            packetClass: packetClass,
            expectedPacketCount: expectedPacketCount,
            token: token
        )
    }

    /// The echo of the sequence byte we sent, which a `0x24` payload carries at
    /// offset 2. Offset 0 is the band's own rolling packet counter; reading it
    /// here labelled every diagnostic with a number we never sent.
    private static func commandSequence(_ packet: DecodedPacket) -> UInt8? {
        guard case .commandResponse(let bytes) = packet, bytes.count >= 3 else {
            return nil
        }
        return bytes[bytes.startIndex + 2]
    }
}
