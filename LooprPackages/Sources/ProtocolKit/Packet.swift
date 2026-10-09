import Foundation

/// The packet discriminator carried by the first byte of a decoded inner
/// packet. These are the Gen 4 packet families.
public enum PacketType: UInt8, CaseIterable, Equatable, Sendable {
    case commandResponse = 0x24
    case compactLiveHeartRate = 0x28
    case realtimeRaw = 0x2B
    case historicalRecord = 0x2F
    case event = 0x30
    case historyMetadata = 0x31
    case console = 0x32
    case realtimeIMU = 0x33

    // Explicit aliases keep call sites readable without creating a second
    // source of truth for the wire values.
    public static var commandResponse24: Self { .commandResponse }
    public static var compactLiveHeartRate28: Self { .compactLiveHeartRate }
    public static var realtimeRaw2B: Self { .realtimeRaw }
    public static var historicalRecord2F: Self { .historicalRecord }
    public static var event30: Self { .event }
    public static var historyMetadata31: Self { .historyMetadata }
    public static var console32: Self { .console }
    public static var realtimeIMU33: Self { .realtimeIMU }
}

/// A reason retained when the packet decoder can identify a packet but cannot
/// honestly interpret its historical-record payload.
public enum DecodeReason: Equatable, Sendable, CustomStringConvertible {
    case unsupportedVersion(UInt8)
    case malformedHistoricalRecord(String)
    case truncatedHistoricalRecord(expectedAtLeast: Int, actual: Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported historical-record version \(version)"
        case .malformedHistoricalRecord(let reason):
            return "malformed historical record: \(reason)"
        case .truncatedHistoricalRecord(let expected, let actual):
            return "truncated historical record: expected at least \(expected) bytes, received \(actual)"
        }
    }
}

/// A small, typed representation of a decoded historical record's gravity
/// vector.  The vector is only populated when the pinned layout contains it;
/// no value is synthesized when a layout omits the field.
public struct GravityVector: Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Fields that are structurally decoded for a recognized historical version.
/// `heartRate` is optional because the pinned version-25 layout does not carry
/// a trustworthy HR field.  Missing values remain absent rather than becoming
/// zeroes.
public struct DecodedHistoricalRecord: Equatable, Sendable {
    public let version: UInt8
    public let raw: Data
    public let counter: UInt32
    public let timestampSeconds: UInt32
    public let subsecondTicks: UInt16?
    public let heartRate: UInt8?
    public let gravity: GravityVector?
    public let rrIntervalsMilliseconds: [UInt16]
    public let ppgGreen: UInt16?
    public let ppgRedIR: UInt16?
    public let skinContact: UInt8?
    public let spo2RedRaw: UInt16?
    public let spo2IRRaw: UInt16?
    /// Unidentified v24 channel at offset 68. Never used as temperature.
    public let unidentified68: UInt16?
    public let skinTemperatureCelsius: Double?
    public let ambientRaw: UInt16?

    public init(
        version: UInt8,
        raw: Data,
        counter: UInt32,
        timestampSeconds: UInt32,
        subsecondTicks: UInt16?,
        heartRate: UInt8?,
        gravity: GravityVector?,
        rrIntervalsMilliseconds: [UInt16] = [],
        ppgGreen: UInt16? = nil,
        ppgRedIR: UInt16? = nil,
        skinContact: UInt8? = nil,
        spo2RedRaw: UInt16? = nil,
        spo2IRRaw: UInt16? = nil,
        unidentified68: UInt16? = nil,
        skinTemperatureCelsius: Double? = nil,
        ambientRaw: UInt16? = nil
    ) {
        self.version = version
        self.raw = raw
        self.counter = counter
        self.timestampSeconds = timestampSeconds
        self.subsecondTicks = subsecondTicks
        self.heartRate = heartRate
        self.gravity = gravity
        self.rrIntervalsMilliseconds = rrIntervalsMilliseconds
        self.ppgGreen = ppgGreen
        self.ppgRedIR = ppgRedIR
        self.skinContact = skinContact
        self.spo2RedRaw = spo2RedRaw
        self.spo2IRRaw = spo2IRRaw
        self.unidentified68 = unidentified68
        self.skinTemperatureCelsius = skinTemperatureCelsius
        self.ambientRaw = ambientRaw
    }

    // Source-oriented aliases used by downstream decode/storage code.
    public var histVersion: UInt8 { version }
    public var tsEpoch: UInt32 { timestampSeconds }
    public var tsSubsecond: UInt16? { subsecondTicks }
    public var hr: UInt8? { heartRate }
    public var accelG: GravityVector? { gravity }
}

/// The honest result of historical-record decoding.  Unknown versions are
/// retained as raw bytes and cannot be mistaken for a successful record with
/// default fields.
public enum HistoricalRecord: Equatable, Sendable {
    case decoded(DecodedHistoricalRecord)
    case unsupported(version: UInt8?, raw: Data, reason: DecodeReason)

    /// Decodes a complete inner historical-record packet, including its 0x2F
    /// discriminator byte.
    public static func decode(_ raw: Data) throws -> Self {
        guard !raw.isEmpty else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 0,
                reason: "truncated historical record: expected packet type and version"
            )
        }
        guard raw[0] == PacketType.historicalRecord.rawValue else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "expected historical-record packet type 0x2f, got 0x\(String(raw[0], radix: 16))"
            )
        }
        guard raw.count >= 2 else {
            // The discriminator identifies this as a historical packet, but
            // there is no version to interpret. Preserve the exact bytes and
            // fail closed instead of turning a one-byte packet into a typed
            // truncation error that loses the packet identity.
            return .unsupported(
                version: nil,
                raw: Data(raw),
                reason: .malformedHistoricalRecord("missing historical-record version byte")
            )
        }

        let version = raw[1]
        guard supportedVersions.contains(version) else {
            return .unsupported(
                version: version,
                raw: Data(raw),
                reason: .unsupportedVersion(version)
            )
        }

        // Version 25 is a roughly 76-byte waveform record. Earlier builds read
        // three values near its tail as an accelerometer vector, but corpus
        // comparison against same-second v24 records refuted that mapping.
        // The upstream decoder uses 75 bytes as the truncation floor and
        // leaves motion absent.
        if version == 25, raw.count < 75 {
            return .unsupported(
                version: version,
                raw: Data(raw),
                reason: .malformedHistoricalRecord(
                    "version 25 must contain at least 75 bytes, received \(raw.count)"
                )
            )
        }

        // Every other supported layout reaches the pinned legacy gravity
        // block. Version 25 needs only the shared counter/timestamp header.
        // OpenStrap's v24 parser rejects records shorter than 89 bytes even
        // though the last surfaced ADC field ends at byte 71. Preserve that
        // complete-record floor so a truncated payload is archived instead of
        // publishing partially trusted optical values.
        let minimumHeaderLength = switch version {
        case 24: 89
        case 25: 11
        default: 72
        }
        guard raw.count >= minimumHeaderLength else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: DecodeReason.truncatedHistoricalRecord(
                    expectedAtLeast: minimumHeaderLength,
                    actual: raw.count
                ).description
            )
        }

        var cursor = ByteCursor(raw)
        _ = try cursor.readByte() // packet type
        _ = try cursor.readByte() // version
        try cursor.skip(1) // reserved byte at offset 2
        let counter = try cursor.readUInt32LE()
        let timestampSeconds = try cursor.readUInt32LE()
        let subsecondTicks: UInt16? = version == 25 ? nil : try cursor.readUInt16LE()
        let heartRate: UInt8?
        switch version {
        case 7:
            try cursor.skip(14) // offset 13 -> HR at 27
            heartRate = try cursor.readByte()
        case 18:
            try cursor.skip(1) // offset 13 -> HR at 14
            heartRate = try cursor.readByte()
        case 9, 12, 24:
            try cursor.skip(4) // offset 13 -> HR at 17
            heartRate = try cursor.readByte()
        case 25:
            heartRate = nil
        default:
            // Guarded by supportedVersions above.  Keeping this branch makes
            // future edits fail closed if the list and layout switch diverge.
            return .unsupported(
                version: version,
                raw: Data(raw),
                reason: .malformedHistoricalRecord("recognized version has no layout")
            )
        }

        if let heartRate, [7, 9, 18].contains(version), !(25...230).contains(Int(heartRate)) {
            return .unsupported(
                version: version,
                raw: Data(raw),
                reason: .malformedHistoricalRecord(
                    "heart rate \(heartRate) is outside pinned physiological range 25...230"
                )
            )
        }

        // WHOOP 4 v24: count at 18, up to four signed little-endian
        // intervals at 19. Keep timing at record-second resolution; the
        // packet does not provide independently measured beat-end times.
        var rrIntervals: [UInt16] = []
        if version == 24 {
            let count = Int(raw[18])
            guard count <= 4 else {
                return .unsupported(version: version, raw: Data(raw), reason: .malformedHistoricalRecord("RR count exceeds the four-interval record block"))
            }
            var rrCursor = ByteCursor(raw)
            try rrCursor.skip(19)
            for _ in 0..<count {
                let interval = try rrCursor.readInt16LE()
                if interval > 0 { rrIntervals.append(UInt16(interval)) }
            }
        }
        let gravity = version == 25 ? nil : try readGravity(from: raw, version: version)
        if let gravity, let gravityReason = gravityValidationReason(gravity, version: version) {
            return .unsupported(
                version: version,
                raw: Data(raw),
                reason: .malformedHistoricalRecord(gravityReason)
            )
        }
        return .decoded(
            DecodedHistoricalRecord(
                version: version,
                raw: Data(raw),
                counter: counter,
                timestampSeconds: timestampSeconds,
                subsecondTicks: subsecondTicks,
                heartRate: heartRate,
                gravity: gravity,
                rrIntervalsMilliseconds: rrIntervals,
                ppgGreen: version == 24 ? readUInt16LE(raw, at: 29) : nil,
                ppgRedIR: version == 24 ? readUInt16LE(raw, at: 31) : nil,
                skinContact: version == 24 ? raw[51] : nil,
                spo2RedRaw: version == 24 ? readUInt16LE(raw, at: 64) : nil,
                spo2IRRaw: version == 24 ? readUInt16LE(raw, at: 66) : nil,
                unidentified68: version == 24 ? readUInt16LE(raw, at: 68) : nil,
                skinTemperatureCelsius: version == 24 ? skinTemperature(raw) : nil,
                ambientRaw: version == 24 ? readUInt16LE(raw, at: 70) : nil
            )
        )
    }

    // Offset 72, u16le, tenths of a degree Celsius, established from recorded band nights.
    // Absolute accuracy remains unverified; the product compares nights to the wearer's baseline.
    private static func skinTemperature(_ raw: Data) -> Double? {
        let value = Double(readUInt16LE(raw, at: 72)) / 10
        return (15...45).contains(value) ? value : nil
    }

    private static let supportedVersions: Set<UInt8> = [7, 9, 12, 18, 24, 25]

    private static func readGravity(from raw: Data, version: UInt8) throws -> GravityVector {
        var cursor = ByteCursor(raw)
        try cursor.skip(36)
        return GravityVector(
            x: try cursor.readFloat32LE(),
            y: try cursor.readFloat32LE(),
            z: try cursor.readFloat32LE()
        )
    }

    private static func readUInt16LE(_ raw: Data, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    /// Applies the source-pinned finite and physiological bounds before any
    /// gravity vector becomes a decoded value.  Invalid raw records remain
    /// available through `.unsupported` and can never leak NaN, infinity, or
    /// an implausible magnitude into downstream storage.
    private static func gravityValidationReason(
        _ gravity: GravityVector,
        version: UInt8
    ) -> String? {
        let values = [gravity.x, gravity.y, gravity.z]
        guard values.allSatisfy(\.isFinite) else {
            return "gravity contains a non-finite component"
        }

        let x = Double(gravity.x)
        let y = Double(gravity.y)
        let z = Double(gravity.z)
        let magnitudeSquared = (x * x) + (y * y) + (z * z)
        guard magnitudeSquared.isFinite else {
            return "gravity magnitude is non-finite"
        }
        // The pinned decoder applies magnitude plausibility only to the
        // legacy 7/9/18 families. Versions 12 and 24 require finite
        // components but do not impose this bound. Version 25 never reaches
        // this function because it has no confirmed motion field.
        guard version != 12, version != 24 else { return nil }

        let magnitude = magnitudeSquared.squareRoot()
        let bounds: ClosedRange<Double> = 0.5...1.8
        guard bounds.contains(magnitude) else {
            return "gravity magnitude \(magnitude) is outside pinned range \(bounds.lowerBound)...\(bounds.upperBound)"
        }
        return nil
    }
}

/// A decoded packet.  For packet families whose field map is not yet modeled,
/// the associated `Data` is the exact bytes following the discriminator.  The
/// historical family is routed through `HistoricalRecord` so unknown versions
/// are explicitly preserved.
public enum DecodedPacket: Equatable, Sendable {
    case commandResponse(Data)
    case compactLiveHeartRate(Data)
    case realtimeRaw(Data)
    case historicalRecord(HistoricalRecord)
    case event(Data)
    case historyMetadata(Data)
    case console(Data)
    case realtimeIMU(Data)
    case unknown(type: UInt8, raw: Data)

    public var packetType: PacketType? {
        switch self {
        case .commandResponse: return .commandResponse
        case .compactLiveHeartRate: return .compactLiveHeartRate
        case .realtimeRaw: return .realtimeRaw
        case .historicalRecord: return .historicalRecord
        case .event: return .event
        case .historyMetadata: return .historyMetadata
        case .console: return .console
        case .realtimeIMU: return .realtimeIMU
        case .unknown: return nil
        }
    }

    /// Exact payload bytes after the packet discriminator.  For an unknown
    /// packet this returns the full raw packet because there is no trusted
    /// payload boundary beyond its first byte.
    public var payload: Data {
        switch self {
        case .commandResponse(let bytes),
             .compactLiveHeartRate(let bytes),
             .realtimeRaw(let bytes),
             .event(let bytes),
             .historyMetadata(let bytes),
             .console(let bytes),
             .realtimeIMU(let bytes):
            return bytes
        case .historicalRecord(let record):
            switch record {
            case .decoded(let decoded): return Data(decoded.raw.dropFirst())
            case .unsupported(_, let raw, _): return Data(raw.dropFirst())
            }
        case .unknown(_, let raw):
            return raw
        }
    }
}

public typealias Packet = DecodedPacket

/// Dispatches the first inner-packet byte after frame-level CRC validation.
public struct PacketDecoder: Sendable {
    public init() {}

    /// Dispatches the already CRC-validated inner bytes of a frame.
    public func decode(_ frame: Frame) throws -> DecodedPacket {
        try decode(frame.paddedInner)
    }

    public func decode(_ inner: Data) throws -> DecodedPacket {
        guard !inner.isEmpty else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 0,
                reason: "truncated packet: expected packet type byte"
            )
        }

        let type = inner[0]
        switch PacketType(rawValue: type) {
        case .commandResponse:
            return .commandResponse(Data(inner.dropFirst()))
        case .compactLiveHeartRate:
            return .compactLiveHeartRate(Data(inner.dropFirst()))
        case .realtimeRaw:
            return .realtimeRaw(Data(inner.dropFirst()))
        case .historicalRecord:
            return .historicalRecord(try HistoricalRecord.decode(inner))
        case .event:
            return .event(Data(inner.dropFirst()))
        case .historyMetadata:
            return .historyMetadata(Data(inner.dropFirst()))
        case .console:
            return .console(Data(inner.dropFirst()))
        case .realtimeIMU:
            return .realtimeIMU(Data(inner.dropFirst()))
        case .none:
            return .unknown(type: type, raw: Data(inner))
        }
    }

    public static func decode(_ inner: Data) throws -> DecodedPacket {
        try Self().decode(inner)
    }
}
