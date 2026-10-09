import Foundation
import ProtocolKit
import XCTest

final class PacketTypeTests: XCTestCase {
    func testV24RejectsPayloadBelowOpenStrapCompleteRecordFloor() throws {
        let raw = try ProtocolFixtureSupport.recordHex("v24_literal_96b.json")
        let truncated = Data(raw.prefix(88))
        XCTAssertThrowsError(try HistoricalRecord.decode(truncated)) { error in
            guard case ProtocolDecodeError.outOfBounds = error else {
                return XCTFail("Expected typed truncation, got \(error)")
            }
        }
    }
    func testWHOOP4HistoricalRRBlockPreservesVerifiedIntervals() throws {
        let raw = try ProtocolFixtureSupport.recordHex("v24_literal_96b.json")
        guard case .historicalRecord(.decoded(let record)) = try PacketDecoder.decode(raw) else {
            return XCTFail("Expected v24")
        }
        XCTAssertEqual(record.rrIntervalsMilliseconds, [728, 501])
        XCTAssertEqual(record.ppgGreen, 3_999)
        XCTAssertEqual(record.ppgRedIR, 33_023)
        XCTAssertEqual(record.skinContact, 70)
        XCTAssertEqual(record.spo2RedRaw, 534)
        XCTAssertEqual(record.spo2IRRaw, 644)
        XCTAssertEqual(record.unidentified68, 700)
        XCTAssertEqual(record.ambientRaw, 646)
        var malformed = raw
        malformed[18] = 5
        guard case .historicalRecord(.unsupported) = try PacketDecoder.decode(malformed) else {
            return XCTFail("RR count must not read beyond its field block")
        }
    }

    func testWHOOP4V24FixtureMapsAllRelativeADCFieldsWithoutHealthMetricNames() throws {
        let raw = try ProtocolFixtureSupport.recordHex("v24_literal_96b.json")
        guard case .decoded(let record) = try HistoricalRecord.decode(raw) else {
            return XCTFail("Expected v24 fixture to decode")
        }
        XCTAssertEqual(record.ppgGreen, 3_999)
        XCTAssertEqual(record.ppgRedIR, 33_023)
        XCTAssertEqual(record.skinContact, 70)
        XCTAssertEqual(record.spo2RedRaw, 534)
        XCTAssertEqual(record.spo2IRRaw, 644)
        XCTAssertEqual(record.unidentified68, 700)
        XCTAssertEqual(record.ambientRaw, 646)
    }

    func testSyntheticV24TemperatureUsesByte72AndRejectsImplausibleValues() throws {
        var raw = try ProtocolFixtureSupport.recordHex("v24_synthetic_temperature_35c.json")
        func decoded(_ bytes: Data) throws -> DecodedHistoricalRecord {
            guard case .decoded(let record) = try HistoricalRecord.decode(bytes) else { throw NSError(domain: "test", code: 1) }
            return record
        }
        XCTAssertEqual(try decoded(raw).skinTemperatureCelsius, 35)
        XCTAssertEqual(try decoded(raw).unidentified68, 700)
        raw[68] = 0; raw[69] = 0
        XCTAssertEqual(try decoded(raw).skinTemperatureCelsius, 35)
        for value in [UInt16(0), 149, 451, UInt16.max] {
            raw[72] = UInt8(truncatingIfNeeded: value); raw[73] = UInt8(truncatingIfNeeded: value >> 8)
            XCTAssertNil(try decoded(raw).skinTemperatureCelsius)
        }
        for value in [UInt16(150), 450] {
            raw[72] = UInt8(truncatingIfNeeded: value); raw[73] = UInt8(truncatingIfNeeded: value >> 8)
            XCTAssertEqual(try decoded(raw).skinTemperatureCelsius, Double(value) / 10)
        }
    }

    func test_dispatchRecognizesEveryPinnedPacketType() throws {
        let cases: [(UInt8, (DecodedPacket) -> Bool)] = [
            (0x24, { if case .commandResponse(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x28, { if case .compactLiveHeartRate(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x2B, { if case .realtimeRaw(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x30, { if case .event(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x31, { if case .historyMetadata(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x32, { if case .console(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false }),
            (0x33, { if case .realtimeIMU(let payload) = $0 { return payload == Data([0xA1, 0x00]) }; return false })
        ]

        for (type, assertion) in cases {
            let packet = try PacketDecoder().decode(Data([type, 0xA1, 0x00]))
            XCTAssertTrue(assertion(packet), "packet type 0x\(String(type, radix: 16)) did not dispatch")
            XCTAssertEqual(packet.packetType?.rawValue, type)
        }
    }

    func test_historicalPacketDispatchesThroughTypedRecordResult() throws {
        let raw = try ProtocolFixtureSupport.recordHex("v9_synthetic_test_helper.json")
        let packet = try PacketDecoder().decode(raw)

        guard case .historicalRecord(.decoded(let record)) = packet else {
            return XCTFail("recognized historical version must decode")
        }
        XCTAssertEqual(record.version, 9)
        XCTAssertEqual(record.timestampSeconds, 0x1122_3344)
        XCTAssertEqual(record.counter, 0x0A0B_0C0D)
        XCTAssertEqual(record.heartRate, 60)
        XCTAssertEqual(record.raw, raw)
    }

    func test_allPinnedHistoricalVersionsUseOnlyProvenFields() throws {
        let expectations: [(String, UInt8, UInt32, UInt32, UInt8?)] = [
            ("v7_synthetic_test_helper.json", 7, 0x1122_3344, 0x0A0B_0C0D, 60),
            ("v9_synthetic_test_helper.json", 9, 0x1122_3344, 0x0A0B_0C0D, 60),
            ("v12_raw_88b.json", 12, 1_783_529_886, 21_658_795, 86),
            ("v18_synthetic_test_helper.json", 18, 0x1122_3344, 0x0A0B_0C0D, 60),
            ("v24_literal_96b.json", 24, 1_775_395_266, 32_324_849, 98),
            ("v25_frame_0.json", 25, 1_781_202_813, 26_624, nil)
        ]

        for (fixture, version, timestamp, counter, heartRate) in expectations {
            let raw = try ProtocolFixtureSupport.recordHex(fixture)
            let result = try HistoricalRecord.decode(raw)
            guard case .decoded(let record) = result else {
                return XCTFail("pinned version \(version) unexpectedly unsupported")
            }
            XCTAssertEqual(record.version, version, fixture)
            XCTAssertEqual(record.timestampSeconds, timestamp, fixture)
            XCTAssertEqual(record.counter, counter, fixture)
            XCTAssertEqual(record.heartRate, heartRate, fixture)
            XCTAssertEqual(record.raw, raw, fixture)

            if version == 12 {
                XCTAssertEqual(raw.count, 88)
            }
            if version == 25 {
                XCTAssertEqual(raw.count, 76)
                XCTAssertNil(record.subsecondTicks)
                XCTAssertNil(record.gravity, "v25 waveform bytes are not motion")
            } else {
                XCTAssertNotNil(record.subsecondTicks, fixture)
            }
        }
    }

    func test_unknownPacketTypeIsExplicitAndPreservesRawBytes() throws {
        let raw = Data([0x7E, 0xAA, 0x00, 0x7E])
        let packet = try PacketDecoder().decode(raw)

        guard case .unknown(let type, let preserved) = packet else {
            return XCTFail("unlisted type must dispatch to unknown")
        }
        XCTAssertEqual(type, 0x7E)
        XCTAssertEqual(preserved, raw)
        XCTAssertNil(packet.packetType)
    }

    func test_historicalUnknownVersionPreservesRawBytesAndNeverDefaultsFields() throws {
        let raw = Data([0x2F, 0xFE, 0x01, 0x02, 0x03, 0x04])
        let packet = try PacketDecoder().decode(raw)

        guard case .historicalRecord(.unsupported(let version, let preserved, let reason)) = packet else {
            return XCTFail("unknown historical version must be unsupported")
        }
        XCTAssertEqual(version, 0xFE)
        XCTAssertEqual(preserved, raw)
        XCTAssertEqual(reason, .unsupportedVersion(0xFE))
    }

    func test_historicalPacketMissingVersionIsUnsupportedAndPreservesRawBytes() throws {
        let raw = Data([0x2F])
        let result = try HistoricalRecord.decode(raw)

        guard case .unsupported(let version, let preserved, let reason) = result else {
            return XCTFail("historical discriminator without a version must be unsupported")
        }
        XCTAssertNil(version)
        XCTAssertEqual(preserved, raw)
        XCTAssertEqual(
            reason,
            .malformedHistoricalRecord("missing historical-record version byte")
        )
    }

    func test_nonV25RecognizedLayoutsRequireSeventyTwoBytes() throws {
        var valid = Data(repeating: 0, count: 72)
        valid[0] = 0x2F
        valid[1] = 9
        valid[17] = 60
        valid.replaceSubrange(44..<48, with: [0x00, 0x00, 0x80, 0x3F])

        let tooShort = Data(valid.dropLast())
        XCTAssertThrowsError(try HistoricalRecord.decode(tooShort)) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertTrue(decodeError.reason.contains("expected at least 72 bytes"), decodeError.reason)
        }

        guard case .decoded(let record) = try HistoricalRecord.decode(valid) else {
            return XCTFail("a structurally valid 72-byte legacy record must decode")
        }
        XCTAssertEqual(record.version, 9)
        XCTAssertEqual(record.heartRate, 60)
        XCTAssertEqual(record.gravity, GravityVector(x: 0, y: 0, z: 1))
    }

    func testInvalidHistoricalMeasurementsStayUnsupportedWithRawBytes() throws {
        var invalidHeartRate = Data(repeating: 0, count: 72)
        invalidHeartRate[0] = 0x2F
        invalidHeartRate[1] = 9
        invalidHeartRate[17] = 24
        invalidHeartRate.replaceSubrange(44..<48, with: [0x00, 0x00, 0x80, 0x3F])
        assertUnsupported(invalidHeartRate, reasonContaining: "heart rate")

        var nonFiniteGravity = Data(repeating: 0, count: 72)
        nonFiniteGravity[0] = 0x2F
        nonFiniteGravity[1] = 9
        nonFiniteGravity[17] = 60
        nonFiniteGravity.replaceSubrange(36..<40, with: [0x00, 0x00, 0xC0, 0x7F]) // NaN
        assertUnsupported(nonFiniteGravity, reasonContaining: "non-finite")

        var implausibleLegacyGravity = Data(repeating: 0, count: 72)
        implausibleLegacyGravity[0] = 0x2F
        implausibleLegacyGravity[1] = 9
        implausibleLegacyGravity[17] = 60
        implausibleLegacyGravity.replaceSubrange(44..<48, with: [0x00, 0x00, 0x00, 0x40]) // 2.0 g
        assertUnsupported(implausibleLegacyGravity, reasonContaining: "gravity magnitude")

        var v25WaveformTail = Data(repeating: 0, count: 76)
        v25WaveformTail[0] = 0x2F
        v25WaveformTail[1] = 25
        v25WaveformTail.replaceSubrange(69..<71, with: [0xFF, 0x7F])
        guard case .decoded(let v25) = try HistoricalRecord.decode(v25WaveformTail) else {
            return XCTFail("a valid v25 waveform record must remain decodable")
        }
        XCTAssertNil(v25.gravity)

        var minimumV25 = Data(repeating: 0, count: 75)
        minimumV25[0] = 0x2F
        minimumV25[1] = 25
        guard case .decoded(let minimumV25Record) = try HistoricalRecord.decode(minimumV25) else {
            return XCTFail("the upstream v25 truncation floor must remain decodable")
        }
        XCTAssertNil(minimumV25Record.gravity)

        // Pinned v12 parity checks finiteness but does not apply the magnitude
        // bounds used by v7/v9/v18.
        for version: UInt8 in [12] {
            var finiteZeroGravity = Data(repeating: 0, count: 72)
            finiteZeroGravity[0] = 0x2F
            finiteZeroGravity[1] = version
            guard case .decoded = try HistoricalRecord.decode(finiteZeroGravity) else {
                return XCTFail("finite v\(version) gravity must not be range-rejected")
            }
        }

        // v24 uses the same gravity validity rule after it reaches
        // OpenStrap's 89-byte complete-record floor.
        var finiteV24ZeroGravity = Data(repeating: 0, count: 89)
        finiteV24ZeroGravity[0] = 0x2F
        finiteV24ZeroGravity[1] = 24
        guard case .decoded = try HistoricalRecord.decode(finiteV24ZeroGravity) else {
            return XCTFail("a complete finite v24 record must not be range-rejected")
        }
    }

    func test_recognizedHistoricalVersionTruncationThrowsTypedError() throws {
        let truncated = Data([0x2F, 0x09, 0x00, 0x0D, 0x0C, 0x0B, 0x0A])

        XCTAssertThrowsError(try PacketDecoder().decode(truncated)) { error in
            guard let decodeError = error as? ProtocolDecodeError else {
                return XCTFail("expected ProtocolDecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError.offset, truncated.count)
            XCTAssertTrue(decodeError.reason.contains("truncated historical record"), decodeError.reason)
        }
    }

    func test_packetTypeRawValuesAreExactlyPinned() {
        XCTAssertEqual(PacketType.commandResponse.rawValue, 0x24)
        XCTAssertEqual(PacketType.compactLiveHeartRate.rawValue, 0x28)
        XCTAssertEqual(PacketType.realtimeRaw.rawValue, 0x2B)
        XCTAssertEqual(PacketType.historicalRecord.rawValue, 0x2F)
        XCTAssertEqual(PacketType.event.rawValue, 0x30)
        XCTAssertEqual(PacketType.historyMetadata.rawValue, 0x31)
        XCTAssertEqual(PacketType.console.rawValue, 0x32)
        XCTAssertEqual(PacketType.realtimeIMU.rawValue, 0x33)
    }

    private func assertUnsupported(_ raw: Data, reasonContaining fragment: String) {
        do {
            let result = try HistoricalRecord.decode(raw)
            guard case .unsupported(let version, let preserved, let reason) = result else {
                return XCTFail("invalid historical measurement unexpectedly decoded")
            }
            XCTAssertEqual(version, raw[1])
            XCTAssertEqual(preserved, raw)
            XCTAssertTrue(reason.description.contains(fragment), reason.description)
        } catch {
            XCTFail("invalid historical measurement should be retained as unsupported, got \(error)")
        }
    }
}
