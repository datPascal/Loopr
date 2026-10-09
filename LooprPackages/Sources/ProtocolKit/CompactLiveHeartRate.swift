import Foundation

/// Identifies whether a compact live packet includes the packet discriminator.
///
/// `PacketDecoder` deliberately strips the discriminator from associated
/// payloads. Requiring callers to state the form prevents the timestamp/HR
/// offsets from silently moving by one byte at the Bluetooth boundary.
public enum CompactLiveHeartRatePayloadForm: String, Equatable, Sendable {
    case fullInner
    case strippedPayload
}

/// The fields that the pinned OpenStrap compact `0x28` parser can prove.
///
/// This is a live, in-memory value. It is not a historical record and must not
/// be passed to a storage writer as if it were durable history.
public struct CompactLiveHeartRateSample: Equatable, Sendable {
    public let revision: UInt8
    public let timestampSeconds: UInt32
    public let subsecondTicks: UInt16?
    public let heartRateBPM: UInt8
    public let rrMilliseconds: [UInt16]
    public let wearing: Bool
    public let locationRaw: UInt8?
    /// The normalized full inner packet, including `0x28` at byte zero.
    public let rawPayload: Data

    public init(
        revision: UInt8 = 1,
        timestampSeconds: UInt32,
        subsecondTicks: UInt16? = nil,
        heartRateBPM: UInt8,
        rrMilliseconds: [UInt16],
        wearing: Bool,
        locationRaw: UInt8? = nil,
        rawPayload: Data
    ) {
        self.revision = revision
        self.timestampSeconds = timestampSeconds
        self.subsecondTicks = subsecondTicks
        self.heartRateBPM = heartRateBPM
        self.rrMilliseconds = rrMilliseconds
        self.wearing = wearing
        self.locationRaw = locationRaw
        self.rawPayload = Data(rawPayload)
    }

    public var heartRate: Int { Int(heartRateBPM) }
    public var rrMillisecondsAsDouble: [Double] { rrMilliseconds.map(Double.init) }
}

/// Decoder for the compact realtime-HR packet aligned with OpenStrap protocol
/// main at `c78c176295e3dcbc183bf3309bf94cb251c2c3d1`.
///
/// The layout is `[0x28][rec][ts u32 LE @2][...][HR @8][RR count @9]`, with
/// up to four little-endian RR slots at offsets 10, 12, 14 and 16 and an
/// optional wearing byte at offset 18. Invalid input returns `nil`; no
/// plausible-looking defaults are synthesized.
public enum CompactLiveHeartRateDecoder {
    public static let upstreamCommit = "c78c176295e3dcbc183bf3309bf94cb251c2c3d1"
    public static let upstreamSource = "OpenStrap protocol/lib/src/control.dart:126-287"

    public static let minimumRRMilliseconds: UInt16 = 200
    public static let maximumRRMilliseconds: UInt16 = 2_500
    public static let maximumRRSlots = 4

    public static func decode(
        _ bytes: Data,
        form: CompactLiveHeartRatePayloadForm = .fullInner
    ) -> CompactLiveHeartRateSample? {
        let inner: Data
        switch form {
        case .fullInner:
            inner = Data(bytes)
        case .strippedPayload:
            var reconstructed = Data([PacketType.compactLiveHeartRate.rawValue])
            reconstructed.append(bytes)
            inner = reconstructed
        }

        // A valid compact frame must reach the HR byte at offset 8. Keep all
        // byte reads behind the bounds-checked accessor below: both full and
        // stripped callers can hand us arbitrary/truncated Data, and a
        // malformed live packet must return nil rather than trap.
        guard inner.count >= 9,
              byte(at: 0, in: inner) == PacketType.compactLiveHeartRate.rawValue else {
            return nil
        }

        // Revision 2 retains the timestamp and HR offsets but adds subsecond,
        // off-body, and body-location fields. It carries no confirmed RR list.
        if byte(at: 1, in: inner) == 2 {
            guard inner.count >= 20,
                  let timestamp = uint32LE(at: 2, in: inner),
                  let subsecond = uint16LE(at: 6, in: inner),
                  let heartRate = byte(at: 8, in: inner),
                  let offBody = byte(at: 18, in: inner),
                  let location = byte(at: 19, in: inner),
                  timestamp > 0,
                  (1...250).contains(Int(heartRate)),
                  offBody != 0 else {
                return nil
            }
            return CompactLiveHeartRateSample(
                revision: 2,
                timestampSeconds: timestamp,
                subsecondTicks: subsecond,
                heartRateBPM: heartRate,
                rrMilliseconds: [],
                wearing: true,
                locationRaw: location,
                rawPayload: inner
            )
        }

        guard let timestamp0 = byte(at: 2, in: inner),
              let timestamp1 = byte(at: 3, in: inner),
              let timestamp2 = byte(at: 4, in: inner),
              let timestamp3 = byte(at: 5, in: inner),
              let heartRate = byte(at: 8, in: inner) else {
            return nil
        }
        let timestamp = UInt32(timestamp0)
            | (UInt32(timestamp1) << 8)
            | (UInt32(timestamp2) << 16)
            | (UInt32(timestamp3) << 24)
        guard timestamp > 0 else { return nil }

        guard (1...250).contains(Int(heartRate)) else { return nil }

        // A nine-byte packet is the explicitly supported HR-only shape. A
        // tenth byte declares an RR count; from that point every declared
        // slot must be present before any slot is read.
        let declaredCount: Int
        if inner.count > 9 {
            guard let countByte = byte(at: 9, in: inner) else { return nil }
            declaredCount = Int(countByte)
        } else {
            declaredCount = 0
        }
        guard declaredCount <= maximumRRSlots else { return nil }
        var intervals: [UInt16] = []
        if declaredCount > 0 {
            // A declared slot whose bytes are absent makes the packet
            // malformed. Do not return a partial RR series that could look
            // valid to HRV/breathing consumers.
            let requiredLength = 10 + (declaredCount * 2)
            guard inner.count >= requiredLength else { return nil }

            for index in 0..<declaredCount {
                let offset = 10 + (index * 2)
                guard let low = byte(at: offset, in: inner),
                      let high = byte(at: offset + 1, in: inner) else {
                    return nil
                }
                let value = UInt16(low) | (UInt16(high) << 8)
                guard value >= minimumRRMilliseconds,
                      value <= maximumRRMilliseconds else {
                    continue
                }
                intervals.append(value)
            }
        }

        // OpenStrap treats an omitted wearing byte as worn. Once the byte is
        // present, only an explicit value of one is trusted as worn. An
        // off-wrist packet is not surfaced as a usable cardiac sample.
        let wearing = byte(at: 18, in: inner).map { $0 == 1 } ?? true
        guard wearing else { return nil }

        return CompactLiveHeartRateSample(
            revision: 1,
            timestampSeconds: timestamp,
            heartRateBPM: heartRate,
            rrMilliseconds: intervals,
            wearing: true,
            rawPayload: inner
        )
    }

    private static func byte(at index: Int, in data: Data) -> UInt8? {
        guard index >= 0, index < data.count else { return nil }
        return data[index]
    }

    private static func uint16LE(at offset: Int, in data: Data) -> UInt16? {
        guard let low = byte(at: offset, in: data),
              let high = byte(at: offset + 1, in: data) else { return nil }
        return UInt16(low) | (UInt16(high) << 8)
    }

    private static func uint32LE(at offset: Int, in data: Data) -> UInt32? {
        guard let low = uint16LE(at: offset, in: data),
              let high = uint16LE(at: offset + 2, in: data) else { return nil }
        return UInt32(low) | (UInt32(high) << 16)
    }
}
