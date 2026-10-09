import Foundation
import OnboardingKit
import Testing

@testable import Loopr

/// The pairing step shows what the Bluetooth model is doing. These pin the
/// mapping so a new Bluetooth status cannot silently show the wrong step.
struct ProductOnboardingPairingPhaseTests {
    private let identifier = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private func phase(_ status: BluetoothApplicationStatus, connected: Bool = false, requested: Bool = false) -> OnboardingPairingPhase {
        ProductOnboardingPairingPhaseMapper.phase(for: status, strapConnected: connected, pairingRequested: requested)
    }

    @Test
    func notStartedStatesShowTheConnectButton() {
        #expect(phase(.checkingProvisioning) == .idle)
        #expect(phase(.needsPairing) == .idle)
        #expect(phase(.removed) == .idle)
        #expect(phase(.explanationRequired) == .confirmReady)
    }

    @Test
    func inFlightStatesShowWaiting() {
        #expect(phase(.pickerPresented) == .choosing)
        for status: BluetoothApplicationStatus in [.preparing(identifier), .retrieving, .scanning, .connecting, .discovering, .subscribing] {
            #expect(phase(status) == .connecting)
        }
        // A link without the product runtime is still connecting to the person.
        #expect(phase(.connected(identifier)) == .connecting)
        #expect(phase(.connected(identifier), connected: true) == .connected)
    }

    @Test
    func problemsAreNamed() {
        #expect(phase(.bluetoothOff(nil)) == .bluetoothOff)
        #expect(phase(.cancelled) == .cancelled)
        #expect(phase(.failed("Timed out")) == .failed("Timed out"))
        #expect(phase(.disconnected(identifier, reason: "Out of range")) == .failed("Out of range"))
        // After a band was chosen, a drop is a reconnect, not a failed pairing.
        #expect(phase(.disconnected(identifier, reason: "Out of range"), requested: true) == .connecting)
    }

    @Test
    func aStaleBondGetsTheForgetThisDeviceSteps() {
        // Both routes to a bond error end in the same message, and only that
        // message turns the step into the Forget This Device repair.
        #expect(phase(.failed(LooprBluetoothFailureCopy.bondRepair)) == .bondRepair)
        #expect(ConnectionErrorCopy.readable("insufficientAuthentication") == LooprBluetoothFailureCopy.bondRepair)
        #expect(phase(.failed(ConnectionErrorCopy.readable("peerRemovedPairingInformation"))) == .bondRepair)
        #expect(phase(.failed(ConnectionErrorCopy.readable("timedOut(20)"))) != .bondRepair)
    }
}
