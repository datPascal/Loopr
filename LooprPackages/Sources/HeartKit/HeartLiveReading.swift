import Foundation
import SwiftUI
import DesignSystem
import DomainKit

/// The live view of the shared Heart and Body zone settings.
public struct HeartZoneScale: Equatable, Sendable {
    public let maxHeartRate: Double
    public let zones: HeartRateZones

    public init?(maxHeartRate: Double?) {
        guard let maxHeartRate,
              let zones = HeartRateZoneSettings(manualMaximum: maxHeartRate).resolved(age: nil) else { return nil }
        self.init(zones: zones)
    }

    public init(zones: HeartRateZones) {
        self.zones = zones
        self.maxHeartRate = zones.maximum
    }

    /// Age-predicted maximum from the same model Body uses.
    public static func agePredicted(age: Int?) -> HeartZoneScale? {
        guard let zones = HeartRateZoneSettings().resolved(age: age) else { return nil }
        return HeartZoneScale(zones: zones)
    }

    public func zone(for bpm: Double) -> HeartZone? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        let share = bpm / maxHeartRate
        let number = zones.number(for: bpm)
        return HeartZone(number: number, percentOfMax: Int((share * 100).rounded()))
    }
}

public struct HeartZone: Equatable, Sendable {
    /// 0 below zone 1, then 1 to 5.
    public let number: Int
    public let percentOfMax: Int

    public init(number: Int, percentOfMax: Int) {
        self.number = min(max(number, 0), 5)
        self.percentOfMax = percentOfMax
    }

    public var title: String { number == 0 ? "Below zone 1" : "Zone \(number)" }

    /// "Zone 2 · 64% of max".
    public var pillText: String { "\(title) · \(percentOfMax)% of max" }

    public var spokenText: String { "\(title), \(percentOfMax) percent of your maximum" }

    /// Grey at rest, then blue, teal, orange, red-orange and the heart accent.
    /// These colour effort during exercise; they never mark a reading as a
    /// problem.
    public var token: LooprColorToken {
        LooprZonePalette.token(for: number)
    }

    /// The shade of `token` that reads as text on the card in both
    /// appearances, keeping the hue of the line it sits above.
    public var textToken: LooprColorToken {
        LooprZonePalette.textToken(for: number)
    }
}

/// One point on the live line.
public struct HeartLivePoint: Equatable, Sendable, Identifiable {
    public let date: Date
    public let bpm: Double
    public var id: Date { date }

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// What the live card shows, worked out from the samples the band streamed.
public struct HeartLiveReading: Equatable, Sendable {
    /// Seconds of history on the live line.
    public static let lineSeconds: TimeInterval = 180
    /// A stream with no sample for this long is no longer live.
    public static let staleAfter: TimeInterval = 10

    public let bpm: Double
    public let receivedAt: Date
    /// True when the band sent no heart rate and the number comes from the
    /// beat-to-beat intervals instead.
    public let fromBeatToBeat: Bool
    public let zone: HeartZone?
    /// The last three minutes, oldest first.
    public let line: [HeartLivePoint]

    public init(bpm: Double, receivedAt: Date, fromBeatToBeat: Bool, zone: HeartZone?, line: [HeartLivePoint]) {
        self.bpm = bpm
        self.receivedAt = receivedAt
        self.fromBeatToBeat = fromBeatToBeat
        self.zone = zone
        self.line = line
    }

    public var bpmText: String { String(Int(bpm.rounded())) }

    /// The heart rate one sample stands for: the band's own number, or, when
    /// that is missing, 60,000 divided by the beat interval.
    static func rate(of sample: HeartLiveSample) -> (bpm: Double, fromBeatToBeat: Bool)? {
        if let bpm = sample.heartRateBPM, bpm.isFinite, HeartTimelineBuilder.plausibleRange.contains(bpm) {
            return (bpm, false)
        }
        if let rr = sample.rrMilliseconds, rr.isFinite, (250...2_400).contains(rr) {
            let bpm = 60_000 / rr
            return HeartTimelineBuilder.plausibleRange.contains(bpm) ? (bpm, true) : nil
        }
        return nil
    }

    /// The live reading, or nil when nothing usable arrived in the last
    /// `staleAfter` seconds.
    public static func resolve(samples: [HeartLiveSample], now: Date, zones: HeartZoneScale?) -> HeartLiveReading? {
        let rated = samples.compactMap { sample -> (Date, Double, Bool)? in
            rate(of: sample).map { (sample.receivedAt, $0.bpm, $0.fromBeatToBeat) }
        }
        .sorted { $0.0 < $1.0 }
        guard let latest = rated.last, now.timeIntervalSince(latest.0) <= staleAfter else { return nil }
        let line = rated
            .filter { now.timeIntervalSince($0.0) <= lineSeconds }
            .map { HeartLivePoint(date: $0.0, bpm: $0.1) }
        return HeartLiveReading(bpm: latest.1, receivedAt: latest.0, fromBeatToBeat: latest.2,
                                zone: zones?.zone(for: latest.1), line: line)
    }

    /// The y range of the live line: at least 20 bpm tall.
    public var lineDomain: ClosedRange<Double> {
        let values = line.map(\.bpm)
        guard let low = values.min(), let high = values.max() else { return (bpm - 10)...(bpm + 10) }
        let middle = (low + high) / 2
        let half = max((high - low) / 2 + 3, 10)
        return (middle - half)...(middle + half)
    }

    public var spokenText: String {
        var parts = ["Live heart rate, \(bpmText) beats per minute"]
        if let zone { parts.append(zone.spokenText) }
        if fromBeatToBeat { parts.append("from beat-to-beat intervals") }
        return parts.joined(separator: ", ")
    }
}

/// What the app hands the Heart tab beyond the day snapshot: daily history
/// for the resting heart rate and HRV cards, the day's heart-rate timeline,
/// the newest stored reading and the zone scale. Each part is optional; the
/// tab leaves out what it cannot get rather than guessing.
public struct HeartTabServices: Sendable {
    /// Daily values of a metric (`LooprMetricLinkID`) for `days` days ending
    /// on the given date.
    public var history: (@Sendable (String, Int, Date) async -> [LooprChartPoint])?
    /// The selected day's heart rate. Nil when the band recorded nothing.
    public var timeline: (@Sendable (LooprDay) async -> HeartDayTimeline?)?
    public var timelineRange: (@Sendable (HeartTimelineRangeRequest) async throws -> [HeartRateSample])?
    /// The newest heart rate the band recorded.
    public var lastReading: (@Sendable () async -> HeartLastReading?)?
    public var zones: HeartZoneScale?
    public var age: Int?
    public var zoneSettings: HeartRateZoneSettings?
    public var saveZoneSettings: (@Sendable (HeartRateZoneSettings) async -> Void)?
    /// Bumped by the app when stored data changed (a day was derived, history
    /// was backfilled). The tab reloads its cards and timeline when it moves.
    public var revision: Int

    public init(
        history: (@Sendable (String, Int, Date) async -> [LooprChartPoint])? = nil,
        timeline: (@Sendable (LooprDay) async -> HeartDayTimeline?)? = nil,
        timelineRange: (@Sendable (HeartTimelineRangeRequest) async throws -> [HeartRateSample])? = nil,
        lastReading: (@Sendable () async -> HeartLastReading?)? = nil,
        zones: HeartZoneScale? = nil,
        age: Int? = nil,
        zoneSettings: HeartRateZoneSettings? = nil,
        saveZoneSettings: (@Sendable (HeartRateZoneSettings) async -> Void)? = nil,
        revision: Int = 0
    ) {
        self.history = history
        self.timelineRange = timelineRange
        self.timeline = timeline
        self.lastReading = lastReading
        self.zones = zones
        self.age = age
        self.zoneSettings = zoneSettings
        self.saveZoneSettings = saveZoneSettings
        self.revision = revision
    }
}

public extension EnvironmentValues {
    @Entry var heartTabServices: HeartTabServices? = nil
}
