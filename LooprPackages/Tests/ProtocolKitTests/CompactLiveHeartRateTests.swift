import Foundation
import ProtocolKit
import XCTest

final class CompactLiveHeartRateTests: XCTestCase {
    func testPinnedLayoutUsesLittleEndianTimestampAndAllFourRRSlots() {
        let raw = compactFrame(
            timestamp: 0x1234_5678,
            heartRate: 62,
            declaredCount: 4,
            rr: [800, 810, 820, 830]
        )

        let sample = CompactLiveHeartRateDecoder.decode(raw)

        XCTAssertEqual(sample?.timestampSeconds, 0x1234_5678)
        XCTAssertEqual(sample?.heartRateBPM, 62)
        XCTAssertEqual(sample?.rrMilliseconds, [800, 810, 820, 830])
        XCTAssertEqual(sample?.wearing, true)
        XCTAssertEqual(sample?.rawPayload, raw)
    }

    func testStrippedPayloadRequiresExplicitFormAndReconstructsFullInnerBytes() {
        let full = compactFrame(
            timestamp: 1_780_840_486,
            heartRate: 65,
            declaredCount: 1,
            rr: [900]
        )

        let decoded = CompactLiveHeartRateDecoder.decode(
            Data(full.dropFirst()),
            form: .strippedPayload
        )

        XCTAssertEqual(decoded?.rawPayload, full)
        XCTAssertEqual(decoded?.timestampSeconds, 1_780_840_486)
        XCTAssertEqual(decoded?.heartRateBPM, 65)
        XCTAssertEqual(decoded?.rrMilliseconds, [900])
    }

    func testNineByteHeartRateOnlyPacketDefaultsOptionalWearingToTrue() {
        let raw = compactFrame(
            timestamp: 1_780_840_486,
            heartRate: 65,
            declaredCount: nil,
            rr: [],
            includeWearing: false
        )

        let decoded = CompactLiveHeartRateDecoder.decode(raw)

        XCTAssertEqual(decoded?.heartRateBPM, 65)
        XCTAssertEqual(decoded?.rrMilliseconds, [])
        XCTAssertEqual(decoded?.wearing, true)
    }

    func testRevisionTwoDecodesTimestampSubsecondAndLocation() {
        var raw = Data(repeating: 0, count: 20)
        raw[0] = 0x28
        raw[1] = 2
        writeUInt32(0x1234_5678, at: 2, in: &raw)
        writeUInt16(0x9ABC, at: 6, in: &raw)
        raw[8] = 79
        raw[18] = 1
        raw[19] = 2

        let sample = CompactLiveHeartRateDecoder.decode(raw)
        XCTAssertEqual(sample?.revision, 2)
        XCTAssertEqual(sample?.timestampSeconds, 0x1234_5678)
        XCTAssertEqual(sample?.subsecondTicks, 0x9ABC)
        XCTAssertEqual(sample?.heartRateBPM, 79)
        XCTAssertEqual(sample?.rrMilliseconds, [])
        XCTAssertEqual(sample?.locationRaw, 2)
    }

    func testInvalidHeartRateTimestampAndPacketShapeFailClosed() {
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(Data()))
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(Data([0x28, 0x01, 0x00])))

        var wrongType = compactFrame(timestamp: 100, heartRate: 60, declaredCount: 0, rr: [])
        wrongType[0] = 0x2B
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(wrongType))

        let zeroTimestamp = compactFrame(timestamp: 0, heartRate: 60, declaredCount: 0, rr: [])
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(zeroTimestamp))

        let invalidLowHR = compactFrame(timestamp: 100, heartRate: 0, declaredCount: 0, rr: [])
        let invalidHighHR = compactFrame(timestamp: 100, heartRate: 251, declaredCount: 0, rr: [])
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(invalidLowHR))
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(invalidHighHR))
    }

    func testOffWristPacketIsAbsentRatherThanUsableCardiacData() {
        let offWrist = compactFrame(
            timestamp: 1_780_840_486,
            heartRate: 65,
            declaredCount: 1,
            rr: [900],
            wearing: 0
        )

        XCTAssertNil(CompactLiveHeartRateDecoder.decode(offWrist))
    }

    func testRRBoundsAreAppliedAndOversizedCountDoesNotReadPastFourSlots() {
        let bounded = compactFrame(
            timestamp: 1_780_840_486,
            heartRate: 62,
            declaredCount: 4,
            rr: [199, 200, 2_500, 2_501]
        )
        XCTAssertEqual(
            CompactLiveHeartRateDecoder.decode(bounded)?.rrMilliseconds,
            [200, 2_500]
        )

        let oversized = compactFrame(
            timestamp: 1_780_840_486,
            heartRate: 62,
            declaredCount: 40,
            rr: [800, 810, 820, 830]
        )
        XCTAssertNil(CompactLiveHeartRateDecoder.decode(oversized))
    }

    func testDeclaredRRSlotWithoutBytesIsMalformed() {
        var truncated = Data(repeating: 0, count: 11)
        truncated[0] = 0x28
        truncated[1] = 0x01
        writeUInt32(1_780_840_486, at: 2, in: &truncated)
        truncated[8] = 65
        truncated[9] = 2
        // Only the first byte of the first RR slot is present. The decoder
        // must reject this without indexing the absent second byte.
        truncated[10] = 0x84 // low byte of 900; high byte is absent

        XCTAssertNil(CompactLiveHeartRateDecoder.decode(truncated))
    }

    func testEveryDeclaredRRCountRejectsEveryTruncatedFullPacket() {
        for declaredCount in 0...CompactLiveHeartRateDecoder.maximumRRSlots {
            let complete = compactFrame(
                timestamp: 1_780_840_486,
                heartRate: 65,
                declaredCount: declaredCount,
                rr: Array(repeating: 900, count: declaredCount),
                includeWearing: false
            )
            let requiredLength = 10 + (declaredCount * 2)
            XCTAssertEqual(complete.count, requiredLength)

            // A nine-byte packet is a valid HR-only form. Every other shorter
            // byte length is malformed; once the count byte is present, all
            // declared slots must be present.
            for length in 0..<requiredLength {
                let truncated = Data(complete.prefix(length))
                if length == 9 {
                    XCTAssertNotNil(CompactLiveHeartRateDecoder.decode(truncated))
                } else {
                    XCTAssertNil(
                        CompactLiveHeartRateDecoder.decode(truncated),
                        "full count \(declaredCount), length \(length)"
                    )
                }
            }
        }
    }

    func testEveryDeclaredRRCountRejectsEveryTruncatedStrippedPacket() {
        for declaredCount in 0...CompactLiveHeartRateDecoder.maximumRRSlots {
            let complete = compactFrame(
                timestamp: 1_780_840_486,
                heartRate: 65,
                declaredCount: declaredCount,
                rr: Array(repeating: 900, count: declaredCount),
                includeWearing: false
            )
            let stripped = Data(complete.dropFirst())
            let requiredLength = 9 + (declaredCount * 2)
            XCTAssertEqual(stripped.count, requiredLength)

            // Eight stripped bytes reconstruct the valid nine-byte HR-only
            // packet. Every other shorter byte length is malformed; a
            // stripped count byte without all declared RR bytes is malformed.
            for length in 0..<requiredLength {
                let truncated = Data(stripped.prefix(length))
                if length == 8 {
                    XCTAssertNotNil(
                        CompactLiveHeartRateDecoder.decode(
                            truncated,
                            form: .strippedPayload
                        )
                    )
                } else {
                    XCTAssertNil(
                        CompactLiveHeartRateDecoder.decode(
                            truncated,
                            form: .strippedPayload
                        ),
                        "stripped count \(declaredCount), length \(length)"
                    )
                }
            }
        }
    }

    func testMalformedCorpusNeverCrashesForFullOrStrippedForms() {
        var seed: UInt64 = 0x28_5E_ED_01
        for length in 0...64 {
            for _ in 0..<16 {
                var bytes = Data()
                bytes.reserveCapacity(length)
                for _ in 0..<length {
                    // Deterministic LCG corpus: broad byte coverage without
                    // relying on randomness or a non-reproducible seed.
                    seed = (seed &* 6_364_136_223_846_793_005) &+ 1
                    bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
                }
                _ = CompactLiveHeartRateDecoder.decode(bytes)
                _ = CompactLiveHeartRateDecoder.decode(bytes, form: .strippedPayload)
            }
        }
    }

    func testDecoderCarriesPinnedSourceProvenance() {
        XCTAssertEqual(
            CompactLiveHeartRateDecoder.upstreamCommit,
            "c78c176295e3dcbc183bf3309bf94cb251c2c3d1"
        )
        XCTAssertTrue(CompactLiveHeartRateDecoder.upstreamSource.contains("control.dart"))
    }

    private func compactFrame(
        timestamp: UInt32,
        heartRate: UInt8,
        declaredCount: Int?,
        rr: [UInt16],
        wearing: UInt8 = 1,
        includeWearing: Bool = true
    ) -> Data {
        let rrSlotCount = min(max(declaredCount ?? 0, 0), CompactLiveHeartRateDecoder.maximumRRSlots)
        let minimumLength = max(9, 10 + (rrSlotCount * 2))
        var bytes = Data(repeating: 0, count: includeWearing ? max(20, minimumLength) : minimumLength)
        bytes[0] = 0x28
        bytes[1] = 0x01
        writeUInt32(timestamp, at: 2, in: &bytes)
        bytes[8] = heartRate
        if let declaredCount {
            bytes[9] = UInt8(truncatingIfNeeded: declaredCount)
            for (index, value) in rr.prefix(4).enumerated() {
                writeUInt16(value, at: 10 + (index * 2), in: &bytes)
            }
        }
        if includeWearing { bytes[18] = wearing }
        return bytes
    }

    private func writeUInt16(_ value: UInt16, at offset: Int, in bytes: inout Data) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32(_ value: UInt32, at offset: Int, in bytes: inout Data) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
