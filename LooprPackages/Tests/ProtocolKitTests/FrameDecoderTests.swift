import Foundation
@testable import ProtocolKit
import XCTest

final class FrameDecoderTests: XCTestCase {
    func test_decode_matchesAllPinnedFramesAndPreservesPadding() throws {
        for vector in try ProtocolFixtureSupport.frameVectors() {
            let raw = try ProtocolFixtureSupport.data(hex: vector.hex)
            let declared = Int(raw[1]) | (Int(raw[2]) << 8)
            let expectedInner = Data(raw[4..<(4 + declared - 4)])
            let frame = try FrameDecoder().decode(raw)

            XCTAssertEqual(frame.raw, raw, vector.source)
            XCTAssertEqual(frame.paddedInner, expectedInner, vector.source)
            XCTAssertEqual(frame.declaredLength, UInt16(declared), vector.source)
        }
    }

    func test_declaredLengthBelowCrcSizeIsRejectedAtLengthOffset() throws {
        let raw = try ProtocolFixtureSupport.malformedHex("impossible_length")
        assertDecodeError(tryDecode: { try FrameDecoder().decode(raw) }, offset: 1, reason: "below")

        let decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(raw).isEmpty)
        XCTAssertEqual(decoder.lastError?.offset, 1)
    }

    func test_declaredTotalAbove4096IsRejectedAtLengthOffset() throws {
        let raw = try ProtocolFixtureSupport.malformedHex("oversized_length")
        assertDecodeError(tryDecode: { try FrameDecoder().decode(raw) }, offset: 1, reason: "maximum")

        let decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(raw).isEmpty)
        XCTAssertEqual(decoder.lastError?.offset, 1)
        XCTAssertLessThanOrEqual(decoder.bufferedByteCount, decoder.maximumBufferedBytes)
    }

    func test_totalLength4096AcceptedAnd4097RejectedByStrictAndStreamDecoders() throws {
        let encoder = FrameEncoder()
        let maximumFrame = try encoder.encode(Data(repeating: 0, count: 4_088))
        XCTAssertEqual(maximumFrame.count, Gen4Frame.maximumTotalLength)
        XCTAssertEqual(try FrameDecoder().decode(maximumFrame).paddedInner.count, 4_088)

        let streamDecoder = FrameDecoder()
        XCTAssertEqual(streamDecoder.feed(maximumFrame).count, 1)
        XCTAssertEqual(streamDecoder.maximumObservedBufferedBytes, 4_096)

        let oversized = Self.frameWithDeclaredLength(4_093, totalLength: 4_097)
        assertDecodeError(
            tryDecode: { try FrameDecoder().decode(oversized) },
            offset: 1,
            reason: "maximum"
        )
        let oversizedStreamDecoder = FrameDecoder()
        XCTAssertTrue(oversizedStreamDecoder.feed(oversized).isEmpty)
        XCTAssertEqual(oversizedStreamDecoder.lastError?.offset, 1)
        XCTAssertLessThanOrEqual(
            oversizedStreamDecoder.bufferedByteCount,
            oversizedStreamDecoder.maximumBufferedBytes
        )
    }

    func test_crcValidStructurallyUnpaddedFrameIsRejectedBeforeTailCRCDispatch() {
        let raw = Self.structurallyUnpaddedFrame()

        assertDecodeError(
            tryDecode: { try FrameDecoder().decode(raw) },
            offset: 1,
            reason: "not a multiple of four"
        )
    }

    func test_badLengthCrcRejectedBeforeBodyAndFollowingFrameRecovers() throws {
        let bad = try ProtocolFixtureSupport.malformedHex("corrupt_length_crc")
        let valid = try ProtocolFixtureSupport.data(hex: try ProtocolFixtureSupport.frameVectors()[1].hex)
        let decoder = FrameDecoder()
        let frames = decoder.feed(bad + valid)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, valid)
        XCTAssertEqual(decoder.lastError?.offset, 3)
    }

    func test_badTailCrcIsRejectedBeforeDispatchAndFollowingFrameRecovers() throws {
        let bad = try ProtocolFixtureSupport.malformedHex("corrupt_tail_crc")
        let valid = try ProtocolFixtureSupport.data(hex: try ProtocolFixtureSupport.frameVectors()[1].hex)
        let decoder = FrameDecoder()
        let frames = decoder.feed(bad + valid)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, valid)
        XCTAssertEqual(decoder.lastError?.offset, 8)
    }

    func test_badPayloadCrcIsRejectedBeforeDispatchAndFollowingFrameRecovers() throws {
        let bad = try ProtocolFixtureSupport.malformedHex("corrupt_payload_crc")
        let valid = try ProtocolFixtureSupport.data(hex: try ProtocolFixtureSupport.frameVectors()[1].hex)
        let decoder = FrameDecoder()
        let frames = decoder.feed(bad + valid)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, valid)
        XCTAssertEqual(decoder.lastError?.offset, 8)
    }

    func test_garbageBeforeValidFrameIsSkippedDeterministically() throws {
        let valid = try ProtocolFixtureSupport.data(hex: try ProtocolFixtureSupport.frameVectors()[0].hex)
        let decoder = FrameDecoder()
        let frames = decoder.feed(Data([0x00, 0x19, 0x7E, 0x01, 0x02]) + valid)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, valid)
        XCTAssertLessThanOrEqual(decoder.bufferedByteCount, decoder.maximumBufferedBytes)
    }

    func test_sustainedGarbageRetainsBoundedMemory() {
        let decoder = FrameDecoder()
        let garbage = Data(repeating: 0x55, count: decoder.maximumBufferedBytes * 10)
        XCTAssertTrue(decoder.feed(garbage).isEmpty)
        XCTAssertLessThanOrEqual(decoder.bufferedByteCount, decoder.maximumBufferedBytes)
        XCTAssertLessThanOrEqual(decoder.maximumObservedBufferedBytes, decoder.maximumBufferedBytes)
    }

    func test_validHeaderWithSustainedPartialBodyRetainsBoundedMemory() {
        let decoder = FrameDecoder()
        let header = Self.frameWithDeclaredLength(4_092, totalLength: 4)
        XCTAssertTrue(decoder.feed(header).isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, 4)

        for _ in 0..<20 {
            _ = decoder.feed(Data(repeating: 0x55, count: 100))
        }
        XCTAssertLessThanOrEqual(decoder.bufferedByteCount, decoder.maximumBufferedBytes)
        XCTAssertLessThanOrEqual(decoder.maximumObservedBufferedBytes, decoder.maximumBufferedBytes)
    }

    func test_embeddedMarkerDoesNotSplitAcceptedFrame() throws {
        let nested = try FrameEncoder().encode(Data([0x31, 0x00, 0x00, 0x00]))
        let paddedInner = Data([0x23, 0x00, 0x00, 0x00]) + nested
        let valid = try FrameEncoder().encode(paddedInner)
        let decoder = FrameDecoder()

        let frames = decoder.feed(valid)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].paddedInner, paddedInner)
        XCTAssertEqual(decoder.rejectionCount, 0)
    }

    func test_nestedValidLookingFrameDoesNotEmitBeforeOuterBoundary() throws {
        let nested = try FrameEncoder().encode(Data([0x31, 0x00, 0x00, 0x00]))
        let outer = try FrameEncoder().encode(Data([0x23, 0x00, 0x00, 0x00]) + nested)
        let decoder = FrameDecoder()

        // The nested frame is complete in this prefix, but the outer frame's
        // declared boundary is not.  The stream decoder must retain it as
        // payload and emit nothing early.
        let nestedEnd = 4 + 4 + nested.count
        XCTAssertTrue(decoder.feed(Data(outer.prefix(nestedEnd))).isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, nestedEnd)

        let frames = decoder.feed(Data(outer.dropFirst(nestedEnd)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, outer)
        XCTAssertEqual(frames[0].paddedInner, Data([0x23, 0x00, 0x00, 0x00]) + nested)
    }

    func test_resetDiscardsPartialCandidate() throws {
        let valid = try ProtocolFixtureSupport.data(hex: try ProtocolFixtureSupport.frameVectors()[0].hex)
        let decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(valid.prefix(5)).isEmpty)
        XCTAssertGreaterThan(decoder.bufferedByteCount, 0)

        decoder.reset()
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertEqual(decoder.feed(valid), [try FrameDecoder().decode(valid)])
    }

    private func assertDecodeError(
        tryDecode: () throws -> Frame,
        offset: Int,
        reason: String
    ) {
        XCTAssertThrowsError(try tryDecode()) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("Expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError.offset, offset)
            XCTAssertTrue(decodeError.reason.contains(reason), decodeError.reason)
        }
    }

    private static func frameWithDeclaredLength(_ declared: Int, totalLength: Int) -> Data {
        precondition(declared >= 0 && declared <= Int(UInt16.max))
        precondition(totalLength >= 4)
        let declaredUInt16 = UInt16(declared)
        let low = UInt8(truncatingIfNeeded: declaredUInt16)
        let high = UInt8(truncatingIfNeeded: declaredUInt16 >> 8)
        let lengthBytes = Data([low, high])
        var frame = Data([Gen4Frame.marker, low, high, CRC8.calculate(lengthBytes)])
        frame.append(contentsOf: repeatElement(UInt8(0), count: totalLength - 4))
        return frame
    }

    private static func structurallyUnpaddedFrame() -> Data {
        let inner = Data([0x42])
        let declared = UInt16(inner.count + 4)
        let lengthBytes = Data([
            UInt8(truncatingIfNeeded: declared),
            UInt8(truncatingIfNeeded: declared >> 8)
        ])
        let tail = CRC32.calculate(inner)
        var frame = Data([Gen4Frame.marker])
        frame.append(lengthBytes)
        frame.append(CRC8.calculate(lengthBytes))
        frame.append(inner)
        frame.append(contentsOf: [
            UInt8(truncatingIfNeeded: tail),
            UInt8(truncatingIfNeeded: tail >> 8),
            UInt8(truncatingIfNeeded: tail >> 16),
            UInt8(truncatingIfNeeded: tail >> 24)
        ])
        return frame
    }
}
