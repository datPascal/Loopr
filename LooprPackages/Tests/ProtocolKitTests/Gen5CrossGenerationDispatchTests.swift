import Foundation
import XCTest
@testable import ProtocolKit

final class Gen5CrossGenerationDispatchTests: XCTestCase {
    private let dispatcher = ProfiledFrameDispatcher()

    func testGenerationIsSelectedOnlyByBandProfile() throws {
        let gen4 = try XCTUnwrap(Data(hex: "aa0800a823002300ada86a2d"))
        let gen5 = try XCTUnwrap(Data(hex: "aa0108000001e67123019101363e5c8d"))

        guard case .gen4 = try dispatcher.decode(gen4, profile: .gen4) else { return XCTFail("expected gen4") }
        XCTAssertThrowsError(try dispatcher.decode(gen4, profile: gen5Profile))
        guard case .gen5 = try dispatcher.decode(gen5, profile: gen5Profile) else { return XCTFail("expected gen5") }
        XCTAssertThrowsError(try dispatcher.decode(gen5, profile: .gen4))
    }

    func testMalformedVectorsFailClosedWithTypedErrors() throws {
        let valid = try XCTUnwrap(Data(hex: "aa0108000001e67123019101363e5c8d"))
        var vectors: [Data] = [Data(), Data(valid.prefix(7)), valid + Data([0])]
        var wrongMarker = valid; wrongMarker[0] = 0xAB; vectors.append(wrongMarker)
        var wrongLength = valid; wrongLength[2] = 0xFF; vectors.append(wrongLength)
        var badCRC16 = valid; badCRC16[6] ^= 1; vectors.append(badCRC16)
        var badCRC32 = valid; badCRC32[badCRC32.count - 1] ^= 1; vectors.append(badCRC32)

        for vector in vectors {
            XCTAssertThrowsError(try dispatcher.decode(vector, profile: gen5Profile)) { error in
                guard case ProfiledFrameDispatchError.malformedGen5 = error else {
                    return XCTFail("expected typed Gen 5 failure, got \(error)")
                }
            }
        }
    }

    func testFragmentedAndCoalescedStreamNeverDispatchesInvalidCandidate() throws {
        let valid = try XCTUnwrap(Data(hex: "aa0108000001e67123019101363e5c8d"))
        var invalid = valid; invalid[invalid.count - 1] ^= 1
        let stream = Gen5FrameStreamDecoder()
        XCTAssertTrue(stream.feed(valid.prefix(3)).isEmpty)
        let decoded = stream.feed(Data(valid.dropFirst(3)) + invalid + valid)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertNotNil(stream.lastError)
    }

    private var gen5Profile: BandProfile {
        BandProfile(
            generation: .gen5,
            model: .unknownGen5,
            gatt: .gen5,
            framing: .gen5,
            commands: .none,
            records: .gen5ArchiveOnly,
            firmwarePolicy: .denyUnknownGen5
        )
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
            data.append(byte); index = next
        }
        self = data
    }
}
