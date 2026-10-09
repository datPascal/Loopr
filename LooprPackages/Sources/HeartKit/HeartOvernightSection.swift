import AnalyticsKit
import DesignSystem
import SwiftUI

/// Display-only interpretation of the cached assessment. No vitals are re-derived here.
struct HeartOvernightPresentation {
    let snapshot: HeartDaySnapshot

    static let rowOrder: [OvernightVitalMetric] = [.heartRateVariability, .restingHeartRate, .respiratoryRate, .skinTemperatureDeviation]

    var assessment: OvernightVitalsAssessment? { snapshot.vitals?.assessment }
    var summary: String {
        guard let assessment else {
            return OvernightVitalMetric.monitored.contains { reading($0) != nil } ? "Learning your usual range" : "No overnight readings"
        }
        let outside = OvernightVitalMetric.monitored.compactMap { signal($0)?.outlier }.count
        if outside > 0 { return LooprSignalFormatting.outsideRangeHeadline(count: outside) }
        if OvernightVitalMetric.monitored.allSatisfy({ signal($0)?.state == .within }) { return "All within your usual range" }
        if assessment.signals.allSatisfy({ $0.state == .unavailable }) { return "No overnight readings" }
        if assessment.signals.contains(where: { $0.state == .learning }) { return "Learning your usual range" }
        return "Available signals within your usual range"
    }

    var explanation: String? {
        if summary == "No overnight readings" {
            return "Wear your band overnight and sync in the morning."
        }
        if OvernightVitalMetric.monitored.contains(where: { signal($0)?.outlier != nil }) {
            return "Alcohol, late meals, a hot room, hard training or travel can shift these readings. Watch how they change over the next few nights."
        }
        guard assessment == nil || assessment?.signals.contains(where: { $0.state == .learning }) == true else { return nil }
        return "Each signal needs 14 nights with a reading for its usual range."
    }

    func signal(_ metric: OvernightVitalMetric) -> OvernightVitalAssessment? {
        assessment?.signals.first { $0.metric == metric }
    }

    func reading(_ metric: OvernightVitalMetric) -> Double? {
        if let signal = signal(metric) {
            return metric == .skinTemperatureDeviation ? signal.delta : signal.value
        }
        let id: HeartMetricID? = switch metric {
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariability: .rmssd
        case .respiratoryRate: .respiration
        default: nil
        }
        return id.flatMap { snapshot.metric($0)?.numericValue }
    }

    func detail(_ metric: OvernightVitalMetric) -> String {
        guard let signal = signal(metric) else {
            return reading(metric) == nil ? "No reading" : "Usual range unavailable"
        }
        switch signal.state {
        case .within: return "Within your usual range"
        case .above: return "Above your usual range"
        case .below: return "Below your usual range"
        case .learning:
            return LooprLearningText.progress(have: signal.scorableNights, need: signal.requiredNights)
        case .unavailable:
            return signal.scorableNights > 0 && signal.scorableNights < signal.requiredNights
                ? LooprLearningText.progress(have: signal.scorableNights, need: signal.requiredNights) : "No reading"
        }
    }

    func formattedValue(_ metric: OvernightVitalMetric) -> String? {
        guard let value = reading(metric) else { return nil }
        if metric == .skinTemperatureDeviation {
            return LooprSignalFormatting.temperatureChange(value)
        }
        return LooprUnitFormatter.number(value, digits: metric == .respiratoryRate ? 1 : 0)
    }

    func comparison(_ metric: OvernightVitalMetric) -> String? {
        guard let signal = signal(metric), signal.state != .unavailable, signal.state != .learning,
              let difference = signal.delta else { return nil }
        if metric == .skinTemperatureDeviation { return nil }
        let digits = metric == .respiratoryRate ? 1 : 0
        return LooprSignalFormatting.comparison(change: difference, unit: Self.unit(metric), digits: digits)
    }

    /// A model or fit reason is distinct from the card's general sync instruction.
    func missingHint(_ metric: OvernightVitalMetric) -> String? {
        guard metric == .skinTemperatureDeviation, reading(metric) == nil,
              signal(metric)?.state != .learning else { return nil }
        return snapshot.vitals?.skinTemperature.missingReason
    }

    static func linkID(_ metric: OvernightVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .heartRateVariability: LooprMetricLinkID.rmssd
        case .respiratoryRate: LooprMetricLinkID.respiratoryRate
        case .skinTemperatureDeviation: LooprMetricLinkID.skinTemperatureDeviation
        case .oxygenSaturation: LooprMetricLinkID.oxygenSaturation
        }
    }

    static func unit(_ metric: OvernightVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "br/min"
        case .skinTemperatureDeviation: "°C"
        case .oxygenSaturation: "%"
        }
    }
}

struct HeartOvernightSection: View {
    let snapshot: HeartDaySnapshot
    let title: String

    var body: some View {
        let presentation = HeartOvernightPresentation(snapshot: snapshot)
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
                LooprText(presentation.summary, style: .cardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation = presentation.explanation {
                    LooprText(explanation, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(HeartOvernightPresentation.rowOrder, id: \.self) { metric in
                    HeartOvernightRow(presentation: presentation, metric: metric)
                    if metric != HeartOvernightPresentation.rowOrder.last {
                        Divider().overlay(Color.loopr(.divider)).accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heart-vitals-section")
    }
}

private struct HeartOvernightRow: View {
    @Environment(\.looprMetricLink) private var metricLink
    let presentation: HeartOvernightPresentation
    let metric: OvernightVitalMetric

    private var linkID: String { HeartOvernightPresentation.linkID(metric) }
    private var unit: String { HeartOvernightPresentation.unit(metric) }
    private var signal: OvernightVitalAssessment? { presentation.signal(metric) }
    private var range: LooprContributorRange? {
        guard let signal, let range = signal.usualRange, let value = signal.value else { return nil }
        return .init(value: value, usual: range.low...range.high)
    }

    var body: some View {
        let canOpen = metricLink?.supports(linkID) == true
        LooprOvernightSignalRow(title: metric.name, value: presentation.formattedValue(metric), unit: unit,
            comparison: presentation.comparison(metric) ?? presentation.missingHint(metric), range: range,
            status: [presentation.detail(metric) == "No reading" ? nil : presentation.detail(metric),
                     metric == .skinTemperatureDeviation && signal?.value != nil ? "Not scored" : nil].compactMap { $0 }.joined(separator: " · "),
            accent: .heart, identifier: "heart-vital-\(metric.rawValue)",
            action: canOpen ? { metricLink?.open(linkID) } : nil)
    }
}

/// Technical measurements stay here; their history belongs to metric detail pages.
struct HeartAdvancedSection: View {
    @Environment(\.looprMetricLink) private var metricLink
    let snapshot: HeartDaySnapshot

    static var metricIDs: [HeartMetricID] { [.sdnn, .pNN50, .heartRateDip, .sleepingHeartRate, .maxHeartRate, .frequencyDomain, .quality] }
    static func explanation(_ id: HeartMetricID) -> String {
        switch id {
        case .sdnn: "How widely the time between heartbeats varied overnight. This is a different HRV measure from the one above."
        case .pNN50: "The share of consecutive beat intervals that differed by more than 50 milliseconds."
        case .heartRateDip: "How far your average heart rate fell during sleep compared with waking hours."
        case .sleepingHeartRate: "Your average heart rate across the recorded sleep window."
        case .maxHeartRate: "The highest heart rate recorded on this day."
        case .frequencyDomain: "How beat interval changes are distributed across slower and faster rhythms."
        case .quality: "How much of the recording was clean enough to use."
        default: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprCard {
                VStack(spacing: LooprSpacing.sm) {
                    ForEach(Self.metricIDs.compactMap { snapshot.metric($0) }) { metric in
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            let id = metric.id.metricLinkID
                            LooprContributorRow(title: metric.id == .sdnn ? "HRV (SDNN)" : metric.title,
                                value: metric.value, unit: metric.unit, accent: .heart,
                                identifier: "heart-metric-\(metric.id.rawValue)",
                                action: id.flatMap { id in
                                    metricLink?.supports(id) == true ? { metricLink?.open(id) } : nil
                                })
                            LooprText(Self.explanation(metric.id), style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if metric.value == nil {
                                LooprText("Wear your band overnight and sync in the morning for this reading.", style: .caption, color: .inkSecondary)
                            }
                        }
                        if metric.id != Self.metricIDs.compactMap({ snapshot.metric($0) }).last?.id { Divider() }
                    }
                }
            }
            HeartBeatToBeatSection(summary: snapshot.vitals?.beatToBeat)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("heart-advanced-section")
    }
}
