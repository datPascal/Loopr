import Foundation
import SwiftUI
import AnalyticsKit
import DesignSystem

/// Overnight skin temperature as analytics stored it for one day.
public struct HeartSkinTemperatureVital: Codable, Equatable, Sendable {
    /// Settled nightly median in approximate degrees Celsius.
    public let nightlyCelsius: Double?
    public let keptSamples: Int
    public let deviation: SkinTemperatureDeviation
    public let settledFraction: Double?
    public let sleepCoverage: Double?
    public let missingReason: String?

    public init(nightlyCelsius: Double?, keptSamples: Int, deviation: SkinTemperatureDeviation,
                settledFraction: Double? = nil, sleepCoverage: Double? = nil, missingReason: String? = nil) {
        self.nightlyCelsius = nightlyCelsius
        self.keptSamples = keptSamples
        self.deviation = deviation
        self.settledFraction = settledFraction; self.sleepCoverage = sleepCoverage; self.missingReason = missingReason
    }

    public func replacingDeviation(_ deviation: SkinTemperatureDeviation) -> HeartSkinTemperatureVital {
        HeartSkinTemperatureVital(nightlyCelsius: nightlyCelsius, keptSamples: keptSamples, deviation: deviation,
            settledFraction: settledFraction, sleepCoverage: sleepCoverage, missingReason: missingReason)
    }
}

/// The band's own oxygen channels for one night.
public struct HeartOxygenVital: Codable, Equatable, Sendable {
    /// Nil when there was no sleep window to assess.
    public let assessment: OxygenSignalAssessment?
    public let nightlyRatio: Double?
    public let deviation: RelativeOxygenDeviation

    public init(assessment: OxygenSignalAssessment?, nightlyRatio: Double?, deviation: RelativeOxygenDeviation) {
        self.assessment = assessment
        self.nightlyRatio = nightlyRatio
        self.deviation = deviation
    }

    public func replacingDeviation(_ deviation: RelativeOxygenDeviation) -> HeartOxygenVital {
        HeartOxygenVital(assessment: assessment, nightlyRatio: nightlyRatio, deviation: deviation)
    }
}

/// The overnight vitals that sit beside the heart metrics.
public struct HeartVitalsSnapshot: Codable, Equatable, Sendable {
    public let skinTemperature: HeartSkinTemperatureVital
    public let oxygen: HeartOxygenVital
    public let beatToBeat: BeatToBeatSummary?
    public let assessment: OvernightVitalsAssessment?

    public init(skinTemperature: HeartSkinTemperatureVital, oxygen: HeartOxygenVital, beatToBeat: BeatToBeatSummary?, assessment: OvernightVitalsAssessment? = nil) {
        self.skinTemperature = skinTemperature
        self.oxygen = oxygen
        self.beatToBeat = beatToBeat
        self.assessment = assessment
    }

    public func replacing(skinTemperature: HeartSkinTemperatureVital? = nil, oxygen: HeartOxygenVital? = nil, assessment: OvernightVitalsAssessment? = nil) -> HeartVitalsSnapshot {
        HeartVitalsSnapshot(skinTemperature: skinTemperature ?? self.skinTemperature,
            oxygen: oxygen ?? self.oxygen, beatToBeat: beatToBeat, assessment: assessment ?? self.assessment)
    }
}

/// A blood oxygen reading another device wrote to Apple Health.
public struct HeartExternalOxygenReading: Equatable, Sendable {
    /// Saturation in percent, 0...100.
    public let percent: Double
    public let date: Date

    public init(percent: Double, date: Date) {
        self.percent = percent
        self.date = date
    }
}

extension EnvironmentValues {
    /// Set by the app from its Apple Health history. Nil shows the band's own
    /// oxygen state.
    @Entry public var heartAppleHealthOxygen: HeartExternalOxygenReading? = nil
}

/// Everything one vital card shows. Pure, so the wording is testable.
public struct HeartVitalPresentation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let eyebrow: String?
    public let value: String?
    public let unit: String?
    public let detail: String?
    public let state: MetricState

    public init(id: String, title: String, eyebrow: String?, value: String?, unit: String?, detail: String?, state: MetricState) {
        self.id = id
        self.title = title
        self.eyebrow = eyebrow
        self.value = value
        self.unit = unit
        self.detail = detail
        self.state = state
    }

    public var accessibilitySummary: String {
        [title, eyebrow, value.map { [$0, unit].compactMap { $0 }.joined(separator: " ") }, detail]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

public enum HeartVitalsPresenter {
    public static func progress(have: Int, need: Int) -> String { LooprLearningText.progress(have: have, need: need) }

    /// Use the same signed change on metric pages and overnight signal rows.
    public static func signedTenths(_ value: Double) -> String {
        LooprSignalFormatting.temperatureChange(value) ?? "—"
    }

    public static func skinTemperature(_ vital: HeartSkinTemperatureVital?) -> HeartVitalPresentation {
        let id = "heart-vital-skin-temperature", title = "Skin temperature"
        switch vital?.deviation ?? .noReading {
        case .noReading:
            return HeartVitalPresentation(id: id, title: title, eyebrow: nil, value: nil, unit: nil,
                detail: vital?.missingReason ?? "Sleep with your band on. A settled overnight reading appears after your next sync.", state: .absent)
        case .calibrating(let remaining):
            return HeartVitalPresentation(id: id, title: title, eyebrow: progress(have: SkinTemperatureAnalytics.calibrationNights - remaining, need: SkinTemperatureAnalytics.calibrationNights), value: nil, unit: nil,
                detail: "Your change from usual appears after 4 nights with a settled reading.", state: .settling)
        case .available(let value):
            // A jump this big is almost always fit, not skin. Showing the
            // number would invite reading it as a body change.
            if value.likelyFitChange {
                return HeartVitalPresentation(id: id, title: title, eyebrow: "vs your usual", value: nil, unit: nil,
                    detail: "Last night was far from your usual, and a change this large usually means the band sat differently. Loopr leaves the number out.",
                    state: .lowConfidence)
            }
            let detail: String
            let state: MetricState
            if !value.trusted {
                detail = "\(progress(have: value.baselineNights + 1, need: 14)). Your usual range appears after 14 nights."
                state = .settling
            } else if value.outsideUsualRange {
                detail = "Outside your usual range."
                state = .partial
            } else {
                detail = "Within your usual range."
                state = .partial
            }
            return HeartVitalPresentation(id: id, title: title, eyebrow: "vs your usual",
                value: signedTenths(value.deltaCelsius), unit: "°C", detail: detail, state: state)
        }
    }

    public static func oxygen(_ vital: HeartOxygenVital?, appleHealth: HeartExternalOxygenReading?) -> HeartVitalPresentation {
        let id = "heart-vital-blood-oxygen", title = "Blood oxygen"
        if let appleHealth, appleHealth.percent.isFinite, (0...100).contains(appleHealth.percent) {
            return HeartVitalPresentation(id: id, title: title, eyebrow: "From Apple Health",
                value: String(format: "%.0f", appleHealth.percent), unit: "%",
                detail: "Measured by another device. Your band doesn't give a percentage.", state: .partial)
        }
        return HeartVitalPresentation(id: id, title: title, eyebrow: "Not available from this band", value: nil, unit: nil,
            detail: "This band doesn't report blood oxygen. Imported readings appear when available.", state: .unsupportedHardware)
    }

    /// The Heart tab can render the same daily assessment used by Today.
    public static func signal(_ signal: OvernightVitalAssessment) -> HeartVitalPresentation {
        let detail: String
        switch signal.state {
        case .within: detail = "Within your usual range"
        case .above: detail = "Above your usual range"
        case .below: detail = "Below your usual range"
        case .learning: detail = "\(signal.learningProgress). Your usual range appears after \(signal.requiredNights) nights."
        case .unavailable: detail = "No settled reading for this night. Sleep with your band on and sync in the morning."
        }
        let digits = signal.metric == .skinTemperatureDeviation || signal.metric == .respiratoryRate ? 1 : 0
        let unit: String = switch signal.metric {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "br/min"
        case .skinTemperatureDeviation: "°C"
        case .oxygenSaturation: "%"
        }
        let number = signal.metric == .skinTemperatureDeviation ? signal.delta : signal.value
        return .init(id: "heart-vital-\(signal.metric.rawValue)", title: signal.metric.name, eyebrow: nil,
            value: number.map { String(format: "%.*f", digits, $0) }, unit: number == nil ? nil : unit,
            detail: detail, state: signal.value == nil ? .absent : signal.state == .learning ? .settling : .partial)
    }
}
