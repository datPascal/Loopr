import XCTest
import ProtocolKit
@testable import BluetoothKit

final class Gen5KillSwitchTests: XCTestCase {
    func testDefaultsOffAndBlocksEveryEntryPoint() async throws {
        let gate = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore())
        let initiallyEnabled = await gate.isEnabled()
        XCTAssertFalse(initiallyEnabled)

        for entryPoint in Gen5GateEntryPoint.allCases {
            do {
                try await gate.authorize(entryPoint)
                XCTFail("expected disabled gate for \(entryPoint)")
            } catch {
                XCTAssertEqual(error as? Gen5FeatureGateError, .disabled(entryPoint))
            }
        }
        do {
            _ = try await gate.makeProfile()
            XCTFail("disabled gate must not construct a Gen 5 profile")
        } catch {
            XCTAssertEqual(error as? Gen5FeatureGateError, .disabled(.connect))
        }
    }

    func testPersistsAcrossControllerRelaunch() async throws {
        let store = InMemoryGen5KillSwitchStore()
        let firstLaunch = Gen5FeatureGate(store: store)
        try await firstLaunch.setEnabled(true)

        let relaunched = Gen5FeatureGate(store: store)
        let persistedEnabled = await relaunched.isEnabled()
        XCTAssertTrue(persistedEnabled)
        let profile = try await relaunched.makeProfile(model: .whoop5)
        XCTAssertEqual(profile.generation, .gen5)
        XCTAssertEqual(profile.model, .whoop5)
    }

    func testCommandGatewayCannotEncodeWhileOff() async throws {
        let gate = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore())
        let gateway = Gen5InitialCommandGateway(gate: gate)
        do {
            _ = try await gateway.clientHello()
            XCTFail("master switch must guard the production encoder")
        } catch {
            XCTAssertEqual(error as? Gen5FeatureGateError, .disabled(.commandEncode))
        }
        try await gate.setEnabled(true)
        let frame = try await gateway.clientHello()
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), "aa0108000001e67123019101363e5c8d")
    }
}

final class GenMGKillSwitchTests: XCTestCase {
    func testMGSwitchIsIndependentAndStableGen4IsUnaffected() async throws {
        let master = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore(persistedValue: true))
        let whoop5 = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore(persistedValue: true))
        let whoopMG = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore())
        let products = Gen5ProductFeatureGates(master: master, whoop5: whoop5, whoopMG: whoopMG)

        try await products.authorize(.connect, model: .whoop5)
        do {
            try await products.authorize(.connect, model: .whoopMG)
            XCTFail("MG must remain disabled independently of WHOOP 5.0")
        } catch {
            XCTAssertEqual(error as? Gen5FeatureGateError, .disabled(.connect))
        }
        XCTAssertEqual(BandProfile.gen4, .gen4)
    }
}

final class Gen5GATTProfileTests: XCTestCase {
    func testExactFd4bTableAndMemfaultIsolation() {
        XCTAssertEqual(Gen5BluetoothProfile.service.uuidString.lowercased(), "fd4b0001-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(Gen5BluetoothProfile.command.uuidString.lowercased(), "fd4b0002-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(Gen5BluetoothProfile.response.uuidString.lowercased(), "fd4b0003-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(Gen5BluetoothProfile.events.uuidString.lowercased(), "fd4b0004-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(Gen5BluetoothProfile.data.uuidString.lowercased(), "fd4b0005-cce1-4033-93ce-002d5875f58a")
        XCTAssertEqual(Gen5BluetoothProfile.memfault.uuidString.lowercased(), "fd4b0007-cce1-4033-93ce-002d5875f58a")

        XCTAssertFalse(Gen5BluetoothProfile.inboundCharacteristics.contains(Gen5BluetoothProfile.memfault))
        XCTAssertFalse(Gen5BluetoothProfile.requiredCharacteristics.contains(Gen5BluetoothProfile.memfault))
        XCTAssertEqual(Gen5BluetoothProfile.inboundCharacteristics, [
            Gen5BluetoothProfile.response,
            Gen5BluetoothProfile.events,
            Gen5BluetoothProfile.data
        ])
    }

    func testStableProfileRemainsGen4() {
        XCTAssertEqual(BandProfile.gen4.generation, .gen4)
        XCTAssertEqual(BandProfile.gen4.model, .whoop4)
        XCTAssertEqual(BandProfile.gen4.gatt, .gen4)
        XCTAssertEqual(BandProfile.gen4.framing, .gen4)
    }
}
