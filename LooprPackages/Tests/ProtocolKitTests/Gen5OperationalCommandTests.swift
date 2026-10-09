import Foundation
import XCTest
@testable import ProtocolKit

final class Gen5OperationalCommandTests: XCTestCase {
    private let encoder = Gen5OperationalCommandEncoder()

    func testCapturedHelloAndHistoryAcknowledgementFrames() throws {
        // OpenStrap protocol@c525e29e:test/gen5_test.dart:56-62,150-155.
        XCTAssertEqual(
            try encoder.encode(.clientHello, sequence: 1).hex,
            "aa0108000001e67123019101363e5c8d"
        )
        let token = Data([0x41, 0xB6, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00])
        XCTAssertEqual(
            try encoder.encode(.historyAcknowledgement(token), sequence: 0).hex,
            "aa0110000001e0d12300170141b6010010000000667da4fb"
        )
        XCTAssertThrowsError(try encoder.encode(.historyAcknowledgement(Data([0x01])), sequence: 0))
    }

    func testOnlySourceBackedBasicCommandsEncode() throws {
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:153-156,352-359,393-395.
        let codec = Gen5FrameCodec()
        for (command, expected) in [
            (Gen5OperationalCommand.battery, Data([0x23, 9, 0x1A, 0])),
            (.clockRead, Data([0x23, 9, 0x93, 0])),
            (.liveHeartRate(true), Data([0x23, 9, 0x03, 0x01])),
            (.dataRange, Data([0x23, 9, 0x22, 0])),
            (.sendHistory, Data([0x23, 9, 0x16, 0]))
        ] {
            let frame = try encoder.encode(command, sequence: 9)
            XCTAssertEqual(try codec.decode(frame).paddedInner, expected)
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
