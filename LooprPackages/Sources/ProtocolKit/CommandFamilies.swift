import Foundation

/// A capability that must be confirmed for the connected device before a
/// PRT-05 command family can be written.  These are deliberately separate
/// switches: a successful identity query never implicitly authorizes a haptic,
/// alarm, rename, or gesture operation.
public enum CommandCapability: String, CaseIterable, Equatable, Hashable, Sendable {
    case battery
    case identity
    case rename
    case haptic
    case alarm
    case gesture
    case heartRateSharing
}

/// Typed capability state supplied by a later transport package.
///
/// The empty value is the only default and denies every PRT-05 family.  The
/// mutating confirmation method is intentionally capability-specific; it never
/// accepts an opcode or arbitrary bytes.
public struct CommandCapabilities: Equatable, Sendable {
    private var confirmedStorage: Set<CommandCapability>

    public init() {
        confirmedStorage = []
    }

    /// Explicit construction is useful for a transport package that has
    /// already completed its per-device capability handshake.
    public init(confirmed: Set<CommandCapability>) {
        confirmedStorage = confirmed
    }

    public static let none = CommandCapabilities()

    public static func confirmed(_ capability: CommandCapability) -> Self {
        var result = Self()
        result.confirm(capability)
        return result
    }

    public func isConfirmed(_ capability: CommandCapability) -> Bool {
        confirmedStorage.contains(capability)
    }

    public mutating func confirm(_ capability: CommandCapability) {
        confirmedStorage.insert(capability)
    }

    public func confirming(_ capability: CommandCapability) -> Self {
        var result = self
        result.confirm(capability)
        return result
    }
}

/// Errors raised while a typed family is validated or deliberately kept
/// unavailable.  Decode failures use the shared `ProtocolDecodeError` so all
/// byte offsets remain visible to callers.
public enum CommandFamilyError: Error, Equatable, Sendable, CustomStringConvertible {
    case capabilityNotConfirmed(CommandCapability)
    case unsupportedFamily(CommandCapability)
    case invalidRename(String)
    case invalidHapticPattern(String)

    public var description: String {
        switch self {
        case .capabilityNotConfirmed(let capability):
            return "command capability \(capability.rawValue) is not confirmed for this device"
        case .unsupportedFamily(let capability):
            return "command family \(capability.rawValue) has no pinned outgoing layout"
        case .invalidRename(let reason):
            return "invalid strap name: \(reason)"
        case .invalidHapticPattern(let reason):
            return "invalid haptic pattern: \(reason)"
        }
    }
}

/// Byte offsets inside a command-response (`0x24`) inner packet.
///
/// Captured on a real WHOOP 4.0 on 2026-09-21. The byte after
/// the packet type is **not** an echo of the sequence we sent: it is the band's
/// own rolling packet counter, which advances across every inbound packet type,
/// not just command responses. Our sequence comes back two bytes later.
///
/// ```
/// [0] 0x24                packet type
/// [1] u8  band counter    the band's own rolling counter, not our sequence
/// [2] u8  opcode          the opcode this reply answers
/// [3] u8  sequence echo   the sequence byte we sent with the command
/// [4] u8  status          0x01 in every reply captured so far
/// [5…]    body            opcode-specific
/// ```
///
/// The pinned Dart reference (`protocol/lib/src/control.dart:423-427`) labels
/// byte 1 `seq`, which is wrong on Gen 4 firmware; its battery decoder reads
/// the body at inner offset 5, which agrees with the layout above.
public enum CommandResponseLayout {
    public static let packetType: UInt8 = 0x24
    /// Offset of the band's own rolling packet counter.
    public static let bandCounterOffset = 1
    public static let opcodeOffset = 2
    /// Offset of the echo of the sequence byte we sent.
    public static let sequenceEchoOffset = 3
    public static let statusOffset = 4
    /// Offset of the first opcode-specific body byte.
    public static let bodyOffset = 5
    /// The only status byte seen on hardware so far.
    public static let successStatus: UInt8 = 0x01

    /// Lower bound for "this u32 could be a real wall-clock epoch", matching
    /// the reference's `_minPlausibleUnix` (2023-11).
    public static let minimumPlausibleUnixSeconds: UInt32 = 1_700_000_000
    /// Upper bound, 2100-01-01, matching the reference's `_maxPlausibleUnix`.
    public static let maximumPlausibleUnixSeconds: UInt32 = 4_102_444_800

    public static func isPlausibleUnixSeconds(_ value: UInt32) -> Bool {
        (minimumPlausibleUnixSeconds...maximumPlausibleUnixSeconds).contains(value)
    }
}

/// The Gen 4 battery query.  The command has an empty semantic payload; its
/// zero byte in a four-byte inner packet is transport padding, not a command
/// argument.
public struct BatteryCommand: Equatable, Sendable {
    public static let opcode: UInt8 = 0x1A
    public static let requestPayload = Data()

    public let sequence: UInt8

    public init(sequence: UInt8 = 0) {
        self.sequence = sequence
    }

    public static func request(sequence: UInt8 = 0) -> Self {
        Self(sequence: sequence)
    }

    internal var inner: Data {
        Data([0x23, sequence, Self.opcode])
    }

    /// Decodes a complete command-response inner packet.  The pinned battery
    /// value is an unsigned little-endian integer at absolute offsets 5–6,
    /// which is the first body field under `CommandResponseLayout`; values
    /// outside 0...100 are invalid and are never clamped into a false reading.
    public static func decodeResponse(_ raw: Data) throws -> BatteryResponse {
        guard raw.count >= 7 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: "truncated battery response: expected UInt16 at offsets 5...6"
            )
        }
        guard raw[0] == 0x24 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "expected command-response packet type 0x24"
            )
        }
        guard raw[2] == Self.opcode else {
            throw ProtocolDecodeError.invalidValue(
                offset: 2,
                reason: "expected battery response opcode 0x1a"
            )
        }
        let rawTenths = UInt16(raw[5]) | (UInt16(raw[6]) << 8)
        let percentage = Double(rawTenths) / 10.0
        guard percentage <= 100 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 5,
                reason: "battery percentage \(percentage) is outside 0...100"
            )
        }
        return try BatteryResponse(percentage: percentage)
    }
}

public struct BatteryResponse: Equatable, Sendable {
    public let percentage: Double

    public init(percentage: Double) throws {
        guard percentage.isFinite, percentage >= 0, percentage <= 100 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "battery percentage \(percentage) is outside 0...100"
            )
        }
        self.percentage = percentage
    }

    public var percent: Double { percentage }
    public var value: Double { percentage }
}

/// Identity queries sourced from the Gen 4 Harvard command table.
public struct IdentityCommand: Equatable, Sendable {
    public enum Query: Equatable, Sendable {
        case hello
        case advertisingName
    }

    public let sequence: UInt8
    public let query: Query

    public init(query: Query, sequence: UInt8 = 0) {
        self.query = query
        self.sequence = sequence
    }

    public static func hello(sequence: UInt8 = 0) -> Self {
        Self(query: .hello, sequence: sequence)
    }

    public static func advertisingName(sequence: UInt8 = 0) -> Self {
        Self(query: .advertisingName, sequence: sequence)
    }

    public var opcode: UInt8 {
        switch query {
        case .hello: return 0x23
        case .advertisingName: return 0x4C
        }
    }

    internal var inner: Data {
        Data([0x23, sequence, opcode, 0x00])
    }

    /// Decodes the sourced length-prefixed advertising-name response.  The
    /// hello body intentionally remains opaque because its identity fields
    /// drift across firmware revisions; callers can retain its exact bytes.
    ///
    /// Offsets 7 and 8 are body offsets 2 and 3 under `CommandResponseLayout`,
    /// so this decoder already agreed with the real command-response layout;
    /// the reference marks the same offsets as verified against a capture.
    public static func decodeAdvertisingNameResponse(_ raw: Data) throws -> String {
        try validateResponse(raw, opcode: 0x4C)
        guard raw.count > 7 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: "truncated advertising-name response: missing length byte at offset 7"
            )
        }
        let length = Int(raw[7])
        guard length > 0, length <= 20 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 7,
                reason: "advertising-name length \(length) is outside 1...20"
            )
        }
        let end = try ProtocolLengthArithmetic.checkedAdd(8, length, offset: 8)
        guard end <= raw.count else {
            throw ProtocolDecodeError.outOfBounds(
                offset: 8,
                reason: "truncated advertising-name response: expected \(length) bytes"
            )
        }
        var nameBytes = Data()
        for (index, byte) in raw[8..<end].enumerated() {
            if byte == 0 { break }
            guard (0x20...0x7E).contains(byte) else {
                throw ProtocolDecodeError.invalidValue(
                    offset: 8 + index,
                    reason: "advertising name contains non-printable ASCII"
                )
            }
            nameBytes.append(byte)
        }
        guard !nameBytes.isEmpty else {
            throw ProtocolDecodeError.invalidValue(
                offset: 8,
                reason: "advertising name is empty"
            )
        }
        return String(decoding: nameBytes, as: UTF8.self)
    }

    /// Retains a complete hello response without guessing at firmware-drifting
    /// identity fields.  The caller can later decode it with a version-aware
    /// layer once the device model is known.
    public static func validateHelloResponse(_ raw: Data) throws -> Data {
        try validateResponse(raw, opcode: 0x23)
        return Data(raw)
    }

    private static func validateResponse(_ raw: Data, opcode: UInt8) throws {
        guard raw.count >= 3 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: "truncated identity response: expected packet type, sequence, and opcode"
            )
        }
        guard raw[0] == 0x24 else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "expected command-response packet type 0x24"
            )
        }
        guard raw[2] == opcode else {
            throw ProtocolDecodeError.invalidValue(
                offset: 2,
                reason: "identity response opcode does not match requested query"
            )
        }
    }
}

/// Validated Gen 4 rename command.  The source uses printable ASCII, a
/// maximum of 20 bytes, and four trailing zero bytes after the name.
public struct RenameCommand: Equatable, Sendable {
    public static let opcode: UInt8 = 0x4D
    public static let maximumNameLength = 20

    public let sequence: UInt8
    public let name: String

    public init(sequence: UInt8 = 0, name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty else {
            throw CommandFamilyError.invalidRename("name must not be empty")
        }
        guard bytes.count <= Self.maximumNameLength else {
            throw CommandFamilyError.invalidRename("name must be at most 20 ASCII bytes")
        }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw CommandFamilyError.invalidRename("name must contain printable ASCII only")
        }
        self.sequence = sequence
        self.name = name
    }

    public static func set(sequence: UInt8 = 0, name: String) throws -> Self {
        try Self(sequence: sequence, name: name)
    }

    internal var inner: Data {
        var bytes = Data([0x23, sequence, Self.opcode, 0x01, UInt8(name.utf8.count)])
        bytes.append(contentsOf: name.utf8)
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return bytes
    }
}

/// A Gen 4 haptic waveform effect.  This is the sourced `0x4F` command; the
/// experimental Gen 5/MG `0x13` opcode is intentionally absent.
public struct HapticCommand: Equatable, Sendable {
    public static let opcode: UInt8 = 0x4F
    public static let defaultPattern: UInt8 = 2

    public let sequence: UInt8
    public let pattern: UInt8

    public init(sequence: UInt8 = 0, pattern: UInt8 = Self.defaultPattern) {
        self.sequence = sequence
        self.pattern = pattern
    }

    public static func run(
        sequence: UInt8 = 0,
        pattern: UInt8 = Self.defaultPattern
    ) -> Self {
        Self(sequence: sequence, pattern: pattern)
    }

    public static func buzz(
        sequence: UInt8 = 0,
        pattern: UInt8 = Self.defaultPattern
    ) -> Self {
        run(sequence: sequence, pattern: pattern)
    }

    internal var inner: Data {
        Data([0x23, sequence, Self.opcode, pattern, 0x00, 0x00, 0x00, 0x00])
    }
}

/// The exact 12-byte waveform block carried by the rich Gen 4 alarm form.
/// Byte for byte the reference's `kDefaultAlarmHaptics`: eight waveform effect
/// slots, a u16 little-endian per-effect loop control, an overall loop count,
/// and a maximum duration in seconds.
public struct AlarmHapticPattern: Equatable, Sendable {
    public static let byteCount = 12
    /// This literal is a source-pinned 12-byte waveform.  The private
    /// constructor avoids turning a known-valid compile-time constant into a
    /// trapping `try!` expression while keeping public construction checked.
    public static let `default` = AlarmHapticPattern(knownValidBytes: [
        47, 152, 0, 0, 0, 0, 0, 0,
        0, 0,
        7,
        30
    ])

    private let storage: Data

    private init(knownValidBytes bytes: [UInt8]) {
        storage = Data(bytes)
    }

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw CommandFamilyError.invalidHapticPattern(
                "alarm waveform must contain exactly 12 bytes, received \(bytes.count)"
            )
        }
        storage = Data(bytes)
    }

    public init(bytes: [UInt8]) throws {
        try self.init(bytes: Data(bytes))
    }

    public var bytes: Data { storage }
    internal var rawData: Data { storage }
}

/// Ongoing Gen 4 alarm controls.  GET/readback is request-supported with the
/// sourced revision byte; its response decoder below accepts only the two
/// source-described forms and rejects unknown forms.
public struct AlarmCommand: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        /// The seven-byte time-only form. The band accepts and ACKs it but
        /// never fires it because it ships no waveform to play. Kept for
        /// diagnostics and reference parity only, exactly as the reference
        /// keeps `cmdSetAlarmSimple`.
        case setupSimple(epochSeconds: UInt32, subsecondTicks: UInt16)
        /// The twenty-byte rich form, the only form the reference says fires
        /// on real hardware. This is what `setup` builds.
        case setupRichReference(index: UInt8, epochSeconds: UInt32, subsecondTicks: UInt16, pattern: AlarmHapticPattern)
        case readback
        case test
        case disable
    }

    public let sequence: UInt8
    public let operation: Operation

    private init(sequence: UInt8, operation: Operation) {
        self.sequence = sequence
        self.operation = operation
    }

    /// Arms a firing alarm. The rich twenty-byte form is the only form the
    /// reference says the band actually executes, so the index and waveform
    /// arguments are carried through rather than discarded.
    public static func setup(
        sequence: UInt8 = 0,
        index: UInt8 = 0,
        epochSeconds: UInt32,
        subsecondTicks: UInt16,
        pattern: AlarmHapticPattern = .default
    ) -> Self {
        setupRichReference(
            sequence: sequence,
            index: index,
            epochSeconds: epochSeconds,
            subsecondTicks: subsecondTicks,
            pattern: pattern
        )
    }

    /// Explicit spelling of the rich slot form, used by readback vectors and
    /// protocol diagnostics that name the form directly.
    public static func setupRichReference(
        sequence: UInt8 = 0,
        index: UInt8 = 0,
        epochSeconds: UInt32,
        subsecondTicks: UInt16,
        pattern: AlarmHapticPattern = .default
    ) -> Self {
        Self(
            sequence: sequence,
            operation: .setupRichReference(
                index: index,
                epochSeconds: epochSeconds,
                subsecondTicks: subsecondTicks,
                pattern: pattern
            )
        )
    }

    /// Builds the sourced simple SET_ALARM_TIME form. The band ACKs this form,
    /// but without a waveform it has no haptic/buzz effect and never fires.
    public static func setupSimple(
        sequence: UInt8 = 0,
        epochSeconds: UInt32,
        subsecondTicks: UInt16
    ) -> Self {
        Self(
            sequence: sequence,
            operation: .setupSimple(
                epochSeconds: epochSeconds,
                subsecondTicks: subsecondTicks
            )
        )
    }

    public static func readback(sequence: UInt8 = 0) -> Self {
        Self(sequence: sequence, operation: .readback)
    }

    public static func test(sequence: UInt8 = 0) -> Self {
        Self(sequence: sequence, operation: .test)
    }

    /// RUN_ALARM (`0x44`, body `0x01`): buzz the alarm waveform now.
    ///
    /// The same bytes as `test`, under the name the wake window uses. The
    /// smart alarm sends this when it decides to wake someone before the end
    /// of their window, so reading the call site should not suggest a
    /// diagnostic.
    public static func runNow(sequence: UInt8 = 0) -> Self {
        test(sequence: sequence)
    }

    public static func disable(sequence: UInt8 = 0) -> Self {
        Self(sequence: sequence, operation: .disable)
    }

    internal func makeInner() throws -> Data {
        switch operation {
        case .setupSimple(let epochSeconds, let subsecondTicks):
            var bytes = Data([0x23, sequence, 0x42, 0x01])
            bytes.append(contentsOf: littleEndian(epochSeconds))
            bytes.append(contentsOf: littleEndian(subsecondTicks))
            return bytes
        case .setupRichReference(let index, let epochSeconds, let subsecondTicks, let pattern):
            var bytes = Data([0x23, sequence, 0x42, 0x04, index])
            bytes.append(contentsOf: littleEndian(epochSeconds))
            bytes.append(contentsOf: littleEndian(subsecondTicks))
            bytes.append(pattern.rawData)
            return bytes
        case .readback:
            return Data([0x23, sequence, 0x43, 0x01])
        case .test:
            return Data([0x23, sequence, 0x44, 0x01])
        case .disable:
            return Data([0x23, sequence, 0x45, 0x01])
        }
    }

    /// Parses a complete command-response inner packet for GET_ALARM_TIME.
    ///
    /// The layout below comes from a WHOOP 4.0 capture on 2026-09-21, not from
    /// the reference. The pinned Dart decoder
    /// (`protocol/lib/src/control.dart:437-452`) reads the form byte at
    /// `inner[3]`, which on real firmware is the echo of the sequence we sent,
    /// so it never matched a form and never produced an epoch. The reference
    /// itself parks this readback as unconfirmed on hardware.
    ///
    /// Observed reply to `GET_ALARM_TIME` with sequence `0x66`, for an alarm
    /// armed at epoch 1790031600 with the rich form, index 0, ticks 0:
    ///
    /// ```
    /// 24 e2 43 66 01 | 01 01 00 f0 b6 b1 6a 00 04 00 20
    ///  |  |  |  |  |    |  |  |  '--- u32 LE epoch ---'
    ///  |  |  |  |  |    |  |  '-- slot index
    ///  |  |  |  |  |    |  '-- armed flag
    ///  |  |  |  |  |    '-- 0x01 readback revision, echoing the [0x01] we sent
    ///  |  |  |  |  '-- status
    ///  |  |  |  '-- echo of our sequence
    ///  |  |  '-- opcode
    ///  |  '-- band's rolling counter
    ///  '-- packet type
    /// ```
    ///
    /// The record boundary is fixed by the `SET_ALARM_TIME` (`0x42`) reply for
    /// the same alarm, `24 dd 42 62 01 | 01 00 f0 b6 b1 6a 00`: its body is the
    /// identical `[flag][index][u32 epoch][0x00]` record with no leading
    /// revision byte and no trailing bytes.
    ///
    /// Uncertainty that this decoder deliberately does not paper over:
    /// * Body byte 1 is read as "armed". Every capture had an alarm armed, so
    ///   a cleared band has never been observed here; `isArmed` may be a
    ///   constant on some firmware. Callers must not treat `false` as proof
    ///   the band holds no alarm, only as "the band did not say it is armed".
    /// * The byte after the epoch (`0x00`) and the trailing `04 00 20` are not
    ///   identified. There is no subsecond field the capture can justify, so
    ///   none is decoded; `SET_ALARM_TIME` was sent with ticks 0 and nothing in
    ///   the reply reads back as 0.
    /// * Only the `0x01` readback revision is accepted. Any other leading byte
    ///   fails closed rather than guessing an epoch offset.
    public static func decodeReadbackResponse(_ raw: Data) throws -> AlarmReadback {
        guard raw.count >= CommandResponseLayout.bodyOffset else {
            throw ProtocolDecodeError.outOfBounds(
                offset: raw.count,
                reason: "truncated alarm readback response"
            )
        }
        guard raw[0] == CommandResponseLayout.packetType else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "expected command-response packet type 0x24"
            )
        }
        guard raw[CommandResponseLayout.opcodeOffset] == 0x43 else {
            throw ProtocolDecodeError.invalidValue(
                offset: CommandResponseLayout.opcodeOffset,
                reason: "expected alarm readback opcode 0x43"
            )
        }

        let bodyOffset = CommandResponseLayout.bodyOffset
        let body = Data(raw.dropFirst(bodyOffset))
        // revision + armed + index + u32 epoch + the trailing byte the SET
        // reply also carries.
        guard body.count >= 8 else {
            throw ProtocolDecodeError.outOfBounds(
                offset: bodyOffset,
                reason: "truncated alarm readback body: expected at least 8 bytes"
            )
        }
        guard body[0] == 0x01 else {
            throw ProtocolDecodeError.invalidValue(
                offset: bodyOffset,
                reason: "unsupported alarm readback revision 0x\(String(body[0], radix: 16))"
            )
        }
        let epochSeconds = readUInt32LE(body, offset: 3)
        guard CommandResponseLayout.isPlausibleUnixSeconds(epochSeconds) else {
            throw ProtocolDecodeError.invalidValue(
                offset: bodyOffset + 3,
                reason: "alarm readback epoch \(epochSeconds) is not a plausible Unix time"
            )
        }
        return AlarmReadback(
            isArmed: body[1] != 0,
            index: body[2],
            epochSeconds: epochSeconds,
            body: body
        )
    }
}

/// One decoded GET_ALARM_TIME reply.
///
/// `body` keeps the undecoded bytes so a later firmware-aware layer can make
/// sense of the trailing fields without another hardware session.
public struct AlarmReadback: Equatable, Sendable {
    /// Whether the band reported the alarm as armed. See the uncertainty note
    /// on `AlarmCommand.decodeReadbackResponse`.
    public let isArmed: Bool
    public let index: UInt8
    public let epochSeconds: UInt32
    public let body: Data

    public init(isArmed: Bool, index: UInt8, epochSeconds: UInt32, body: Data = Data()) {
        self.isArmed = isArmed
        self.index = index
        self.epochSeconds = epochSeconds
        self.body = Data(body)
    }
}

/// Outgoing gesture configuration is intentionally modeled but unavailable:
/// the pinned Gen 4 source contains only an incoming double-tap event (14),
/// not a command layout for configuring it.
public struct GestureCommand: Equatable, Sendable {
    public enum Action: UInt8, CaseIterable, Equatable, Sendable {
        case none = 0
        case markMoment = 1
        case toggleWorkout = 2
    }

    public let sequence: UInt8
    public let action: Action

    private init(sequence: UInt8, action: Action) {
        self.sequence = sequence
        self.action = action
    }

    public static func configureDoubleTap(
        sequence: UInt8 = 0,
        action: Action
    ) -> Self {
        Self(sequence: sequence, action: action)
    }
}

/// The only pinned Gen 4 gesture signal modeled in ProtocolKit.  The wire
/// field is a u16 little-endian event id, so the constant is typed to match
/// the field it is compared against.
public enum GestureEvent: Equatable, Sendable {
    case doubleTap

    public static let doubleTapEventID: UInt16 = 14

    public static func decode(eventID: UInt16) -> Self? {
        eventID == Self.doubleTapEventID ? .doubleTap : nil
    }
}

/// The asynchronous band event ids Loopr acts on.  Every value is taken from
/// the reference `EventId` table; ids Loopr does not act on are deliberately
/// absent rather than guessed.
public enum BandEventID {
    // Documented in NOOP docs/PROTOCOL_IMPLEMENTATION.md, EventId table.
    public static let batteryLevel: UInt16 = 3
    public static let chargingOn: UInt16 = 7
    public static let chargingOff: UInt16 = 8
    public static let wristOn: UInt16 = 9
    public static let wristOff: UInt16 = 10
    public static let extendedBatteryInformation: UInt16 = 63
    public static let doubleTap: UInt16 = 14
    public static let setRTC: UInt16 = 16
    public static let alarmLatched: UInt16 = 56
    public static let strapAlarmExecuted: UInt16 = 57
    public static let appAlarmExecuted: UInt16 = 58
    public static let alarmDisabled: UInt16 = 59
    public static let hapticsFired: UInt16 = 60
}

/// A decoded asynchronous band event packet (`0x30` on the events
/// characteristic).
///
/// Layout, from the reference `parseEvent`:
/// `[0x30][u8 seq][u16 LE event id][u32 LE epoch seconds][u16 LE subseconds][body from 12]`.
///
/// The id is a u16 little-endian at inner offset 2, not a u8.  Every field
/// past the id is optional on the wire: a short frame degrades to a decoded id
/// with no timestamp instead of reading past the packet.  The event body is
/// never retained here; only typed battery and wear state are exposed.
public struct BandEventPacket: Equatable, Sendable {
    public static let packetType: UInt8 = 0x30
    public static let minimumLength = 4

    public let sequence: UInt8
    public let eventID: UInt16
    public let bandEpochSeconds: UInt32?
    public let subsecondTicks: UInt16?
    public let batteryPercentage: Double?
    public let batteryMillivolts: UInt16?
    public let charging: Bool?
    public let onWrist: Bool?

    public init(
        sequence: UInt8,
        eventID: UInt16,
        bandEpochSeconds: UInt32?,
        subsecondTicks: UInt16?,
        batteryPercentage: Double? = nil,
        batteryMillivolts: UInt16? = nil,
        charging: Bool? = nil,
        onWrist: Bool? = nil
    ) {
        self.sequence = sequence
        self.eventID = eventID
        self.bandEpochSeconds = bandEpochSeconds
        self.subsecondTicks = subsecondTicks
        self.batteryPercentage = batteryPercentage
        self.batteryMillivolts = batteryMillivolts
        self.charging = charging
        self.onWrist = onWrist
    }

    /// Decodes a complete event inner packet, including its `0x30`
    /// discriminator.  The bytes are copied into an array first so a sliced
    /// `Data` cannot make an offset read land at the wrong absolute index.
    public static func decode(_ raw: Data, model: BandModel = .whoop4) throws -> Self {
        let bytes = Array(raw)
        guard bytes.count >= minimumLength else {
            throw ProtocolDecodeError.outOfBounds(
                offset: bytes.count,
                reason: "truncated band event: expected type, sequence, and a UInt16 event id"
            )
        }
        guard bytes[0] == packetType else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "expected band event packet type 0x30"
            )
        }
        let eventID = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        // The reference reads the epoch only when the packet is long enough
        // to hold the whole u32, and the subseconds only at ten bytes.
        let epoch: UInt32?
        if bytes.count >= 8 {
            epoch = UInt32(bytes[4])
                | (UInt32(bytes[5]) << 8)
                | (UInt32(bytes[6]) << 16)
                | (UInt32(bytes[7]) << 24)
        } else {
            epoch = nil
        }
        let ticks: UInt16? = bytes.count >= 10
            ? UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
            : nil
        // NOOP docs/PROTOCOL_TRANSPORT.md, WHOOP 4 battery sources:
        // Event 3 offsets 17/21/26 are absolute frame offsets. The Gen 4
        // envelope is four bytes, so inner offsets are 13/17/22.
        // NOOP docs/BLE_REVERSE_ENGINEERING.md, WHOOP 5.0 EVENT:
        // captures on 50.38.1.0 establish full-frame offsets 21/25/30,
        // also inner 13/17/22. Respect its declared body length at inner 10.
        // Event 63 remains unknown for both families.
        // The documented +4 frame shift also puts the Gen 4 body length at
        // inner 10. Require the charging field inside that body, not padding.
        let bodyLength = bytes.count >= 12 ? Int(UInt16(bytes[10]) | UInt16(bytes[11]) << 8) : 0
        // The capture establishes WHOOP 5.0, not an MG-specific event body.
        // MG still reports charging and wrist state through transition ids.
        let knownFamily = model == .whoop4 || model == .whoop5
        let denseBattery = eventID == BandEventID.batteryLevel && knownFamily &&
            bodyLength >= 11 && bytes.count >= 12 + bodyLength
        let percent: Double? = denseBattery && bytes.count >= 15
            ? Double(UInt16(bytes[13]) | UInt16(bytes[14]) << 8) / 10 : nil
        let millivolts: UInt16? = denseBattery && bytes.count >= 19
            ? UInt16(bytes[17]) | UInt16(bytes[18]) << 8 : nil
        let charging: Bool? = eventID == BandEventID.chargingOn ? true
            : eventID == BandEventID.chargingOff ? false
            : denseBattery && bytes.count >= 23 ? bytes[22] & 1 == 1 : nil
        let onWrist: Bool? = eventID == BandEventID.wristOn ? true
            : eventID == BandEventID.wristOff ? false : nil
        return Self(
            sequence: bytes[1],
            eventID: eventID,
            bandEpochSeconds: epoch,
            subsecondTicks: ticks,
            batteryPercentage: percent.flatMap { (0...100).contains($0) ? $0 : nil },
            batteryMillivolts: millivolts,
            charging: charging,
            onWrist: onWrist
        )
    }
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24)
    ]
}

private func littleEndian(_ value: UInt16) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8)
    ]
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}


/// Standard heart-rate advertising controls, documented in NOOP
/// docs/PROTOCOL_COMMANDS.md and docs/PROTOCOL_CONFIGURATION.md.
/// The Gen 5 key is deliberately closed; callers cannot write arbitrary config.
public struct HeartRateSharingCommand: Equatable, Sendable {
    public static let key = "whoop_live_hr_in_adv_ind_pkt"
    public let sequence: UInt8
    public let enabled: Bool

    public init(sequence: UInt8, enabled: Bool) {
        self.sequence = sequence
        self.enabled = enabled
    }

    public var gen4Inner: Data { Data([0x23, sequence, 14, enabled ? 1 : 0]) }

    public static var keyField: Data {
        let bytes = Data(key.utf8)
        return bytes + Data(repeating: 0, count: 32 - bytes.count)
    }

    public var gen5WriteBody: Data {
        Data([119, 1]) + Self.keyField + Data([enabled ? 0x31 : 0x30]) + Data(repeating: 0, count: 31)
    }

    public static var gen5ReadBody: Data { Data([121, 1]) + keyField }

    /// Validates the complete semantic response before reading the value.
    /// Origin sequence and connection generation are checked by the runtime.
    public static func decodeGen5Readback(_ raw: Data, sequence: UInt8) throws -> Bool {
        let bytes = Array(raw)
        guard bytes.count >= 70 else {
            throw ProtocolDecodeError.outOfBounds(offset: bytes.count, reason: "truncated heart rate sharing response")
        }
        guard bytes[0] == 0x24, bytes[2] == 121, bytes[3] == sequence,
              bytes[4] == 1, bytes[5] == 1,
              Data(bytes[6..<38]) == keyField else {
            throw ProtocolDecodeError.invalidValue(offset: 2, reason: "invalid heart rate sharing response")
        }
        let value = Array(bytes[38..<70])
        guard let end = value.firstIndex(of: 0), end == 1,
              value.dropFirst(end).allSatisfy({ $0 == 0 }),
              [UInt8(0x30), 0x31, 0x32].contains(value[0]) else {
            throw ProtocolDecodeError.invalidValue(offset: 38, reason: "invalid heart rate sharing value")
        }
        return value[0] == 0x31
    }
}
