@testable import BluetoothKit
import Foundation
import XCTest

final class BluetoothDiscoveryPolicyTests: XCTestCase {
    func testForegroundNameFallbackRestoresServiceFilterWhenBackgrounded() {
        var policy = BluetoothDiscoveryPolicy(isForeground: true)
        XCTAssertNil(policy.serviceUUIDs)
        XCTAssertTrue(policy.accepts(name: "WHOOP 4A0B", services: []))
        policy.isForeground = false
        XCTAssertEqual(policy.serviceUUIDs, [HarvardBluetoothProfile.service])
        policy.isForeground = true
        XCTAssertNil(policy.serviceUUIDs)
    }

    func testRestoredBackgroundScanRequiresHarvardService() {
        let policy = BluetoothDiscoveryPolicy(isForeground: false)
        XCTAssertEqual(policy.serviceUUIDs, [HarvardBluetoothProfile.service])
    }

    func testAdvertisementGateAcceptsServiceOrCaseInsensitiveName() {
        let policy = BluetoothDiscoveryPolicy(isForeground: true)
        XCTAssertTrue(policy.accepts(name: nil, services: [HarvardBluetoothProfile.service]))
        XCTAssertTrue(policy.accepts(name: "wHoOp 4A0B", services: []))
        XCTAssertFalse(policy.accepts(name: "Unrelated device", services: []))
        XCTAssertFalse(policy.accepts(name: nil, services: []))
    }
}
