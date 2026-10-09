import Foundation

public enum Gen5OperationalCommandError: Error, Equatable, Sendable {
    case invalidHistoryTokenLength(Int)
}

/// Only the basic FD4B operations with source-backed command bytes. The
/// caller still owns consent, generation fencing, and the durable ACK barrier.
package enum Gen5OperationalCommand: Equatable, Sendable {
    case clientHello
    case battery
    case heartRateSharing(Bool)
    case heartRateSharingRead
    case clockRead
    case liveHeartRate(Bool)
    case dataRange
    case sendHistory
    case historyAcknowledgement(Data)

    package var innerBody: Data {
        switch self {
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:342-350.
        case .clientHello: Data([0x91, 0x01])
        // OpenStrap protocol@c525e29e:lib/src/constants.dart:40-51 and
        // lib/src/commands.dart:76-77.
        case .battery: Data([0x1A])
        // NOOP docs/PROTOCOL_CONFIGURATION.md, named configuration interface.
        case .heartRateSharing(let enabled): HeartRateSharingCommand(sequence: 0, enabled: enabled).gen5WriteBody
        case .heartRateSharingRead: HeartRateSharingCommand.gen5ReadBody
        // OpenStrap protocol@c525e29e:lib/src/constants.dart:90-96 and
        // lib/src/commands.dart:393-395. Firmware-specific readback remains
        // gated because noop's revision-1 body differs.
        case .clockRead: Data([0x93])
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:153-156.
        case .liveHeartRate(let enabled): Data([0x03, enabled ? 0x01 : 0x00])
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:352-359.
        case .dataRange: Data([0x22])
        case .sendHistory: Data([0x16])
        // OpenStrap protocol@c525e29e:lib/src/commands.dart:33-49 and
        // test/gen5_test.dart:130-155. Token bytes remain opaque.
        case .historyAcknowledgement(let token): Data([0x17, 0x01]) + token
        }
    }
}

package struct Gen5OperationalCommandEncoder: Sendable {
    package init() {}

    package func encode(_ command: Gen5OperationalCommand, sequence: UInt8) throws -> Data {
        if case .historyAcknowledgement(let token) = command, token.count != 8 {
            throw Gen5OperationalCommandError.invalidHistoryTokenLength(token.count)
        }
        let inner = Data([0x23, sequence]) + command.innerBody
        try CommandFirewall.validateFrameInner(inner)
        return try Gen5FrameCodec().encode(inner)
    }
}
