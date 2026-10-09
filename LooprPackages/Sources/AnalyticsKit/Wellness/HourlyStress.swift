import Foundation

public struct HourlyStressSample: Sendable {
    public let time: Date
    public let heartRate: Double?
    public let rrMilliseconds: [Double]
    public init(time: Date, heartRate: Double?, rrMilliseconds: [Double]) {
        self.time = time; self.heartRate = heartRate; self.rrMilliseconds = rrMilliseconds
    }
}

/// Small sufficient statistics, persisted with a day's canonical derivation.
/// No raw beats enter the rolling baseline or the view tree.
public struct StressHourFeature: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case quiet, active, asleep, missing }
    public let start: Date
    public let end: Date
    public let state: State
    public let heartRate: Double?
    public let rmssd: Double?
    public var id: Date { start }
    public init(start: Date, end: Date, state: State, heartRate: Double? = nil, rmssd: Double? = nil) {
        self.start = start; self.end = end; self.state = state; self.heartRate = heartRate; self.rmssd = rmssd
    }
}

public struct StressHour: Codable, Equatable, Sendable, Identifiable {
    public let feature: StressHourFeature
    public let score: Double?
    public let baselineDays: Int
    public var id: Date { feature.start }
    public var isHigh: Bool { score.map { $0 >= 65 } ?? false }
    public var daysRemaining: Int { max(0, HourlyStress.minimumBaselineDays - baselineDays) }
}

public struct HourlyStressDay: Codable, Equatable, Sendable {
    public let hours: [StressHour]
    public let timeZoneIdentifier: String
    public var daysRemaining: Int { hours.filter { $0.feature.state != .asleep }.map(\.daysRemaining).min() ?? HourlyStress.minimumBaselineDays }
    public var hasSustainedHigh: Bool {
        zip(hours, hours.dropFirst()).contains { left, right in
            left.isHigh && right.isHigh && left.feature.end == right.feature.start
        }
    }
}

/// Loopr's relative daytime indicator, designed from first principles. This
/// is autonomic load relative to the person's own quiet waking hours, not a
/// measurement of emotion or a clinical threshold.
///
/// Each absolute five-minute window needs 120 distinct HR seconds, 120 clean
/// beats and 80% RR quality, with HR within 25 bpm of the beat-derived rate. HRVTime receives the corrected beat clock so it
/// never pairs beats across a dropout. Three usable windows form an hour;
/// medians resist brief spikes. Windows overlapping sleep or workouts are
/// excluded. Motion >=0.06 g in three minutes, or HR >=60% of the configured HR reserve, also
/// excludes activity windows. Six activity windows mask an hour as Active.
///
/// Compare the same local clock hour on 14 distinct preceding days in a
/// 28-calendar-day window. Robust median/MAD scales have floors of 5 bpm and
/// 0.15 log-RMSSD, preventing nearly identical days from amplifying noise.
/// Equal weights combine HR rise and log-RMSSD fall, then map z to 50+15z.
/// Scores >=65 are high, <=35 low. These are display thresholds, not medical
/// cutoffs. Current-day data never enters its own reference.
///
/// Cost: one pass groups seconds into at most 300 windows; RR filtering runs
/// on short windows only. The baseline reads <=28*25 cached hourly features,
/// never 28 days of raw beats. DST hours keep their absolute identity and
/// repeated clock hours contribute only one reference observation per day.
public enum HourlyStress {
    public static let version = "loopr.hourly-stress.1"
    public static let minimumBaselineDays = 14
    public static let baselineWindowDays = 28

    public static func features(samples: [HourlyStressSample], dayStart: Date, calendar: Calendar,
                                sleep: [DateInterval] = [], workouts: [DateInterval] = [],
                                motion: [MotionMinute] = [], restingHR: Double? = nil, maximumHR: Double? = nil) -> [StressHourFeature] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), dayEnd > dayStart else { return [] }
        let grouped = Dictionary(grouping: samples.filter { $0.time.timeIntervalSince1970.isFinite && $0.time >= dayStart && $0.time < dayEnd }) {
            Int($0.time.timeIntervalSince(dayStart) / 300)
        }
        let movingMinutes = Dictionary(grouping: motion.filter {
            $0.start.isFinite && $0.start >= dayStart.timeIntervalSince1970 && $0.start < dayEnd.timeIntervalSince1970 && $0.sampleCount >= 30 && $0.dynamicAmplitude.isFinite && $0.dynamicAmplitude >= 0.06
        }) { Int(($0.start - dayStart.timeIntervalSince1970) / 300) }
        let moving = Set(movingMinutes.filter { Set($0.value.map(\.start)).count >= 3 }.keys)
        var hours: [StressHourFeature] = []
        var hour = dayStart
        while hour < dayEnd {
            let end = min(hour.addingTimeInterval(3600), dayEnd)
            var active = 0, asleep = 0
            var rates: [Double] = [], variability: [Double] = []
            for index in 0..<Int(end.timeIntervalSince(hour) / 300) {
                let start = hour.addingTimeInterval(Double(index * 300))
                let stop = start.addingTimeInterval(300)
                // A recorded or detected workout wins over inferred sleep.
                if workouts.contains(where: { $0.start < stop && $0.end > start }) { active += 1; continue }
                if sleep.contains(where: { $0.start < stop && $0.end > start }) { asleep += 1; continue }
                let key = Int(start.timeIntervalSince(dayStart) / 300)
                let records = grouped[key] ?? []
                let valid = records.filter { $0.heartRate.map { $0.isFinite && (25...240).contains($0) } ?? false }
                let rate = AnalyticsMath.median(valid.compactMap(\.heartRate))
                let highActivityHR: Bool
                if let rate, let restingHR, let maximumHR, maximumHR > restingHR {
                    highActivityHR = rate >= restingHR + 0.6 * (maximumHR - restingHR)
                } else { highActivityHR = false }
                if moving.contains(key) || highActivityHR {
                    active += 1; continue
                }
                guard Set(valid.map { Int($0.time.timeIntervalSince1970) }).count >= 120, let rate else { continue }
                let ordered = records.sorted { $0.time < $1.time }
                let beats = ordered.flatMap(\.rrMilliseconds)
                let times = ordered.flatMap { record in record.rrMilliseconds.map { _ in record.time.timeIntervalSince1970 * 1000 } }
                guard let clean = RRQuality.gated(beats, beatTimestampsMilliseconds: times, minimumCleanFraction: 0.8, minimumIntervals: 120).value,
                      let rmssd = HRVTime.derive(clean.normalIntervalsMilliseconds, beatTimesMilliseconds: clean.normalTimesMilliseconds)
                        .value?.rmssdMilliseconds, rmssd.isFinite, rmssd > 0,
                      let medianBeat = AnalyticsMath.median(clean.normalIntervalsMilliseconds),
                      abs(60000 / medianBeat - rate) <= 25 else { continue }
                rates.append(rate); variability.append(rmssd)
            }
            let state: StressHourFeature.State = active >= 6 ? .active : asleep >= 6 ? .asleep : rates.count >= 3 ? .quiet : .missing
            hours.append(StressHourFeature(start: hour, end: end, state: state,
                heartRate: state == .quiet ? AnalyticsMath.median(rates) : nil,
                rmssd: state == .quiet ? AnalyticsMath.median(variability) : nil))
            hour = end
        }
        return hours
    }

    public static func resolve(_ features: [StressHourFeature], baseline: [StressHourFeature], calendar: Calendar) -> HourlyStressDay {
        let orderedBaseline = baseline.sorted { $0.start < $1.start }
        let hours = features.map { feature -> StressHour in
            let today = calendar.startOfDay(for: feature.start)
            let lower = calendar.date(byAdding: .day, value: -baselineWindowDays, to: today) ?? today
            let hour = calendar.component(.hour, from: feature.start)
            var references: [Date: StressHourFeature] = [:]
            for candidate in orderedBaseline {
                guard candidate.start >= lower, candidate.start < today, candidate.state == .quiet,
                      calendar.component(.hour, from: candidate.start) == hour,
                      let hr = candidate.heartRate, hr.isFinite, let rmssd = candidate.rmssd, rmssd.isFinite, rmssd > 0 else { continue }
                references[calendar.startOfDay(for: candidate.start)] = candidate
            }
            let count = references.count
            guard feature.state == .quiet, count >= minimumBaselineDays,
                  let hr = feature.heartRate, hr.isFinite, let rmssd = feature.rmssd, rmssd.isFinite, rmssd > 0 else {
                return StressHour(feature: feature, score: nil, baselineDays: count)
            }
            func deviation(_ value: Double, _ values: [Double], floor: Double) -> Double {
                guard let center = AnalyticsMath.median(values), let mad = AnalyticsMath.median(values.map { abs($0 - center) }) else { return 0 }
                return (value - center) / max(floor, 1.4826 * mad)
            }
            let rates = references.values.compactMap(\.heartRate)
            let logs = references.values.compactMap(\.rmssd).map(log)
            let z = (deviation(hr, rates, floor: 5) - deviation(log(rmssd), logs, floor: 0.15)) / 2
            return StressHour(feature: feature, score: min(100, max(0, 50 + 15 * z)), baselineDays: count)
        }
        return HourlyStressDay(hours: hours, timeZoneIdentifier: calendar.timeZone.identifier)
    }
}
