import Foundation
import DomainKit
import DesignSystem
import BluetoothKit

public enum HeartFixtures {
    public static let day = DayIdentity(year: 2023, month: 11, day: 14)

    /// The moment the fixture day ends, shared with the other tab fixtures.
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Values come from `LooprFixtureMetrics`, so each row matches the metric
    /// page it opens and each metric has its own believable number. Heart-rate
    /// dip stays absent: Loopr does not calculate it, and its page says so.
    public static func snapshot(for state: MetricState) -> HeartDaySnapshot {
        let hasValue = [.measuredZero, .partial, .lowConfidence, .settling, .stale].contains(state)
        let confidence: String? = state == .lowConfidence ? "Low confidence" : nil
        func text(_ linkID: String, digits: Int = 0) -> String? {
            guard hasValue else { return nil }
            if state == .measuredZero { return "0" }
            return LooprFixtureMetrics.today(linkID).map { String(format: "%.\(digits)f", $0) }
        }
        func number(_ linkID: String) -> Double? {
            guard hasValue else { return nil }
            return state == .measuredZero ? 0 : LooprFixtureMetrics.today(linkID)
        }
        let rhr = text(LooprMetricLinkID.restingHeartRate)
        let metrics = [
            HeartMetricValue(id: .restingHeartRate, title: "Resting heart rate", value: rhr, unit: "bpm", state: state, confidence: confidence, trend: rhr == nil ? nil : "Down 3 bpm", source: "ANA-02.nocturnal", algorithmVersion: "ana02.nocturnal.v1", numericValue: number(LooprMetricLinkID.restingHeartRate), numericUnit: .beatsPerMinute),
            HeartMetricValue(id: .rmssd, title: "HRV", value: text(LooprMetricLinkID.rmssd), unit: "ms", state: state, confidence: confidence, qualityDetail: hasValue ? "PRV-derived" : nil, source: "ANA-02.hrv", algorithmVersion: "ana02.hrv.v1", numericValue: number(LooprMetricLinkID.rmssd), numericUnit: .milliseconds),
            HeartMetricValue(id: .sdnn, title: "SDNN", value: text(LooprMetricLinkID.sdnn), unit: "ms", state: state, confidence: confidence, source: "ANA-02.hrv", algorithmVersion: "ana02.hrv.v1", numericValue: number(LooprMetricLinkID.sdnn), numericUnit: .milliseconds),
            HeartMetricValue(id: .pNN50, title: "pNN50", value: text(LooprMetricLinkID.pNN50), unit: "%", state: state, confidence: confidence, source: "ANA-02.hrv", algorithmVersion: "ana02.hrv.v1", numericValue: number(LooprMetricLinkID.pNN50), numericUnit: .percentagePoints),
            HeartMetricValue(id: .respiration, title: "Respiratory rate", value: text(LooprMetricLinkID.respiratoryRate, digits: 1), unit: "br/min", state: state, confidence: confidence, source: "ANA-02.respiration", algorithmVersion: "ana02.respiration.v1", numericValue: number(LooprMetricLinkID.respiratoryRate), numericUnit: .breathsPerMinute),
            HeartMetricValue(id: .heartRateDip, title: "Heart rate dip", value: nil, unit: "%", state: hasValue ? .absent : state, source: "ANA-02.nocturnal", algorithmVersion: "ana02.nocturnal.v1")
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let history = LooprFixtureMetrics.history(LooprMetricLinkID.restingHeartRate, days: 7, endingOn: baseDate, calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: history.map { (calendar.startOfDay(for: $0.date), $0.value) })
        let trend = (0..<7).reversed().compactMap { offset -> HeartTrendPoint? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: baseDate)) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let localDay = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let value = hasValue ? (state == .measuredZero ? "0" : byDay[date].map { String(format: "%.0f", $0) }) : nil
            return HeartTrendPoint(id: "rhr-\(localDay)", metric: .restingHeartRate, localDay: localDay, value: value, unit: "bpm", state: value == nil && hasValue ? .absent : state, source: "ANA-02.nocturnal", algorithmVersion: "ana02.nocturnal.v1")
        }
        return HeartDaySnapshot(day: day, state: state, metrics: metrics, liveState: state, source: "ANA-02.canonical", algorithmVersion: "ana02.v1", trend: trend)
    }

    public static var allStates: [(state: MetricState, snapshot: HeartDaySnapshot)] {
        MetricState.allCases.map { (state: $0, snapshot: snapshot(for: $0)) }
    }

    public static var populated: HeartDaySnapshot { snapshot(for: .partial) }

    public static var spotCheck: HeartSpotCheckResult {
        HeartSpotCheckResult(state: .partial, heartRateBPM: 56, rmssdMilliseconds: 42, sdnnMilliseconds: 54, durationSeconds: 60, qualityDetail: "Good signal coverage.", source: "BLE-07.spot-check")
    }
}
