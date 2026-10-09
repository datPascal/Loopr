/// The Gen 4 CRC-8 used for the two-byte declared-length field.
///
/// This is the algorithm in the pinned OpenStrap protocol source
/// (`7edcb3e377329968118c62cb03a81d95e2f6db8e:lib/src/crc.dart`): polynomial
/// `0x07`, initial value `0`, and a non-reflected bit order.
public enum CRC8 {
    public static let polynomial: UInt8 = 0x07
    public static let initialValue: UInt8 = 0

    /// Calculates CRC-8 over `bytes`.
    public static func calculate<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc = initialValue
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ polynomial
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

}

/// The Gen 4 reflected IEEE CRC-32 used for padded inner packet bytes.
///
/// This is the zlib/IEEE algorithm in the pinned OpenStrap protocol source
/// (`7edcb3e377329968118c62cb03a81d95e2f6db8e:lib/src/crc.dart`): reflected
/// polynomial `0xEDB88320`, initial value `0xffffffff`, and final XOR
/// `0xffffffff`.
public enum CRC32 {
    public static let polynomial: UInt32 = 0xEDB8_8320
    public static let initialValue: UInt32 = 0xffff_ffff
    public static let finalXOR: UInt32 = 0xffff_ffff

    /// Calculates reflected IEEE CRC-32 over `bytes`.
    public static func calculate<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc = initialValue
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ finalXOR
    }

}

/// CRC16-Modbus used by the experimental fd4b frame header. The checksum is
/// calculated over header bytes 0...5 and serialized little-endian.
public enum CRC16Modbus {
    public static let polynomial: UInt16 = 0xA001
    public static let initialValue: UInt16 = 0xFFFF

    public static func calculate<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc = initialValue
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ polynomial : crc >> 1
            }
        }
        return crc
    }
}

/// Small free-function spellings used by protocol call sites.
public func crc8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
    CRC8.calculate(bytes)
}

public func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    CRC32.calculate(bytes)
}

public func crc16Modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
    CRC16Modbus.calculate(bytes)
}
