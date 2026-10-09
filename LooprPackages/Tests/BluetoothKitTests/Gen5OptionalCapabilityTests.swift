import XCTest
@testable import BluetoothKit

final class Gen5OptionalCapabilityKillSwitchTests: XCTestCase {
    func testEightIndependentSwitchesDefaultOff() async {
        let switches = Gen5OptionalCapabilitySwitches()
        XCTAssertEqual(Gen5OptionalCapability.allCases.count, 8)
        for capability in Gen5OptionalCapability.allCases {
            let enabled = await switches.isEnabled(capability)
            XCTAssertFalse(enabled)
        }

        await switches.setEnabled(true, for: .alarm)
        let alarmEnabled = await switches.isEnabled(.alarm)
        XCTAssertTrue(alarmEnabled)
        for capability in Gen5OptionalCapability.allCases where capability != .alarm {
            let enabled = await switches.isEnabled(capability)
            XCTAssertFalse(enabled)
        }
    }
}
