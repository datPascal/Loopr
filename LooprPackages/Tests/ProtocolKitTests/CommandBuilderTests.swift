import Foundation
import ProtocolKit
import XCTest

final class CommandBuilderTests: XCTestCase {
    func testFivePinnedInitializationBuildersAreByteExact() throws {
        let actual: [Data] = [
            try CommandBuilder.hello(),
            try CommandBuilder.advertisingName(),
            try CommandBuilder.dataRange(),
            try CommandBuilder.alarmTime(),
            try CommandBuilder.startHistoricalData()
        ]
        let expected = try ProtocolFixtureSupport.initFrameVectors().map {
            try ProtocolFixtureSupport.data(hex: $0.hex)
        }

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 5)
    }

    func testSetClockVectorsPreserveLittleEndianFieldsAndFrameBytes() throws {
        for vector in try ProtocolFixtureSupport.clockVectors() where vector.literalTestedInnerHex.count > 8 {
            let inner = try ProtocolFixtureSupport.data(hex: vector.literalTestedInnerHex)
            XCTAssertEqual(inner.count, 12)
            XCTAssertEqual(inner[0], 0x23)
            XCTAssertEqual(inner[1], vector.sequence)
            XCTAssertEqual(inner[2], 0x0A)
            XCTAssertEqual(inner[9], 0)
            XCTAssertEqual(inner[10], 0)
            XCTAssertEqual(inner[11], 0)

            let unixSeconds = UInt32(inner[3])
                | (UInt32(inner[4]) << 8)
                | (UInt32(inner[5]) << 16)
                | (UInt32(inner[6]) << 24)
            let subsecondTicks = UInt16(inner[7]) | (UInt16(inner[8]) << 8)
            let actual = try CommandBuilder.setClock(
                sequence: vector.sequence,
                unixSeconds: unixSeconds,
                subsecondTicks: subsecondTicks
            )

            XCTAssertEqual(actual, try ProtocolFixtureSupport.data(hex: vector.fullFrameHex))
            XCTAssertEqual(try FrameDecoder().decode(actual).paddedInner, inner)
        }
    }

    func testSetClockUsesUInt32SecondsUInt16TicksAndTwoZeroBytes() throws {
        let actual = try CommandBuilder.setClock(
            sequence: 0x5A,
            unixSeconds: 0x7856_3412,
            subsecondTicks: 0xBEEF
        )
        let inner = try FrameDecoder().decode(actual).paddedInner
        XCTAssertEqual(inner, Data([
            0x23, 0x5A, 0x0A,
            0x12, 0x34, 0x56, 0x78,
            0xEF, 0xBE,
            0x00, 0x00, 0x00
        ]))
    }

    func testHistoryACKBuilderUsesExactOpaqueTokenBytes() throws {
        let tokenBytes = try ProtocolFixtureSupport.data(hex: "0102030405060708")
        let token = try HistoryToken(bytes: tokenBytes)
        let actual = try CommandBuilder.historyACK(sequence: 0x05, token: token)
        XCTAssertEqual(
            try FrameDecoder().decode(actual).paddedInner,
            Data([0x23, 0x05, 0x17, 0x01]) + tokenBytes
        )
    }

    func testTypedWriterProducesSamePinnedInitializationBytes() throws {
        let writer = ProductionCommandWriter()
        XCTAssertEqual(
            try writer.encode(.hello(sequence: 0)),
            try CommandBuilder.hello()
        )
        XCTAssertEqual(
            try writer.encode(.startHistoricalData(sequence: 4)),
            try CommandBuilder.startHistoricalData()
        )
    }
}
