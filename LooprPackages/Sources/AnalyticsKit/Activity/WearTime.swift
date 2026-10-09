import Foundation

/// One stored second reduced to what wear-time needs: when it was recorded,
/// the heart rate the band reported, and whether skin contact was ruled out.
public struct WearSample: Sendable, Equatable {
    public let timestamp: TimeInterval
    public let bpm: Double?
    /// False only when the band said it had no skin contact. A record that
    /// carries no contact flag is not treated as off-wrist.
    public let skinContact: Bool

    public init(timestamp: TimeInterval, bpm: Double?, skinContact: Bool = true) {
        self.timestamp = timestamp
        self.bpm = bpm
        self.skinContact = skinContact
    }
}

public enum WearTime {
    /// Strain and Stress stay blank until this many on-wrist minutes of the
    /// civil day have been recorded. A band put on at midday after days off
    /// otherwise scores a few minutes of data as if it were the whole day.
    public static let minimumWearMinutesForDayMetrics = 60

    /// Distinct clock minutes holding at least one on-wrist heart-rate sample.
    /// A zero or missing heart rate, a physiologically impossible one, or an
    /// explicit no-skin-contact flag marks the sample as off-wrist. Minutes
    /// with no sample at all (a gap in the stream) are not counted.
    public static func wornMinutes(_ samples: [WearSample]) -> Int {
        var minutes = Set<Int64>()
        for sample in samples {
            guard sample.skinContact, sample.timestamp.isFinite,
                  let bpm = sample.bpm, bpm.isFinite, (25...230).contains(bpm) else { continue }
            minutes.insert(Int64((sample.timestamp / 60).rounded(.down)))
        }
        return minutes.count
    }

    /// True once the day holds enough on-wrist minutes for Strain and Stress.
    public static func hasEnoughWear(_ wornMinutes: Int) -> Bool {
        wornMinutes >= minimumWearMinutesForDayMetrics
    }
}
