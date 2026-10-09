import BluetoothKit
import Foundation

/// Actor-backed write notifications for tests that need to synchronize on a
/// specific outbound command.  The regular lock-protected write history is
/// intentionally kept as-is for existing assertions; this companion signal
/// avoids timing/count polling when a test must inject a response only after
/// the corresponding request has been registered.
private actor ScriptedWriteEvents {
    private var writes: [Data] = []
    private var waiters: [Int: [CheckedContinuation<Data, Never>]] = [:]

    func record(_ data: Data) {
        let index = writes.count
        writes.append(data)
        let continuations = waiters.removeValue(forKey: index) ?? []
        continuations.forEach { $0.resume(returning: data) }
    }

    func wait(for index: Int) async -> Data {
        if index < writes.count {
            return writes[index]
        }
        return await withCheckedContinuation { continuation in
            if index < writes.count {
                continuation.resume(returning: writes[index])
            } else {
                waiters[index, default: []].append(continuation)
            }
        }
    }
}

/// A deterministic ordered event transport for state-machine and GATT tests.
/// Events are emitted only after `events()` is requested, so constructing a
/// fake cannot race the session that will consume it. When `awaitWrites` is
/// enabled, each event after the first waits for one transport write, making
/// the event/write boundary explicit and deterministic. `holdWrites` is a
/// separate opt-in for tests that need to release a pending write manually.
public final class ScriptedTransport: BLETransport, BLEPeripheralRetriever, BLEPeripheralScanner, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [TransportEvent]
    private var streamContinuation: AsyncStream<TransportEvent>.Continuation?
    private var stream: AsyncStream<TransportEvent>?
    private var emitterTask: Task<Void, Never>?
    private var emitted = 0
    private var connectCalls: [PeripheralID] = []
    private var serviceDiscoveryCalls: [[ServiceID]] = []
    private var notifyCalls: [(CharacteristicID, Bool)] = []
    private var writes: [(Data, CharacteristicID)] = []
    private let writeEvents = ScriptedWriteEvents()
    private var disconnectCallCount = 0
    private let awaitWrites: Bool
    private let holdWrites: Bool
    private var writeBoundaryWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingWriteBoundaries = 0
    private var heldWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var retrievalResult: [PeripheralID]
    private var retrievalCalls: [[PeripheralID]] = []
    private var scanCalls: [ServiceID] = []

    public init(
        events: [TransportEvent],
        awaitWrites: Bool = false,
        holdWrites: Bool = false,
        retrievalResult: [PeripheralID] = []
    ) {
        script = events
        self.awaitWrites = awaitWrites
        self.holdWrites = holdWrites
        self.retrievalResult = retrievalResult
    }

    public func events() -> AsyncStream<TransportEvent> {
        lock.withLock {
            if let stream { return stream }
            let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
            self.stream = stream
            streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.streamContinuation = nil }
                self.cancelPendingScriptWaiters()
                self.lock.withLock { self.emitterTask?.cancel() }
            }
            // The deterministic script must not inherit the caller's actor or
            // executor. Under a full instrumented package run that executor
            // can remain occupied after this method returns, starving the
            // final setup notification even though the stream is ready.
            emitterTask = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.emitScript()
            }
            return stream
        }
    }

    public func connect(_ peripheral: PeripheralID) async {
        lock.withLock { connectCalls.append(peripheral) }
    }

    public func retrieve(_ peripherals: [PeripheralID]) async -> [PeripheralID] {
        lock.withLock {
            retrievalCalls.append(peripherals)
            return retrievalResult
        }
    }

    public func scan(for service: ServiceID) async {
        lock.withLock { scanCalls.append(service) }
    }

    public func discoverServices(_ ids: [ServiceID]) async {
        lock.withLock { serviceDiscoveryCalls.append(ids) }
    }

    public func setNotify(_ char: CharacteristicID, enabled: Bool) async {
        lock.withLock { notifyCalls.append((char, enabled)) }
    }

    public func write(_ data: Data, to char: CharacteristicID) async throws {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            writes.append((Data(data), char))
            if awaitWrites {
                if let waiter = writeBoundaryWaiters.first {
                    writeBoundaryWaiters.removeFirst()
                    return waiter
                }
                pendingWriteBoundaries += 1
            }
            return nil
        }
        waiter?.resume()
        await writeEvents.record(Data(data))
        if holdWrites {
            await withCheckedContinuation { continuation in
                lock.withLock { heldWriteWaiters.append(continuation) }
            }
        }
    }

    public func disconnect() async {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            disconnectCallCount += 1
            let waiters = heldWriteWaiters
            heldWriteWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Releases one event that was configured to wait for a write boundary.
    public func resumeAfterWrite() {
        let waiter = lock.withLock { heldWriteWaiters.isEmpty ? nil : heldWriteWaiters.removeFirst() }
        waiter?.resume()
    }

    public func recordedConnects() -> [PeripheralID] { lock.withLock { connectCalls } }
    public func recordedRetrievals() -> [[PeripheralID]] { lock.withLock { retrievalCalls } }
    public func recordedScans() -> [ServiceID] { lock.withLock { scanCalls } }
    public func recordedServiceDiscovery() -> [[ServiceID]] { lock.withLock { serviceDiscoveryCalls } }
    public func recordedNotifications() -> [(CharacteristicID, Bool)] { lock.withLock { notifyCalls } }
    public func recordedWrites() -> [(Data, CharacteristicID)] { lock.withLock { writes } }
    /// Awaits registration of the outbound write at `index` without polling.
    /// The returned bytes are the immutable copy captured by the transport.
    public func waitForWrite(at index: Int) async -> Data {
        await writeEvents.wait(for: index)
    }
    public func recordedDisconnectCount() -> Int { lock.withLock { disconnectCallCount } }
    public func emittedEventCount() -> Int { lock.withLock { emitted } }

    private func emitScript() async {
        // AsyncStream buffers values until its consumer runs. Emitting a
        // non-write-gated script without artificial scheduler hops keeps the
        // deterministic fake deterministic even under repeated instrumented
        // package tests.
        while true {
            let next: TransportEvent? = lock.withLock {
                guard emitted < script.count else { return nil }
                return script[emitted]
            }
            guard let next else {
                finishStream()
                return
            }
            if awaitWrites, emitted > 0 {
                await waitForWriteBoundary()
                guard !Task.isCancelled else { return }
            }
            let continuation = lock.withLock { () -> AsyncStream<TransportEvent>.Continuation? in
                guard emitted < script.count else { return nil }
                emitted += 1
                return streamContinuation
            }
            guard let continuation else { return }
            continuation.yield(next)
        }
    }

    private func finishStream() {
        let continuation = lock.withLock { () -> AsyncStream<TransportEvent>.Continuation? in
            let continuation = streamContinuation
            streamContinuation = nil
            return continuation
        }
        continuation?.finish()
    }

    private func waitForWriteBoundary() async {
        if Task.isCancelled { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if pendingWriteBoundaries > 0 {
                        pendingWriteBoundaries -= 1
                        return true
                    }
                    writeBoundaryWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            cancelPendingScriptWaiters()
        }
    }

    private func cancelPendingScriptWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let waiters = writeBoundaryWaiters
            writeBoundaryWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

public enum ReplayTransportError: Error, Equatable, Sendable, LocalizedError {
    case missingFile(String)
    case emptyFile(String)
    case invalidFile(String)
    case unexpectedWrite(index: Int, actual: ReplayWrite)
    case writeMismatch(index: Int, expected: ReplayWrite, actual: ReplayWrite)
    case incompleteWrites(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): "Replay capture is missing: \(path)"
        case .emptyFile(let path): "Replay capture is empty: \(path)"
        case .invalidFile(let reason): "Replay capture is invalid: \(reason)"
        case .unexpectedWrite(let index, let actual):
            "Replay emitted unexpected write \(index) to \(actual.characteristic.uuidString)."
        case .writeMismatch(let index, let expected, let actual):
            "Replay write \(index) mismatch: expected \(expected.bytes), got \(actual.bytes)."
        case .incompleteWrites(let expected, let actual):
            "Replay ended with \(actual) writes; expected \(expected)."
        }
    }
}

/// A capture row preserves characteristic attribution and notification chunk
/// boundaries.  The JSON shape is intentionally small and source-neutral:
/// `{ "characteristic": "UUID", "bytes": "0011aaff" }`.
public struct ReplayValue: Codable, Equatable, Sendable {
    public let characteristic: UUID
    public let bytes: String

    public init(characteristic: UUID, bytes: String) {
        self.characteristic = characteristic
        self.bytes = bytes
    }

    public func data() throws -> Data { try Self.decodeHex(bytes) }

    fileprivate static func decodeHex(_ bytes: String) throws -> Data {
        let chars = Array(bytes)
        guard chars.count.isMultiple(of: 2), chars.allSatisfy({ $0.isHexDigit }) else {
            throw ReplayTransportError.invalidFile("value \(bytes) is not an even-length hex string")
        }
        var result = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            let pair = String(chars[index...index + 1])
            guard let value = UInt8(pair, radix: 16) else {
                throw ReplayTransportError.invalidFile("invalid byte \(pair)")
            }
            result.append(value)
            index += 2
        }
        return result
    }
}

/// One expected outbound write in a replay capture. It preserves the target
/// characteristic and exact byte string so a replay fails closed on the first
/// mismatch instead of silently accepting a divergent command stream.
public struct ReplayWrite: Codable, Equatable, Sendable {
    public let characteristic: UUID
    public let bytes: String

    public init(characteristic: UUID, bytes: String) {
        self.characteristic = characteristic
        self.bytes = bytes
    }

    public func data() throws -> Data { try ReplayValue.decodeHex(bytes) }
}

/// Codable representation accepted by `ReplayTransport(fileAt:)`. The
/// original capture format was a top-level array of `ReplayValue`; the object
/// form adds an optional `writes` list without invalidating those fixtures.
public struct ReplayCapture: Codable, Equatable, Sendable {
    public let values: [ReplayValue]
    public let writes: [ReplayWrite]

    public init(values: [ReplayValue], writes: [ReplayWrite] = []) {
        self.values = values
        self.writes = writes
    }

    private enum CodingKeys: String, CodingKey { case values, writes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([ReplayValue].self, forKey: .values)
        writes = try container.decodeIfPresent([ReplayWrite].self, forKey: .writes) ?? []
    }
}

/// Replays recorded notification chunks.  It fails with a typed error for a
/// missing/empty fixture rather than silently making a fake successful session.
public final class ReplayTransport: BLETransport, @unchecked Sendable {
    private let scripted: ScriptedTransport
    private let lock = NSLock()
    private let expectedWrites: [ReplayWrite]
    private var writeIndex = 0

    public init(values: [ReplayValue], expectedWrites: [ReplayWrite] = []) throws {
        guard !values.isEmpty else { throw ReplayTransportError.emptyFile("<memory>") }
        for write in expectedWrites { _ = try write.data() }
        let events = try values.map {
            TransportEvent.value($0.characteristic, try $0.data())
        }
        scripted = ScriptedTransport(events: events)
        self.expectedWrites = expectedWrites
    }

    public convenience init(fileAt path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReplayTransportError.missingFile(path)
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw ReplayTransportError.invalidFile(error.localizedDescription) }
        guard !data.isEmpty else { throw ReplayTransportError.emptyFile(path) }
        do {
            let decoder = JSONDecoder()
            let firstJSONByte = data.first(where: { byte in
                byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x20
            })
            if firstJSONByte == 0x5B { // '[': the legacy top-level values array
                let values = try decoder.decode([ReplayValue].self, from: data)
                try self.init(values: values)
            } else {
                let capture = try decoder.decode(ReplayCapture.self, from: data)
                try self.init(values: capture.values, expectedWrites: capture.writes)
            }
        } catch let error as ReplayTransportError {
            throw error
        } catch {
            throw ReplayTransportError.invalidFile(error.localizedDescription)
        }
    }

    public func events() -> AsyncStream<TransportEvent> { scripted.events() }
    public func connect(_ peripheral: PeripheralID) async { await scripted.connect(peripheral) }
    public func discoverServices(_ ids: [ServiceID]) async { await scripted.discoverServices(ids) }
    public func setNotify(_ char: CharacteristicID, enabled: Bool) async { await scripted.setNotify(char, enabled: enabled) }
    public func write(_ data: Data, to char: CharacteristicID) async throws {
        guard !expectedWrites.isEmpty else {
            try await scripted.write(data, to: char)
            return
        }

        let indexAndExpected = lock.withLock { () -> (Int, ReplayWrite?) in
            let index = writeIndex
            guard index < expectedWrites.count else { return (index, nil) }
            let expected = expectedWrites[index]
            writeIndex += 1
            return (index, expected)
        }
        let actual = ReplayWrite(characteristic: char, bytes: Self.hex(data))
        guard let expected = indexAndExpected.1 else {
            throw ReplayTransportError.unexpectedWrite(index: indexAndExpected.0, actual: actual)
        }
        guard expected.characteristic == actual.characteristic,
              (try? expected.data()) == (try? actual.data()) else {
            throw ReplayTransportError.writeMismatch(
                index: indexAndExpected.0,
                expected: expected,
                actual: actual
            )
        }
        try await scripted.write(data, to: char)
    }
    public func disconnect() async { await scripted.disconnect() }

    public func recordedServiceDiscovery() -> [[ServiceID]] { scripted.recordedServiceDiscovery() }
    public func recordedNotifications() -> [(CharacteristicID, Bool)] { scripted.recordedNotifications() }
    public func recordedWrites() -> [(Data, CharacteristicID)] { scripted.recordedWrites() }

    /// Fails if a capture declared outbound writes that the replay never sent.
    public func assertWritesComplete() throws {
        let actual = lock.withLock { writeIndex }
        guard actual == expectedWrites.count else {
            throw ReplayTransportError.incompleteWrites(expected: expectedWrites.count, actual: actual)
        }
    }

    public var writesVerified: Bool {
        lock.withLock { writeIndex == expectedWrites.count }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ChaosFault: Equatable, Sendable {
    case disconnectAfterPacket(Int)
    case dropWriteCompletion
    case corruptByte(packet: Int, offset: Int)
    case splitNotifications
    case duplicatePacket(Int)
    case stallForNanoseconds(UInt64)
}

public struct ChaosSchedule: Equatable, Sendable {
    public let seed: UInt64
    public let faults: [ChaosFault]

    public init(seed: UInt64, faults: [ChaosFault]) {
        self.seed = seed
        self.faults = faults
    }

    /// Produces a stable, enumerable family of schedules for a finite packet
    /// window. The seed rotates the order only; it never changes which faults
    /// are covered, so CI can persist a failing index as a regression case.
    public static func enumerate(seed: UInt64, packetCount: Int) -> [ChaosSchedule] {
        guard packetCount > 0 else { return [ChaosSchedule(seed: seed, faults: [])] }
        var schedules: [ChaosSchedule] = [ChaosSchedule(seed: seed, faults: [])]
        for packet in 1...packetCount {
            schedules.append(ChaosSchedule(seed: seed, faults: [.disconnectAfterPacket(packet)]))
            schedules.append(ChaosSchedule(seed: seed, faults: [.duplicatePacket(packet)]))
            schedules.append(ChaosSchedule(seed: seed, faults: [.corruptByte(packet: packet, offset: 0)]))
        }
        schedules.append(ChaosSchedule(seed: seed, faults: [.splitNotifications]))
        schedules.append(ChaosSchedule(seed: seed, faults: [.dropWriteCompletion]))
        schedules.append(ChaosSchedule(seed: seed, faults: [.stallForNanoseconds(0)]))
        let rotation = Int(seed % UInt64(schedules.count))
        return Array(schedules[rotation...]) + Array(schedules[..<rotation])
    }
}

/// A deterministic fault-injection wrapper.  Its event stream transforms only
/// value/disconnect boundaries; all writes and control calls still reach the
/// wrapped transport so tests can assert cleanup and ordering.
public final class ChaosTransport: BLETransport, @unchecked Sendable {
    private let base: any BLETransport
    private let schedule: ChaosSchedule
    private let clock: any BluetoothClock

    public init(
        base: any BLETransport,
        schedule: ChaosSchedule,
        clock: any BluetoothClock = SystemBluetoothClock()
    ) {
        self.base = base
        self.schedule = schedule
        self.clock = clock
    }

    public var faultSchedule: ChaosSchedule { schedule }

    public func events() -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
        Task { [base, schedule, clock] in
            var packet = 0
            var selectedPeripheral: PeripheralID?
            for await event in base.events() {
                switch event {
                case .connected(let peripheral):
                    selectedPeripheral = peripheral
                    continuation.yield(event)
                case .disconnected(let peripheral, _):
                    if selectedPeripheral == peripheral { selectedPeripheral = nil }
                    continuation.yield(event)
                case .writeCompleted where schedule.faults.contains(.dropWriteCompletion):
                    // Intentionally swallow the callback while allowing the
                    // underlying write call to remain observable to the test.
                    continue
                case .value(let characteristic, let bytes):
                    packet += 1
                    var values = [event]
                    for fault in schedule.faults {
                        switch fault {
                        case .disconnectAfterPacket(let boundary) where boundary == packet:
                            values.append(.disconnected(
                                selectedPeripheral ?? UUID(),
                                error: .disconnected
                            ))
                        case .duplicatePacket(let boundary) where boundary == packet:
                            values.append(event)
                        case .corruptByte(let boundary, let offset) where boundary == packet:
                            guard bytes.indices.contains(offset) else { continue }
                            var corrupted = bytes
                            corrupted[offset] ^= 0xFF
                            values[0] = .value(characteristic, corrupted)
                        case .splitNotifications:
                            // Split into one-byte chunks while preserving the
                            // original characteristic attribution.
                            values = bytes.map { .value(characteristic, Data([$0])) }
                        case .stallForNanoseconds(let nanoseconds):
                            try? await clock.sleep(forNanoseconds: nanoseconds)
                        case .dropWriteCompletion, .disconnectAfterPacket, .corruptByte, .duplicatePacket:
                            break
                        }
                    }
                    values.forEach { continuation.yield($0) }
                default:
                    continuation.yield(event)
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func connect(_ peripheral: PeripheralID) async { await base.connect(peripheral) }
    public func discoverServices(_ ids: [ServiceID]) async { await base.discoverServices(ids) }
    public func setNotify(_ char: CharacteristicID, enabled: Bool) async { await base.setNotify(char, enabled: enabled) }
    public func write(_ data: Data, to char: CharacteristicID) async throws { try await base.write(data, to: char) }
    public func disconnect() async { await base.disconnect() }
}

/// A manually advanced clock for connection timeout tests.  It never sleeps
/// wall-clock time, so a test can prove the 20-second bound deterministically.
public final class ManualBluetoothClock: BluetoothClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    public init(nowNanoseconds: UInt64 = 0) { value = nowNanoseconds }

    public func nowNanoseconds() -> UInt64 { lock.withLock { value } }

    public func advance(byNanoseconds nanoseconds: UInt64) {
        lock.withLock { value = value.addingReportingOverflow(nanoseconds).overflow ? UInt64.max : value + nanoseconds }
    }

    public func sleep(forNanoseconds nanoseconds: UInt64) async throws {
        advance(byNanoseconds: nanoseconds)
    }
}
