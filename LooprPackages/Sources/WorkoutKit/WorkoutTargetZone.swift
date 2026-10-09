import AnalyticsKit
import DomainKit
import Foundation

public struct WorkoutPause: Codable, Equatable, Sendable {
    public let start: Date
    public var end: Date?
    public init(start: Date, end: Date? = nil) { self.start = start; self.end = end }
}

public struct WorkoutZoneTarget: Codable, Equatable, Sendable {
    public let target: WorkoutZoneAlertTarget
    public let lower: Int
    public let upper: Int
    public let source: String
    public var range: ClosedRange<Int> { lower...upper }
    public var title: String {
        switch target {
        case .zoneTwo: "Zone 2"
        case .zone(let number): "Zone \(number)"
        case .custom: "Target"
        case .off: "Alerts off"
        }
    }
    public func status(bpm: Int?) -> String {
        guard let bpm else { return "No heart rate" }
        if bpm > upper { return "Above by \(bpm - upper) bpm" }
        if bpm < lower { return "Below by \(lower - bpm) bpm" }
        return "In zone"
    }

    public init?(preference: WorkoutZoneAlertPreference, zones: HeartRateZoneSet?, zoneTwo: ZoneTwoRange?) {
        let preset = preference.resolvedZoneTwo(zoneTwo)
        guard let range = preference.target.range(in: zones, zoneTwo: preset) else { return nil }
        target = preference.target; lower = range.lowerBound; upper = range.upperBound
        source = switch preference.target {
        case .zoneTwo: switch preset?.source {
            case .restingHeartRate: "From your resting and max heart rate"
            case .maximumHeartRate: "From max heart rate"
            default: "Manual range"
            }
        case .custom: "Manual range"
        default: zones?.restingHR == nil ? "From max heart rate" : "From your resting and max heart rate"
        }
    }
}

public struct WorkoutZoneTargetChange: Codable, Equatable, Sendable {
    public let at: Date
    public let target: WorkoutZoneTarget?
    public init(at: Date, target: WorkoutZoneTarget?) { self.at = at; self.target = target }
}

public extension WorkoutRecord {
    func activeElapsed(at now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        let end = endedAt ?? now
        let paused = (pauses ?? []).reduce(0.0) { total, pause in
            total + max(0, min(end, pause.end ?? end).timeIntervalSince(max(startedAt, pause.start)))
        }
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }
    var currentZoneTarget: WorkoutZoneTarget? { zoneTargetChanges?.last?.target }
    func targetStatus(bpm: Int?, at now: Date) -> String? {
        guard let target = currentZoneTarget else { return nil }
        if state == .paused { return "Paused" }
        let remaining = Double((zoneAlertPreference?.warmUpMinutes ?? 8) * 60) - (activeElapsed(at: now) ?? 0)
        if remaining > 0 {
            let seconds = Int(ceil(remaining))
            return "Warm-up \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
        return target.status(bpm: bpm)
    }
}

public struct WorkoutTargetZoneSummary: Sendable {
    public let spans: [TargetZoneTimeline.Span]
    public let insideSeconds: TimeInterval
    public let observedSeconds: TimeInterval
    public let targetSeconds: TimeInterval
    public let title: String
    public let rangeText: String
    public func seconds(in position: TargetZoneTimeline.Position) -> TimeInterval {
        spans.filter { $0.position == position }.reduce(0) { $0 + $1.end - $1.start }
    }
    public var percent: Int? { targetSeconds > 0 ? Int((insideSeconds / targetSeconds * 100).rounded()) : nil }

    public init?(workout: WorkoutRecord) {
        guard let start = workout.startedAt, let end = workout.endedAt,
              let changes = workout.zoneTargetChanges, changes.contains(where: { $0.target != nil }) else { return nil }
        let samples = workout.samples.map {
            ActivityHeartRateSample(timestamp: $0.timestamp.timeIntervalSince1970, bpm: $0.heartRate.map(Double.init) ?? .nan, valid: $0.heartRate != nil)
        }
        var spans: [TargetZoneTimeline.Span] = []
        var targetSeconds = 0.0
        var titles: Set<String> = []
        var ranges: Set<String> = []
        for (index, change) in changes.enumerated() {
            guard let target = change.target else { continue }
            let left = max(start, change.at)
            let right = min(end, index + 1 < changes.count ? changes[index + 1].at : end)
            guard right > left else { continue }
            titles.insert(target.title)
            ranges.insert("\(target.lower)–\(target.upper) bpm")
            // Subtract pauses from both the denominator and measured spans.
            var windows = [(left, right)]
            for pause in workout.pauses ?? [] {
                let pauseEnd = pause.end ?? end
                windows = windows.flatMap { a, b -> [(Date, Date)] in
                    guard pause.start < b, pauseEnd > a else { return [(a, b)] }
                    var result: [(Date, Date)] = []
                    if a < pause.start { result.append((a, min(b, pause.start))) }
                    if pauseEnd < b { result.append((max(a, pauseEnd), b)) }
                    return result
                }
            }
            for (a, b) in windows {
                targetSeconds += b.timeIntervalSince(a)
                spans += TargetZoneTimeline.spans(samples, range: target.range, start: a.timeIntervalSince1970, end: b.timeIntervalSince1970)
            }
        }
        self.spans = spans
        insideSeconds = spans.filter { $0.position == .inside }.reduce(0) { $0 + $1.end - $1.start }
        observedSeconds = spans.reduce(0) { $0 + $1.end - $1.start }
        self.targetSeconds = targetSeconds
        title = titles.count == 1 ? titles.first! : "Target"
        rangeText = ranges.count == 1 ? ranges.first! : "Range changed during workout"
    }
}

public struct WorkoutZoneContext: Equatable, Sendable {
    public let zones: HeartRateZoneSet?
    public let zoneTwo: ZoneTwoRange?
    public let usesPhoneCues: Bool
    public init(zones: HeartRateZoneSet? = nil, zoneTwo: ZoneTwoRange? = nil, usesPhoneCues: Bool = false) {
        self.zones = zones; self.zoneTwo = zoneTwo; self.usesPhoneCues = usesPhoneCues
    }
}
