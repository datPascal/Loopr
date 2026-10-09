import DesignSystem
import Foundation
import DomainKit

// The selected day's heart rate as the Heart tab draws it: per-second
// readings folded into 5-minute buckets (lowest, average, highest), with the
// night's sleep and the day's workouts laid over it. Everything here is pure
// so the bucketing rules can be tested without a database or a view.

/// One second of band data. `time` is seconds since 1970, as
/// `decoded_second` stores it. Gravity and beat intervals are optional; when
/// present they let the timeline tell a still wrist with a racing number
/// apart from real effort.
public struct HeartRateSample: Equatable, Sendable {
    public let time: TimeInterval
    public let bpm: Double
    /// The accelerometer's gravity vector in g, if the band sent one.
    public let gravity: SIMD3<Double>?
    /// Beat-to-beat intervals recorded in this second, in milliseconds.
    public let rrMilliseconds: [Double]

    public init(time: TimeInterval, bpm: Double, gravity: SIMD3<Double>? = nil, rrMilliseconds: [Double] = []) {
        self.time = time
        self.bpm = bpm
        self.gravity = gravity
        self.rrMilliseconds = rrMilliseconds
    }
}

/// Five minutes of readings.
public struct HeartTimelineBucket: Equatable, Sendable, Identifiable {
    public let start: Date
    public let end: Date
    public let minimum: Double
    public let average: Double
    public let maximum: Double
    public let sampleCount: Int
    /// Readings in minutes the beat-to-beat check could not confirm.
    public let unconfirmedCount: Int

    public var id: Date { start }
    public var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    /// Most of the bucket sits in unconfirmed minutes.
    public var isUnconfirmed: Bool { unconfirmedCount * 2 > sampleCount }

    public init(start: Date, end: Date, minimum: Double, average: Double, maximum: Double, sampleCount: Int,
                unconfirmedCount: Int = 0) {
        self.start = start
        self.end = end
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.sampleCount = sampleCount
        self.unconfirmedCount = unconfirmedCount
    }
}

/// A stretch of the day drawn behind the heart rate: sleep or a workout.
public struct HeartTimelineSpan: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case sleep
        case workout
    }

    public let kind: Kind
    public let start: Date
    public let end: Date
    /// "Run", "Cycling" for workouts; nil for sleep.
    public let title: String?

    public var id: String { "\(kind.rawValue)-\(start.timeIntervalSince1970)" }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    public init(kind: Kind, start: Date, end: Date, title: String? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.title = title
    }
}

/// The day's lowest, average and highest heart rate, from confirmed minutes.
public struct HeartTimelineSummary: Equatable, Sendable {
    /// The lowest 1-minute median. A minute keeps one-second spikes and
    /// dropouts out of the extremes without hiding a real low or peak.
    public let lowest: Double
    /// The mean of every valid, confirmed reading.
    public let average: Double
    /// The highest 1-minute median.
    public let highest: Double
    /// Minutes with at least one reading.
    public let measuredMinutes: Int

    public init(lowest: Double, average: Double, highest: Double, measuredMinutes: Int) {
        self.lowest = lowest
        self.average = average
        self.highest = highest
        self.measuredMinutes = measuredMinutes
    }
}

public struct HeartDayTimeline: Equatable, Sendable {
    public let dayStart: Date
    public let dayEnd: Date
    public let bucketSeconds: Int
    public let buckets: [HeartTimelineBucket]
    /// Sleep clipped to the day, oldest first.
    public let sleep: [HeartTimelineSpan]
    /// Workouts clipped to the day, oldest first.
    public let workouts: [HeartTimelineSpan]
    public let summary: HeartTimelineSummary?

    public init(dayStart: Date, dayEnd: Date, bucketSeconds: Int, buckets: [HeartTimelineBucket],
                sleep: [HeartTimelineSpan] = [], workouts: [HeartTimelineSpan] = [], summary: HeartTimelineSummary?) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.bucketSeconds = bucketSeconds
        self.buckets = buckets
        self.sleep = sleep
        self.workouts = workouts
        self.summary = summary
    }

    public var isEmpty: Bool { buckets.isEmpty }

    /// Whether any bucket is mostly unconfirmed readings.
    public var hasUnconfirmed: Bool { buckets.contains(where: \.isUnconfirmed) }

    /// Runs of neighbouring buckets with the same confirmation. A missing
    /// bucket starts a new run, so the chart never draws a line across time
    /// the band did not record.
    public var segments: [[HeartTimelineBucket]] {
        var result: [[HeartTimelineBucket]] = []
        for bucket in buckets {
            if let last = result.last?.last, bucket.start.timeIntervalSince(last.end) < 1,
               last.isUnconfirmed == bucket.isUnconfirmed {
                result[result.count - 1].append(bucket)
            } else {
                result.append([bucket])
            }
        }
        return result
    }

    /// The bucket under `date`, or nil over a gap.
    public func bucket(at date: Date) -> HeartTimelineBucket? {
        guard !buckets.isEmpty else { return nil }
        var low = 0
        var high = buckets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let bucket = buckets[mid]
            if date < bucket.start { high = mid - 1 }
            else if date >= bucket.end { low = mid + 1 }
            else { return bucket }
        }
        return nil
    }

    /// The workout or sleep under `date`. A workout wins over sleep.
    public func span(at date: Date) -> HeartTimelineSpan? {
        workouts.first { $0.start <= date && date < $0.end }
            ?? sleep.first { $0.start <= date && date < $0.end }
    }

    /// The y range the chart draws: the buckets' extremes, padded, and at
    /// least `minimumSpan` bpm tall so a calm day does not look dramatic.
    public func yDomain(minimumSpan: Double = 40) -> ClosedRange<Double> {
        guard let low = buckets.map(\.minimum).min(), let high = buckets.map(\.maximum).max() else {
            return 40...100
        }
        var lower = (low - 4).rounded(.down)
        var upper = (high + 4).rounded(.up)
        if upper - lower < minimumSpan {
            let middle = (upper + lower) / 2
            lower = middle - minimumSpan / 2
            upper = middle + minimumSpan / 2
        }
        lower = max(0, (lower / 10).rounded(.down) * 10)
        upper = (upper / 10).rounded(.up) * 10
        return lower...upper
    }

    /// The peak 5-minute average inside a span, for the workout marker.
    public func peak(in span: HeartTimelineSpan) -> HeartTimelineBucket? {
        buckets.filter { $0.end > span.start && $0.start < span.end }.max { $0.average < $1.average }
    }
}

/// A workout to mark on the timeline, from any source.
public struct HeartTimelineWorkout: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let title: String

    public init(start: Date, end: Date, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

public enum HeartTimelineBuilder {
    public static let bucketSeconds = 300
    /// Readings outside this range are sensor noise, not a heart rate.
    public static let plausibleRange: ClosedRange<Double> = 25...240
    /// A 5-minute bucket needs at least this many readings (one minute's
    /// worth at 1 Hz) to be drawn. Fewer and it is a gap.
    public static let minimumSamplesPerBucket = 60
    /// A minute needs this many readings to count towards the lowest and
    /// highest values.
    public static let minimumSamplesPerMinute = 20

    // The beat-to-beat check. The band sometimes reports a racing number
    // while the wrist is still and its own beat timing says otherwise (the
    // monitors lane found 160 to 200 bpm against about 75 from the beats on
    // real data). A minute is unconfirmed when all of these hold, outside a
    // workout: the band's median is at least `checkFromBPM`, the wrist was
    // still (mean second-to-second gravity change at most `stillMotion` g,
    // the at-rest limit the heart-rate alerts use), and the beats either
    // disagree by more than `agreementBPM` or are too few to say.
    public static let checkFromBPM = 110.0
    public static let stillMotion = 0.06
    public static let agreementBPM = 25.0
    public static let minimumBeatsPerMinute = 20

    /// Folds per-second readings into buckets for the day `[dayStart, dayEnd)`.
    ///
    /// Readings outside the day or the plausible range are dropped. Sleep and
    /// workouts are clipped to the day; overlapping workouts are merged.
    public static func build(
        samples: [HeartRateSample],
        dayStart: Date,
        dayEnd: Date,
        bucketSeconds: Int = HeartTimelineBuilder.bucketSeconds,
        sleep: [DateInterval] = [],
        workouts: [HeartTimelineWorkout] = []
    ) -> HeartDayTimeline {
        let width = max(60, bucketSeconds)
        let start = dayStart.timeIntervalSince1970
        let end = dayEnd.timeIntervalSince1970
        let slots = max(0, Int(((end - start) / Double(width)).rounded(.up)))

        let day = DateInterval(start: dayStart, end: max(dayStart, dayEnd))
        let sleepSpans = clip(sleep.map { HeartTimelineSpan(kind: .sleep, start: $0.start, end: $0.end) }, to: day)
        let workoutSpans = mergeWorkouts(clip(workouts.map {
            HeartTimelineSpan(kind: .workout, start: $0.start, end: $0.end, title: $0.title)
        }, to: day))
        let unconfirmed = unconfirmedMinutes(samples, dayStart: start, dayEnd: end, workouts: workoutSpans)

        var counts = [Int](repeating: 0, count: slots)
        var doubted = [Int](repeating: 0, count: slots)
        var sums = [Double](repeating: 0, count: slots)
        var lows = [Double](repeating: .infinity, count: slots)
        var highs = [Double](repeating: -.infinity, count: slots)
        var minutes: [Int: [Double]] = [:]
        var measuredMinutes = Set<Int>()
        var total = 0.0
        var totalCount = 0

        for sample in samples {
            let bpm = sample.bpm
            guard bpm.isFinite, plausibleRange.contains(bpm), sample.time >= start, sample.time < end else { continue }
            let offset = sample.time - start
            let slot = Int(offset / Double(width))
            guard slot >= 0, slot < slots else { continue }
            let minute = Int(offset / 60)
            counts[slot] += 1
            sums[slot] += bpm
            lows[slot] = min(lows[slot], bpm)
            highs[slot] = max(highs[slot], bpm)
            measuredMinutes.insert(minute)
            if unconfirmed.contains(minute) {
                doubted[slot] += 1
                continue
            }
            minutes[minute, default: []].append(bpm)
            total += bpm
            totalCount += 1
        }

        var buckets: [HeartTimelineBucket] = []
        for slot in 0..<slots where counts[slot] >= minimumSamplesPerBucket {
            let bucketStart = Date(timeIntervalSince1970: start + Double(slot * width))
            let bucketEnd = Date(timeIntervalSince1970: min(end, start + Double((slot + 1) * width)))
            buckets.append(HeartTimelineBucket(
                start: bucketStart, end: bucketEnd,
                minimum: lows[slot], average: sums[slot] / Double(counts[slot]), maximum: highs[slot],
                sampleCount: counts[slot], unconfirmedCount: doubted[slot]))
        }

        let minuteMedians = minutes.values.compactMap { values -> Double? in
            values.count >= minimumSamplesPerMinute ? median(values) : nil
        }
        let summary: HeartTimelineSummary?
        if let lowest = minuteMedians.min(), let highest = minuteMedians.max(), totalCount > 0 {
            summary = HeartTimelineSummary(lowest: lowest, average: total / Double(totalCount),
                                           highest: highest, measuredMinutes: measuredMinutes.count)
        } else {
            summary = nil
        }

        return HeartDayTimeline(dayStart: dayStart, dayEnd: dayEnd, bucketSeconds: width, buckets: buckets,
                                sleep: sleepSpans, workouts: workoutSpans, summary: summary)
    }

    /// Minutes (from the day's start) the beat-to-beat check could not
    /// confirm. Days without gravity data are never judged.
    static func unconfirmedMinutes(_ samples: [HeartRateSample], dayStart: TimeInterval, dayEnd: TimeInterval,
                                   workouts: [HeartTimelineSpan]) -> Set<Int> {
        struct Minute {
            var rates: [Double] = []
            var motion: [Double] = []
            var beats: [Double] = []
            var lastBeat: Double?
        }
        var minutes: [Int: Minute] = [:]
        var previous: (time: TimeInterval, gravity: SIMD3<Double>)?
        for sample in samples where sample.time >= dayStart && sample.time < dayEnd {
            let key = Int((sample.time - dayStart) / 60)
            var minute = minutes[key] ?? Minute()
            if sample.bpm.isFinite, plausibleRange.contains(sample.bpm) { minute.rates.append(sample.bpm) }
            if let gravity = sample.gravity {
                if let previous, sample.time - previous.time == 1 {
                    let change = gravity - previous.gravity
                    minute.motion.append((change * change).sum().squareRoot())
                }
                previous = (sample.time, gravity)
            } else {
                previous = nil
            }
            for beat in sample.rrMilliseconds {
                // The band repeats a placeholder interval (500 ms, 333 ms)
                // when it has no beat; an exact repeat is not a new beat.
                if (300...2_000).contains(beat), beat != minute.lastBeat { minute.beats.append(beat) }
                minute.lastBeat = beat
            }
            minutes[key] = minute
        }
        var result = Set<Int>()
        for (key, minute) in minutes {
            guard minute.rates.count >= minimumSamplesPerMinute, !minute.motion.isEmpty,
                  let band = median(minute.rates), band >= checkFromBPM else { continue }
            let motion = minute.motion.reduce(0, +) / Double(minute.motion.count)
            guard motion <= stillMotion else { continue }
            let minuteStart = Date(timeIntervalSince1970: dayStart + Double(key * 60))
            let minuteEnd = minuteStart.addingTimeInterval(60)
            guard !workouts.contains(where: { $0.start < minuteEnd && $0.end > minuteStart }) else { continue }
            if minute.beats.count >= minimumBeatsPerMinute, let interval = median(minute.beats),
               abs(60_000 / interval - band) <= agreementBPM {
                continue
            }
            result.insert(key)
        }
        return result
    }

    static func clip(_ spans: [HeartTimelineSpan], to day: DateInterval) -> [HeartTimelineSpan] {
        spans.compactMap { span in
            let start = max(span.start, day.start)
            let end = min(span.end, day.end)
            guard end.timeIntervalSince(start) >= 60 else { return nil }
            return HeartTimelineSpan(kind: span.kind, start: start, end: end, title: span.title)
        }
        .sorted { $0.start < $1.start }
    }

    /// Two sources can report the same session (a recorded workout and the
    /// detector). Overlapping spans become one, keeping the first title.
    static func mergeWorkouts(_ spans: [HeartTimelineSpan]) -> [HeartTimelineSpan] {
        var result: [HeartTimelineSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start < last.end {
                result[result.count - 1] = HeartTimelineSpan(kind: .workout, start: last.start,
                    end: max(last.end, span.end), title: last.title ?? span.title)
            } else {
                result.append(span)
            }
        }
        return result
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The newest heart rate the band recorded, for the row shown when the band
/// is not streaming.
public struct HeartLastReading: Equatable, Sendable {
    public let bpm: Double
    public let at: Date

    public init(bpm: Double, at: Date) {
        self.bpm = bpm
        self.at = at
    }

    /// "64 bpm · 10:42" today, "64 bpm · Wed 22:11" on an earlier day this
    /// week, "64 bpm · 14 Sep 22:11" before that.
    public func text(now: Date, calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB")) -> String {
        "\(Int(bpm.rounded())) bpm · \(Self.when(at, now: now, calendar: calendar, locale: locale))"
    }

    /// What VoiceOver reads: "64 beats per minute at 10:42".
    public func spokenText(now: Date, calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB")) -> String {
        "\(Int(bpm.rounded())) beats per minute, \(Self.when(at, now: now, calendar: calendar, locale: locale))"
    }

    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let format: String
        if calendar.isDate(date, inSameDayAs: now) {
            format = "HH:mm"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day, days > 0, days < 7 {
            format = "EEE HH:mm"
        } else {
            format = "d MMM HH:mm"
        }
        return LooprDateFormatterCache.string(from: date, format: format, calendar: calendar, locale: locale)
    }
}
