import Foundation
@testable import ProtocolKit
import XCTest

final class ReassemblerPropertyTests: XCTestCase {
    func test_oneFrameInOneNotificationEmitsExactlyOneByteExactFrame() throws {
        let expected = try pinnedFrame(at: 0)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(expected)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].raw, expected)
    }

    func test_everyPossibleSplitPointEmitsOneByteExactFrame() throws {
        let expected = try pinnedFrame(at: 0)

        for split in 1..<expected.count {
            var reassembler = FrameReassembler()
            let first = Data(expected.prefix(split))
            let second = Data(expected.dropFirst(split))

            XCTAssertTrue(reassembler.ingest(first).isEmpty, "split \(split)")
            let frames = reassembler.ingest(second)

            XCTAssertEqual(frames.count, 1, "split \(split)")
            XCTAssertEqual(frames[0].raw, expected, "split \(split)")
            XCTAssertEqual(reassembler.bufferedByteCount, 0, "split \(split)")
        }
    }

    func test_oneBytePerNotificationEmitsOnlyAfterFinalByte() throws {
        let expected = try pinnedFrame(at: 1)
        var reassembler = FrameReassembler()

        for index in 0..<expected.count {
            let frames = reassembler.ingest(Data([expected[index]]))
            if index < expected.count - 1 {
                XCTAssertTrue(frames.isEmpty, "byte \(index)")
            } else {
                XCTAssertEqual(frames.count, 1)
                XCTAssertEqual(frames[0].raw, expected)
            }
        }
    }

    func test_twoOrMoreFramesInOneNotificationEmitsAllFramesInOrder() throws {
        let expected = try (0..<3).map { try pinnedFrame(at: $0) }
        let input = expected.reduce(into: Data()) { $0.append($1) }
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(input)

        XCTAssertEqual(frames.map(\.raw), expected)
        XCTAssertEqual(reassembler.bufferedByteCount, 0)
    }

    func test_garbageBeforeFrameIsSkipped() throws {
        let expected = try pinnedFrame(at: 2)
        var reassembler = FrameReassembler()
        let garbage = Data([0x00, 0x01, 0x7E, 0x10, 0xFE, 0x55])

        let frames = reassembler.ingest(garbage + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
    }

    func test_embeddedStartMarkerInsideAcceptedFrameIsNotASecondFrame() throws {
        let nested = try FrameEncoder().encode(Data([0x31, 0x00, 0x00, 0x00]))
        let paddedInner = Data([0x23, 0x00, 0x00, 0x00]) + nested
        let expected = try FrameEncoder().encode(paddedInner)
        var reassembler = FrameReassembler()

        let nestedEnd = 4 + 4 + nested.count
        XCTAssertTrue(reassembler.ingest(Data(expected.prefix(nestedEnd))).isEmpty)
        let frames = reassembler.ingest(Data(expected.dropFirst(nestedEnd)))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].paddedInner, paddedInner)
        XCTAssertEqual(reassembler.rejectionCount, 0)
    }

    func test_crcValidStructurallyUnpaddedFrameIsRejectedAndFollowingFrameRecovers() throws {
        let corrupt = Self.structurallyUnpaddedFrame()
        let expected = try pinnedFrame(at: 1)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(corrupt + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertEqual(reassembler.lastError?.offset, 1)
        XCTAssertTrue(reassembler.lastError?.reason.contains("not a multiple of four") == true)
    }

    func test_corruptLengthCRCRejectsCandidateAndRecoversFollowingFrame() throws {
        let corrupt = try ProtocolFixtureSupport.malformedHex("corrupt_length_crc")
        let expected = try pinnedFrame(at: 1)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(corrupt + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertEqual(reassembler.lastError?.offset, 3)
        XCTAssertGreaterThanOrEqual(reassembler.rejectionCount, 1)
    }

    func test_corruptPayloadCRCRejectsCandidateAndRecoversFollowingFrame() throws {
        let corrupt = try ProtocolFixtureSupport.malformedHex("corrupt_payload_crc")
        let expected = try pinnedFrame(at: 1)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(corrupt + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertEqual(reassembler.lastError?.offset, 8)
        XCTAssertGreaterThanOrEqual(reassembler.rejectionCount, 1)
    }

    func test_corruptTailCRCRejectsCandidateAndRecoversFollowingFrame() throws {
        let corrupt = try ProtocolFixtureSupport.malformedHex("corrupt_tail_crc")
        let expected = try pinnedFrame(at: 1)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(corrupt + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertEqual(reassembler.lastError?.offset, 8)
        XCTAssertGreaterThanOrEqual(reassembler.rejectionCount, 1)
    }

    func test_droppedMiddleBytesFollowedByValidFrameStillRecoversTrailingFrame() throws {
        let longFrame = try FrameEncoder().encode(Data(repeating: 0x11, count: 32))
        let expected = try pinnedFrame(at: 1)

        // Remove bytes from the body of a candidate whose header remains
        // valid.  The trailing frame marker consequently overlaps the first
        // candidate's declared boundary and exercises loss recovery after a
        // tail-CRC rejection.
        let dropped = Data(longFrame.prefix(8)) + Data(longFrame.dropFirst(12))
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(dropped + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertGreaterThanOrEqual(reassembler.rejectionCount, 1)
        XCTAssertLessThanOrEqual(reassembler.bufferedByteCount, reassembler.maximumBufferedBytes)
    }

    func test_impossibleAndOversizedLengthsRejectWithoutUnboundedRetention() throws {
        let impossible = try ProtocolFixtureSupport.malformedHex("impossible_length")
        let oversized = try ProtocolFixtureSupport.malformedHex("oversized_length")
        let expected = try pinnedFrame(at: 3)
        var reassembler = FrameReassembler()

        let frames = reassembler.ingest(impossible + oversized + expected)

        XCTAssertEqual(frames.map(\.raw), [expected])
        XCTAssertGreaterThanOrEqual(reassembler.rejectionCount, 2)
        XCTAssertLessThanOrEqual(reassembler.bufferedByteCount, reassembler.maximumBufferedBytes)
        XCTAssertLessThanOrEqual(
            reassembler.maximumObservedBufferedBytes,
            reassembler.maximumBufferedBytes
        )
    }

    func test_validHeaderWithPartialBodyRetainsBoundedMemory() {
        let declared = 4_092 // 4,088-byte padded inner + 4-byte tail CRC.
        let lengthBytes = Data([
            UInt8(truncatingIfNeeded: declared),
            UInt8(truncatingIfNeeded: declared >> 8)
        ])
        let header = Data([Gen4Frame.marker]) + lengthBytes + Data([CRC8.calculate(lengthBytes)])
        var reassembler = FrameReassembler()

        XCTAssertTrue(reassembler.ingest(header).isEmpty)
        XCTAssertEqual(reassembler.bufferedByteCount, header.count)

        for _ in 0..<20 {
            XCTAssertTrue(reassembler.ingest(Data(repeating: 0x55, count: 100)).isEmpty)
        }

        XCTAssertLessThanOrEqual(reassembler.bufferedByteCount, reassembler.maximumBufferedBytes)
        XCTAssertLessThanOrEqual(
            reassembler.maximumObservedBufferedBytes,
            reassembler.maximumBufferedBytes
        )
    }

    func test_exact4096ByteFrameIsAcceptedAndNextPaddedBoundaryIsRejectedAndRecovers() throws {
        let maximum = try FrameEncoder().encode(Data(repeating: 0, count: 4_088))
        let nextPaddedBoundary = Self.frame(paddedInner: Data(repeating: 0, count: 4_092))
        let expected = try pinnedFrame(at: 0)
        var reassembler = FrameReassembler()

        XCTAssertEqual(maximum.count, Gen4Frame.maximumTotalLength)
        let maximumFrames = reassembler.ingest(maximum)
        XCTAssertEqual(maximumFrames.count, 1)
        XCTAssertEqual(maximumFrames[0].raw, maximum)
        XCTAssertEqual(reassembler.maximumObservedBufferedBytes, Gen4Frame.maximumTotalLength)

        let recoveredFrames = reassembler.ingest(nextPaddedBoundary + expected)
        XCTAssertEqual(recoveredFrames.map(\.raw), [expected])
        XCTAssertEqual(reassembler.lastError?.offset, 1)
        XCTAssertTrue(reassembler.lastError?.reason.contains("exceeds maximum") == true)
        XCTAssertLessThanOrEqual(reassembler.bufferedByteCount, reassembler.maximumBufferedBytes)
        XCTAssertLessThanOrEqual(
            reassembler.maximumObservedBufferedBytes,
            reassembler.maximumBufferedBytes
        )
    }

    func test_resetDiscardsPartialFrameStateBeforeFreshFrame() throws {
        let expected = try pinnedFrame(at: 4)
        var reassembler = FrameReassembler()

        XCTAssertTrue(reassembler.ingest(Data(expected.prefix(5))).isEmpty)
        XCTAssertGreaterThan(reassembler.bufferedByteCount, 0)
        reassembler.reset()
        XCTAssertEqual(reassembler.bufferedByteCount, 0)

        let frames = reassembler.ingest(expected)
        XCTAssertEqual(frames.map(\.raw), [expected])
    }

    func test_reassemblerCopiesHaveIndependentValueState() throws {
        let expected = try pinnedFrame(at: 0)
        var first = FrameReassembler()
        var copy = first

        XCTAssertTrue(first.ingest(Data(expected.prefix(5))).isEmpty)
        XCTAssertEqual(copy.bufferedByteCount, 0)
        XCTAssertEqual(copy.ingest(expected).map(\.raw), [expected])
    }

    private func pinnedFrame(at index: Int) throws -> Data {
        let vectors = try ProtocolFixtureSupport.frameVectors()
        return try ProtocolFixtureSupport.data(hex: vectors[index].hex)
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

    private static func frame(paddedInner: Data) -> Data {
        precondition(paddedInner.count.isMultiple(of: 4))
        let declared = UInt16(paddedInner.count + 4)
        let lengthBytes = Data([
            UInt8(truncatingIfNeeded: declared),
            UInt8(truncatingIfNeeded: declared >> 8)
        ])
        let tail = CRC32.calculate(paddedInner)
        var frame = Data([Gen4Frame.marker])
        frame.append(lengthBytes)
        frame.append(CRC8.calculate(lengthBytes))
        frame.append(paddedInner)
        frame.append(contentsOf: [
            UInt8(truncatingIfNeeded: tail),
            UInt8(truncatingIfNeeded: tail >> 8),
            UInt8(truncatingIfNeeded: tail >> 16),
            UInt8(truncatingIfNeeded: tail >> 24)
        ])
        return frame
    }
}
