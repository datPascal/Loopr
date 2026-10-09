import Foundation
@testable import ProtocolKit
import XCTest

final class CommandFirewallTests: XCTestCase {
    func testEveryDangerousOpcodeIsRejectedByTheProductionWriter() {
        let cases: [(ProductionCommand, UInt8)] = [
            (.forceTrim, 0x19),
            (.reboot, 0x1D),
            (.powerCycle, 0x20),
            (.persistentRaw, 0x9A),
            (.firmwareCommand24, 0x24),
            (.firmwareCommand25, 0x25),
            (.firmwareCommand26, 0x26)
        ]

        for (command, opcode) in cases {
            XCTAssertThrowsError(try ProductionCommandWriter().encode(command)) { error in
                guard let firewallError = error as? CommandFirewallError else {
                    return XCTFail("expected CommandFirewallError, got \(error)")
                }
                XCTAssertEqual(firewallError, .dangerousOpcodeRejected(opcode))
            }
        }
    }

    func testFirewallDangerousSetIncludesGen4AndGen5FirmwareFamilies() {
        XCTAssertEqual(CommandFirewall.dangerousOpcodes, [
            0x19, 0x1D, 0x20, 0x9A, 0x24, 0x25, 0x26,
            0x8E, 0x8F, 0x90
        ])
        for opcode in CommandFirewall.dangerousOpcodes {
            XCTAssertTrue(CommandFirewall.isDangerous(opcode: opcode))
        }
        XCTAssertFalse(CommandFirewall.isDangerous(opcode: 0x23))
        XCTAssertFalse(CommandFirewall.isDangerous(opcode: 0x0A))
        XCTAssertFalse(CommandFirewall.isDangerous(opcode: 0x17))
    }

    func testSafeTypedCommandsRemainEncodable() throws {
        let token = try HistoryToken(bytes: Data(repeating: 0xA5, count: 8))
        let writer = ProductionCommandWriter()
        for command in [
            ProductionCommand.hello(sequence: 0),
            .advertisingName(sequence: 1),
            .dataRange(sequence: 2),
            .alarmTime(sequence: 3),
            .startHistoricalData(sequence: 4),
            .setClock(sequence: 5, unixSeconds: 1, subsecondTicks: 2),
            .historyAcknowledgement(sequence: 6, token: token)
        ] {
            XCTAssertNoThrow(try writer.encode(command))
        }
    }

    func testDirectFrameEncoderRejectsEveryDangerousCommandOpcode() {
        let encoder = FrameEncoder()
        for opcode in CommandFirewall.dangerousOpcodes {
            let paddedInner = Data([0x23, 0xB0, opcode, 0x00])
            XCTAssertThrowsError(try encoder.encode(paddedInner)) { error in
                guard let firewallError = error as? CommandFirewallError else {
                    return XCTFail("expected CommandFirewallError, got \(error)")
                }
                XCTAssertEqual(firewallError, .dangerousOpcodeRejected(opcode))
            }
        }
    }

    /// Confirming the Gen 4 command families is what makes rename, haptic and
    /// alarm encodable. It must not make the trim, reboot, power cycle or
    /// firmware opcodes encodable with them.
    func testConfirmedGen4CapabilitiesDoNotUnlockDangerousOpcodes() throws {
        let writer = ProductionCommandWriter(capabilities: BandProfile.gen4.commands)
        XCTAssertEqual(BandProfile.gen4.commands, CommandCapabilities(confirmed: [
            .battery, .identity, .rename, .haptic, .alarm, .heartRateSharing
        ]))
        XCTAssertFalse(BandProfile.gen4.commands.isConfirmed(.gesture))

        let dangerous: [(ProductionCommand, UInt8)] = [
            (.forceTrim, 0x19),
            (.reboot, 0x1D),
            (.powerCycle, 0x20),
            (.persistentRaw, 0x9A),
            (.firmwareCommand24, 0x24),
            (.firmwareCommand25, 0x25),
            (.firmwareCommand26, 0x26)
        ]
        for (command, opcode) in dangerous {
            XCTAssertThrowsError(try writer.encode(command)) { error in
                XCTAssertEqual(
                    error as? CommandFirewallError,
                    .dangerousOpcodeRejected(opcode)
                )
            }
        }

        // The same fence applies to a pre-framed dangerous opcode arriving at
        // the transport boundary rather than through the typed writer.
        for opcode in CommandFirewall.dangerousOpcodes {
            var padded = Data([0x23, 0x60, opcode, 0x00])
            let declared = UInt16(padded.count + 4)
            let length = Data([
                UInt8(truncatingIfNeeded: declared),
                UInt8(truncatingIfNeeded: declared >> 8)
            ])
            var raw = Data([Gen4Frame.marker, length[0], length[1], CRC8.calculate(length)])
            raw.append(padded)
            let crc = CRC32.calculate(padded)
            raw.append(contentsOf: [
                UInt8(truncatingIfNeeded: crc),
                UInt8(truncatingIfNeeded: crc >> 8),
                UInt8(truncatingIfNeeded: crc >> 16),
                UInt8(truncatingIfNeeded: crc >> 24)
            ])
            padded.removeAll()
            XCTAssertThrowsError(try CommandFirewall.validateEncodedFrame(raw)) { error in
                XCTAssertEqual(
                    error as? CommandFirewallError,
                    .dangerousOpcodeRejected(opcode)
                )
            }
        }

        // ABORT_HISTORICAL_TRANSMITS only cancels a transfer the band is
        // already running, so it stays outside the dangerous set.
        XCTAssertFalse(CommandFirewall.isDangerous(opcode: 0x14))
        let abort = try writer.encode(.abortHistoricalData(sequence: 0xB0))
        XCTAssertEqual(
            try FrameDecoder().decode(abort).paddedInner,
            Data([0x23, 0xB0, 0x14, 0x00])
        )
    }

    func testNoUnconstrainedRawWritePathIsNeededForFirewallCoverage() {
        // The production API accepts only ProductionCommand. Dangerous values
        // are typed sentinels and all fail before the internal FrameEncoder
        // sees any bytes; there is intentionally no public raw write path.
        XCTAssertTrue(CommandFirewall.isDangerous(opcode: 0x9A))
    }

    func testPRT05FamiliesUseTheSharedFirewallAndStayOutsideDangerousSet() throws {
        let rename = try RenameCommand.set(sequence: 2, name: "Loopr")
        let commands: [ProductionCommand] = [
            .battery(.request(sequence: 0x10)),
            .identity(.hello(sequence: 0)),
            .rename(rename),
            .haptic(.run(sequence: 3, pattern: 2)),
            .alarm(.setup(
                sequence: 11,
                epochSeconds: 0x1234_5678,
                subsecondTicks: 0x4000
            )),
            .alarm(.readback(sequence: 4)),
            .alarm(.test(sequence: 1)),
            .alarm(.disable(sequence: 3))
        ]
        let capabilities = CommandCapabilities(confirmed: Set(CommandCapability.allCases))
        let writer = ProductionCommandWriter(capabilities: capabilities)
        for command in commands {
            let frame = try writer.encode(command)
            let inner = try FrameDecoder().decode(frame).paddedInner
            XCTAssertEqual(inner[0], 0x23)
            XCTAssertFalse(CommandFirewall.isDangerous(opcode: inner[2]))
        }
    }
}
