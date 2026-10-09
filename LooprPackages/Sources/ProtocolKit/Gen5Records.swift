import Foundation

public struct Gen5V18Sample: Equatable, Sendable {
    public let timestampSeconds: UInt32
    public let recordIndex: UInt32
    public let heartRate: UInt8?
    public let rrIntervalsMilliseconds: [UInt16]
    public let dynamicAccelerationG: Float?
    public let gravityG: [Float]

    public init(
        timestampSeconds: UInt32,
        recordIndex: UInt32,
        heartRate: UInt8?,
        rrIntervalsMilliseconds: [UInt16],
        dynamicAccelerationG: Float?,
        gravityG: [Float]
    ) {
        self.timestampSeconds = timestampSeconds
        self.recordIndex = recordIndex
        self.heartRate = heartRate
        self.rrIntervalsMilliseconds = rrIntervalsMilliseconds
        self.dynamicAccelerationG = dynamicAccelerationG
        self.gravityG = gravityG
    }
}

public struct Gen5RawArchiveRecord: Equatable, Sendable {
    public let version: UInt8
    public let timestampSeconds: UInt32
    public let recordIndex: UInt32
    public let raw: Data
}

public struct Gen5V26ArchiveRecord: Equatable, Sendable {
    public let timestampSeconds: UInt32
    public let recordIndex: UInt32
    public let samples: [Int16]
    public let raw: Data
}

public enum Gen5DecodedRecord: Equatable, Sendable {
    case v18(Gen5V18Sample)
    case v20Raw(Gen5RawArchiveRecord)
    case v21Raw(Gen5RawArchiveRecord)
    case v26Archive(Gen5V26ArchiveRecord)
}

public enum Gen5RecordDecodeError: Error, Equatable, Sendable {
    case truncated(version: UInt8?, expectedAtLeast: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case invalidShape(version: UInt8, actualLength: Int)
    case invalidValue(version: UInt8, offset: Int)
}

public struct Gen5RecordDecoder: Sendable {
    public init() {}

    public func decode(_ inner: Data) throws -> Gen5DecodedRecord {
        guard inner.count >= 2 else {
            throw Gen5RecordDecodeError.truncated(version: nil, expectedAtLeast: 2, actual: inner.count)
        }
        // v21 is shape-gated before trusting its nominal version byte. The
        // same buffer can arrive through historical 0x2f or realtime 0x2b.
        let isV21Packet = inner[0] == PacketType.historicalRecord.rawValue
            || inner[0] == PacketType.realtimeRaw.rawValue
        let countA = inner.count == 1_232 ? inner.u16(at: 16) : 0
        let countB = inner.count == 1_232 ? inner.u16(at: 622) : 0
        if isV21Packet,
           (1...100).contains(countA),
           (1...100).contains(countB) {
            return .v21Raw(try rawArchive(inner, version: 21))
        }
        guard inner[0] == PacketType.historicalRecord.rawValue else {
            throw Gen5RecordDecodeError.invalidValue(version: inner[1], offset: 0)
        }
        switch inner[1] {
        case 18: return .v18(try decodeV18(inner))
        case 20:
            guard inner.count == 2_128 else { throw Gen5RecordDecodeError.invalidShape(version: 20, actualLength: inner.count) }
            return .v20Raw(try rawArchive(inner, version: 20))
        case 21:
            throw Gen5RecordDecodeError.invalidShape(version: 21, actualLength: inner.count)
        case 26: return .v26Archive(try decodeV26(inner))
        default: throw Gen5RecordDecodeError.unsupportedVersion(inner[1])
        }
    }

    private func decodeV18(_ inner: Data) throws -> Gen5V18Sample {
        guard inner.count >= 109 else {
            throw Gen5RecordDecodeError.truncated(version: 18, expectedAtLeast: 109, actual: inner.count)
        }
        let rawHeartRate = inner[14]
        // Bit 7 at offset 28 is an estimator-corroboration flag, not an HR
        // validity bit. Real records carry valid HR while it is clear.
        let heartRate: UInt8? = (25...230).contains(rawHeartRate) ? rawHeartRate : nil
        let declaredRR = Int(inner[15])
        var rr: [UInt16] = []
        if declaredRR <= 4 {
            for index in 0..<declaredRR {
                let value = inner.u16(at: 16 + index * 2)
                if (200...2_500).contains(value) { rr.append(value) }
            }
        }
        let dynamicAcceleration = inner.f32(at: 33)
        let gravity = [inner.f32(at: 37), inner.f32(at: 41), inner.f32(at: 45)]
        let dynamicAccelerationValue = dynamicAcceleration.isFinite
            && (0...16).contains(dynamicAcceleration) ? dynamicAcceleration : nil
        let gravityValue = gravity.allSatisfy { $0.isFinite && abs($0) <= 16 }
            ? gravity : []
        return Gen5V18Sample(
            timestampSeconds: inner.u32(at: 7),
            recordIndex: inner.u32(at: 3),
            heartRate: heartRate,
            rrIntervalsMilliseconds: rr,
            dynamicAccelerationG: dynamicAccelerationValue,
            gravityG: gravityValue
        )
    }

    private func decodeV26(_ inner: Data) throws -> Gen5V26ArchiveRecord {
        guard inner.count == 76 else {
            throw Gen5RecordDecodeError.invalidShape(version: 26, actualLength: inner.count)
        }
        var samples: [Int16] = []
        samples.reserveCapacity(24)
        for index in 0..<24 { samples.append(Int16(bitPattern: inner.u16(at: 19 + index * 2))) }
        return Gen5V26ArchiveRecord(
            timestampSeconds: inner.u32(at: 7),
            // OpenStrap protocol feat/multiband-whoop5,
            // test/gen5_historical_test.dart:119-131,163-190 confirms this
            // counter is u16 in consecutive captured v26 frames.
            recordIndex: UInt32(inner.u16(at: 3)),
            samples: samples,
            raw: inner
        )
    }

    private func rawArchive(_ inner: Data, version: UInt8) throws -> Gen5RawArchiveRecord {
        guard inner.count >= 11 else {
            throw Gen5RecordDecodeError.truncated(version: version, expectedAtLeast: 11, actual: inner.count)
        }
        return Gen5RawArchiveRecord(
            version: version,
            timestampSeconds: inner.u32(at: 7),
            recordIndex: inner.u32(at: 3),
            raw: inner
        )
    }
}

public enum Gen5ArchiveDecision: Equatable, Sendable {
    case decoded(Gen5DecodedRecord)
    case unknownRaw(version: UInt8, bytes: Data)
}

public extension Gen5RecordDecoder {
    /// Research ingestion never drops an unknown version. Unknown MG and 5.0
    /// records remain byte-exact raw evidence and acquire no metric semantics.
    func decodeOrArchiveUnknown(_ inner: Data) throws -> Gen5ArchiveDecision {
        do { return .decoded(try decode(inner)) }
        catch Gen5RecordDecodeError.unsupportedVersion(let version) {
            return .unknownRaw(version: version, bytes: Data(inner))
        }
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func f32(at offset: Int) -> Float { Float(bitPattern: u32(at: offset)) }
}
