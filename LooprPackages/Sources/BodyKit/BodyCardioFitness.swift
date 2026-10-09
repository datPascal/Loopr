import Foundation
import SwiftUI
import AnalyticsKit
import DesignSystem

/// The day's cardio fitness inputs as analytics stored them.
public struct BodyCardioFitness: Codable, Equatable, Sendable {
    /// Loopr's resting heart-rate ratio estimate, when there is one.
    public let estimate: HeartRateRatioEstimate?
    /// Why there is no estimate. Nil whenever `estimate` is set.
    public let gap: CardioFitnessGap?
    public let nightsRemaining: Int
    public let age: Int?
    /// Nil when the profile has no biological sex; the level then stays out.
    public let referenceGroup: FriendReferenceGroup?

    public init(estimate: HeartRateRatioEstimate?, gap: CardioFitnessGap?, nightsRemaining: Int, age: Int?,
                referenceGroup: FriendReferenceGroup?) {
        self.estimate = estimate
        self.gap = gap
        self.nightsRemaining = nightsRemaining
        self.age = age
        self.referenceGroup = referenceGroup
    }

    /// Eligible Apple Health values only. Legacy estimates stay archived.
    public func resolve(appleHealth: [HealthKitVO2MaxSample], now: Date,
                        timeZone: TimeZone = .autoupdatingCurrent) -> CardioFitnessResolution? {
        CardioFitnessResolver.resolve(estimate: estimate, appleHealth: appleHealth, age: age,
            group: referenceGroup, now: now, timeZone: timeZone)
    }
}

extension EnvironmentValues {
    /// Apple Health VO2 max samples, set by the app from its Health import.
    /// Empty shows the Apple Health setup guidance.
    @Entry public var bodyAppleHealthVO2Max: [HealthKitVO2MaxSample] = []
}

public struct BodyCardioFitnessPresentation: Equatable, Sendable {
    public let title: String
    public let eyebrow: String?
    public let value: String?
    public let unit: String?
    public let detail: String
    public let state: MetricState
    public let level: CardioFitnessLevel?

    public var accessibilitySummary: String {
        [title, eyebrow, value.map { [$0, unit].compactMap { $0 }.joined(separator: " ") }, detail]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

public enum BodyCardioFitnessPresenter {
    static let title = "Cardio fitness"
    static let unit = "ml/kg/min"

    // Apple documents Outdoor Walk, Outdoor Run and Hiking workouts here:
    // https://support.apple.com/en-us/108790
    public static let empty = BodyCardioFitnessPresentation(title: "Cardio fitness", eyebrow: "From Apple Health",
        value: nil, unit: nil,
        detail: "Cardio fitness needs three Apple Health readings over at least two weeks. An Apple Watch can record one during an outdoor walk, run or hike. Allow Loopr to read cardio fitness in Health settings.",
        state: .absent, level: nil)

    public static func present(_ fitness: BodyCardioFitness, resolution: CardioFitnessResolution?) -> BodyCardioFitnessPresentation {
        if let resolution {
            let value = String(format: "%.0f", resolution.vo2Max)
            let compare: String = if let level = resolution.level {
                "\(level.title) for your age and sex."
            } else if fitness.age != nil, fitness.referenceGroup == nil {
                "Add your sex to your profile to compare with people your age."
            } else {
                "Loopr compares with people aged 20 to 79."
            }
            switch resolution.source {
            case .appleHealth:
                return BodyCardioFitnessPresentation(title: title, eyebrow: "VO₂ max · from Apple Health", value: value, unit: unit,
                    detail: compare, state: .partial, level: resolution.level)
            case .heartRateRatio:
                let range = "\(String(format: "%.0f", resolution.lower ?? resolution.vo2Max)) to \(String(format: "%.0f", resolution.upper ?? resolution.vo2Max))"
                return BodyCardioFitnessPresentation(title: title, eyebrow: "VO₂ max estimate · likely \(range)", value: value, unit: unit,
                    detail: "\(compare) Loopr estimates this from your resting heart rate and age. It can be off by several points, so watch how it moves over weeks, not days.",
                    state: .lowConfidence, level: resolution.level)
            }
        }
        return empty
    }
}

struct BodyCardioFitnessCard: View {
    let presentation: BodyCardioFitnessPresentation

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(presentation.title, style: .cardTitle)
                        if let eyebrow = presentation.eyebrow {
                            LooprText(eyebrow.uppercased(), style: .confidence, color: .inkSecondary)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: LooprSpacing.xs)
                    if let level = presentation.level {
                        StatusChip(level.title, symbol: "figure.run", accent: .brand)
                    }
                }
                if let value = presentation.value {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        LooprText(value, style: .metric, color: .heart)
                        if let unit = presentation.unit {
                            LooprText(unit, style: .metricUnit, color: .inkSecondary)
                        }
                    }
                }
                LooprText(presentation.detail, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
        .accessibilityIdentifier("body-cardio-fitness")
    }
}
