import BluetoothKit
import Foundation
import ProtocolKit
import TestSupport
import XCTest

/// Narrow adversarial checks for the native/session boundary. These tests are
/// deliberately independent of the runtime composition so a failure points at
/// one GATT or command invariant instead of a large end-to-end fixture.
final class FinalParityAdversarialTests: XCTestCase {
    func testEdgeLiveControlFramesUseExactOpcodesAndOpticalRevisionPayloads() throws {
        let cases: [(ProductionCommand, Data)] = [
            (
                .toggleRealtimeHR(sequence: 0xA0, enabled: true),
                Data([0x23, 0xA0, 0x03, 0x01])
            ),
            (
                .sendR10R11Realtime(sequence: 0xA1, enabled: true),
                Data([0x23, 0xA1, 0x3F, 0x01])
            ),
            (
                .toggleIMUMode(sequence: 0xA2, enabled: true),
                Data([0x23, 0xA2, 0x6A, 0x01])
            ),
            (
                .enableOpticalData(sequence: 0xA3, enabled: true),
                Data([0x23, 0xA3, 0x6B, 0x01, 0x01, 0x00, 0x00, 0x00])
            ),
            (
                .toggleOpticalMode(sequence: 0xA4, enabled: false),
                Data([0x23, 0xA4, 0x6C, 0x01, 0x00, 0x00, 0x00, 0x00])
            ),
            (
                .enableOpticalData(sequence: 0xA5, enabled: false),
                Data([0x23, 0xA5, 0x6B, 0x01, 0x00, 0x00, 0x00, 0x00])
            )
        ]

        for (command, expectedInner) in cases {
            let encoded = try ProductionCommandWriter().encode(command)
            XCTAssertEqual(try FrameDecoder().decode(encoded).paddedInner, expectedInner)
        }
    }

    func testDiscoveryWatchdogExpiryDisconnectsAndClearsAllAttemptState() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [peripheral])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: UUID()),
            clock: clock
        )

        guard case .connect(let generation, peripheral: peripheral) = await coordinator.start() else {
            return XCTFail("persisted accessory must enter connect phase")
        }
        _ = await coordinator.handle(.connected(peripheral), generation: generation)
        let activePhase = await coordinator.activeWatchdogPhase()
        XCTAssertEqual(activePhase, .discovery)

        clock.advance(byNanoseconds: BluetoothTiming.gattDiscoveryNanoseconds)
        let expired = await coordinator.expireWatchdogIfNeeded()
        XCTAssertTrue(expired)
        let state = await coordinator.state()
        XCTAssertEqual(state, .idle)
        let clearedPhase = await coordinator.activeWatchdogPhase()
        XCTAssertNil(clearedPhase)
        let clearedDeadline = await coordinator.watchdogDeadline()
        XCTAssertNil(clearedDeadline)
        XCTAssertEqual(transport.recordedDisconnectCount(), 1)
    }

    func testSessionWatchdogRoutesScopedDiscoveryDisconnectThroughSession() async throws {
        let peripheral = UUID()
        let transport = ScopedWatchdogTransport(retrievalResult: [peripheral])
        let clock = ManualBluetoothClock()
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: UUID()),
            clock: clock
        )
        var events = transport.events().makeAsyncIterator()

        guard case .connect(let generation, peripheral: peripheral) = await session.start() else {
            return XCTFail("persisted accessory must enter connect phase")
        }
        let identity = TransportSessionIdentity(peripheral: peripheral)
        transport.install(identity)
        _ = await session.handle(.connectedInSession(identity), generation: generation)
        let connectedIdentity = await session.activeSessionIdentity()
        XCTAssertEqual(connectedIdentity, identity)

        clock.advance(byNanoseconds: BluetoothTiming.gattDiscoveryNanoseconds)
        let didExpire = await session.expireWatchdogIfNeeded()
        XCTAssertTrue(didExpire)
        guard let event = await events.next() else {
            return XCTFail("watchdog must emit one scoped disconnect event")
        }
        guard case .disconnectedInSession(let emittedIdentity, error: .timeout) = event else {
            return XCTFail("watchdog emitted an unexpected event: \(event)")
        }
        XCTAssertEqual(emittedIdentity, identity)

        let transition = await session.handle(event, generation: generation)
        guard case .accepted(.reconnecting) = transition else {
            return XCTFail("scoped watchdog disconnect must be accepted: \(transition)")
        }
        let clearedIdentity = await session.activeSessionIdentity()
        XCTAssertNil(clearedIdentity)
        let setupReady = await session.setupReady()
        XCTAssertFalse(setupReady)
    }

    func testPreConnectWatchdogScopedDisconnectFailsClosedWithoutAnActiveIdentity() async throws {
        let peripheral = UUID()
        let transport = ScopedWatchdogTransport(retrievalResult: [peripheral])
        let clock = ManualBluetoothClock()
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: UUID()),
            clock: clock
        )
        var events = transport.events().makeAsyncIterator()

        guard case .connect(let generation, peripheral: peripheral) = await session.start() else {
            return XCTFail("persisted accessory must enter connect phase")
        }
        let initialIdentity = await session.activeSessionIdentity()
        XCTAssertNil(initialIdentity)
        clock.advance(byNanoseconds: BluetoothTiming.foregroundConnectNanoseconds)
        let didExpire = await session.expireWatchdogIfNeeded()
        XCTAssertTrue(didExpire)
        guard let event = await events.next() else {
            return XCTFail("pre-connect watchdog must emit one scoped disconnect event")
        }
        guard case .disconnectedInSession(let identity, error: .timeout) = event,
              identity.peripheral == peripheral else {
            return XCTFail("pre-connect watchdog emitted an unexpected event: \(event)")
        }
        let transition = await session.handle(event, generation: generation)
        guard case .accepted(.reconnecting) = transition else {
            return XCTFail("pre-connect scoped watchdog disconnect must be accepted: \(transition)")
        }
        let clearedIdentity = await session.activeSessionIdentity()
        XCTAssertNil(clearedIdentity)
    }

    func testSamePeripheralOldSessionCallbackIsRejectedAfterFreshIdentity() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [])
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: ManualBluetoothClock()
        )

        guard case .scan(let firstGeneration, _) = await session.start() else {
            return XCTFail("first attempt must start a service-filtered scan")
        }
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: firstGeneration
        )
        let firstIdentity = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(firstIdentity), generation: firstGeneration)
        _ = await session.handle(
            .disconnectedInSession(firstIdentity, error: .disconnected),
            generation: firstGeneration
        )
        await session.disconnect()

        guard case .scan(let secondGeneration, _) = await session.start() else {
            return XCTFail("a torn-down attempt must permit a fresh scan")
        }
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: secondGeneration
        )
        let secondIdentity = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(secondIdentity), generation: secondGeneration)
        let activeIdentity = await session.activeSessionIdentity()
        XCTAssertEqual(activeIdentity, secondIdentity)

        let stale = await session.handle(
            .valueInSession(
                firstIdentity,
                characteristic: HarvardBluetoothProfile.response,
                Data([0xAA])
            ),
            generation: secondGeneration
        )
        guard case .rejected(.staleSession(expected: let second, received: let first)) = stale else {
            return XCTFail("same-peripheral callback from the prior identity was accepted: \(stale)")
        }
        XCTAssertEqual(second, secondIdentity)
        XCTAssertEqual(first, firstIdentity)
        let frames = await session.drainFrames()
        XCTAssertTrue(frames.isEmpty)
    }

    func testGATTValidationFailureClearsParserIdentityAndDisconnectsOnce() async throws {
        let peripheral = UUID()
        let transport = ScriptedTransport(events: [])
        let session = BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: ManualBluetoothClock()
        )

        guard case .scan(let generation, _) = await session.start() else {
            return XCTFail("expected initial scan")
        }
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: generation
        )
        let identity = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(identity), generation: generation)
        _ = await session.handle(
            .servicesDiscoveredInSession(identity, services: HarvardBluetoothProfile.requiredServices),
            generation: generation
        )
        let invalid = [
            CharacteristicDescriptor(id: HarvardBluetoothProfile.command, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.response, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.events, properties: [.notify]),
            CharacteristicDescriptor(id: HarvardBluetoothProfile.data, properties: [.notify])
        ]

        let result = await session.handle(
            .characteristicsDiscoveredInSession(identity, characteristics: invalid),
            generation: generation
        )
        guard case .rejected(.gattValidationFailed(.propertyMismatch)) = result else {
            return XCTFail("invalid GATT properties were not rejected: \(result)")
        }
        let clearedIdentity = await session.activeSessionIdentity()
        XCTAssertNil(clearedIdentity)
        let setupReady = await session.setupReady()
        XCTAssertFalse(setupReady)
        let frames = await session.drainFrames()
        XCTAssertTrue(frames.isEmpty)
        let state = await session.state()
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(transport.recordedDisconnectCount(), 1)
    }
}

/// Native watchdog test seam: unlike ScriptedTransport's silent disconnect,
/// this transport emits the scoped operation identity that CoreBluetooth emits
/// before it tears down its active peripheral session.
private final class ScopedWatchdogTransport: BLEWatchdogDisconnecting, BLEPeripheralRetriever, BLEPeripheralScanner, @unchecked Sendable {
    private let lock = NSLock()
    private let retrievalResult: [PeripheralID]
    private var stream: AsyncStream<TransportEvent>?
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var watchdogIdentity: TransportSessionIdentity?

    init(retrievalResult: [PeripheralID]) {
        self.retrievalResult = retrievalResult
    }

    func events() -> AsyncStream<TransportEvent> {
        lock.withLock {
            if let stream { return stream }
            let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
            self.stream = stream
            self.continuation = continuation
            return stream
        }
    }

    func connect(_ peripheral: PeripheralID) async {}
    func retrieve(_ peripherals: [PeripheralID]) async -> [PeripheralID] { retrievalResult }
    func scan(for service: ServiceID) async {}
    func stopScan() async {}
    func discoverServices(_ ids: [ServiceID]) async {}
    func setNotify(_ char: CharacteristicID, enabled: Bool) async {}
    func write(_ data: Data, to char: CharacteristicID) async throws {}
    func disconnect() async {}

    func disconnectForWatchdog() async -> Bool {
        let identity = lock.withLock {
            watchdogIdentity ?? TransportSessionIdentity(peripheral: retrievalResult[0])
        }
        lock.withLock { watchdogIdentity = identity }
        continuation?.yield(.disconnectedInSession(identity, error: .timeout))
        return true
    }

    func install(_ identity: TransportSessionIdentity) {
        lock.withLock { watchdogIdentity = identity }
    }
}
