import Foundation
import ProtocolKit
import XCTest

final class TokenRoundTripTests: XCTestCase {
    func testPersistenceBytesAreExactCopyAndCannotMutateToken() throws {
        let source = Data([0x00, 0xFF, 0x10, 0x80, 0xDE, 0xAD, 0xBE, 0xEF])
        let token = try HistoryToken(bytes: source)

        var copy = token.persistedBytes
        copy[0] = 0xAA

        XCTAssertEqual(token.persistedBytes, source)
        XCTAssertNotEqual(copy, token.persistedBytes)
    }

    func test_exactEightOpaqueBytesSurviveACKBuildInSourceOrder() throws {
        let tokens = [
            "0000000000000000",
            "1122334455667788",
            "deadbeef11223344",
            "80aa00ff7e010203",
            "00aa112233445566",
            "11223344556677aa"
        ]

        for hex in tokens {
            let tokenBytes = try ProtocolFixtureSupport.data(hex: hex)
            let token = try HistoryToken(bytes: tokenBytes)
            let ack = try CommandBuilder.historyAcknowledgement(sequence: 0xA5, token: token)
            let frame = try FrameDecoder().decode(ack)
            XCTAssertEqual(
                frame.paddedInner,
                Data([0x23, 0xA5, 0x17, 0x01]) + tokenBytes,
                "token bytes changed for \(hex)"
            )
        }
    }

    func testPinnedHistoryACKVectorsAreByteExact() throws {
        for vector in try ProtocolFixtureSupport.historyAckVectors() {
            guard let tokenHex = vector.tokenHex else {
                // The pinned failure vector is intentionally non-tokenized and
                // must not be turned into an ACK.
                continue
            }
            let token = try HistoryToken(bytes: ProtocolFixtureSupport.data(hex: tokenHex))
            let actual = try CommandBuilder.historyAcknowledgement(
                sequence: vector.sequence,
                token: token
            )
            XCTAssertEqual(actual, try ProtocolFixtureSupport.data(hex: vector.fullFrameHex), tokenHex)
            XCTAssertEqual(
                try FrameDecoder().decode(actual).paddedInner,
                try ProtocolFixtureSupport.data(hex: vector.literalTestedInnerHex),
                tokenHex
            )
        }
    }

    func testWrongTokenLengthsAreRejectedWithoutNormalization() {
        for length in [0, 1, 7, 9, 32] {
            XCTAssertThrowsError(try HistoryToken(bytes: Data(repeating: 0xAA, count: length))) { error in
                guard let decodeError = error as? ProtocolDecodeError else {
                    return XCTFail("expected ProtocolDecodeError, got \(error)")
                }
                XCTAssertEqual(decodeError.offset, 0)
                XCTAssertTrue(decodeError.reason.contains("exactly 8 bytes"), decodeError.reason)
            }
        }
    }
}
