import BluetoothKit
import Foundation
import ProtocolKit

/// One asynchronous event the band pushed on its events characteristic.
///
/// The envelope carries typed state, the decoded identifier and the connection generation
/// that observed it, so a consumer can drop an event that belongs to a link
/// that has since been replaced.  Raw event bytes are deliberately absent:
/// only typed battery and wear observations cross this boundary.
public struct BandEventEnvelope: Sendable, Equatable {
    /// NOOP docs/PROTOCOL_IMPLEMENTATION.md: 3 battery, 7/8 charging,
    /// 9/10 wrist state, 14 double tap, 56 alarm latched,
    /// 57/58 alarm fired, 59 alarm disabled, 60 haptics fired.
    public let batteryPercentage: Double?
    public let charging: Bool?
    public let onWrist: Bool?
    public let eventID: UInt16
    public let generation: UInt64
    public let receivedAt: Date
    /// The band's own clock at the moment of the event, when the packet was
    /// long enough to carry it.  The band RTC can be unset, so this is not a
    /// wall-clock timestamp and callers must guard on plausibility.
    public let bandEpochSeconds: UInt32?

    public init(
        eventID: UInt16,
        generation: UInt64,
        receivedAt: Date,
        bandEpochSeconds: UInt32?,
        batteryPercentage: Double? = nil,
        charging: Bool? = nil,
        onWrist: Bool? = nil
    ) {
        self.batteryPercentage = batteryPercentage
        self.charging = charging
        self.onWrist = onWrist
        self.eventID = eventID
        self.generation = generation
        self.receivedAt = receivedAt
        self.bandEpochSeconds = bandEpochSeconds
    }
}

/// Failures a band action can report to a caller.  Every case is terminal for
/// the one call that produced it; none of them describe partial work.
public enum BandCommandError: Error, Sendable, Equatable {
    /// The runtime is not running, setup has not completed for the current
    /// generation, the link is down, or the radio is not powered on.
    case notReady
    case timedOut
    case rejected(String)
    case invalidName
}

/// The band's alarm time split, plus the wall-to-band clock shift.
///
/// The band fires its wake alarm autonomously on its own RTC, so the epoch on
/// the wire has to be expressed in the band's clock frame.  This is the
/// reference's `AlarmPayloads.toStrapFrame`: with `driftSeconds = wall - band`
/// the band reads `W - drift` at wall time `W`, so the target moves back by
/// the drift.  The shift is whole seconds, so the subsecond remainder of the
/// requested time survives it.
public struct BandAlarmFrame: Equatable, Sendable {
    public static let ticksPerSecond: Int64 = 32_768

    public let epochSeconds: UInt32
    public let subsecondTicks: UInt16
    public let driftSeconds: Int64

    /// Builds the on-wire time fields for `fireDate`, shifted into the band's
    /// clock frame.  A drift of zero arms the raw wall epoch, which is what
    /// the reference does when it has no clock correlation yet.
    public init(fireDate: Date, driftSeconds: Int64) throws {
        let shifted = fireDate.addingTimeInterval(-TimeInterval(driftSeconds))
        let milliseconds = Int64((shifted.timeIntervalSince1970 * 1_000).rounded(.down))
        let seconds = milliseconds.dividedReportingOverflow(by: 1_000)
        guard !seconds.overflow,
              seconds.partialValue >= 0,
              seconds.partialValue <= Int64(UInt32.max) else {
            throw ClockSequenceError.unrepresentableDate
        }
        let remainder = milliseconds - (seconds.partialValue * 1_000)
        let ticks = (remainder * Self.ticksPerSecond) / 1_000
        guard ticks >= 0, ticks <= Int64(UInt16.max) else {
            throw ClockSequenceError.unrepresentableDate
        }
        epochSeconds = UInt32(seconds.partialValue)
        subsecondTicks = UInt16(ticks)
        self.driftSeconds = driftSeconds
    }

    /// The wall-clock instant this frame arms, without the band shift. Useful
    /// for comparing a readback against what the caller asked for.
    public var armedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds)
            + (TimeInterval(subsecondTicks) / TimeInterval(Self.ticksPerSecond)))
    }

    /// Inverts the band shift on a `GET_ALARM_TIME` answer.
    ///
    /// The epoch the band reports is in the band's own clock, the same frame
    /// the arm was written in. At wall time `W` the band RTC reads
    /// `W - drift`, so the wall instant it will fire at is `epoch + drift`.
    /// Without this a readback taken on a band whose RTC never latched reads
    /// back as a time decades away and every comparison fails.
    public static func wallDate(fromBandEpochSeconds epoch: UInt32, driftSeconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epoch) + TimeInterval(driftSeconds))
    }
}
