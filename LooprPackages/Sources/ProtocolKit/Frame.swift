import Foundation

/// Constants shared by the Gen 4 frame encoder and decoder.
public enum Gen4Frame {
    public static let marker: UInt8 = 0xAA
    public static let minimumDeclaredLength = 4 // trailing CRC-32 only
    public static let maximumTotalLength = 4_096
}

/// A validated Gen 4 frame envelope.
///
/// `paddedInner` intentionally includes every byte between the length CRC-8
/// and the trailing CRC-32, including protocol padding.  No packet-level
/// interpretation is performed by ProtocolKit's framing layer.
public struct Frame: Equatable, Sendable {
    public let raw: Data
    public let paddedInner: Data
    public let declaredLength: UInt16

    internal init(raw: Data, paddedInner: Data, declaredLength: UInt16) {
        self.raw = raw
        self.paddedInner = paddedInner
        self.declaredLength = declaredLength
    }
}

/// Encodes a padded inner packet into the Gen 4 frame envelope.
///
/// This is deliberately module-internal.  ProtocolKit exposes framing reads
/// through `FrameDecoder`, while production writes must go through the closed
/// `ProductionCommandWriter` and its capability/firewall policy.
struct FrameEncoder: Sendable {
    init() {}

    /// Encodes bytes that are already padded to a four-byte boundary.
    func encode(_ paddedInner: Data) throws -> Data {
        guard paddedInner.count % 4 == 0 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "inner packet length \(paddedInner.count) is not padded to a four-byte boundary"
            )
        }

        // Keep the production command firewall at the final framing boundary
        // as well as in the typed writer. This protects the shared encoder
        // even when exercised by another ProtocolKit implementation.
        try CommandFirewall.validateFrameInner(paddedInner)

        let declaredInt = try ProtocolLengthArithmetic.checkedAdd(
            paddedInner.count,
            4,
            offset: 1
        )
        let totalInt = try ProtocolLengthArithmetic.checkedAdd(declaredInt, 4, offset: 0)

        guard totalInt <= Gen4Frame.maximumTotalLength else {
            throw ProtocolDecodeError.invalidRange(
                offset: 1,
                reason: "total frame length \(totalInt) exceeds maximum \(Gen4Frame.maximumTotalLength)"
            )
        }
        guard declaredInt <= Int(UInt16.max) else {
            throw ProtocolDecodeError.invalidRange(
                offset: 1,
                reason: "declared frame length \(declaredInt) does not fit UInt16"
            )
        }

        let declared = UInt16(declaredInt)
        let lengthBytes = Data([
            UInt8(truncatingIfNeeded: declared),
            UInt8(truncatingIfNeeded: declared >> 8)
        ])

        var frame = Data([Gen4Frame.marker])
        frame.append(lengthBytes)
        frame.append(CRC8.calculate(lengthBytes))
        frame.append(paddedInner)

        let tail = CRC32.calculate(paddedInner)
        frame.append(contentsOf: [
            UInt8(truncatingIfNeeded: tail),
            UInt8(truncatingIfNeeded: tail >> 8),
            UInt8(truncatingIfNeeded: tail >> 16),
            UInt8(truncatingIfNeeded: tail >> 24)
        ])
        return frame
    }

}

/// A strict single-frame decoder plus a bounded stream decoder.
///
/// `decode(_:)` accepts exactly one complete frame and throws a typed
/// `ProtocolDecodeError` for every malformed or truncated input.  `feed(_:)`
/// is the transport-facing recovery API: it consumes arbitrary garbage and
/// fragmented/coalesced bytes, returns only CRC-valid frames, and retains at
/// most one candidate frame in memory.
public final class FrameDecoder {
    /// The retained stream candidate can never exceed this protocol cap.
    public let maximumBufferedBytes = Gen4Frame.maximumTotalLength

    private var buffer = Data()
    private var errorsStorage: [ProtocolDecodeError] = []

    public private(set) var maximumObservedBufferedBytes = 0
    public private(set) var rejectionCount = 0
    public private(set) var lastError: ProtocolDecodeError?

    /// A bounded diagnostic history.  It is deliberately capped so malformed
    /// input cannot turn error reporting into an unbounded memory sink.
    public var errors: [ProtocolDecodeError] { errorsStorage }
    public var bufferedByteCount: Int { buffer.count }

    public init() {}

    /// Decodes one complete frame.  The input must contain no leading or
    /// trailing bytes; use `feed(_:)` for a byte stream.
    public func decode(_ raw: Data) throws -> Frame {
        try Self.decodeFrame(raw)
    }

    /// Consumes transport bytes and returns every complete, CRC-valid frame.
    /// Invalid candidates are rejected and recovery continues in the same
    /// call.  Rejections are available through `lastError` and `errors`.
    @discardableResult
    public func feed(_ bytes: Data) -> [Frame] {
        var frames: [Frame] = []
        for byte in bytes {
            buffer.append(byte)
            maximumObservedBufferedBytes = max(maximumObservedBufferedBytes, buffer.count)
            frames.append(contentsOf: processAvailable())
        }
        return frames
    }

    /// Discards a partial candidate and all bounded diagnostics.
    public func reset() {
        buffer = Data()
        errorsStorage.removeAll(keepingCapacity: true)
        maximumObservedBufferedBytes = 0
        rejectionCount = 0
        lastError = nil
    }

    private func processAvailable() -> [Frame] {
        var frames: [Frame] = []

        while true {
            guard !buffer.isEmpty else { return frames }

            // Transport garbage is discarded only until the next deterministic
            // marker.  Once a valid length is accepted, this branch is never
            // used for bytes inside that candidate.
            guard buffer[0] == Gen4Frame.marker else {
                resynchronize()
                continue
            }

            // Keep only the marker and the two length bytes until the header is
            // complete.  This also means an invalid length is rejected before
            // any declared body is retained as a candidate.
            guard buffer.count >= 4 else { return frames }

            let declared = Int(buffer[1]) | (Int(buffer[2]) << 8)
            if declared < Gen4Frame.minimumDeclaredLength {
                reject(.invalidValue(
                    offset: 1,
                    reason: "declared length \(declared) is below minimum \(Gen4Frame.minimumDeclaredLength)"
                ))
                resynchronize()
                continue
            }

            let total: Int
            do {
                total = try ProtocolLengthArithmetic.checkedAdd(declared, 4, offset: 1)
            } catch let error as ProtocolDecodeError {
                reject(error)
                resynchronize()
                continue
            } catch {
                reject(.arithmeticOverflow(offset: 1, reason: "overflow while computing total frame length"))
                resynchronize()
                continue
            }
            if total > Gen4Frame.maximumTotalLength {
                reject(.invalidRange(
                    offset: 1,
                    reason: "total frame length \(total) exceeds maximum \(Gen4Frame.maximumTotalLength)"
                ))
                resynchronize()
                continue
            }
            if total > maximumBufferedBytes {
                reject(.invalidRange(
                    offset: 1,
                    reason: "total frame length \(total) exceeds buffered-memory bound \(maximumBufferedBytes)"
                ))
                resynchronize()
                continue
            }

            let expectedCRC8 = CRC8.calculate(Data([buffer[1], buffer[2]]))
            if buffer[3] != expectedCRC8 {
                reject(.invalidValue(
                    offset: 3,
                    reason: "CRC-8 mismatch for declared length \(declared)"
                ))
                resynchronize()
                continue
            }

            guard buffer.count >= total else { return frames }

            // The byte-wise feed path normally makes this exact.  The guard is
            // retained for defensive correctness if the implementation changes
            // to batch appends in the future.
            let candidate = Data(buffer.prefix(total))
            // Rebuild the Data value so every candidate has a zero-based
            // index after a frame is consumed.
            buffer = Data(buffer.dropFirst(total))
            do {
                frames.append(try Self.decodeFrame(candidate))
            } catch let error as ProtocolDecodeError {
                // A valid header fixes the candidate boundary.  Remove the
                // whole candidate even when its tail CRC is bad, preserving any
                // embedded 0xAA and allowing the next frame to be considered.
                reject(error)
            } catch {
                reject(.invalidValue(offset: total - 4, reason: "unexpected frame decode failure: \(error)"))
            }
        }
    }

    private func resynchronize() {
        guard let nextMarker = buffer.dropFirst().firstIndex(of: Gen4Frame.marker) else {
            buffer = Data()
            return
        }
        // Rebuild the Data value so every candidate has a zero-based index
        // after garbage is discarded.
        buffer = Data(buffer.dropFirst(nextMarker))
    }

    private func reject(_ error: ProtocolDecodeError) {
        rejectionCount += 1
        lastError = error
        if errorsStorage.count == 64 {
            errorsStorage.removeFirst()
        }
        errorsStorage.append(error)
    }

    private static func decodeFrame(_ raw: Data) throws -> Frame {
        guard !raw.isEmpty else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 0,
                reason: "truncated input: expected frame marker byte, input is empty"
            )
        }
        guard raw[0] == Gen4Frame.marker else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "invalid frame marker 0x\(String(raw[0], radix: 16))"
            )
        }
        guard raw.count >= 3 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 1,
                reason: "truncated input: expected 2 byte(s) for declared length, only \(max(0, raw.count - 1)) remaining"
            )
        }

        let declared = Int(raw[1]) | (Int(raw[2]) << 8)
        guard declared >= Gen4Frame.minimumDeclaredLength else {
            throw ProtocolDecodeError.invalidValue(
                offset: 1,
                reason: "declared length \(declared) is below minimum \(Gen4Frame.minimumDeclaredLength)"
            )
        }

        let total = try ProtocolLengthArithmetic.checkedAdd(declared, 4, offset: 1)
        guard total <= Gen4Frame.maximumTotalLength else {
            throw ProtocolDecodeError.invalidRange(
                offset: 1,
                reason: "total frame length \(total) exceeds maximum \(Gen4Frame.maximumTotalLength)"
            )
        }
        guard raw.count >= 4 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 3,
                reason: "truncated input: expected length CRC-8 byte, only \(max(0, raw.count - 3)) remaining"
            )
        }

        let expectedCRC8 = CRC8.calculate(Data([raw[1], raw[2]]))
        guard raw[3] == expectedCRC8 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 3,
                reason: "CRC-8 mismatch for declared length \(declared)"
            )
        }

        let innerLength = declared - 4
        guard innerLength % 4 == 0 else {
            throw ProtocolDecodeError.invalidRange(
                offset: 1,
                reason: "padded inner length \(innerLength) is not a multiple of four"
            )
        }
        guard raw.count >= total else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: "truncated frame: expected total length \(total), only \(raw.count) byte(s) available"
            )
        }
        guard raw.count == total else {
            throw ProtocolDecodeError.invalidRange(
                offset: total,
                reason: "unexpected trailing bytes: frame length is \(total), input contains \(raw.count)"
            )
        }

        let innerStart = 4
        let tailStart = total - 4
        let paddedInner = Data(raw[innerStart..<tailStart])
        let expectedCRC32 = CRC32.calculate(paddedInner)
        let storedCRC32 = UInt32(raw[tailStart])
            | (UInt32(raw[tailStart + 1]) << 8)
            | (UInt32(raw[tailStart + 2]) << 16)
            | (UInt32(raw[tailStart + 3]) << 24)

        guard storedCRC32 == expectedCRC32 else {
            throw ProtocolDecodeError.invalidValue(
                offset: tailStart,
                reason: "CRC-32 mismatch for \(innerLength)-byte padded inner packet"
            )
        }

        return Frame(
            raw: Data(raw),
            paddedInner: paddedInner,
            declaredLength: UInt16(declared)
        )
    }
}
