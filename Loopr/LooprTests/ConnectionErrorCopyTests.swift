import Foundation
import Testing
@testable import Loopr

/// `BluetoothAdoptionRuntimeState.lastError` is built with
/// `String(describing:)`, so these raw values are exactly what the runtime
/// produces today. None of them may reach a user.
@MainActor
struct ConnectionErrorCopyTests {
    @Test
    func rawTransportValuesBecomeInstructions() {
        #expect(
            ConnectionErrorCopy.readable("outOfRange")
                == "Your band is out of range. Bring it closer to your iPhone."
        )
        #expect(
            ConnectionErrorCopy.readable("bluetoothOff")
                .hasPrefix("Bluetooth is off.")
        )
        #expect(
            ConnectionErrorCopy.readable("peerRemovedPairing")
                .contains("forget the band")
        )
        #expect(
            ConnectionErrorCopy.readable("timedOut(20)")
                .contains("pulses blue")
        )
    }

    @Test
    func unrecognizedErrorsNeverLeakInternals() {
        let raw = "invalidState(\"a write is already pending\")"
        let shown = ConnectionErrorCopy.readable(raw)

        #expect(!shown.contains("invalidState"))
        #expect(shown.contains("band"))
    }
}
