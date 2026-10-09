import Foundation

public enum Gen5FrameEnvelope {
    public static let marker: UInt8 = 0xAA
    public static let fixedHeaderByte: UInt8 = 0x01
    public static let outboundDirectionMarker = Data([0x00, 0x01])
    public static let observedInboundDirectionMarker = Data([0x01, 0x00])
    public static let headerLength = 8
    public static let minimumDeclaredLength = 4
    public static let maximumTotalLength = 4_096
}

public enum Gen5FrameError: Error, Equatable, Sendable {
    case truncated(offset: Int)
    case invalidMarker(UInt8)
    case invalidFixedHeaderByte(UInt8)
    case invalidLength(Int)
    case unexpectedTrailingBytes(expected: Int, actual: Int)
    case headerCRC16Mismatch(expected: UInt16, actual: UInt16)
    case payloadCRC32Mismatch(expected: UInt32, actual: UInt32)
}

public struct Gen5DecodedFrame: Equatable, Sendable {
    public let raw: Data
    public let paddedInner: Data
    public let declaredLength: UInt16
    public let directionMarker: Data
}

/// Profile-specific fd4b framing. It deliberately does not reject a frame by
/// direction marker: current capture evidence observes distinct host/strap
/// pairs, but does not establish a complete semantic validity rule.
package struct Gen5FrameCodec: Sendable {
    package init() {}

    func encode(_ inner: Data, directionMarker: Data = Gen5FrameEnvelope.outboundDirectionMarker) throws -> Data {
        guard directionMarker.count == 2 else { throw Gen5FrameError.invalidLength(directionMarker.count) }
        var padded = inner
        padded.append(contentsOf: repeatElement(0, count: (4 - padded.count % 4) % 4))
        let declared = padded.count + 4
        let total = declared + Gen5FrameEnvelope.headerLength
        guard declared <= Int(UInt16.max), total <= Gen5FrameEnvelope.maximumTotalLength else {
            throw Gen5FrameError.invalidLength(declared)
        }

        var result = Data([
            Gen5FrameEnvelope.marker,
            Gen5FrameEnvelope.fixedHeaderByte,
            UInt8(truncatingIfNeeded: declared),
            UInt8(truncatingIfNeeded: declared >> 8),
            directionMarker[0],
            directionMarker[1]
        ])
        let headerCRC = CRC16Modbus.calculate(result)
        result.append(UInt8(truncatingIfNeeded: headerCRC))
        result.append(UInt8(truncatingIfNeeded: headerCRC >> 8))
        result.append(padded)
        let tail = CRC32.calculate(padded)
        result.append(contentsOf: [
            UInt8(truncatingIfNeeded: tail),
            UInt8(truncatingIfNeeded: tail >> 8),
            UInt8(truncatingIfNeeded: tail >> 16),
            UInt8(truncatingIfNeeded: tail >> 24)
        ])
        return result
    }

    func decode(_ raw: Data) throws -> Gen5DecodedFrame {
        guard raw.count >= Gen5FrameEnvelope.headerLength else { throw Gen5FrameError.truncated(offset: raw.count) }
        guard raw[0] == Gen5FrameEnvelope.marker else { throw Gen5FrameError.invalidMarker(raw[0]) }
        guard raw[1] == Gen5FrameEnvelope.fixedHeaderByte else { throw Gen5FrameError.invalidFixedHeaderByte(raw[1]) }

        let declared = Int(raw[2]) | Int(raw[3]) << 8
        let total = declared + Gen5FrameEnvelope.headerLength
        guard declared >= Gen5FrameEnvelope.minimumDeclaredLength,
              total <= Gen5FrameEnvelope.maximumTotalLength else {
            throw Gen5FrameError.invalidLength(declared)
        }
        guard raw.count >= total else { throw Gen5FrameError.truncated(offset: raw.count) }
        guard raw.count == total else { throw Gen5FrameError.unexpectedTrailingBytes(expected: total, actual: raw.count) }

        let expectedHeaderCRC = CRC16Modbus.calculate(raw.prefix(6))
        let actualHeaderCRC = UInt16(raw[6]) | UInt16(raw[7]) << 8
        guard actualHeaderCRC == expectedHeaderCRC else {
            throw Gen5FrameError.headerCRC16Mismatch(expected: expectedHeaderCRC, actual: actualHeaderCRC)
        }

        let tailStart = total - 4
        let paddedInner = Data(raw[Gen5FrameEnvelope.headerLength..<tailStart])
        guard paddedInner.count % 4 == 0 else { throw Gen5FrameError.invalidLength(declared) }
        let expectedTail = CRC32.calculate(paddedInner)
        let actualTail = UInt32(raw[tailStart])
            | UInt32(raw[tailStart + 1]) << 8
            | UInt32(raw[tailStart + 2]) << 16
            | UInt32(raw[tailStart + 3]) << 24
        guard actualTail == expectedTail else {
            throw Gen5FrameError.payloadCRC32Mismatch(expected: expectedTail, actual: actualTail)
        }

        return Gen5DecodedFrame(
            raw: raw,
            paddedInner: paddedInner,
            declaredLength: UInt16(declared),
            directionMarker: Data(raw[4...5])
        )
    }
}

package final class Gen5FrameStreamDecoder {
    private let codec = Gen5FrameCodec()
    private var buffer = Data()
    private(set) var lastError: Gen5FrameError?

    package init() {}

    package func feed(_ bytes: Data) -> [Gen5DecodedFrame] {
        buffer.append(bytes)
        var result: [Gen5DecodedFrame] = []
        while !buffer.isEmpty {
            // `Data.removeFirst` advances the collection's start index; a
            // coalesced second frame therefore cannot be addressed with
            // absolute zero-based subscripts. Always index relative to the
            // current slice boundary.
            let start = buffer.startIndex
            guard buffer[start] == Gen5FrameEnvelope.marker else {
                buffer = Data(buffer.dropFirst())
                continue
            }
            guard buffer.count >= Gen5FrameEnvelope.headerLength else { break }
            let lengthLow = buffer.index(start, offsetBy: 2)
            let lengthHigh = buffer.index(start, offsetBy: 3)
            let declared = Int(buffer[lengthLow]) | Int(buffer[lengthHigh]) << 8
            let total = declared + Gen5FrameEnvelope.headerLength
            guard declared >= Gen5FrameEnvelope.minimumDeclaredLength,
                  total <= Gen5FrameEnvelope.maximumTotalLength else {
                lastError = .invalidLength(declared)
                buffer = Data(buffer.dropFirst())
                continue
            }
            guard buffer.count >= total else { break }
            let candidate = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            do { result.append(try codec.decode(candidate)) }
            catch let error as Gen5FrameError { lastError = error }
            catch { lastError = .invalidLength(declared) }
        }
        if buffer.count > Gen5FrameEnvelope.maximumTotalLength { buffer.removeAll() }
        return result
    }
}
