import Foundation

/// The single decoding failure type used by ProtocolKit's byte primitives.
///
/// A decode error always identifies the byte offset at which the decoder could
/// not make progress.  The reason is intentionally a string because it is
/// useful in diagnostics while keeping this package independent of any
/// logging/UI framework.
public enum ProtocolDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A read needed more bytes than are available in the cursor.
    case outOfBounds(offset: Int, reason: String)

    /// A requested length or range is not valid for the cursor.
    case invalidRange(offset: Int, reason: String)

    /// A checked length operation could not be represented by its integer type.
    case arithmeticOverflow(offset: Int, reason: String)

    /// Bytes were present but did not represent an acceptable value.
    case invalidValue(offset: Int, reason: String)

    /// The byte offset where decoding failed.
    public var offset: Int {
        switch self {
        case .outOfBounds(let offset, _),
             .invalidRange(let offset, _),
             .arithmeticOverflow(let offset, _),
             .invalidValue(let offset, _):
            return offset
        }
    }

    /// An explanation suitable for diagnostics and test assertions.
    public var reason: String {
        switch self {
        case .outOfBounds(_, let reason),
             .invalidRange(_, let reason),
             .arithmeticOverflow(_, let reason),
             .invalidValue(_, let reason):
            return reason
        }
    }

    public var description: String {
        "Protocol decode failed at byte \(offset): \(reason)"
    }
}

/// Overflow-checked arithmetic for offsets and lengths used during decoding.
///
/// Swift's normal integer operators trap in debug builds and wrap when
/// explicitly requested in release-oriented code.  Protocol parsing must do
/// neither: malformed input is data, so arithmetic failure is represented by a
/// `ProtocolDecodeError` instead.
public enum ProtocolLengthArithmetic {
    /// Returns `lhs + rhs`, or a typed error if the result is not representable.
    public static func checkedAdd<T: FixedWidthInteger>(
        _ lhs: T,
        _ rhs: T,
        offset: Int = 0
    ) throws -> T {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw ProtocolDecodeError.arithmeticOverflow(
                offset: offset,
                reason: "integer overflow while adding \(String(describing: lhs)) and \(String(describing: rhs))"
            )
        }
        return result.partialValue
    }

    /// Returns `lhs * rhs`, or a typed error if the result is not representable.
    public static func checkedMultiply<T: FixedWidthInteger>(
        _ lhs: T,
        _ rhs: T,
        offset: Int = 0
    ) throws -> T {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw ProtocolDecodeError.arithmeticOverflow(
                offset: offset,
                reason: "integer overflow while multiplying \(String(describing: lhs)) by \(String(describing: rhs))"
            )
        }
        return result.partialValue
    }

}

/// A bounds-checked cursor over an immutable byte buffer.
///
/// Every read validates the complete field before advancing `position`, so a
/// truncated field never returns a partial value and never leaves the cursor
/// halfway through that field.  `Data` is a value type; slices returned by this
/// cursor are copied with `subdata(in:)` and do not expose storage outside the
/// requested range.
public struct ByteCursor: Sendable {
    private let storage: Data
    private var positionStorage: Int

    /// Creates a cursor positioned at byte zero.
    public init(_ data: Data) {
        storage = data
        positionStorage = 0
    }

    /// The complete source data.  `Data`'s value semantics prevent callers from
    /// mutating the cursor's backing bytes through this property.
    public var data: Data { storage }

    /// The current byte position, measured from the beginning of `data`.
    public var position: Int { positionStorage }

    /// Number of unread bytes.
    public var remaining: Int { storage.count - positionStorage }

    /// Whether all source bytes have been consumed.
    public var isAtEnd: Bool { positionStorage == storage.count }

    /// Reads one byte and advances by one position.
    public mutating func readByte() throws -> UInt8 {
        let bytes = try readRaw(count: 1)
        // `readRaw(count: 1)` proves this index exists before returning.
        return bytes[bytes.startIndex]
    }

    /// Reads an unsigned 16-bit little-endian integer.
    public mutating func readUInt16LE() throws -> UInt16 {
        let bytes = try readRaw(count: MemoryLayout<UInt16>.size)
        return UInt16(bytes[0])
            | (UInt16(bytes[1]) << 8)
    }

    /// Reads an unsigned 32-bit little-endian integer.
    public mutating func readUInt32LE() throws -> UInt32 {
        let bytes = try readRaw(count: MemoryLayout<UInt32>.size)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    /// Reads an unsigned 64-bit little-endian integer.
    public mutating func readUInt64LE() throws -> UInt64 {
        let bytes = try readRaw(count: MemoryLayout<UInt64>.size)
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (UInt64(index) * 8)
        }
        return value
    }

    /// Reads a signed 8-bit integer.
    public mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readByte())
    }

    /// Reads a signed 16-bit little-endian integer.
    public mutating func readInt16LE() throws -> Int16 {
        Int16(bitPattern: try readUInt16LE())
    }

    /// Reads a signed 32-bit little-endian integer.
    public mutating func readInt32LE() throws -> Int32 {
        Int32(bitPattern: try readUInt32LE())
    }

    /// Reads a signed 64-bit little-endian integer.
    public mutating func readInt64LE() throws -> Int64 {
        Int64(bitPattern: try readUInt64LE())
    }

    /// Reads an IEEE-754 32-bit float encoded little-endian.
    public mutating func readFloat32LE() throws -> Float {
        Float(bitPattern: try readUInt32LE())
    }

    /// Explicit byte-slice reader that advances the cursor.
    public mutating func readSlice(length: Int) throws -> Data {
        try readRaw(count: length)
    }

    /// Returns an independent copy of an absolute byte range without moving
    /// the cursor.  The range is checked before constructing `Range`, so bad
    /// offsets and lengths remain typed decode errors rather than traps.
    public func slice(offset: Int, length: Int) throws -> Data {
        let end = try checkedRangeEnd(offset: offset, length: length)
        return storage.subdata(in: offset..<end)
    }

    /// Moves the cursor over `count` bytes after validating that they exist.
    public mutating func skip(_ count: Int) throws {
        _ = try checkedRangeEnd(offset: positionStorage, length: count)
        positionStorage += count
    }


    private mutating func readRaw(count: Int) throws -> Data {
        let start = positionStorage
        let end = try checkedRangeEnd(offset: start, length: count)
        let result = storage.subdata(in: start..<end)
        positionStorage = end
        return result
    }

    private func checkedRangeEnd(offset: Int, length: Int) throws -> Int {
        guard offset >= 0 else {
            throw ProtocolDecodeError.invalidRange(
                offset: max(0, offset),
                reason: "negative byte offset \(offset)"
            )
        }
        guard length >= 0 else {
            throw ProtocolDecodeError.invalidRange(
                offset: offset,
                reason: "negative byte length \(length)"
            )
        }

        let end = try ProtocolLengthArithmetic.checkedAdd(offset, length, offset: offset)
        guard offset <= storage.count else {
            throw ProtocolDecodeError.invalidRange(
                offset: offset,
                reason: "byte offset \(offset) is past the end of \(storage.count)-byte input"
            )
        }
        guard end <= storage.count else {
            throw ProtocolDecodeError.outOfBounds(
                offset: offset,
                reason: "truncated input: expected \(length) byte(s), only \(storage.count - offset) remaining"
            )
        }
        return end
    }
}
