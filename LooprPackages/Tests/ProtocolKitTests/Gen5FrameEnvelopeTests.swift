import Foundation
import XCTest
@testable import ProtocolKit

final class Gen5FrameEnvelopeTests: XCTestCase {
    private let codec = Gen5FrameCodec()

    func testCanonicalHelloIsByteExact() throws {
        XCTAssertEqual(CRC16Modbus.calculate([0xaa, 0x01, 0x08, 0x00, 0x00, 0x01]), 0x71E6)
        let encoded = try codec.encode(Data([0x23, 0x01, 0x91, 0x01]))
        XCTAssertEqual(encoded.hex, "aa0108000001e67123019101363e5c8d")
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.paddedInner, Data([0x23, 0x01, 0x91, 0x01]))
        XCTAssertEqual(decoded.directionMarker, Gen5FrameEnvelope.outboundDirectionMarker)
    }

    func testObservedInboundMarkerIsAcceptedWhenBothCRCsAreValid() throws {
        let raw = try XCTUnwrap(Data(hex: "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"))
        let decoded = try codec.decode(raw)
        XCTAssertEqual(decoded.directionMarker, Gen5FrameEnvelope.observedInboundDirectionMarker)
    }

    func testFragmentedAndCoalescedFramesRemainBoundedAndOrdered() throws {
        let first = try codec.encode(Data([0x23, 0x01, 0x91, 0x01]))
        let second = try codec.encode(Data([0x23, 0x02, 0x22]))
        let decoder = Gen5FrameStreamDecoder()
        XCTAssertTrue(decoder.feed(first.prefix(5)).isEmpty)
        let frames = decoder.feed(Data(first.dropFirst(5)) + second)
        XCTAssertEqual(frames.map(\.paddedInner), [
            Data([0x23, 0x01, 0x91, 0x01]),
            Data([0x23, 0x02, 0x22, 0x00])
        ])
    }

    func testBadHeaderAndTailChecksumsFailClosed() throws {
        let encoded = try codec.encode(Data([0x23, 0x01, 0x91, 0x01]))
        var badHeader = encoded
        badHeader[6] ^= 0xFF
        XCTAssertThrowsError(try codec.decode(badHeader))
        var badTail = encoded
        badTail[badTail.count - 1] ^= 0xFF
        XCTAssertThrowsError(try codec.decode(badTail))
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
