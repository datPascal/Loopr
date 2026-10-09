import Foundation
import XCTest
@testable import ProtocolKit

final class BandLinkProtocolTests: XCTestCase {
    func testGen4SharingBytesAndCapabilityFence() throws {
        let writer = ProductionCommandWriter(capabilities: .confirmed(.heartRateSharing))
        for enabled in [true, false] {
            let command = ProductionCommand.heartRateSharing(.init(sequence: 9, enabled: enabled))
            let frame = try writer.encode(command)
            XCTAssertEqual(try FrameDecoder().decode(frame).paddedInner, Data([0x23, 9, 14, enabled ? 1 : 0]))
            XCTAssertNoThrow(try CommandFirewall.validateEncodedFrame(frame))
            XCTAssertThrowsError(try ProductionCommandWriter().encode(command))
        }
        for command in [ProductionCommand.forceTrim, .reboot, .powerCycle, .persistentRaw,
                        .firmwareCommand24, .firmwareCommand25, .firmwareCommand26] {
            XCTAssertThrowsError(try writer.encode(command))
        }
    }

    func testGen5FullFieldsFramingAndReadback() throws {
        let expectedKey = Data([0x77,0x68,0x6f,0x6f,0x70,0x5f,0x6c,0x69,0x76,0x65,0x5f,0x68,0x72,0x5f,
                                0x69,0x6e,0x5f,0x61,0x64,0x76,0x5f,0x69,0x6e,0x64,0x5f,0x70,0x6b,0x74,0,0,0,0])
        let encoder = Gen5OperationalCommandEncoder()
        for enabled in [true, false] {
            let frame = try encoder.encode(.heartRateSharing(enabled), sequence: 9)
            XCTAssertEqual(frame.count, 80)
            let inner = try Gen5FrameCodec().decode(frame).paddedInner
            XCTAssertEqual(Data(inner.prefix(4)), Data([0x23,9,119,1]))
            XCTAssertEqual(Data(inner[4..<36]), expectedKey)
            XCTAssertEqual(Data(inner[36..<68]), Data([enabled ? 0x31 : 0x30]) + Data(repeating: 0, count: 31))
            XCTAssertNoThrow(try CommandFirewall.validateFrameInner(inner))
        }
        for opcode in CommandFirewall.dangerousOpcodes {
            XCTAssertThrowsError(try CommandFirewall.validateFrameInner(Data([0x23,9,opcode,0])))
        }
        let read = try encoder.encode(.heartRateSharingRead, sequence: 9)
        XCTAssertEqual(read.count, 48)
        XCTAssertEqual(try Gen5FrameCodec().decode(read).paddedInner, Data([0x23,9,121,1]) + expectedKey)
        let reply = Data([0x24,99,121,9,1,1]) + expectedKey + Data([0x31]) + Data(repeating: 0, count: 31)
        XCTAssertTrue(try HeartRateSharingCommand.decodeGen5Readback(reply, sequence: 9))
        for offset in [0,2,3,4,5,6,39] {
            var bad = reply; bad[offset] = 0xff
            XCTAssertThrowsError(try HeartRateSharingCommand.decodeGen5Readback(bad, sequence: 9))
        }
        for count in 0..<70 {
            XCTAssertThrowsError(try HeartRateSharingCommand.decodeGen5Readback(Data(reply.prefix(count)), sequence: 9))
        }
        for (value, enabled) in [(UInt8(0x30), false), (0x31, true), (0x32, false)] {
            var changed = reply; changed[38] = value
            XCTAssertEqual(try HeartRateSharingCommand.decodeGen5Readback(changed, sequence: 9), enabled)
        }
        var empty = reply; empty[38] = 0
        XCTAssertThrowsError(try HeartRateSharingCommand.decodeGen5Readback(empty, sequence: 9))
    }

    func testBatteryEventOffsetsAndFamilyBounds() throws {
        var inner = Data(repeating: 0, count: 24)
        inner[0] = 0x30; inner[2] = 3; inner[10] = 11
        inner[13] = 0x0d; inner[14] = 0x03 // 78.1 percent
        inner[17] = 0xd8; inner[18] = 0x0e // 3800 mV
        inner[22] = 0x81
        for model in [BandModel.whoop4, .whoop5] {
            let packet = try BandEventPacket.decode(inner, model: model)
            XCTAssertEqual(packet.batteryPercentage, 78.1)
            XCTAssertEqual(packet.batteryMillivolts, 3800)
            XCTAssertEqual(packet.charging, true)
        }
        var zero = inner; zero[13] = 0; zero[14] = 0
        XCTAssertEqual(try BandEventPacket.decode(zero).batteryPercentage, 0)
        XCTAssertNil(try BandEventPacket.decode(inner, model: .whoopMG).batteryPercentage)
        XCTAssertNil(try BandEventPacket.decode(inner, model: .whoopMG).charging)
        XCTAssertNil(try BandEventPacket.decode(inner, model: .unknownGen5).batteryPercentage)
        inner[10] = 10; inner[22] = 0
        XCTAssertNil(try BandEventPacket.decode(inner, model: .whoop4).charging,
            "a zero padding byte is not a discharging observation")
        inner[10] = 1
        for model in [BandModel.whoop4, .whoop5, .whoopMG] {
            XCTAssertNil(try BandEventPacket.decode(inner, model: model).charging)
        }
        inner[10] = 11
        inner[2] = 63
        XCTAssertNil(try BandEventPacket.decode(inner).batteryPercentage)
        XCTAssertNil(try BandEventPacket.decode(inner).charging)
        inner[2] = 3; inner[13] = 0xff; inner[14] = 0xff
        XCTAssertNil(try BandEventPacket.decode(inner).batteryPercentage)
        for count in 4..<23 {
            XCTAssertNil(try BandEventPacket.decode(Data(inner.prefix(count))).charging)
        }
    }

    func testTransitionsAndAlarmEventsStaySeparate() throws {
        let transitions: [(UInt8, Bool?, Bool?)] = [
            (7, true, nil), (8, false, nil), (9, nil, true), (10, nil, false)
        ]
        for (id, charging, onWrist) in transitions {
            let packet = try BandEventPacket.decode(Data([0x30, 1, id, 0]))
            XCTAssertEqual(packet.charging, charging)
            XCTAssertEqual(packet.onWrist, onWrist)
        }
        for id in UInt8(56)...60 {
            let packet = try BandEventPacket.decode(Data([0x30,1,id,0]))
            XCTAssertEqual(packet.eventID, UInt16(id))
            XCTAssertNil(packet.charging)
            XCTAssertNil(packet.onWrist)
        }
    }
}
