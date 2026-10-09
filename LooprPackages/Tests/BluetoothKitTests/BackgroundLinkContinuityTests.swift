import BluetoothKit
import Foundation
import TestSupport
import XCTest

/// Covers the rule that keeps the band reachable while the app is suspended:
/// a connect issued in the background is never bounded by a timer, because iOS
/// completes a pending connect in the background and that completion is the
/// only thing that wakes a suspended app.
final class BackgroundLinkContinuityTests: XCTestCase {
    func testBackgroundConnectIsArmedWithoutADeadline() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [paired])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )

        await coordinator.setApplicationBackgrounded(true)
        guard case .connect(_, let peripheral) = await coordinator.start() else {
            return XCTFail("a retrieved peripheral must still be connected in the background")
        }
        XCTAssertEqual(peripheral, paired)
        let deadline = await coordinator.connectDeadline()
        XCTAssertNil(deadline, "a background connect must not carry a deadline")
        let phase = await coordinator.activeWatchdogPhase()
        XCTAssertEqual(phase, .connect)

        clock.advance(byNanoseconds: BluetoothTiming.foregroundConnectNanoseconds * 10)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertFalse(expired, "no elapsed time may cancel an outstanding background connect")
        let state = await coordinator.state()
        XCTAssertEqual(state, .connecting(generation: 2, peripheral: paired))
        XCTAssertEqual(transport.recordedDisconnectCount(), 0)
        XCTAssertEqual(transport.recordedConnects(), [paired])
    }

    func testBackgroundingAnInFlightConnectDropsItsDeadlineAndForegroundRestoresIt() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [paired])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )

        _ = await coordinator.start()
        let foregroundDeadline = await coordinator.connectDeadline()
        XCTAssertEqual(foregroundDeadline, BluetoothTiming.foregroundConnectNanoseconds)

        await coordinator.setApplicationBackgrounded(true)
        let backgroundDeadline = await coordinator.connectDeadline()
        XCTAssertNil(backgroundDeadline)
        let backgrounded = await coordinator.isApplicationBackgrounded()
        XCTAssertTrue(backgrounded)

        await coordinator.setApplicationBackgrounded(false)
        let restoredDeadline = await coordinator.connectDeadline()
        XCTAssertEqual(
            restoredDeadline,
            clock.nowNanoseconds() + BluetoothTiming.foregroundConnectNanoseconds,
            "returning to the foreground re-arms the bounded connect"
        )
        XCTAssertEqual(transport.recordedDisconnectCount(), 0)
    }

    func testBackgroundScanTimeoutFallsBackToAPendingConnectOnThePairedBand() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )

        await coordinator.setApplicationBackgrounded(true)
        guard case .scan = await coordinator.start() else {
            return XCTFail("a retrieval miss still falls back to the filtered scan")
        }

        clock.advance(byNanoseconds: BluetoothTiming.foregroundScanNanoseconds)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertTrue(expired)
        XCTAssertEqual(transport.recordedConnects(), [paired])
        let phase = await coordinator.activeWatchdogPhase()
        XCTAssertEqual(phase, .connect)
        let deadline = await coordinator.connectDeadline()
        XCTAssertNil(deadline)
        guard case .connecting(_, let peripheral) = await coordinator.state() else {
            return XCTFail("a background scan timeout parks on a pending connect, not out of range")
        }
        XCTAssertEqual(peripheral, paired)
    }

    func testForegroundScanTimeoutStillParksOutOfRange() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )

        _ = await coordinator.start()
        clock.advance(byNanoseconds: BluetoothTiming.foregroundScanNanoseconds)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertTrue(expired)
        let state = await coordinator.state()
        XCTAssertEqual(state, .outOfRange)
        XCTAssertTrue(transport.recordedConnects().isEmpty)
    }

    func testForegroundConnectTimeoutStillTearsTheAttemptDown() async throws {
        let paired = UUID()
        let transport = ScriptedTransport(events: [], retrievalResult: [paired])
        let clock = ManualBluetoothClock()
        let coordinator = BluetoothConnectionCoordinator(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(identifier: paired),
            clock: clock
        )

        _ = await coordinator.start()
        clock.advance(byNanoseconds: BluetoothTiming.foregroundConnectNanoseconds)
        let expired = await coordinator.expireConnectIfNeeded()
        XCTAssertTrue(expired)
        XCTAssertEqual(transport.recordedDisconnectCount(), 1)
        let state = await coordinator.state()
        XCTAssertEqual(state, .idle)
    }
}
