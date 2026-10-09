import Foundation
@testable import ProtocolKit
import XCTest

final class FrameEncoderTests: XCTestCase {
    func test_encode_matches_allPinnedFramesByteForByte() throws {
        let encoder = FrameEncoder()
        for vector in try ProtocolFixtureSupport.frameVectors() {
            let expected = try ProtocolFixtureSupport.data(hex: vector.hex)
            let declared = Int(expected[1]) | (Int(expected[2]) << 8)
            let inner = Data(expected[4..<(4 + declared - 4)])
            XCTAssertEqual(try encoder.encode(inner), expected, vector.source)
        }
    }

    func test_strictEncoderRejectsUnpaddedInputAndOversizedFrame() {
        let encoder = FrameEncoder()
        XCTAssertThrowsError(try encoder.encode(Data([0x23]))) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("Expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError.offset, 0)
            XCTAssertTrue(decodeError.reason.contains("four-byte"), decodeError.reason)
        }

        XCTAssertThrowsError(try encoder.encode(Data(repeating: 0, count: 4_092))) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("Expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError.offset, 1)
            XCTAssertTrue(decodeError.reason.contains("exceeds maximum"), decodeError.reason)
        }
    }

    func test_totalLength4096IsAcceptedAndNextPaddedBoundaryIsRejected() throws {
        let encoder = FrameEncoder()
        let maximumInner = Data(repeating: 0, count: 4_088)
        let frame = try encoder.encode(maximumInner)
        XCTAssertEqual(frame.count, 4_096)

        // Padded inner lengths are multiples of four, so the next representable
        // frame is 4,100 bytes; it must remain outside the 4,096-byte cap.
        XCTAssertThrowsError(try encoder.encode(Data(repeating: 0, count: 4_092))) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("Expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError.offset, 1)
            XCTAssertTrue(decodeError.reason.contains("4100"), decodeError.reason)
        }
    }
}
