import AnalyticsKit
import Foundation

public struct WorkoutHeartSample: Equatable, Sendable {
    public let date: Date
    public let bpm: Double
    public init(date: Date, bpm: Double) { self.date = date; self.bpm = bpm }
}

/// Where a session's heart rate came from. The page names it.
public enum WorkoutHeartSource: String, Equatable, Sendable {
    /// Streamed from the band while the session ran.
    case live
    /// Read back from the band's history after a sync, for a session with no phone nearby.
    case bandHistory
}

public struct WorkoutHeartSeries: Equatable, Sendable {
    public let samples: [WorkoutHeartSample]
    public let source: WorkoutHeartSource

    /// Keeps readings a heart can make, in time order.
    public init(samples: [WorkoutHeartSample], source: WorkoutHeartSource) {
        self.samples = samples
            .filter { $0.bpm.isFinite && (25...250).contains($0.bpm) }
            .sorted { $0.date < $1.date }
        self.source = source
    }
}

/// One hard effort in a session, from the timer's work phases or found in the heart rate.
public struct WorkoutEffort: Equatable, Sendable, Identifiable {
    public let number: Int
    public let start: Date
    public let end: Date
    public let peakBPM: Int
    /// How far heart rate fell in the 60 seconds after the peak. Nil when the readings stop first.
    public let dropBPM: Int?
    public var id: Int { number }
    public var seconds: TimeInterval { end.timeIntervalSince(start) }
}

public struct WorkoutDrift: Equatable, Sendable {
    public let firstHalfBPM: Double
    public let secondHalfBPM: Double
    public var percent: Double { (secondHalfBPM - firstHalfBPM) / firstHalfBPM * 100 }
}

/// Everything the page says about a session's heart rate. Pure, so it is tested without a screen.
public struct WorkoutSessionAnalysis: Equatable, Sendable {
    /// A reading stands for at most this long, so a gap never counts as time at the last value.
    public static let longestReadingSeconds: TimeInterval = 10
    /// A longer silence is a gap on the chart.
    public static let gapSeconds: TimeInterval = 30
    /// Drift needs this much heart rate after the warm-up is skipped.
    public static let driftMinimumSeconds: TimeInterval = 30 * 60
    public static let driftWarmUpSeconds: TimeInterval = 10 * 60
    /// The printed rule for efforts found in heart rate.
    public static let effortRiseBPM = 20.0
    public static let effortFallBPM = 15.0
    public static let effortRule = "An effort is a rise of 20 bpm or more followed by a fall of 15 bpm or more."

    public let samples: [WorkoutHeartSample]
    public let source: WorkoutHeartSource?
    public let averageBPM: Int?
    public let peakBPM: Int?
    /// Seconds with a heart rate reading, pauses left out.
    public let coveredSeconds: TimeInterval
    /// Seconds the session ran, pauses left out.
    public let activeSeconds: TimeInterval?
    /// Seconds per zone number. Empty when zones are unknown.
    public let secondsInZones: [Int: TimeInterval]
    public let drift: WorkoutDrift?
    public let efforts: [WorkoutEffort]
    /// True when `efforts` came from the heart rate and not from a timer.
    public let effortsAreFound: Bool
    /// Session strain on the 0 to 21 scale. An estimate; nil without resting and maximum heart rate.
    public let strain: Double?

    public var hasHeartRate: Bool { !samples.isEmpty }
    public var coverageIsPartial: Bool {
        guard let activeSeconds, hasHeartRate else { return false }
        return coveredSeconds < activeSeconds - 60
    }

    public init(workout: WorkoutRecord, history: WorkoutHeartSeries? = nil, zones: HeartRateZoneSet? = nil) {
        let series = Self.series(for: workout, history: history)
        let kept = (series?.samples ?? []).filter { Self.isCounted($0.date, in: workout) }
        samples = kept
        source = kept.isEmpty ? nil : series?.source
        activeSeconds = workout.duration

        var covered = 0.0, weighted = 0.0, peak = 0.0
        var zoneSeconds: [Int: TimeInterval] = [:]
        for (index, sample) in kept.enumerated() {
            let next = index + 1 < kept.count ? kept[index + 1].date : sample.date.addingTimeInterval(1)
            let seconds = min(Self.longestReadingSeconds, max(0, next.timeIntervalSince(sample.date)))
            covered += seconds
            weighted += sample.bpm * seconds
            peak = max(peak, sample.bpm)
            if let zones {
                let number = zones.zoneNumber(for: sample.bpm)
                if number > 0 { zoneSeconds[number, default: 0] += seconds }
            }
        }
        coveredSeconds = covered
        averageBPM = covered > 0 ? Int((weighted / covered).rounded()) : nil
        peakBPM = peak > 0 ? Int(peak.rounded()) : nil
        secondsInZones = zoneSeconds

        let windows = workout.effortWindows ?? []
        if !windows.isEmpty {
            efforts = Self.efforts(windows: windows, samples: kept)
            effortsAreFound = false
        } else if workout.activity.showsEfforts {
            efforts = Self.foundEfforts(samples: kept)
            effortsAreFound = true
        } else {
            efforts = []
            effortsAreFound = false
        }
        drift = workout.activity.showsDrift && windows.isEmpty ? Self.drift(samples: kept) : nil
        strain = Self.strain(samples: kept, zones: zones)
    }

    /// The session's own samples while it has any, band history when it has none.
    private static func series(for workout: WorkoutRecord, history: WorkoutHeartSeries?) -> WorkoutHeartSeries? {
        let live = workout.samples.compactMap { sample -> WorkoutHeartSample? in
            sample.heartRate.flatMap { $0 > 0 ? WorkoutHeartSample(date: sample.timestamp, bpm: Double($0)) : nil }
        }
        let own = WorkoutHeartSeries(samples: live, source: .live)
        // Two readings cannot draw a session; a checkpoint or a fixture can leave that few behind.
        if own.samples.count >= 2 || history == nil { return own.samples.isEmpty ? nil : own }
        return history
    }

    private static func isCounted(_ date: Date, in workout: WorkoutRecord) -> Bool {
        if let start = workout.startedAt, date < start { return false }
        if let end = workout.endedAt, date > end { return false }
        return !(workout.pauses ?? []).contains { pause in
            date >= pause.start && date < (pause.end ?? workout.endedAt ?? date.addingTimeInterval(1))
        }
    }

    /// Second half against first half, the first ten minutes skipped.
    static func drift(samples: [WorkoutHeartSample]) -> WorkoutDrift? {
        guard let first = samples.first else { return nil }
        let settled = samples.filter { $0.date.timeIntervalSince(first.date) >= driftWarmUpSeconds }
        guard let start = settled.first, let end = settled.last,
              end.date.timeIntervalSince(start.date) >= driftMinimumSeconds else { return nil }
        let middle = start.date.addingTimeInterval(end.date.timeIntervalSince(start.date) / 2)
        let early = settled.filter { $0.date < middle }.map(\.bpm)
        let late = settled.filter { $0.date >= middle }.map(\.bpm)
        guard !early.isEmpty, !late.isEmpty else { return nil }
        return WorkoutDrift(firstHalfBPM: early.reduce(0, +) / Double(early.count),
                            secondHalfBPM: late.reduce(0, +) / Double(late.count))
    }

    static func efforts(windows: [WorkoutEffortWindow], samples: [WorkoutHeartSample]) -> [WorkoutEffort] {
        windows.compactMap { window in
            // Heart rate lags the work, so a peak can land just after the phase ends.
            let peakEnd = window.end.addingTimeInterval(15)
            guard let peak = samples.filter({ $0.date >= window.start && $0.date <= peakEnd }).max(by: { $0.bpm < $1.bpm }) else {
                return nil
            }
            return WorkoutEffort(number: window.round, start: window.start, end: window.end, peakBPM: Int(peak.bpm.rounded()),
                                 dropBPM: drop(after: peak, samples: samples))
        }
    }

    /// Walks 10-second averages. A rise of 20 bpm from the last low arms an effort; a fall of 15 from its peak closes it.
    static func foundEfforts(samples: [WorkoutHeartSample]) -> [WorkoutEffort] {
        let buckets = averages(samples: samples, seconds: 10)
        guard let first = buckets.first else { return [] }
        var results: [WorkoutEffort] = []
        var low = first, peak: WorkoutHeartSample?, riseStart = first
        func close(_ top: WorkoutHeartSample) {
            results.append(WorkoutEffort(number: results.count + 1, start: riseStart.date, end: top.date,
                                         peakBPM: Int(top.bpm.rounded()), dropBPM: drop(after: top, samples: samples)))
        }
        for bucket in buckets.dropFirst() {
            if let top = peak {
                if bucket.bpm > top.bpm {
                    peak = bucket
                } else if top.bpm - bucket.bpm >= effortFallBPM {
                    close(top)
                    peak = nil
                    low = bucket
                }
            } else if bucket.bpm < low.bpm {
                low = bucket
            } else if bucket.bpm - low.bpm >= effortRiseBPM {
                riseStart = low
                peak = bucket
            }
        }
        // A session that ends on a hard effort still counts it, with no drop to report.
        if let top = peak { close(top) }
        return results
    }

    private static func drop(after peak: WorkoutHeartSample, samples: [WorkoutHeartSample]) -> Int? {
        let target = peak.date.addingTimeInterval(60)
        guard let later = samples.first(where: { $0.date >= target }),
              later.date.timeIntervalSince(target) <= longestReadingSeconds else { return nil }
        return Int((peak.bpm - later.bpm).rounded())
    }

    /// Averages per bucket, in time order. Empty buckets are skipped, so a gap stays a gap.
    public static func averages(samples: [WorkoutHeartSample], seconds: TimeInterval) -> [WorkoutHeartSample] {
        guard let first = samples.first, seconds > 0 else { return [] }
        var results: [WorkoutHeartSample] = []
        var bucketIndex = 0, total = 0.0, count = 0.0
        func flush() {
            guard count > 0 else { return }
            results.append(WorkoutHeartSample(date: first.date.addingTimeInterval(Double(bucketIndex) * seconds + seconds / 2),
                                              bpm: total / count))
        }
        for sample in samples {
            let index = Int(sample.date.timeIntervalSince(first.date) / seconds)
            if index != bucketIndex {
                flush()
                bucketIndex = index; total = 0; count = 0
            }
            total += sample.bpm; count += 1
        }
        flush()
        return results
    }

    private static func strain(samples: [WorkoutHeartSample], zones: HeartRateZoneSet?) -> Double? {
        guard let zones, !samples.isEmpty else { return nil }
        let metric = ActivityAnalytics.strain(hr: samples.map(\.bpm), timestamps: samples.map { $0.date.timeIntervalSince1970 },
                                              restingHR: zones.restingHR, maxHR: zones.maxHR, source: zones.source)
        return metric.value.map { ActivityAnalytics.strainScore($0.trimp) }
    }
}
