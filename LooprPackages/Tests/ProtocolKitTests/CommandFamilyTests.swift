import Foundation
@testable import ProtocolKit
import XCTest

final class CommandFamilyTests: XCTestCase {
    private var fixture: [String: Any] {
        get throws {
            let url = ProtocolFixtureSupport.repositoryRoot
                .appendingPathComponent("Fixtures/Protocol/command_families.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let object = object as? [String: Any] else {
                throw FixtureError.invalidRoot
            }
            return object
        }
    }

    func testBatteryRequestAndResponseVectorsAreByteExactAndUnclamped() throws {
        let family = try requiredDictionary(try fixture, key: "battery")
        let request = try requiredDictionary(family, key: "request")
        let sequence = try requiredUInt8(request, key: "sequence")
        let capabilities = CommandCapabilities.confirmed(.battery)
        let command = BatteryCommand.request(sequence: sequence)
        XCTAssertEqual(command.inner, Data([0x23, sequence, 0x1A]))
        XCTAssertEqual(BatteryCommand.requestPayload, Data())
        let actual = try ProductionCommandWriter(capabilities: capabilities)
            .encode(.battery(command))
        XCTAssertEqual(actual, try data(request, key: "full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(actual).paddedInner,
            try data(request, key: "padded_inner_hex")
        )

        let response = try requiredDictionary(family, key: "response")
        let vectors = try requiredArray(response, key: "vectors")
        for vectorValue in vectors {
            let vector = try requiredDictionary(vectorValue)
            let inner = try data(vector, key: "inner_hex")
            let expected = try requiredDictionary(vector, key: "expected")
            if let expectedValue = expected["battery_pct"] as? NSNumber,
               !(expected["battery_pct"] is NSNull) {
                let decoded = try BatteryCommand.decodeResponse(inner)
                XCTAssertEqual(decoded.percentage, expectedValue.doubleValue, accuracy: 0.000_1)
            } else {
                XCTAssertThrowsError(try BatteryCommand.decodeResponse(inner)) { error in
                    guard let decodeError = error as? ProtocolDecodeError else {
                        return XCTFail("expected ProtocolDecodeError, got \(error)")
                    }
                    XCTAssertEqual(decodeError.offset, 5)
                }
            }
        }
    }

    func testIdentityHelloAndNameReadbackVectorsAreByteExact() throws {
        let root = try fixture
        let identity = try requiredDictionary(root, key: "identity")
        let request = try requiredDictionary(identity, key: "request")
        let sequence = try requiredUInt8(request, key: "sequence")
        let actual = try ProductionCommandWriter(
            capabilities: .confirmed(.identity)
        ).encode(.identity(.hello(sequence: sequence)))
        XCTAssertEqual(actual, try data(request, key: "full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(actual).paddedInner,
            try data(request, key: "padded_inner_hex")
        )

        let response = try requiredDictionary(identity, key: "response")
        let vector = try requiredDictionary(try requiredArray(response, key: "vectors").first)
        XCTAssertEqual(
            try IdentityCommand.validateHelloResponse(try data(vector, key: "inner_hex")),
            try data(vector, key: "inner_hex")
        )

        let rename = try requiredDictionary(root, key: "rename")
        let readback = try requiredDictionary(rename, key: "readback")
        let advertisingRequest = try data(readback, key: "request_padded_inner_hex")
        let advertisingFrame = try ProductionCommandWriter(
            capabilities: .confirmed(.identity)
        ).encode(.identity(.advertisingName(sequence: advertisingRequest[1])))
        XCTAssertEqual(advertisingFrame, try data(readback, key: "request_full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(advertisingFrame).paddedInner,
            advertisingRequest
        )
        let name = try IdentityCommand.decodeAdvertisingNameResponse(
            try data(readback, key: "inner_hex", fallbackKey: "response_vector")
        )
        let responseVector = try requiredDictionary(readback, key: "response_vector")
        XCTAssertEqual(name, responseVector["expected_name"] as? String)
    }

    func testRenameVectorAndValidationAreExact() throws {
        let family = try requiredDictionary(try fixture, key: "rename")
        let request = try requiredDictionary(family, key: "request")
        let vector = try requiredDictionary(try requiredArray(request, key: "vectors").first)
        let command = try RenameCommand.set(
            sequence: try requiredUInt8(vector, key: "sequence"),
            name: try requiredString(vector, key: "name_text")
        )
        let actual = try ProductionCommandWriter(
            capabilities: .confirmed(.rename)
        ).encode(.rename(command))
        XCTAssertEqual(actual, try data(vector, key: "full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(actual).paddedInner,
            try data(vector, key: "padded_inner_hex")
        )

        XCTAssertThrowsError(try RenameCommand(name: String(repeating: "A", count: 21)))
        XCTAssertThrowsError(try RenameCommand(name: "WHOOP\n"))
        XCTAssertThrowsError(try RenameCommand(name: "é"))
    }

    func testHapticVectorUsesGen4OpcodeAndSharedWriter() throws {
        let family = try requiredDictionary(try fixture, key: "haptic")
        let request = try requiredDictionary(family, key: "request")
        let vector = try requiredDictionary(try requiredArray(request, key: "vectors").first)
        let command = HapticCommand.run(
            sequence: try requiredUInt8(vector, key: "sequence"),
            pattern: try requiredUInt8(vector, key: "pattern")
        )
        XCTAssertEqual(
            command.inner,
            Data([0x23, command.sequence, 0x4F, command.pattern, 0x00, 0x00, 0x00, 0x00])
        )
        let actual = try ProductionCommandWriter(
            capabilities: .confirmed(.haptic)
        ).encode(.haptic(command))
        XCTAssertEqual(actual, try data(vector, key: "full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(actual).paddedInner,
            try data(vector, key: "padded_inner_hex")
        )
        XCTAssertEqual(HapticCommand.opcode, 0x4F)
        XCTAssertNotEqual(HapticCommand.opcode, 0x13)
    }

    func testAlarmSetupReadbackTestAndDisableVectorsAreExact() throws {
        let family = try requiredDictionary(try fixture, key: "alarm")
        let subfamilies = try requiredDictionary(family, key: "subfamilies")
        let rich = try requiredDictionary(subfamilies, key: "set_rich")
        let richPattern = try AlarmHapticPattern(bytes: try dataHex(
            requiredString(rich, key: "default_haptic_pattern")
        ))
        let richCommand = AlarmCommand.setupRichReference(
            sequence: try requiredUInt8(rich, key: "sequence"),
            index: 0,
            epochSeconds: 0x1234_5678,
            subsecondTicks: 0x4000,
            pattern: richPattern
        )
        let writer = ProductionCommandWriter(capabilities: .confirmed(.alarm))
        let richPadded = try data(rich, key: "padded_inner_hex")
        XCTAssertEqual(try richCommand.makeInner(), Data(richPadded.dropLast()))
        let richFrame = try writer.encode(.alarm(richCommand))
        XCTAssertEqual(richFrame, try data(rich, key: "full_frame_hex"))
        XCTAssertEqual(
            try FrameDecoder().decode(richFrame).paddedInner,
            richPadded
        )

        // `setup` is the ergonomic entry point and must produce the rich form
        // byte for byte, including the index and waveform it is handed.
        let firingCommand = AlarmCommand.setup(
            sequence: try requiredUInt8(rich, key: "sequence"),
            index: 0,
            epochSeconds: 0x1234_5678,
            subsecondTicks: 0x4000,
            pattern: richPattern
        )
        XCTAssertEqual(try firingCommand.makeInner(), try richCommand.makeInner())
        XCTAssertEqual(try writer.encode(.alarm(firingCommand)), richFrame)

        let simple = try requiredDictionary(subfamilies, key: "set_simple")
        let simplePadded = try data(simple, key: "padded_inner_hex")
        let simpleSequence = simplePadded[1]
        let simpleEpoch = UInt32(simplePadded[4])
            | (UInt32(simplePadded[5]) << 8)
            | (UInt32(simplePadded[6]) << 16)
            | (UInt32(simplePadded[7]) << 24)
        let simpleTicks = UInt16(simplePadded[8]) | (UInt16(simplePadded[9]) << 8)
        let simpleCommand = AlarmCommand.setupSimple(
            sequence: simpleSequence,
            epochSeconds: simpleEpoch,
            subsecondTicks: simpleTicks
        )
        XCTAssertEqual(try simpleCommand.makeInner(), Data(simplePadded.dropLast(2)))
        let simpleFrame = try writer.encode(.alarm(simpleCommand))
        XCTAssertEqual(simpleFrame, try data(simple, key: "full_frame_hex"))
        XCTAssertEqual(try FrameDecoder().decode(simpleFrame).paddedInner, simplePadded)

        let read = try requiredDictionary(subfamilies, key: "read")
        let readFrame = try writer.encode(.alarm(.readback(
            sequence: try requiredUInt8(read, key: "sequence")
        )))
        XCTAssertEqual(readFrame, try data(read, key: "full_frame_hex"))
        // Vectors captured off a real WHOOP 4.0, not synthesised from the
        // reference: the reference reads the form byte where the band puts the
        // echo of our sequence.
        let responseVectors = try requiredArray(read, key: "response_vectors")
        XCTAssertFalse(responseVectors.isEmpty)
        for value in responseVectors {
            let vector = try requiredDictionary(value)
            let expected = try requiredDictionary(vector, key: "expected")
            let response = try AlarmCommand.decodeReadbackResponse(
                try data(vector, key: "inner_hex")
            )
            XCTAssertEqual(response.isArmed, expected["armed"] as? Bool)
            XCTAssertEqual(
                UInt32(response.index),
                (expected["alarm_index"] as? NSNumber)?.uint32Value
            )
            XCTAssertEqual(
                response.epochSeconds,
                (expected["epoch_seconds"] as? NSNumber)?.uint32Value
            )
        }

        // The SET_ALARM_TIME reply is kept as the evidence that fixes the
        // record boundary; the same epoch sits one byte earlier in it.
        let setResponses = try requiredArray(read, key: "set_response_vectors")
        let setReply = try data(try requiredDictionary(setResponses.first), key: "inner_hex")
        let setEpoch = UInt32(setReply[7])
            | (UInt32(setReply[8]) << 8)
            | (UInt32(setReply[9]) << 16)
            | (UInt32(setReply[10]) << 24)
        XCTAssertEqual(setEpoch, 1_790_031_600)

        // Wrong packet type, wrong opcode, truncated body, an unknown readback
        // revision, and a body whose epoch is not a plausible wall clock all
        // fail closed rather than reporting an alarm.
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x23, 0xE2, 0x43, 0x66, 0x01, 0x01, 0x01, 0x00, 0xF0, 0xB6, 0xB1, 0x6A, 0x00])
        ))
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x24, 0xE2, 0x42, 0x66, 0x01, 0x01, 0x01, 0x00, 0xF0, 0xB6, 0xB1, 0x6A, 0x00])
        ))
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x24, 0xE2, 0x43, 0x66, 0x01, 0x01, 0x01, 0x00, 0xF0, 0xB6, 0xB1])
        ))
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x24, 0xE2, 0x43, 0x66, 0x01, 0x04, 0x01, 0x00, 0xF0, 0xB6, 0xB1, 0x6A, 0x00])
        ))
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x24, 0xE2, 0x43, 0x66, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        ))
        // The pre-capture layout, where the rich form byte sat at inner
        // offset 3, must no longer decode.
        XCTAssertThrowsError(try AlarmCommand.decodeReadbackResponse(
            Data([0x24, 0x11, 0x43, 0x04, 0x00])
                + Data([0x78, 0x56, 0x34, 0x12, 0x00, 0x40])
                + richPattern.rawData
        ))

        let test = try requiredDictionary(subfamilies, key: "test")
        let testFrame = try writer.encode(.alarm(.test(
            sequence: try requiredUInt8(test, key: "sequence")
        )))
        XCTAssertEqual(testFrame, try data(test, key: "full_frame_hex"))

        let disable = try requiredDictionary(subfamilies, key: "disable")
        let disableFrame = try writer.encode(.alarm(.disable(
            sequence: try requiredUInt8(disable, key: "sequence")
        )))
        XCTAssertEqual(disableFrame, try data(disable, key: "full_frame_hex"))
    }

    /// The reference's own alarm vector, `edge/test/alarm_test.dart`: epoch
    /// 0x01020304, 16384 subsecond ticks, and the stock wake buzz. `setup` is
    /// what `setBandAlarm` calls, so this is the exact 20 byte payload that
    /// reaches the band.
    func testAlarmSetupEmitsTheReferenceRichPayloadByteForByte() throws {
        let command = AlarmCommand.setup(
            sequence: 0x11,
            index: 0,
            epochSeconds: 0x0102_0304,
            subsecondTicks: 16_384
        )
        let expectedInner = Data([
            0x23, 0x11, 0x42,
            0x04,                      // rich form marker
            0x00,                      // alarm slot index
            0x04, 0x03, 0x02, 0x01,    // u32 LE epoch seconds
            0x00, 0x40,                // u16 LE subsecond ticks
            47, 152, 0, 0, 0, 0, 0, 0, // eight waveform effect slots
            0, 0,                      // u16 LE per-effect loop control
            7,                         // overall waveform loop count
            30                         // maximum alarm duration in seconds
        ])
        XCTAssertEqual(try command.makeInner(), expectedInner)
        XCTAssertEqual(expectedInner.count - 3, 20)
        XCTAssertEqual(AlarmHapticPattern.default.bytes, Data([
            47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 7, 30
        ]))

        // The rich frame is the only command that exceeds the 20 byte ATT
        // payload of a default 23 byte MTU, so guard the wire size that makes
        // a long write necessary.
        let frame = try ProductionCommandWriter(capabilities: .confirmed(.alarm))
            .encode(.alarm(command))
        XCTAssertEqual(frame.count, 32)

        let custom = try AlarmHapticPattern(bytes: Array(1...12).map(UInt8.init))
        let customInner = try AlarmCommand.setup(
            sequence: 0x11,
            index: 3,
            epochSeconds: 0x0102_0304,
            subsecondTicks: 16_384,
            pattern: custom
        ).makeInner()
        XCTAssertEqual(customInner[4], 3)
        XCTAssertEqual(Data(customInner.suffix(12)), custom.bytes)
    }

    func testBandEventDecoderReadsAUInt16IdAndBoundsChecksEveryField() throws {
        // [0x30][seq][u16 LE id][u32 LE epoch][u16 LE subsec][body from 12]
        let doubleTap = Data([
            0x30, 0x07,
            0x0E, 0x00,
            0x04, 0x03, 0x02, 0x01,
            0x00, 0x40,
            0xAA, 0xBB, 0xCC, 0xDD
        ])
        let packet = try BandEventPacket.decode(doubleTap)
        XCTAssertEqual(packet.sequence, 7)
        XCTAssertEqual(packet.eventID, BandEventID.doubleTap)
        XCTAssertEqual(packet.bandEpochSeconds, 0x0102_0304)
        XCTAssertEqual(packet.subsecondTicks, 16_384)
        XCTAssertEqual(GestureEvent.decode(eventID: packet.eventID), .doubleTap)

        // A high byte in the id field proves the wire value is a UInt16: read
        // as a UInt8 this would decode as event 60 instead of 316.
        let wideID = try BandEventPacket.decode(Data([0x30, 0x00, 0x3C, 0x01]))
        XCTAssertEqual(wideID.eventID, 316)
        XCTAssertNil(GestureEvent.decode(eventID: wideID.eventID))

        // Alarm lifecycle ids survive the same decode.
        for id in [
            BandEventID.alarmLatched,
            BandEventID.strapAlarmExecuted,
            BandEventID.appAlarmExecuted,
            BandEventID.alarmDisabled,
            BandEventID.hapticsFired
        ] {
            let inner = Data([0x30, 0x01, UInt8(truncatingIfNeeded: id), 0x00])
            XCTAssertEqual(try BandEventPacket.decode(inner).eventID, id)
        }

        // A packet that carries the id but not the whole timestamp degrades
        // to no timestamp rather than reading past the packet.
        let noTimestamp = try BandEventPacket.decode(Data([0x30, 0x02, 0x0E, 0x00, 0x99]))
        XCTAssertEqual(noTimestamp.eventID, BandEventID.doubleTap)
        XCTAssertNil(noTimestamp.bandEpochSeconds)
        XCTAssertNil(noTimestamp.subsecondTicks)

        let noSubseconds = try BandEventPacket.decode(
            Data([0x30, 0x02, 0x0E, 0x00, 0x04, 0x03, 0x02, 0x01])
        )
        XCTAssertEqual(noSubseconds.bandEpochSeconds, 0x0102_0304)
        XCTAssertNil(noSubseconds.subsecondTicks)

        for truncated in [Data(), Data([0x30]), Data([0x30, 0x01]), Data([0x30, 0x01, 0x0E])] {
            XCTAssertThrowsError(try BandEventPacket.decode(truncated)) { error in
                guard case .outOfBounds = error as? ProtocolDecodeError else {
                    return XCTFail("expected outOfBounds for \(truncated.count) bytes, got \(error)")
                }
            }
        }

        XCTAssertThrowsError(try BandEventPacket.decode(Data([0x24, 0x01, 0x0E, 0x00]))) { error in
            guard case .invalidValue = error as? ProtocolDecodeError else {
                return XCTFail("expected invalidValue for a non-event packet type, got \(error)")
            }
        }
    }

    func testEveryFamilyIsDeniedByDefault() throws {
        let commands: [ProductionCommand] = [
            .battery(.request()),
            .identity(.hello()),
            .rename(try RenameCommand.set(name: "Loopr")),
            .haptic(.run()),
            .alarm(.test()),
            .gesture(.configureDoubleTap(action: .none))
        ]
        for command in commands {
            XCTAssertThrowsError(try ProductionCommandWriter().encode(command)) { error in
                guard case .capabilityNotConfirmed = error as? CommandFamilyError else {
                    return XCTFail("expected default capability denial, got \(error)")
                }
            }
        }
    }

    func testGestureConfigurationFailsClosedEvenWhenCapabilityIsConfirmed() throws {
        let command = GestureCommand.configureDoubleTap(action: .markMoment)
        XCTAssertThrowsError(
            try ProductionCommandWriter(
                capabilities: .confirmed(.gesture)
            ).encode(.gesture(command))
        ) { error in
            XCTAssertEqual(error as? CommandFamilyError, .unsupportedFamily(.gesture))
        }
        XCTAssertEqual(GestureEvent.decode(eventID: 14), .doubleTap)
        XCTAssertNil(GestureEvent.decode(eventID: 15))
    }

    private func data(
        _ object: [String: Any],
        key: String,
        fallbackKey: String? = nil
    ) throws -> Data {
        if let hex = object[key] as? String {
            return try ProtocolFixtureSupport.data(hex: hex)
        }
        if let fallbackKey, let fallback = object[fallbackKey] as? [String: Any] {
            if let hex = fallback["inner_hex"] as? String {
                return try ProtocolFixtureSupport.data(hex: hex)
            }
            if let hex = fallback["padded_inner_hex"] as? String {
                return try ProtocolFixtureSupport.data(hex: hex)
            }
        }
        throw FixtureError.missingKey(key)
    }

    private func dataHex(_ hex: String) throws -> Data {
        try ProtocolFixtureSupport.data(hex: hex)
    }

    private func requiredDictionary(_ object: Any?, key: String? = nil) throws -> [String: Any] {
        guard let dictionary = object as? [String: Any] else {
            throw FixtureError.expectedDictionary(key ?? "value")
        }
        return dictionary
    }

    private func requiredDictionary(
        _ object: [String: Any],
        key: String
    ) throws -> [String: Any] {
        try requiredDictionary(object[key], key: key)
    }

    private func requiredArray(_ object: [String: Any], key: String) throws -> [Any] {
        guard let array = object[key] as? [Any] else {
            throw FixtureError.missingKey(key)
        }
        return array
    }

    private func requiredString(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw FixtureError.missingKey(key)
        }
        return value
    }

    private func requiredUInt8(_ object: [String: Any], key: String) throws -> UInt8 {
        guard let value = object[key] as? NSNumber,
              value.intValue >= 0,
              value.intValue <= 255 else {
            throw FixtureError.missingKey(key)
        }
        return UInt8(value.intValue)
    }

    private enum FixtureError: Error {
        case invalidRoot
        case expectedDictionary(String)
        case missingKey(String)
    }
}
