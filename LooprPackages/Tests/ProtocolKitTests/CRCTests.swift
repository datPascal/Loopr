import Foundation
import ProtocolKit
import XCTest

final class CRCTests: XCTestCase {
    func test_crc8_matches_allPinnedLengthFields() throws {
        for vector in try ProtocolFixtureSupport.frameVectors() {
            let bytes = try ProtocolFixtureSupport.data(hex: vector.hex)
            XCTAssertGreaterThanOrEqual(bytes.count, 4)
            let lengthBytes = Data(bytes[1...2])
            XCTAssertEqual(CRC8.calculate(lengthBytes), bytes[3], vector.source)
            XCTAssertEqual(crc8(lengthBytes), bytes[3], vector.source)
        }
    }

    func test_crc32_matches_allPinnedPaddedInnerFields() throws {
        for vector in try ProtocolFixtureSupport.frameVectors() {
            let bytes = try ProtocolFixtureSupport.data(hex: vector.hex)
            let declared = Int(bytes[1]) | (Int(bytes[2]) << 8)
            let innerEnd = 4 + declared - 4
            let paddedInner = Data(bytes[4..<innerEnd])
            let expected = UInt32(bytes[innerEnd])
                | (UInt32(bytes[innerEnd + 1]) << 8)
                | (UInt32(bytes[innerEnd + 2]) << 16)
                | (UInt32(bytes[innerEnd + 3]) << 24)
            XCTAssertEqual(CRC32.calculate(paddedInner), expected, vector.source)
            XCTAssertEqual(crc32(paddedInner), expected, vector.source)
        }
    }
}
