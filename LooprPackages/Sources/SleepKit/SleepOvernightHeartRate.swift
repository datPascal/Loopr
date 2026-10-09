import Foundation
import DesignSystem

/// One minute of heart rate during the night: the mean of that minute's
/// per-second readings.
public struct SleepHeartRateMinute: Codable, Equatable, Hashable, Sendable {
    public let date: Date
    public let bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// The overnight heart-rate line drawn above the stage lanes.
///
/// Shown only when the band recorded heart rate for a real share of the
/// night: at least 30 minutes and at least a quarter of the main sleep.
/// Anything less would be a few dots pretending to be a night.
public struct SleepOvernightHeartRate: Equatable, Sendable {
    public static let minimumMinutes = 30
    public static let minimumCoverage = 0.25
    /// Stretches without a reading longer than this break the line.
    public static let maximumGap: TimeInterval = 5 * 60
    /// Minutes in the rolling median that smooths the drawn line.
    public static let smoothingMinutes = 3

    /// Per-minute samples inside the night, oldest first, smoothed.
    public let samples: [SleepHeartRateMinute]
    public let start: Date
    public let end: Date

    /// Builds the line, or nil when the night has too little heart rate.
    public static func make(samples raw: [SleepHeartRateMinute], start: Date, end: Date) -> SleepOvernightHeartRate? {
        guard end > start else { return nil }
        let inside = raw
            .filter { $0.date >= start && $0.date <= end && $0.bpm.isFinite && $0.bpm >= 25 && $0.bpm <= 230 }
            .sorted { $0.date < $1.date }
        let nightMinutes = end.timeIntervalSince(start) / 60
        guard inside.count >= minimumMinutes, Double(inside.count) >= nightMinutes * minimumCoverage else { return nil }
        return SleepOvernightHeartRate(samples: smooth(inside), start: start, end: end)
    }

    init(samples: [SleepHeartRateMinute], start: Date, end: Date) {
        self.samples = samples
        self.start = start
        self.end = end
    }

    /// A centred rolling median over `smoothingMinutes`, reset at every gap so
    /// a reading never borrows from the other side of one.
    static func smooth(_ samples: [SleepHeartRateMinute]) -> [SleepHeartRateMinute] {
        let half = smoothingMinutes / 2
        guard half > 0 else { return samples }
        return samples.indices.map { index in
            var window: [Double] = [samples[index].bpm]
            var cursor = index
            for _ in 0..<half {
                guard cursor > 0, samples[cursor].date.timeIntervalSince(samples[cursor - 1].date) <= maximumGap else { break }
                cursor -= 1
                window.append(samples[cursor].bpm)
            }
            cursor = index
            for _ in 0..<half {
                guard cursor + 1 < samples.count, samples[cursor + 1].date.timeIntervalSince(samples[cursor].date) <= maximumGap else { break }
                cursor += 1
                window.append(samples[cursor].bpm)
            }
            return SleepHeartRateMinute(date: samples[index].date, bpm: SleepUsualRange.percentile(window, 50) ?? samples[index].bpm)
        }
    }

    public var lowest: SleepHeartRateMinute? { samples.min { $0.bpm < $1.bpm } }
    public var highest: SleepHeartRateMinute? { samples.max { $0.bpm < $1.bpm } }
    public var average: Double? {
        guard !samples.isEmpty else { return nil }
        return samples.map(\.bpm).reduce(0, +) / Double(samples.count)
    }

    /// The line for the stage timeline.
    public var line: LooprStageTimelineLine {
        LooprStageTimelineLine(title: "Heart rate", unit: "bpm",
                               points: samples.map { LooprChartPoint(date: $0.date, value: $0.bpm) },
                               accent: .heart, maximumGap: Self.maximumGap)
    }

    /// "Heart rate 52 to 71 bpm, lowest at 03:12."
    public func summary(timeZone: TimeZone = .current) -> String? {
        guard let lowest, let highest else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return "Lowest \(Int(lowest.bpm.rounded())) bpm at \(lowest.date.formatted(style)), highest \(Int(highest.bpm.rounded())) bpm"
    }
}
