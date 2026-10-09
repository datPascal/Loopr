import XCTest
import ProtocolKit
@testable import BluetoothKit

final class Gen5ConsentGateTests: XCTestCase {
    func testProvisioningRequiresBothConsentAndMasterSwitch() async throws {
        let feature = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore())
        let consent = InMemoryGen5ConsentStore()
        let gate = Gen5ConsentGate(consentStore: consent, featureGate: feature)

        do {
            try await gate.authorizeProvisioning()
            XCTFail("provisioning must not be reachable before consent")
        } catch {
            XCTAssertEqual(error as? Gen5ConsentError, .consentRequired)
        }

        try await gate.recordConsent()
        do {
            try await gate.authorizeProvisioning()
            XCTFail("consent must not bypass the master switch")
        } catch {
            XCTAssertEqual(error as? Gen5FeatureGateError, .disabled(.provisioning))
        }

        try await feature.setEnabled(true)
        try await gate.authorizeProvisioning()
    }

    func testWithdrawalTurnsMasterSwitchOff() async throws {
        let feature = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore(persistedValue: true))
        let gate = Gen5ConsentGate(
            consentStore: InMemoryGen5ConsentStore(consented: true),
            featureGate: feature
        )
        try await gate.withdrawConsent()
        let enabled = await feature.isEnabled()
        XCTAssertFalse(enabled)
        do {
            try await gate.authorizeProvisioning()
            XCTFail("withdrawn consent must close provisioning")
        } catch {
            XCTAssertEqual(error as? Gen5ConsentError, .consentRequired)
        }
    }
}

final class Gen5DescriptorConfigTests: XCTestCase {
    func testFd4bRequiresOptInInEveryDistribution() {
        let baseline = AccessoryDescriptorCatalog.stableGen4
        for distribution in [LooprDistribution.internalDevelopment, .testFlight, .appStore] {
            XCTAssertEqual(AccessoryDescriptorCatalog.descriptors(for: distribution), baseline)
            let descriptors = AccessoryDescriptorCatalog.descriptors(for: distribution, experimentalSupportEnabled: true)
            XCTAssertEqual(Array(descriptors.prefix(baseline.count)), baseline)
            XCTAssertEqual(descriptors.last, AccessoryServiceDescriptor(
                generation: .gen5,
                service: GATTProfile.gen5.service
            ))
        }
    }

    func testCandidateIdentityPreservesAllProfileEvidence() {
        let id = UUID()
        let candidate = Gen5CandidateIdentity(
            peripheralID: id,
            service: GATTProfile.gen5.service,
            name: "candidate",
            helloIdentity: Data([1, 2, 3]),
            firmware: "unknown",
            model: .unknownGen5,
            modelConfidence: 0.25
        )
        XCTAssertEqual(candidate.peripheralID, id)
        XCTAssertEqual(candidate.service, GATTProfile.gen5.service)
        XCTAssertEqual(candidate.helloIdentity, Data([1, 2, 3]))
        XCTAssertEqual(candidate.model, .unknownGen5)
        XCTAssertEqual(candidate.modelConfidence, 0.25)
    }
}

final class ProfileConfusionRejectionTests: XCTestCase {
    func testDualFamilyAdvertisementRejectsBeforeConnect() {
        XCTAssertThrowsError(try BandProfileResolver.generation(for: [
            GATTProfile.gen4.service,
            GATTProfile.gen5.service
        ])) { error in
            XCTAssertEqual(error as? BandProfileResolutionError, .ambiguousServiceFamilies)
        }
    }

    func testSingleFamiliesRemainDistinct() throws {
        XCTAssertEqual(try BandProfileResolver.generation(for: [GATTProfile.gen4.service]), .gen4)
        XCTAssertEqual(try BandProfileResolver.generation(for: [GATTProfile.gen5.service]), .gen5)
    }
}
