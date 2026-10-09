import Foundation
import XCTest
@testable import ProtocolKit

final class Gen5CommandAllowlistFirewallTests: XCTestCase {
    func testInitialVocabularyContainsOnlyClientHello() throws {
        XCTAssertEqual(Gen5InitialCommand.allowedOpcodes, [0x91])
        let encoded = try Gen5InitialCommandEncoder().encode(.clientHello(sequence: 1))
        XCTAssertEqual(try Gen5FrameCodec().decode(encoded).paddedInner, Data([0x23, 0x01, 0x91, 0x01]))
    }

    func testEveryDeferredOpcodeIsAbsentFromInitialAllowlist() {
        let deferred: Set<UInt8> = [
            146, 147, // clock set/read
            0x16, 0x23, // history request/result ACK
            0x13, 0x42, 0x44, 0x45, // haptic/alarm
            0x4D, 0x78 // rename/config/deep buffer
        ]
        XCTAssertTrue(Gen5InitialCommand.allowedOpcodes.isDisjoint(with: deferred))
    }
}
