import Foundation
import XCTest
@testable import ProtocolKit

final class Gen5RecordVersionDecoderTests: XCTestCase {
    private let records = Gen5RecordDecoder()

    func testRealV18FixtureDecodesOnlyValidatedProductFields() throws {
        let frame = try XCTUnwrap(Data(hex:
            "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b" +
            "0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7" +
            "000901f10b0007010c020c00000000000000000000000000000000000000000000000" +
            "100656f1e1e0000009d61a7c00000003e862817"))
        let inner = try Gen5FrameCodec().decode(frame).paddedInner
        guard case .v18(let sample) = try records.decode(inner) else { return XCTFail("expected v18") }
        XCTAssertEqual(sample.timestampSeconds, 1_780_916_150)
        XCTAssertEqual(sample.recordIndex, 25_443_699)
        XCTAssertEqual(sample.heartRate, 102)
        XCTAssertEqual(sample.rrIntervalsMilliseconds, [602, 613])
        XCTAssertEqual(try XCTUnwrap(sample.dynamicAccelerationG), 0.00916, accuracy: 0.001)
        XCTAssertEqual(sample.gravityG[0], -0.7252, accuracy: 0.001)
    }

    func testV20AndV21AreRawArchiveOnly() throws {
        var v20 = Data(repeating: 0, count: 2_128)
        v20[0] = 0x2F; v20[1] = 20
        guard case .v20Raw(let optical) = try records.decode(v20) else { return XCTFail("expected v20 raw") }
        XCTAssertEqual(optical.raw, v20)

        var v21 = Data(repeating: 0, count: 1_232)
        v21[0] = 0x2F; v21[1] = 21
        v21.setU16(100, at: 16); v21.setU16(100, at: 622)
        guard case .v21Raw(let imu) = try records.decode(v21) else { return XCTFail("expected v21 raw") }
        XCTAssertEqual(imu.raw, v21)

        // Partially filled buffers are valid. The count fields report how
        // many entries are live, not whether the buffer reached capacity.
        v21.setU16(1, at: 16); v21.setU16(42, at: 622)
        guard case .v21Raw = try records.decode(v21) else {
            return XCTFail("expected partially filled v21 raw buffer")
        }
    }

    func testRealV26UsesCapturedUInt16RecordIndexAndArchivesSamplesWithoutMetricMapping() throws {
        // OpenStrap protocol feat/multiband-whoop5,
        // test/gen5_historical_test.dart:108-132,163-190.
        let frame = try XCTUnwrap(Data(hex:
            "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46f" +
            "c8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe8" +
            "4fe15ff5cff405fb33c50080101006cb67c17"))
        let inner = try Gen5FrameCodec().decode(frame).paddedInner
        guard case .v26Archive(let waveform) = try records.decode(inner) else { return XCTFail("expected v26") }
        XCTAssertEqual(waveform.recordIndex, 16_813)
        XCTAssertNotEqual(waveform.recordIndex, inner.testU32(at: 3))
        XCTAssertEqual(waveform.timestampSeconds, 1_780_917_232)
        XCTAssertEqual(waveform.samples.count, 24)
        XCTAssertEqual(Array(waveform.samples.prefix(4)), [-1432, -1332, -1139, -954])
    }

    func testV18DoesNotUseEstimatorAgreementAsHeartRateValidity() throws {
        var inner = Data(repeating: 0, count: 112)
        inner[0] = 0x2F; inner[1] = 18
        inner[14] = 72
        inner[15] = 2
        inner.setU16(800, at: 16); inner.setU16(810, at: 18)
        inner[28] = 0 // bit 7 clear, but HR is still valid
        inner.setFloat32(0.01, at: 33)
        inner.setFloat32(2.5, at: 37)
        inner.setFloat32(2.5, at: 41)
        inner.setFloat32(2.5, at: 45)

        guard case .v18(let sample) = try records.decode(inner) else {
            return XCTFail("expected v18")
        }
        XCTAssertEqual(sample.heartRate, 72)
        XCTAssertEqual(sample.rrIntervalsMilliseconds, [800, 810])
        XCTAssertEqual(sample.gravityG, [2.5, 2.5, 2.5])
    }

    func testImplausibleV18HeartRateDoesNotDiscardBeatsOrMotion() throws {
        var inner = Data(repeating: 0, count: 112)
        inner[0] = 0x2F; inner[1] = 18
        inner[14] = 240
        inner[15] = 2
        inner.setU16(800, at: 16); inner.setU16(810, at: 18)
        inner.setFloat32(0.01, at: 33)
        inner.setFloat32(0, at: 37)
        inner.setFloat32(0, at: 41)
        inner.setFloat32(1, at: 45)

        guard case .v18(let sample) = try records.decode(inner) else {
            return XCTFail("expected v18")
        }
        XCTAssertNil(sample.heartRate)
        XCTAssertEqual(sample.rrIntervalsMilliseconds, [800, 810])
        XCTAssertEqual(sample.gravityG, [0, 0, 1])
    }

    func testNonRecordPacketCannotDecodeAsGen5History() {
        var control = Data(repeating: 0, count: 112)
        control[0] = 0x32
        control[1] = 18
        XCTAssertThrowsError(try records.decode(control))
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

    mutating func setU16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func setFloat32(_ value: Float, at offset: Int) {
        let bits = value.bitPattern
        self[offset] = UInt8(truncatingIfNeeded: bits)
        self[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: bits >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: bits >> 24)
    }

    func testU32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
