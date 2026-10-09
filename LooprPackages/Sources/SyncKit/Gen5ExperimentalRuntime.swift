import Foundation
import BluetoothKit
import ProtocolKit
import StorageKit

/// The fd4b path shares the app's one native transport owner with Gen 4, but
/// cannot pass through Gen 4's Harvard setup or command encoder.
public actor Gen5ExperimentalRuntime {
    private let transport: any BLETransport
    private let peripheral: PeripheralID
    private let model: BandModel
    private let wire: Gen5WireWriter
    private let history: HistoryCoordinator
    private let live: LiveStreamManager
    private var frameDecoders: [CharacteristicID: Gen5FrameStreamDecoder] = [:]
    private let recordDecoder = Gen5RecordDecoder()
    private var stream: AsyncStream<BluetoothAdoptionRuntimeState>?
    private var continuation: AsyncStream<BluetoothAdoptionRuntimeState>.Continuation?
    private var observation: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var running = false
    private var generation: UInt64 = 1
    private var session: TransportSessionIdentity?
    private var connection: BluetoothConnectionState = .idle
    private var radio: ConnectionRadioState = .unknown
    private var subscribed: Set<CharacteristicID> = []
    private var setupReady = false
    private var setupComplete = false
    private var burstOpen = false
    private var historyBufferedItems = 0
    private var lastError: String?
    private var charging: Bool?
    private var onWrist: Bool?
    private var sharingReplies: [UInt8: CheckedContinuation<Data, any Error>] = [:]
    private var sharingWriteInProgress = false
    private var eventContinuations: [UUID: AsyncStream<BandEventEnvelope>.Continuation] = [:]
    private var batteryPercentage: Double?
    private var lastPacketAt: Date?
    private var historyCommitAt: Date?
    private var completedSyncAt: Date?
    private var lastHistoryAcknowledgementAt: Date?
    private var historyAckFailed = false
    private var validFrames: UInt64 = 0
    private var corruptFrames: UInt64 = 0

    public init(transport: any BLETransport, peripheral: PeripheralID, model: BandModel, store: any HistoryBatchStore) {
        self.transport = transport
        self.peripheral = peripheral
        self.model = model
        let wire = Gen5WireWriter(transport: transport)
        self.wire = wire
        self.live = LiveStreamManager(commandSink: Gen5LiveCommandSink(wire: wire))
        self.history = HistoryCoordinator(
            store: store,
            transport: Gen5HistoryTransport(transport: transport),
            generationPinnedACKWriter: { sequence, token, generation in
                // OpenStrap protocol@c525e29e:lib/src/control.dart:670-711
                // supplies the exact 8-byte token; HistoryCoordinator commits
                // before this closure is called.
                try await wire.write(.historyAcknowledgement(token.persistedBytes), sequence: sequence, generation: generation)
            }
        )
    }

    public func states() -> AsyncStream<BluetoothAdoptionRuntimeState> {
        if let stream { return stream }
        let pair = AsyncStream<BluetoothAdoptionRuntimeState>.makeStream(bufferingPolicy: .bufferingNewest(32))
        stream = pair.stream
        continuation = pair.continuation
        return pair.stream
    }

    public func currentState() async -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: running, generation: running ? generation : nil,
            connection: connection, setupReady: setupReady, setupComplete: setupComplete,
            radioState: radio,
            health: ConnectionHealthReport(
                healthy: setupReady, stale: false, shouldBounce: false,
                ageOfLatestObservation: lastPacketAt.map { Date().timeIntervalSince($0) },
                corruptionRate: validFrames + corruptFrames == 0 ? 0 : Double(corruptFrames) / Double(validFrames + corruptFrames),
                reasons: []
            ),
            pendingReconnect: nil, liveConsumerCount: await live.totalConsumerCount(),
            pendingHistoryReplayCount: 0, validFrameCount: validFrames,
            corruptFrameCount: corruptFrames, writeTimeoutCount: 0,
            lastError: lastError, charging: charging, onWrist: onWrist, batteryPercentage: batteryPercentage,
            lastPacketAt: lastPacketAt, historyCommitAt: historyCommitAt,
            completedSyncAt: completedSyncAt, historyOffloadActive: burstOpen,
            bandModel: model
        )
    }

    public func start() async {
        guard !running else { return }
        running = true
        let events = transport.events()
        observation = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    public func stop() async {
        running = false
        clearBandState()
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
        retry?.cancel()
        observation?.cancel()
        await wire.invalidate()
        await live.reset()
        await transport.disconnect()
        connection = .idle
        setupReady = false
        setupComplete = false
        await emit()
        continuation?.finish()
    }

    public func enterForeground() async {
        await live.setBackgroundPolicy(.foreground)
        if running && !setupReady { await connect() }
    }

    public func enterBackground() async { await live.setBackgroundPolicy(.ordinaryBackground) }

    public func runBackgroundSync(maxDuration: TimeInterval) async -> Bool {
        guard setupReady, maxDuration > 0 else { return false }
        let startedAt = Date()
        let sessionGeneration = generation
        historyAckFailed = false
        do {
            try await wire.write(.dataRange, generation: generation)
            // OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:2794-2796.
            try await Task.sleep(for: .milliseconds(120))
            try await wire.write(.sendHistory, generation: generation)
        } catch {
            lastError = String(describing: error)
            await emit()
            return false
        }
        let deadline = startedAt.addingTimeInterval(maxDuration)
        while !Task.isCancelled && Date() < deadline {
            if historyAckFailed || generation != sessionGeneration || !setupReady { return false }
            if let completedSyncAt, completedSyncAt >= startedAt { return true }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { break }
        }
        // A drain can exceed a bounded background window. A committed and
        // acknowledged chunk is still real progress, even if COMPLETE has
        // not arrived when the window ends.
        return lastHistoryAcknowledgementAt.map { $0 >= startedAt } ?? false
    }

    public func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        guard setupReady, kind == .compactHeartRateRR else { throw LiveStreamError.generationUnavailable }
        return try await live.acquire(kind: kind, consumer: consumer)
    }

    public func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        guard setupReady, kind == .compactHeartRateRR else { throw LiveStreamError.generationUnavailable }
        return try await live.acquireEventStream(kind: kind, consumer: consumer, generation: generation)
    }

    public func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        await live.bufferedSamples(for: kind)
    }

    public func bandEvents() -> AsyncStream<BandEventEnvelope> {
        let id = UUID()
        let pair = AsyncStream<BandEventEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(16))
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return pair.stream
    }

    private func removeEventContinuation(_ id: UUID) { eventContinuations.removeValue(forKey: id) }

    public func setHeartRateSharing(enabled: Bool) async throws -> Bool? {
        guard running, setupReady, radio == .poweredOn, !sharingWriteInProgress else {
            throw BandCommandError.notReady
        }
        sharingWriteInProgress = true
        defer { sharingWriteInProgress = false }
        let expected = generation
        try await wire.write(.heartRateSharing(enabled), generation: expected)
        guard generation == expected, setupReady else { throw BandCommandError.notReady }
        return try await readHeartRateSharing()
    }

    public func readHeartRateSharing() async throws -> Bool? {
        guard running, setupReady, radio == .poweredOn else { throw BandCommandError.notReady }
        let expected = generation
        let sequence = await wire.reserveSequence()
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            sharingReplies[sequence] = continuation
            Task { [weak self] in
                await self?.readSharing(sequence: sequence, generation: expected)
            }
        }
        guard generation == expected, setupReady else { throw BandCommandError.notReady }
        return try HeartRateSharingCommand.decodeGen5Readback(reply, sequence: sequence)
    }

    private func readSharing(sequence: UInt8, generation expected: UInt64) async {
        do {
            try await wire.write(.heartRateSharingRead, sequence: sequence, generation: expected)
            try await Task.sleep(for: .seconds(6))
            if generation == expected {
                sharingReplies.removeValue(forKey: sequence)?.resume(throwing: BandCommandError.timedOut)
            }
        } catch {
            if generation == expected {
                sharingReplies.removeValue(forKey: sequence)?.resume(throwing: error)
            }
        }
    }

    private func clearBandState() {
        charging = nil
        onWrist = nil
        let replies = sharingReplies
        sharingReplies.removeAll()
        for reply in replies.values { reply.resume(throwing: BandCommandError.notReady) }
    }

    private func connect() async {
        guard running, radio == .poweredOn, !connection.isConnected else { return }
        connection = .retrieving(generation: generation)
        await emit()
        if let retriever = transport as? any BLEPeripheralRetriever,
           await retriever.retrieve([peripheral]).contains(peripheral) {
            connection = .connecting(generation: generation, peripheral: peripheral)
            await transport.connect(peripheral)
        } else if let scanner = transport as? any BLEPeripheralScanner {
            connection = .scanning(generation: generation, service: Gen5BluetoothProfile.service)
            await scanner.scan(for: Gen5BluetoothProfile.service)
        } else {
            connection = .connecting(generation: generation, peripheral: peripheral)
            await transport.connect(peripheral)
        }
        await emit()
    }

    private func handle(_ event: TransportEvent) async {
        guard running else { return }
        if let eventSession = event.sessionIdentity,
           !isNewConnection(event), eventSession != session { return }
        switch event {
        case .managerState(let state):
            if state == .poweredOff {
                guard radio != .poweredOff else { break }
                clearBandState()
                radio = .poweredOff
                setupReady = false
                setupComplete = false
                subscribed.removeAll()
                frameDecoders.removeAll()
                session = nil
                burstOpen = false
                generation &+= 1
                await wire.invalidate()
                await live.reset()
                try? await history.replaceGeneration(generation)
                connection = .bluetoothOff
            } else if state == .poweredOn {
                let becameReady = radio != .poweredOn
                radio = .poweredOn
                if becameReady && !connection.isConnected { await connect() }
            }
        case .discovered(let id, let services), .discoveredWithAdvertisement(let id, _, let services):
            guard id == peripheral, services.contains(Gen5BluetoothProfile.service) else { break }
            if let scanner = transport as? any BLEPeripheralScanner { await scanner.stopScan() }
            connection = .connecting(generation: generation, peripheral: peripheral)
            await transport.connect(peripheral)
        case .connected(let id):
            guard id == peripheral else { break }
            await connected(nil)
        case .connectedInSession(let identity):
            guard identity.peripheral == peripheral,
                  case .connecting = connection else { break }
            await connected(identity)
        case .servicesDiscovered(let services), .servicesDiscoveredInSession(_, let services):
            guard services.contains(Gen5BluetoothProfile.service),
                  let discoverer = transport as? any BLEGATTDiscoverer else {
                await fail("FD4B service unavailable")
                break
            }
            await discoverer.discoverCharacteristics(Array(Gen5BluetoothProfile.requiredCharacteristics))
        case .characteristicsDiscovered(let chars), .characteristicsDiscoveredInSession(_, let chars):
            let byID = Dictionary(uniqueKeysWithValues: chars.map { ($0.id, $0) })
            guard Gen5BluetoothProfile.requiredCharacteristics.allSatisfy({ byID[$0] != nil }),
                  byID[Gen5BluetoothProfile.command]?.supportsWriteWithResponse == true,
                  Gen5BluetoothProfile.inboundCharacteristics.allSatisfy({ byID[$0]?.supportsNotify == true }) else {
                await fail("FD4B characteristics unavailable")
                break
            }
            do {
                // noop@5ac2cc2a:Strand/BLE/BLEManager.swift:6530-6566:
                // with-response CLIENT_HELLO must trigger the iOS bond before
                // proprietary notification subscription.
                try await wire.write(.clientHello, sequence: 1, generation: generation)
                connection = .subscribing(generation: generation, peripheral: peripheral)
                for char in Gen5BluetoothProfile.inboundCharacteristics { await transport.setNotify(char, enabled: true) }
            } catch { await fail(String(describing: error)) }
        case .notificationStateChanged(let char, let enabled), .notificationStateChangedInSession(_, let char, let enabled):
            guard Gen5BluetoothProfile.inboundCharacteristics.contains(char) else { break }
            if enabled { subscribed.insert(char) } else { subscribed.remove(char) }
            if subscribed == Gen5BluetoothProfile.inboundCharacteristics { await ready() }
        case .value(let char, let bytes), .valueInSession(_, let char, let bytes):
            guard Gen5BluetoothProfile.inboundCharacteristics.contains(char) else { break }
            let decoder = frameDecoders[char] ?? Gen5FrameStreamDecoder()
            frameDecoders[char] = decoder
            for frame in decoder.feed(bytes) { await process(frame) }
        case .disconnected(let id, _):
            if id == peripheral { await disconnected() }
        case .disconnectedInSession(let identity, _):
            if identity.peripheral == peripheral { await disconnected() }
        case .restored(let snapshot):
            radio = snapshot.managerState == .poweredOn ? .poweredOn : .unknown
        default: break
        }
        await emit()
    }

    private func isNewConnection(_ event: TransportEvent) -> Bool {
        if case .connectedInSession = event { return true }
        return false
    }

    private func connected(_ identity: TransportSessionIdentity?) async {
        session = identity
        subscribed.removeAll()
        frameDecoders.removeAll()
        await wire.setGeneration(generation)
        connection = .discovering(generation: generation, peripheral: peripheral)
        await transport.discoverServices([Gen5BluetoothProfile.service])
    }

    private func ready() async {
        guard !setupReady else { return }
        setupReady = true
        setupComplete = true
        historyAckFailed = false
        connection = .listening(generation: generation, peripheral: peripheral)
        await live.markHistorySafetyPassed()
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:352-359,393-395.
        // GET_CLOCK is read-only; SET_CLOCK is withheld pending hardware
        // validation of the version-specific payload and readback.
        for command in [Gen5OperationalCommand.clockRead, .battery, .dataRange, .sendHistory] {
            do {
                try await wire.write(command, generation: generation)
                if command == .dataRange {
                    // OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:2794-2796.
                    try await Task.sleep(for: .milliseconds(120))
                }
            }
            catch { lastError = String(describing: error); break }
        }
    }

    private func disconnected() async {
        clearBandState()
        setupReady = false
        setupComplete = false
        burstOpen = false
        subscribed.removeAll()
        session = nil
        generation &+= 1
        await wire.invalidate()
        await live.reset()
        try? await history.replaceGeneration(generation)
        connection = .reconnecting(generation: generation)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func fail(_ message: String) async {
        lastError = message
        await transport.disconnect()
        await disconnected()
    }

    private func process(_ frame: Gen5DecodedFrame) async {
        validFrames &+= 1
        lastPacketAt = Date()
        let inner = frame.paddedInner
        guard let kind = inner.first else { return }
        switch kind {
        case PacketType.commandResponse.rawValue:
            // noop@5ac2cc2a:docs/PROTOCOL_TRANSPORT.md:160-177.
            // Only the older direct-percent form is interpreted; zero and
            // unrecognized replies leave battery absent.
            if inner.count >= 6, inner[2] == 0x1A, inner[4] == 1,
               (1...100).contains(inner[5]) { batteryPercentage = Double(inner[5]) }
            // NOOP docs/PROTOCOL_TRANSPORT.md, response prefix. Pending
            // remains open until a final result or the bounded timeout.
            if inner.count >= 5, inner[2] == 121, inner[4] != 2 {
                sharingReplies.removeValue(forKey: inner[3])?.resume(returning: inner)
            }
        case BandEventPacket.packetType:
            if let packet = try? BandEventPacket.decode(inner, model: model) {
                if let value = packet.batteryPercentage { batteryPercentage = value }
                if let value = packet.charging { charging = value }
                if let value = packet.onWrist { onWrist = value }
                let envelope = BandEventEnvelope(eventID: packet.eventID, generation: generation,
                    receivedAt: Date(), bandEpochSeconds: packet.bandEpochSeconds,
                    batteryPercentage: batteryPercentage, charging: charging, onWrist: onWrist)
                for continuation in eventContinuations.values { continuation.yield(envelope) }
            }
        case PacketType.compactLiveHeartRate.rawValue:
            await live.ingest(kind: .compactHeartRateRR, payload: Data(inner.dropFirst()), receivedAt: Date(), generation: generation)
        case PacketType.historyMetadata.rawValue:
            await processMetadata(inner)
        case PacketType.historicalRecord.rawValue:
            await processHistorical(inner)
        default: break
        }
    }

    private func ensureBurst() async {
        guard !burstOpen else { return }
        do {
            _ = try await history.beginBurst(generation: generation, receivedAt: Int64(Date().timeIntervalSince1970))
            burstOpen = true
            historyBufferedItems = 0
        } catch { lastError = String(describing: error) }
    }

    private func processMetadata(_ inner: Data) async {
        guard inner.count >= 3 else { return }
        // OpenStrap protocol@c525e29e:lib/src/control.dart:670-711:
        // sub-type is inner[2], token is inner[13..<21].
        switch inner[2] {
        case 1: await ensureBurst()
        case 2:
            guard inner.count >= 21, burstOpen,
                  let token = try? HistoryToken(Data(inner[13..<21])) else { return }
            let outcome = await history.receiveHistoryEnd(token: token, generation: generation)
            if case .acknowledged = outcome {
                historyCommitAt = Date()
                lastHistoryAcknowledgementAt = Date()
            } else { historyAckFailed = true }
            if case .rejected(let error) = outcome {
                historyAckFailed = true
                lastError = String(describing: error)
            }
            burstOpen = false
            historyBufferedItems = 0
        case 3:
            if burstOpen {
                let outcome = await history.receiveHistoryComplete(generation: generation)
                if case .completionTailCommitted = outcome {
                    historyCommitAt = Date()
                    if !historyAckFailed { completedSyncAt = Date() }
                }
                if case .rejected(let error) = outcome {
                    lastError = String(describing: error)
                }
                burstOpen = false
                historyBufferedItems = 0
            } else if !historyAckFailed {
                completedSyncAt = Date()
            }
        default:
            if burstOpen { _ = try? await history.receiveMetadata(inner, generation: generation) }
        }
    }

    private func processHistorical(_ inner: Data) async {
        await ensureBurst()
        guard burstOpen else { return }
        guard historyBufferedItems < BluetoothAdoptionRuntime.defaultHistoryBufferLimit else {
            try? await history.discardBurst(generation: generation)
            await fail("Gen 5 history chunk exceeded the buffer limit")
            return
        }
        do {
            switch try recordDecoder.decodeOrArchiveUnknown(inner) {
            case .decoded(.v18(let sample)):
                _ = try await history.receive(record: Gen5CanonicalMapping.record(from: sample, raw: inner), generation: generation)
                historyBufferedItems += 1
            case .decoded, .unknownRaw:
                try await archive(inner, reason: "Gen 5 record retained without canonical fields")
            }
        } catch {
            try? await archive(inner, reason: String(describing: error))
        }
    }

    private func archive(_ inner: Data, reason: String) async throws {
        _ = try await history.receive(archived: ArchivedHistoricalRecord(
            raw: inner, reason: reason, capturedAt: Int64(Date().timeIntervalSince1970),
            packetType: inner.first, version: inner.count > 1 ? inner[1] : nil
        ), generation: generation)
        historyBufferedItems += 1
    }

    private func emit() async { continuation?.yield(await currentState()) }
}

private actor Gen5WireWriter {
    private let transport: any BLETransport
    private var generation: UInt64?
    private var sequence = SeqAllocator()
    private var writing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(transport: any BLETransport) { self.transport = transport }
    func reserveSequence() -> UInt8 { sequence.nextLive() }
    func setGeneration(_ value: UInt64) { generation = value; sequence.reset() }
    func invalidate() { generation = nil }

    func write(_ command: Gen5OperationalCommand, sequence supplied: UInt8? = nil, generation expected: UInt64) async throws {
        if writing {
            await withCheckedContinuation { waiting.append($0) }
        }
        writing = true
        defer {
            if waiting.isEmpty { writing = false }
            else { waiting.removeFirst().resume() }
        }
        guard generation == expected else { throw TransportError.disconnected }
        let encoded = try Gen5OperationalCommandEncoder().encode(command, sequence: supplied ?? sequence.nextLive())
        try await transport.write(encoded, to: Gen5BluetoothProfile.command)
        guard generation == expected else { throw TransportError.disconnected }
    }
}

private struct Gen5LiveCommandSink: LiveStreamCommandSink {
    let wire: Gen5WireWriter

    func setLiveStream(_ kind: LiveStreamKind, enabled: Bool) async throws {
        guard kind == .compactHeartRateRR, let generation = await wire.activeGeneration() else {
            throw LiveStreamError.generationUnavailable
        }
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:153-168.
        try await wire.write(.liveHeartRate(enabled), generation: generation)
    }
}

private struct Gen5HistoryTransport: CommandWriteTransport {
    let transport: any BLETransport
    func writeCommand(_ data: Data) async throws { throw TransportError.unsupported }
    func disconnect() async { await transport.disconnect() }
}

private extension Gen5WireWriter {
    func activeGeneration() -> UInt64? { generation }
}
