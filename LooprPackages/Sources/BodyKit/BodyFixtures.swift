import Foundation
import DomainKit
import DesignSystem
import AnalyticsKit

public enum BodyFixtures {
    public static let day = DayIdentity(year: 2023, month: 11, day: 14)

    /// Minutes per heart-rate zone on the fixture day, named as production
    /// names them.
    public static let zoneMinutes: [BodyZoneMinutes] = [
        BodyZoneMinutes(id: 1, name: "Recovery", minutes: 42),
        BodyZoneMinutes(id: 2, name: "Aerobic", minutes: 18),
        BodyZoneMinutes(id: 3, name: "Tempo", minutes: 6),
        BodyZoneMinutes(id: 4, name: "Threshold", minutes: 2),
        BodyZoneMinutes(id: 5, name: "Peak", minutes: 0)
    ]

    /// Strain, steps and active energy come from `LooprFixtureMetrics`, so the
    /// rows agree with Today and with their metric pages. Training load is
    /// worked out from the fixture history (`BodyFixtureHistoryProvider`), as
    /// production works it out from the metric history.
    public static func snapshot(for state: MetricState) -> BodyDaySnapshot {
        let hasValue = state == .measuredZero || state == .partial || state == .lowConfidence || state == .settling || state == .stale
        let zero = state == .measuredZero
        func value(_ text: String) -> String? { hasValue ? (zero ? "0" : text) : nil }
        let strain = LooprFixtureMetrics.today(LooprMetricLinkID.strain) ?? 0
        let steps = LooprFixtureMetrics.today(LooprMetricLinkID.steps) ?? 0
        let energy = LooprFixtureMetrics.today(LooprMetricLinkID.activeEnergy) ?? 0
        let zoneTotal = zoneMinutes.reduce(0) { $0 + $1.minutes }
        let confidence: String? = state == .lowConfidence ? "Low confidence" : nil
        let metrics = [
            BodyMetricValue(id: .strain, title: "Strain", value: value(String(format: "%.1f", strain)), unit: "/21", state: state, confidence: confidence, source: "ANA-05.activity", algorithmVersion: "activity.v1"),
            BodyMetricValue(id: .zones, title: "Heart-rate zones", value: value(String(format: "%.0f", zoneTotal)), unit: "minutes", state: state, confidence: confidence, source: "ANA-05.zones", algorithmVersion: "activity.v1"),
            BodyMetricValue(id: .steps, title: "Estimated steps", value: value(LooprUnitFormatter.number(steps) ?? ""), unit: "steps", state: state, confidence: hasValue && !zero ? "Estimated from wrist motion and your walking pace" : confidence, source: "ANA-05.steps", algorithmVersion: "activity.v1"),
            // Most people have no measured maximum heart rate, so production marks
            // this estimate low confidence and keeps it out of Apple Health.
            BodyMetricValue(id: .energy, title: "Active energy", value: value(String(format: "%.0f", energy)), unit: "kcal", state: hasValue && !zero ? .lowConfidence : state, confidence: hasValue && !zero ? "Estimated with a default maximum heart rate" : confidence, source: "ANA-05.energy", algorithmVersion: "activity.v1")
        ]
        let cardio = CardioAgeResult.unavailable(reason: state == .unsupportedHardware ? .missingRequiredDomain : .noVO2MaxSource)
        let loopr = LooprAgeResult(realAgeYears: 35, cardioAge: cardio, modelWindow: DateInterval(start: Date(timeIntervalSince1970: 1_684_000_000), duration: 180 * 86_400), contributors: [], coverage: .empty, confidence: 0, confidenceTier: .unavailable, modelVersion: 0, referenceVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_700_000_000), absenceReason: .compositeNotYetValidated)
        return BodyDaySnapshot(day: day, state: state, metrics: metrics, composition: BodyCompositionContext(weight: hasValue ? "70.0 kg" : nil, height: hasValue ? "175 cm" : nil, bodyFat: nil, state: hasValue ? .partial : state, source: "APP-02A.profile"), cardioAge: cardio, looprAge: loopr, source: "ANA-05/ANA-07 canonical", algorithmVersion: "activity.v1", zoneMinutes: hasValue && !zero ? zoneMinutes : [])
    }

    /// A day with no age in the profile, as on a fresh install: strain,
    /// training load and active energy wait on the profile, while zones and
    /// the rest still show. It mirrors the real-data case.
    public static var needsAge: BodyDaySnapshot {
        let metrics = [
            BodyMetricValue(id: .strain, title: "Strain", value: nil, unit: "/21", state: .absent,
                            confidence: "Add your age to your profile to see strain", source: "ANA-05.activity", algorithmVersion: "activity.v1"),
            BodyMetricValue(id: .steps, title: "Estimated steps", value: nil, unit: "steps", state: .absent,
                            confidence: "A few more days of wear and this is ready", source: "ANA-05.steps", algorithmVersion: "activity.v1"),
            BodyMetricValue(id: .energy, title: "Active energy", value: nil, unit: "kcal", state: .absent,
                            confidence: "Add your age, height and weight to your profile to see this", source: "ANA-05.energy", algorithmVersion: "activity.v1")
        ]
        return BodyDaySnapshot(day: day, state: .partial, metrics: metrics,
            composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "Your profile"),
            cardioAge: nil, looprAge: nil, source: "ANA-05/ANA-07 canonical", algorithmVersion: "activity.v1", zoneMinutes: zoneMinutes,
            cardioFitness: BodyCardioFitness(estimate: nil, gap: .needsAge, nightsRemaining: 2, age: nil, referenceGroup: nil))
    }

    public static var allStates: [(state: MetricState, snapshot: BodyDaySnapshot)] {
        MetricState.allCases.map { (state: $0, snapshot: snapshot(for: $0)) }
    }

    public static var populated: BodyDaySnapshot { snapshot(for: .partial) }
}
