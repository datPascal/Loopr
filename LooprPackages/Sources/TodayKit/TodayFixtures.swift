import Foundation
import DomainKit
import DesignSystem

/// Deterministic fixtures are package-local inputs for state-matrix tests and
/// DEBUG launch compositions.  They are not used by production repositories.
public enum TodayFixtures {
    public static let day = DayIdentity(year: 2023, month: 11, day: 14)

    public static func summary(for state: MetricState) -> TodaySummary {
        let metricValues: [TodayMetricID: (String, String)] = [
            .readiness: ("Recovery", "%"),
            .recovery: ("Recovery", "%"),
            .sleep: ("Sleep", "hours"),
            .heart: ("Resting heart rate", "bpm"),
            .strain: ("Strain", "/21"),
            .stress: ("Stress", "/100"),
            .hrv: ("HRV", "ms"),
            .restingHeartRate: ("Resting heart rate", "bpm"),
            .calories: ("Active energy", "kcal"),
            .steps: ("Estimated steps", "steps"),
            .wearQuality: ("Wear quality", "%")
        ]
        let metrics = TodayMetricID.allCases.map { id in
            let metadata = metricValues[id]!
            let value: String?
            let number: Double?
            switch state {
            case .measuredZero:
                value = "0"
                number = 0
            case .partial, .lowConfidence, .settling, .stale:
                // The same believable day every fixture shows.
                number = fixtureNumber(for: id)
                value = number.map { fixtureText(for: id, value: $0) }
            default:
                value = nil
                number = nil
            }
            return TodayMetricValue(
                id: id,
                title: metadata.0,
                value: value,
                unit: metadata.1,
                trend: nil,
                confidence: state == .lowConfidence ? "Low confidence" : nil,
                state: state,
                contributors: id == .readiness && value != nil
                    ? [TodayContributor(id: "sleep", label: "Sleep", detail: "Canonical sleep derivation", contribution: 0.4)]
                    : [],
                source: "fixture.today.\(id.rawValue)",
                algorithmVersion: "fixture.v1",
                numericValue: number,
                numericUnit: numericUnit(for: id)
            )
        }

        let connection: TodayConnectionState = switch state {
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .settling, .loading: .syncing
        default: .connected
        }
        let updatedAt: Date? = switch state {
        case .stale: Date(timeIntervalSince1970: 1_699_000_000)
        case .loading, .noRecords, .absent, .permissionDenied, .unsupportedHardware, .recoverableError, .destructiveFailure: nil
        default: Date(timeIntervalSince1970: 1_700_000_000)
        }
        return TodaySummary(
            day: day,
            overallState: state,
            freshness: TodayFreshness(state: state, updatedAt: updatedAt, ageMinutes: updatedAt == nil ? nil : state == .stale ? 1_440 : 5, detail: state.detail),
            device: TodayDeviceSnapshot(name: "WHOOP 4.0", model: "WHOOP 4.0", generation: "4", connection: connection, status: state),
            metrics: metrics,
            goals: [TodayGoalProgress(id: "movement", title: "Move today", value: state == .measuredZero ? "0" : nil, target: "30", unit: "minutes", state: state, progressFraction: state == .measuredZero ? 0 : nil)],
            coachPlan: .placeholder,
            notableChanges: []
        )
    }

    public static var allStates: [(state: MetricState, summary: TodaySummary)] {
        MetricState.allCases.map { (state: $0, summary: summary(for: $0)) }
    }

    /// A good morning after a good night, with every number taken from
    /// `LooprFixtureMetrics` so the tab, its rings and the metric pages agree:
    /// recovery 79 (high band; rounded from the fixture history's formula), HRV 61 ms against a usual of about 50, resting
    /// heart rate 51 bpm against about 54, 7 h 42 m of sleep against a 7 h 30 m
    /// need, strain 8.6 so far.
    public static var populated: TodaySummary {
        func metric(_ id: TodayMetricID, _ title: String, _ unit: String, source: String, version: String,
                    confidence: String? = nil, contributors: [TodayContributor] = []) -> TodayMetricValue {
            let number = id == .readiness ? visualRecoveryOverride ?? fixtureNumber(for: id) : fixtureNumber(for: id)
            return TodayMetricValue(
                id: id, title: title, value: number.map { fixtureText(for: id, value: $0) }, unit: unit,
                trend: nil, confidence: confidence, state: .partial, contributors: contributors,
                source: source, algorithmVersion: version, numericValue: number, numericUnit: numericUnit(for: id)
            )
        }
        let hrv = fixtureNumber(for: .hrv) ?? 0
        let usualHRV = LooprFixtureMetrics.usual(LooprMetricLinkID.rmssd) ?? hrv
        let hrvPercent = Int(((hrv - usualHRV) / usualHRV * 100).rounded())
        let sleepText = LooprUnitFormatter.duration(minutes: fixtureNumber(for: .sleep) ?? 0) ?? ""
        return TodaySummary(
            day: day,
            overallState: .partial,
            freshness: TodayFreshness(state: .partial, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), ageMinutes: 2, detail: "Synced just now."),
            device: TodayDeviceSnapshot(name: "WHOOP 4.0", model: "WHOOP 4.0", generation: "4", connection: .connected, status: .partial),
            metrics: [
                metric(.readiness, "Recovery", "%", source: "ANA-08.readiness", version: "wellness.v1",
                       confidence: "Based on your recent nights",
                       contributors: [
                           TodayContributor(id: "hrv", label: "HRV", detail: "\(hrvPercent)% above your usual", contribution: 0.5),
                           TodayContributor(id: "sleep", label: "Sleep", detail: sleepText, contribution: 0.3)
                       ]),
                metric(.sleep, "Sleep", "hours", source: "ANA-03.sleep", version: "sleep.v1"),
                metric(.heart, "Resting heart rate", "bpm", source: "ANA-02.nocturnal", version: "ana02.nocturnal.v1"),
                metric(.strain, "Strain", "/21", source: "ANA-05.activity", version: "activity.v1"),
                metric(.stress, "Stress", "/100", source: "ANA-04.wellness", version: "wellness.v1", confidence: "Low"),
                metric(.hrv, "HRV", "ms", source: "ANA-02.hrv", version: "ana02.hrv.v1"),
                metric(.steps, "Estimated steps", "steps", source: "ANA-05.steps", version: "activity.v1",
                       confidence: "Estimated from wrist motion and your walking pace"),
                metric(.calories, "Active energy", "kcal", source: "ANA-05.energy", version: "activity.v1",
                       confidence: "Estimated with a default maximum heart rate")
            ],
            goals: [TodayGoalProgress(id: "movement", title: "Move today", value: "24", target: "30", unit: "minutes", state: .partial, progressFraction: 0.8)],
            coachPlan: .placeholder,
            notableChanges: ["HRV is \(hrvPercent)% above your recent days."] + debugStressHint,
            sleepNeedMinutes: LooprFixtureMetrics.sleepNeedMinutes
        )
    }

    /// Capture runs that seed scored hourly stress also show its Today link.
    private static var debugStressHint: [String] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--loopr-hourly-stress-fixture=scored") {
            return [TodayDayInsight.sustainedStressHint]
        }
        #endif
        return []
    }

    /// Visual QA can exercise all three ambient recovery colours without
    /// changing the default coherent fixture or any production data.
    private static var visualRecoveryOverride: Double? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--loopr-visual-recovery=middle") { return 52 }
        if ProcessInfo.processInfo.arguments.contains("--loopr-visual-recovery=low") { return 22 }
        #endif
        return nil
    }

    /// The fixture day's number for a Today metric, in the unit the metric's
    /// `numericUnit` names (minutes for sleep, 0 to 100 for scores).
    public static func fixtureNumber(for id: TodayMetricID) -> Double? {
        let linkID: String? = switch id {
        case .readiness, .recovery: LooprMetricLinkID.recovery
        case .sleep: LooprMetricLinkID.sleepDuration
        case .heart, .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .strain: LooprMetricLinkID.strain
        case .stress: LooprMetricLinkID.stress
        case .hrv: LooprMetricLinkID.rmssd
        case .calories: LooprMetricLinkID.activeEnergy
        case .steps: LooprMetricLinkID.steps
        case .wearQuality: nil
        }
        guard let linkID else { return 96 }
        return LooprFixtureMetrics.today(linkID)
    }

    /// The display string production would build for the same number.
    static func fixtureText(for id: TodayMetricID, value: Double) -> String {
        switch id {
        case .sleep: "\(Int(value) / 60):\(String(format: "%02d", Int(value) % 60))"
        case .strain: String(format: "%.1f", value)
        case .steps, .calories: LooprUnitFormatter.number(value) ?? ""
        default: String(format: "%.0f", value)
        }
    }

    public static var empty: TodaySummary { summary(for: .noRecords) }

    private static func numericUnit(for id: TodayMetricID) -> TodayMetricUnitID {
        switch id {
        case .readiness, .recovery: .scorePoints
        case .sleep: .minutes
        case .heart, .restingHeartRate: .beatsPerMinute
        case .strain: .strainScore
        case .stress: .scorePoints
        case .hrv: .milliseconds
        case .calories: .kilocalories
        case .steps: .count
        case .wearQuality: .percentagePoints
        }
    }

}
