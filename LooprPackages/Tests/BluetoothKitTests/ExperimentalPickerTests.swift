import XCTest
import ProtocolKit
@testable import BluetoothKit

private actor RecordingExperimentalPicker: AccessorySetupClient {
    private var offered: [[AccessoryDiscoveryDescriptor]] = []

    func provisionedAccessories() -> [ProvisionedAccessory] { [] }
    func showPicker(for descriptor: AccessoryDiscoveryDescriptor) -> ProvisionedAccessory? {
        offered.append([descriptor])
        return nil
    }
    func showPicker(for descriptors: [AccessoryDiscoveryDescriptor]) -> ProvisionedAccessory? {
        offered.append(descriptors)
        return nil
    }
    func removeAccessory(_ accessory: ProvisionedAccessory) {}
    func lastOffer() -> [AccessoryDiscoveryDescriptor]? { offered.last }
}

final class ExperimentalPickerTests: XCTestCase {
    func testFd4bScanPolicyUsesItsOwnService() {
        // OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:959-993,1162-1185.
        let policy = BluetoothDiscoveryPolicy(
            isForeground: false,
            service: GATTProfile.gen5.service
        )
        XCTAssertEqual(policy.serviceUUIDs, [GATTProfile.gen5.service])
        XCTAssertTrue(policy.accepts(name: nil, services: [GATTProfile.gen5.service]))
        XCTAssertFalse(policy.accepts(name: nil, services: [GATTProfile.gen4.service]))
    }

    func testConsentAddsBothFd4bItemsAndWithdrawalRemovesThem() async {
        let consent = InMemoryGen5ConsentStore()
        let picker = RecordingExperimentalPicker()
        let controller = AccessoryProvisioningController(
            client: picker,
            store: InMemoryAccessoryProvisioningStore(),
            experimentalSupportEnabled: { await consent.loadConsent() }
        )

        _ = await controller.userTappedPair()
        _ = await controller.continueAfterExplanation()
        var offered = await picker.lastOffer()
        XCTAssertEqual(offered?.map(\.displayName), ["WHOOP 4.0"])

        await consent.saveConsent(true)
        _ = await controller.userTappedPair()
        _ = await controller.continueAfterExplanation()
        offered = await picker.lastOffer()
        XCTAssertEqual(offered?.map(\.displayName), ["WHOOP 4.0", "WHOOP 5.0", "WHOOP MG"])
        XCTAssertEqual(offered?[1].bluetoothServiceUUID, GATTProfile.gen5.service)
        XCTAssertEqual(offered?[2].bluetoothServiceUUID, GATTProfile.gen5.service)
        XCTAssertNil(offered?[1].bluetoothNameSubstring)

        await consent.saveConsent(false)
        _ = await controller.userTappedPair()
        _ = await controller.continueAfterExplanation()
        offered = await picker.lastOffer()
        XCTAssertEqual(offered?.map(\.displayName), ["WHOOP 4.0"])
    }
}
