import Foundation

/// The entire Gate-1 public vocabulary is one typed command. Historical,
/// clock, ACK, haptic, alarm, rename/config, and deep-buffer opcodes do not
/// appear here and therefore have no production encode route.
package enum Gen5InitialCommand: Equatable, Sendable {
    case clientHello(sequence: UInt8)

    package static var allowedOpcodes: Set<UInt8> { [0x91] }

    package var paddedInner: Data {
        switch self {
        case .clientHello(let sequence): Data([0x23, sequence, 0x91, 0x01])
        }
    }
}

package struct Gen5InitialCommandEncoder: Sendable {
    package init() {}

    package func encode(_ command: Gen5InitialCommand) throws -> Data {
        try Gen5FrameCodec().encode(command.paddedInner)
    }
}
