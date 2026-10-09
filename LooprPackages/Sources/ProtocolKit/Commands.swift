import Foundation

/// Errors produced by the production command writer.  No error case accepts
/// caller-supplied raw bytes; command construction is closed over typed cases.
public enum CommandFirewallError: Error, Equatable, Sendable, CustomStringConvertible {
    case dangerousOpcodeRejected(UInt8)

    public var opcode: UInt8 {
        switch self {
        case .dangerousOpcodeRejected(let opcode): return opcode
        }
    }

    public var description: String {
        "production command rejected dangerous opcode 0x\(String(opcode, radix: 16, uppercase: false))"
    }
}

/// The seven opcode values that the production writer must never emit.
public enum CommandFirewall {
    public static let dangerousOpcodes: Set<UInt8> = [
        0x19, // force trim
        0x1D, // reboot
        0x20, // power cycle
        0x9A, // persistent raw/R21
        0x24, // firmware family
        0x25,
        0x26,
        // Gen 5 firmware load/commit/rollback family. Hardware reports show
        // these can leave a band unable to boot, so they share the same final
        // transport fence even though Loopr exposes no typed builder for them.
        0x8E,
        0x8F,
        0x90
    ]

    public static func isDangerous(opcode: UInt8) -> Bool {
        dangerousOpcodes.contains(opcode)
    }

    /// Validates a complete wire frame at the transport adapter boundary.
    ///
    /// The frame decoder is deliberately used here instead of trusting a
    /// caller-provided inner packet.  This closes the last public escape hatch:
    /// even a caller that bypasses `ProductionCommandWriter` cannot hand an
    /// unvalidated framed trim/reboot/firmware opcode to a BLE adapter.
    /// (Pinned protocol source: `lib/src/framing.dart`, frame envelope and
    /// `lib/src/constants.dart`, dangerous command set.)
    public static func validateEncodedFrame(_ raw: Data) throws {
        let frame = try FrameDecoder().decode(raw)
        try validateFrameInner(frame.paddedInner)
    }

    /// Validates a closed, typed production command before it reaches the
    /// frame encoder.  Dangerous typed cases are represented solely so the
    /// firewall can prove runtime rejection; there is no raw opcode/bytes
    /// writer API.
    public static func validate(_ command: ProductionCommand) throws {
        switch command {
        case .forceTrim:
            try rejectIfDangerous(0x19)
        case .reboot:
            try rejectIfDangerous(0x1D)
        case .powerCycle:
            try rejectIfDangerous(0x20)
        case .persistentRaw:
            try rejectIfDangerous(0x9A)
        case .firmwareCommand24:
            try rejectIfDangerous(0x24)
        case .firmwareCommand25:
            try rejectIfDangerous(0x25)
        case .firmwareCommand26:
            try rejectIfDangerous(0x26)
        default:
            return
        }
    }

    /// Shared final validation for every padded command inner before framing.
    /// Only the command envelope marker is inspected; ordinary packet
    /// families remain fully encodable through the internal `FrameEncoder`.
    internal static func validateFrameInner(_ paddedInner: Data) throws {
        guard paddedInner.count >= 3, paddedInner[0] == 0x23 else { return }
        try rejectIfDangerous(paddedInner[2])
    }

    private static func rejectIfDangerous(_ opcode: UInt8) throws {
        guard dangerousOpcodes.contains(opcode) else { return }
        throw CommandFirewallError.dangerousOpcodeRejected(opcode)
    }
}

/// Commands that the production writer is allowed to understand.  The
/// dangerous cases are explicit typed sentinels and are always rejected by
/// `ProductionCommandWriter`; they are not arbitrary opcode injection.
public enum ProductionCommand: Equatable, Sendable {
    case hello(sequence: UInt8)
    case advertisingName(sequence: UInt8)
    case dataRange(sequence: UInt8)
    case alarmTime(sequence: UInt8)
    case startHistoricalData(sequence: UInt8)
    /// ABORT_HISTORICAL_TRANSMITS.  The band stops an in-flight historical
    /// burst so a stalled offload can be restarted instead of wedging the
    /// link until it drops.  (Pinned protocol source: `lib/src/commands.dart`,
    /// `cmdAbortHistorical`; Edge `_abortAndRetryHistorical`.)
    case abortHistoricalData(sequence: UInt8)
    case setClock(sequence: UInt8, unixSeconds: UInt32, subsecondTicks: UInt16)
    case getClock(sequence: UInt8)
    case historyAcknowledgement(sequence: UInt8, token: HistoryToken)

    // Edge live-control commands.  These are intentionally typed rather than
    // exposed as opcode/raw-payload pairs, so the final writer can keep the
    // exact live-control layouts while retaining the dangerous-opcode fence.
    // (Pinned Edge source: `edge/lib/ble/ble_engine.dart`,
    // `enableLiveStreams`, `enableHeartRateOnly`, and `disableLiveStreams`.)
    case linkValid(sequence: UInt8)
    case toggleRealtimeHR(sequence: UInt8, enabled: Bool)
    case sendR10R11Realtime(sequence: UInt8, enabled: Bool)
    case toggleIMUMode(sequence: UInt8, enabled: Bool)
    case enableOpticalData(sequence: UInt8, enabled: Bool)
    case toggleOpticalMode(sequence: UInt8, enabled: Bool)
    case getBatteryLevel(sequence: UInt8)

    // PRT-05 typed command families.  These cases deliberately carry only
    // closed value types; there is no public opcode-plus-raw-bytes escape hatch.
    case heartRateSharing(HeartRateSharingCommand)
    case battery(BatteryCommand)
    case identity(IdentityCommand)
    case rename(RenameCommand)
    case haptic(HapticCommand)
    case alarm(AlarmCommand)
    case gesture(GestureCommand)

    #if DEBUG
    /// Byte-level experiment hatch, DEBUG builds only.
    ///
    /// `body` is the inner packet after `[0x23][sequence]`, so
    /// `[0x42, 0x04, ...]` is a SET_ALARM. It exists because a WHOOP 4 ACKs a
    /// byte-perfect SET_ALARM, reads it back correctly, and then does not
    /// buzz, and the only way to find the byte that matters is to send
    /// variants at real hardware from the debug alarm request file.
    ///
    /// This is not an escape from the firewall. `encode` runs
    /// `CommandFirewall.validateFrameInner` over the assembled inner packet,
    /// and `BLECommandTransportAdapter` validates the framed result again, so
    /// trim, reboot, power cycle, and the firmware family are still rejected.
    case debugRaw(sequence: UInt8, body: Data)
    #endif

    case forceTrim
    case reboot
    case powerCycle
    case persistentRaw
    case firmwareCommand24
    case firmwareCommand25
    case firmwareCommand26
}

/// A distinct eight-byte opaque history token.  The stored representation is
/// private and only the exact input bytes are retained; no integer conversion,
/// byte reversal, normalization, or public mutable-byte accessor exists.
public struct HistoryToken: Equatable, Hashable, Sendable {
    public static let byteCount = 8

    private let storage: Data

    /// Creates a token from exactly eight bytes, preserving source order.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw ProtocolDecodeError.invalidValue(
                offset: 0,
                reason: "history token must contain exactly \(Self.byteCount) bytes, received \(bytes.count)"
            )
        }
        storage = Data(bytes)
    }

    /// Array convenience for decoded byte slices and test vectors.
    public init(bytes: [UInt8]) throws {
        try self.init(bytes: Data(bytes))
    }

    /// Unlabeled convenience spelling; still validates exact length.
    public init(_ bytes: Data) throws {
        try self.init(bytes: bytes)
    }

    /// Unlabeled array convenience; still validates exact length.
    public init(_ bytes: [UInt8]) throws {
        try self.init(bytes: bytes)
    }

    internal var rawData: Data { storage }

    /// Returns an immutable-value copy suitable for durable persistence.
    /// Mutating the returned `Data` cannot mutate this token.
    public var persistedBytes: Data { Data(storage) }

    /// The Edge history cursor uses the final four token bytes as the durable
    /// batch identity (little-endian).  Keep the token itself opaque while
    /// exposing this deterministic, token-derived identity for correlation.
    /// (Pinned protocol source: `lib/src/control.dart`, `batchId` extraction.)
    public var batchIdentifier: UInt32 {
        UInt32(storage[4])
            | (UInt32(storage[5]) << 8)
            | (UInt32(storage[6]) << 16)
            | (UInt32(storage[7]) << 24)
    }

    /// The band reuses a batch number with a new token, for example when it
    /// sends a batch again after a dropped link. The number alone is not a
    /// durable key, so the identity covers all eight token bytes. Edge uses
    /// the number for logging only.
    public var derivedBatchID: String {
        let prefix = storage.prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(format: "history-%08x-", batchIdentifier) + prefix
    }
}

/// Builds the exact Gen 4 commands required by the ProtocolKit phase.
public enum CommandBuilder {
    /// Builds the pinned sequence-0 Hello initialization frame.
    public static func hello() throws -> Data {
        try build(.hello(sequence: 0))
    }

    public static func hello(sequence: UInt8) throws -> Data {
        try build(.hello(sequence: sequence))
    }

    /// Builds the pinned sequence-1 advertising-name initialization frame.
    public static func advertisingName() throws -> Data {
        try build(.advertisingName(sequence: 1))
    }

    public static func advertisingName(sequence: UInt8) throws -> Data {
        try build(.advertisingName(sequence: sequence))
    }

    /// Builds the pinned sequence-2 data-range initialization frame.
    public static func dataRange() throws -> Data {
        try build(.dataRange(sequence: 2))
    }

    public static func dataRange(sequence: UInt8) throws -> Data {
        try build(.dataRange(sequence: sequence))
    }

    /// Builds the pinned sequence-3 alarm-time initialization frame.
    public static func alarmTime() throws -> Data {
        try build(.alarmTime(sequence: 3))
    }

    public static func alarmTime(sequence: UInt8) throws -> Data {
        try build(.alarmTime(sequence: sequence))
    }

    /// Builds the pinned sequence-4 historical-data initialization frame.
    public static func startHistoricalData() throws -> Data {
        try build(.startHistoricalData(sequence: 4))
    }

    public static func startHistoricalData(sequence: UInt8) throws -> Data {
        try build(.startHistoricalData(sequence: sequence))
    }

    /// Builds ABORT_HISTORICAL_TRANSMITS.  The opcode is not in the dangerous
    /// set; it only cancels a transfer the band is already running.
    public static func abortHistoricalData(sequence: UInt8) throws -> Data {
        try build(.abortHistoricalData(sequence: sequence))
    }

    /// Builds SET_CLOCK.  The subsecond field is already expressed in the
    /// pinned 32,768-Hz tick unit and is written verbatim as UInt16 LE.
    public static func setClock(
        sequence: UInt8,
        unixSeconds: UInt32,
        subsecondTicks: UInt16
    ) throws -> Data {
        try build(.setClock(
            sequence: sequence,
            unixSeconds: unixSeconds,
            subsecondTicks: subsecondTicks
        ))
    }

    /// Builds GET_CLOCK.  The command has no payload beyond its command
    /// envelope and the pinned four-byte padding boundary.
    public static func getClock(sequence: UInt8) throws -> Data {
        try build(.getClock(sequence: sequence))
    }

    public static func linkValid(sequence: UInt8) throws -> Data {
        try build(.linkValid(sequence: sequence))
    }

    public static func toggleRealtimeHR(sequence: UInt8, enabled: Bool) throws -> Data {
        try build(.toggleRealtimeHR(sequence: sequence, enabled: enabled))
    }

    public static func sendR10R11Realtime(sequence: UInt8, enabled: Bool) throws -> Data {
        try build(.sendR10R11Realtime(sequence: sequence, enabled: enabled))
    }

    public static func toggleIMUMode(sequence: UInt8, enabled: Bool) throws -> Data {
        try build(.toggleIMUMode(sequence: sequence, enabled: enabled))
    }

    public static func enableOpticalData(sequence: UInt8, enabled: Bool) throws -> Data {
        try build(.enableOpticalData(sequence: sequence, enabled: enabled))
    }

    public static func toggleOpticalMode(sequence: UInt8, enabled: Bool) throws -> Data {
        try build(.toggleOpticalMode(sequence: sequence, enabled: enabled))
    }

    public static func getBatteryLevel(sequence: UInt8) throws -> Data {
        try build(.getBatteryLevel(sequence: sequence))
    }

    public static func buildLinkValid(sequence: UInt8) throws -> Data {
        try linkValid(sequence: sequence)
    }

    public static func buildToggleRealtimeHR(sequence: UInt8, enabled: Bool) throws -> Data {
        try toggleRealtimeHR(sequence: sequence, enabled: enabled)
    }

    public static func buildSendR10R11Realtime(sequence: UInt8, enabled: Bool) throws -> Data {
        try sendR10R11Realtime(sequence: sequence, enabled: enabled)
    }

    public static func buildToggleIMUMode(sequence: UInt8, enabled: Bool) throws -> Data {
        try toggleIMUMode(sequence: sequence, enabled: enabled)
    }

    public static func buildEnableOpticalData(sequence: UInt8, enabled: Bool) throws -> Data {
        try enableOpticalData(sequence: sequence, enabled: enabled)
    }

    public static func buildToggleOpticalMode(sequence: UInt8, enabled: Bool) throws -> Data {
        try toggleOpticalMode(sequence: sequence, enabled: enabled)
    }

    public static func buildGetBatteryLevel(sequence: UInt8) throws -> Data {
        try getBatteryLevel(sequence: sequence)
    }

    /// Builds a successful history ACK.  The caller must invoke this only
    /// after the corresponding batch has been durably committed in SQLite;
    /// this pure builder does not and cannot establish that commit barrier.
    public static func historyAcknowledgement(
        sequence: UInt8,
        token: HistoryToken
    ) throws -> Data {
        try build(.historyAcknowledgement(sequence: sequence, token: token))
    }

    // Source-compatible acronym spelling.
    public static func historyACK(sequence: UInt8, token: HistoryToken) throws -> Data {
        try historyAcknowledgement(sequence: sequence, token: token)
    }

    public static func historyAck(sequence: UInt8, token: HistoryToken) throws -> Data {
        try historyAcknowledgement(sequence: sequence, token: token)
    }

    public static func buildHello() throws -> Data { try hello() }
    public static func buildAdvertisingName() throws -> Data { try advertisingName() }
    public static func buildDataRange() throws -> Data { try dataRange() }
    public static func buildAlarmTime() throws -> Data { try alarmTime() }
    public static func buildStartHistoricalData() throws -> Data { try startHistoricalData() }
    public static func buildSetClock(
        sequence: UInt8,
        unixSeconds: UInt32,
        subsecondTicks: UInt16
    ) throws -> Data {
        try setClock(sequence: sequence, unixSeconds: unixSeconds, subsecondTicks: subsecondTicks)
    }
    public static func buildGetClock(sequence: UInt8) throws -> Data {
        try getClock(sequence: sequence)
    }
    public static func buildHistoryAcknowledgement(
        sequence: UInt8,
        token: HistoryToken
    ) throws -> Data {
        try historyAcknowledgement(sequence: sequence, token: token)
    }
    public static func buildHistoryACK(sequence: UInt8, token: HistoryToken) throws -> Data {
        try historyAcknowledgement(sequence: sequence, token: token)
    }

    private static func build(_ command: ProductionCommand) throws -> Data {
        try ProductionCommandWriter().encode(command)
    }
}

/// The sole production command-to-frame entry point.
public struct ProductionCommandWriter: Sendable {
    private let capabilities: CommandCapabilities

    /// Creates the single production writer.  Every PRT-05 capability is
    /// denied by default; a later transport package must explicitly confirm
    /// the capability for the connected device before a family can be encoded.
    public init(capabilities: CommandCapabilities = .none) {
        self.capabilities = capabilities
    }

    public func encode(_ command: ProductionCommand) throws -> Data {
        // Capability checks intentionally happen before the shared firewall
        // and frame encoder.  A family is never writable merely because its
        // bytes are known; the device-specific capability must be confirmed.
        switch command {
        case .heartRateSharing:
            try requireCapability(.heartRateSharing)
        case .battery:
            try requireCapability(.battery)
        case .identity:
            try requireCapability(.identity)
        case .rename:
            try requireCapability(.rename)
        case .haptic:
            try requireCapability(.haptic)
        case .alarm:
            try requireCapability(.alarm)
        case .gesture:
            try requireCapability(.gesture)
        default:
            break
        }

        try CommandFirewall.validate(command)
        let inner: Data
        switch command {
        case .hello(let sequence):
            inner = Data([0x23, sequence, 0x23, 0x00])
        case .advertisingName(let sequence):
            inner = Data([0x23, sequence, 0x4C, 0x00])
        case .dataRange(let sequence):
            inner = Data([0x23, sequence, 0x22, 0x00])
        case .alarmTime(let sequence):
            // The pinned one-time initialization frame uses 0x01 in the
            // fourth byte (distinct from the ongoing alarm family in PRT-05).
            inner = Data([0x23, sequence, 0x43, 0x01])
        case .startHistoricalData(let sequence):
            inner = Data([0x23, sequence, 0x16, 0x00])
        case .abortHistoricalData(let sequence):
            inner = Data([0x23, sequence, 0x14, 0x00])
        case .setClock(let sequence, let unixSeconds, let subsecondTicks):
            inner = Data([
                0x23,
                sequence,
                0x0A,
                UInt8(truncatingIfNeeded: unixSeconds),
                UInt8(truncatingIfNeeded: unixSeconds >> 8),
                UInt8(truncatingIfNeeded: unixSeconds >> 16),
                UInt8(truncatingIfNeeded: unixSeconds >> 24),
                UInt8(truncatingIfNeeded: subsecondTicks),
                UInt8(truncatingIfNeeded: subsecondTicks >> 8),
                0x00,
                0x00,
                // The command payload ends with the two pinned zero bytes;
                // this final zero is transport padding to a 4-byte boundary.
                0x00
            ])
        case .getClock(let sequence):
            inner = Data([0x23, sequence, 0x0B, 0x00])
        case .historyAcknowledgement(let sequence, let token):
            var bytes = Data([0x23, sequence, 0x17, 0x01])
            bytes.append(token.rawData)
            inner = bytes
        case .linkValid(let sequence):
            inner = Data([0x23, sequence, 0x01, 0x00])
        case .toggleRealtimeHR(let sequence, let enabled):
            inner = Data([0x23, sequence, 0x03, enabled ? 0x01 : 0x00])
        case .sendR10R11Realtime(let sequence, let enabled):
            inner = Data([0x23, sequence, 0x3F, enabled ? 0x01 : 0x00])
        case .toggleIMUMode(let sequence, let enabled):
            inner = Data([0x23, sequence, 0x6A, enabled ? 0x01 : 0x00])
        case .enableOpticalData(let sequence, let enabled):
            // Edge sends [revision1,1] for optical streaming and
            // [revision1,0] when the stream is disabled.
            inner = Data([0x23, sequence, 0x6B, 0x01, enabled ? 0x01 : 0x00])
        case .toggleOpticalMode(let sequence, let enabled):
            inner = Data([0x23, sequence, 0x6C, 0x01, enabled ? 0x01 : 0x00])
        case .getBatteryLevel(let sequence):
            inner = Data([0x23, sequence, 0x1A, 0x00])
        case .heartRateSharing(let command):
            inner = command.gen4Inner
        case .battery(let command):
            inner = command.inner
        case .identity(let command):
            inner = command.inner
        case .rename(let command):
            inner = command.inner
        case .haptic(let command):
            inner = command.inner
        case .alarm(let command):
            inner = try command.makeInner()
        #if DEBUG
        case .debugRaw(let sequence, let body):
            var bytes = Data([0x23, sequence])
            bytes.append(body)
            try CommandFirewall.validateFrameInner(bytes)
            inner = bytes
        #endif
        case .gesture:
            // Gesture configuration has no pinned Gen 4 outgoing layout.  It
            // remains fail-closed even if a future transport confirms the
            // capability; only the incoming event model is supported here.
            throw CommandFamilyError.unsupportedFamily(.gesture)
        case .forceTrim, .reboot, .powerCycle, .persistentRaw,
             .firmwareCommand24, .firmwareCommand25, .firmwareCommand26:
            // CommandFirewall.validate above rejects every one of these.
            throw CommandFirewallError.dangerousOpcodeRejected(opcode(for: command))
        }
        return try FrameEncoder().encode(paddedInner(inner))
    }

    private func requireCapability(_ capability: CommandCapability) throws {
        guard capabilities.isConfirmed(capability) else {
            throw CommandFamilyError.capabilityNotConfirmed(capability)
        }
    }

    private func paddedInner(_ inner: Data) -> Data {
        var result = Data(inner)
        let remainder = result.count % 4
        if remainder != 0 {
            result.append(contentsOf: repeatElement(UInt8(0), count: 4 - remainder))
        }
        return result
    }

    private func opcode(for command: ProductionCommand) -> UInt8 {
        switch command {
        case .forceTrim: return 0x19
        case .reboot: return 0x1D
        case .powerCycle: return 0x20
        case .persistentRaw: return 0x9A
        case .firmwareCommand24: return 0x24
        case .firmwareCommand25: return 0x25
        case .firmwareCommand26: return 0x26
        default: return 0
        }
    }
}

/// Functional spelling for callers that prefer a standalone writer function.
public func encodeProductionCommand(_ command: ProductionCommand) throws -> Data {
    try ProductionCommandWriter().encode(command)
}
