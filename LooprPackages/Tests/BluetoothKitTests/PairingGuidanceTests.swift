import Foundation
import XCTest
@testable import BluetoothKit

/// The pairing sheet's name and picture, the pairing guidance, and the rule
/// for the "another app may be connected" hint.
final class PairingGuidanceTests: XCTestCase {
    private let band = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    func testPickerNamesTheBandAsOnboardingDoes() {
        let descriptor = AccessoryDiscoveryDescriptor.harvardWHOOP4
        XCTAssertEqual(descriptor.displayName, "WHOOP 4.0")
        XCTAssertEqual(descriptor.productImageNames, ["band-product-pairing", "band-product"])
        XCTAssertEqual(ProvisionedAccessory(bluetoothIdentifier: band).displayName, "WHOOP 4.0")
    }

    #if canImport(AccessorySetupKit) && os(iOS)
    func testPickerFallsBackToADrawnBandWhenNoPictureShips() {
        let descriptor = AccessoryDiscoveryDescriptor(productImageNames: ["no-such-picture"])
        let image = AccessorySetupKitDescriptorFactory.productImage(for: descriptor, bundle: Bundle(for: Self.self))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertFalse(image.isSymbolImage, "The fallback is a picture of a band, not an SF Symbol")
    }
    #endif

    func testGuidanceUsesTheResearchedHandover() {
        let long = AccessoryProvisioningController.ownershipExplanation
        let short = AccessoryProvisioningController.ownershipExplanationShort
        for text in [long, short] {
            XCTAssertTrue(text.contains("Bluetooth access"), text)
            XCTAssertTrue(text.contains("Privacy & Security"), text)
            XCTAssertTrue(text.contains("two fingers"), text)
            // Claims the research found unsupported.
            XCTAssertFalse(text.contains("to itself"), text)
            XCTAssertFalse(text.contains("one app at a time"), text)
            XCTAssertFalse(text.contains("\u{2014}"), text)
        }
        // The tap method leads; the battery pack is only for a new band.
        let tap = long.range(of: "two fingers")
        let pack = long.range(of: "battery pack")
        XCTAssertNotNil(tap)
        XCTAssertNotNil(pack)
        if let tap, let pack { XCTAssertLessThan(tap.lowerBound, pack.lowerBound) }
        XCTAssertTrue(long.contains("never paired"))
        XCTAssertTrue(long.contains("3 minutes"))
    }

    func testHintWhenIOSListsTheBandBeforeLooprConnects() {
        XCTAssertTrue(SharedLinkHint.otherAppHoldsLink(
            systemConnected: [other, band], provisioned: band, restored: [], hasConnectedLocally: false
        ))
    }

    func testNoHintWhenTheBandIsNotListed() {
        XCTAssertFalse(SharedLinkHint.otherAppHoldsLink(
            systemConnected: [other], provisioned: band, restored: [], hasConnectedLocally: false
        ))
        XCTAssertFalse(SharedLinkHint.otherAppHoldsLink(
            systemConnected: [], provisioned: band, restored: [], hasConnectedLocally: false
        ))
    }

    func testNoHintOnceLooprHasItsOwnLink() {
        // After Loopr's first connection the system link may be Loopr's own.
        XCTAssertFalse(SharedLinkHint.otherAppHoldsLink(
            systemConnected: [band], provisioned: band, restored: [], hasConnectedLocally: true
        ))
    }

    func testNoHintForALinkIOSRestoredToLoopr() {
        // A restored peripheral is Loopr's link, kept alive by iOS.
        XCTAssertFalse(SharedLinkHint.otherAppHoldsLink(
            systemConnected: [band], provisioned: band, restored: [band], hasConnectedLocally: false
        ))
    }
}
