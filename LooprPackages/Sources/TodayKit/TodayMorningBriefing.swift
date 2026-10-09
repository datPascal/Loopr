import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation

/// Deterministic wording shared by Today, its snapshot headline and the recap.
public enum TodayMorningSentence {
    public enum Signal: String, CaseIterable, Sendable { case hrv, restingHeartRate, breathing }
    public struct Driver: Equatable, Sendable {
        public let signal: Signal
        public let change: Double
        public let contribution: Double
        public init(signal: Signal, change: Double, contribution: Double) {
            self.signal = signal; self.change = change; self.contribution = contribution
        }
    }

    public static func make(score: Double, drivers: [Driver], sleepMinutes: Double?, sleepNeed: Double?) -> String {
        guard score.isFinite, (0...100).contains(score) else { return "Recovery needs at least two overnight heart readings with enough history." }
        let shown = score.rounded()
        let positive = shown >= 50
        // Do not name a direction hidden by the printed precision, or a term
        // whose direction disagrees with the value shown beside the hero.
        let eligible = drivers.filter { driver in
            let precision = driver.signal == .breathing ? 10.0 : 1.0
            let change = (driver.change * precision).rounded() / precision
            let goodSign = driver.signal == .hrv ? 1.0 : -1.0
            return change.isFinite && driver.contribution.isFinite && change != 0
                && driver.contribution != 0 && (driver.contribution > 0) == positive
                && (change * goodSign > 0) == (driver.contribution > 0)
        }.sorted {
            abs($0.contribution) == abs($1.contribution)
                ? $0.signal.rawValue < $1.signal.rawValue : abs($0.contribution) > abs($1.contribution)
        }
        var seen: Set<Signal> = []
        let chosen = eligible.filter { seen.insert($0.signal).inserted }.prefix(2)
        let clauses = chosen.map { driver in
            let higher = driver.change > 0
            return switch driver.signal {
            case .hrv: "\(higher ? "higher" : "lower") HRV"
            case .restingHeartRate: "a \(higher ? "higher" : "lower") resting heart rate"
            case .breathing: "a \(higher ? "higher" : "lower") breathing rate"
            }
        }
        let shortSleep = sleepMinutes.flatMap { minutes in
            sleepNeed.map { need in minutes.isFinite && need.isFinite && minutes > 0 && need > 0 && need - minutes >= 60 }
        } ?? false
        guard !clauses.isEmpty else {
            return shortSleep ? "Sleep fell short of your need; this score reflects your overnight heart readings."
                : "This score reflects the available overnight heart readings."
        }
        let subject = clauses.joined(separator: " and ")
        let verb = positive ? "supported" : "lowered"
        if shortSleep, !positive { return "Sleep was short, and \(subject) \(verb) this score." }
        let capitalized = subject.prefix(1).uppercased() + subject.dropFirst()
        return shortSleep ? "\(capitalized) \(verb) this score, while sleep fell short of your need."
            : "\(capitalized) \(verb) this score."
    }

    public static func plan(range: ClosedRange<Double>?, adjustment: StrainTarget.Adjustment? = nil) -> String? {
        guard let range, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound <= 21 else { return nil }
        let low = Int(range.lowerBound.rounded()), high = Int(range.upperBound.rounded())
        let reason = switch adjustment {
        case .heavy: " The range is lower after a heavy week."
        case .lighter: " A lighter week leaves more room today."
        case nil: ""
        }
        return "Keep strain between \(low) and \(high) today." + reason
    }
}

public struct TodayMorningContributor: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: String?
    public let unit: String?
    public let comparison: String?
    public let rangeLabel: String?
    public let isOutside: Bool
    public let contextOnly: Bool
    public let learning: String?
    public let linkID: String
    public var range: LooprContributorRange? = nil
    public var scoringReason: String? = nil

    var statusText: String {
        [rangeLabel, learning, contextOnly ? "Not scored" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum TodayMorningSignals: Equatable, Sendable {
    case hidden
    case empty
    case readings([TodayMorningContributor])

    init(rows: [TodayMorningContributor], stale: Bool) {
        self = rows.contains { $0.value != nil } ? .readings(rows) : stale ? .hidden : .empty
    }

    func subtitle(hasRecovery: Bool) -> String? {
        guard case .readings(let rows) = self, rows.contains(where: { $0.learning != nil }) else { return nil }
        if hasRecovery { return "Usual ranges need 14 nights with a reading." }
        let nights = WellnessAnalytics.readinessCompositeMinBaseline + 1
        return "Recovery can start after \(nights) nights. These ranges need 14."
    }
}

/// Today uses the displayed precision for comparisons, including VoiceOver.
enum TodayMorningComparison {
    static func temperatureChange(_ change: Double) -> String? {
        LooprSignalFormatting.temperatureChange(change)
    }

    static func isSameAsUsual(_ delta: LooprDelta) -> Bool {
        guard case .change(let change) = delta.kind, change.isFinite else { return false }
        let precision: Double = switch delta.format {
        case .number(let digits): pow(10, Double(max(0, digits)))
        case .duration, .percent: 1
        }
        return (abs(change) * precision).rounded() == 0
    }

    static func text(_ delta: LooprDelta) -> String {
        if case .usual = delta.kind { return "In your usual range" }
        if case .learning(let have, let need) = delta.kind {
            return LooprLearningText.progress(have: have, need: need, noun: delta.learningNoun)
        }
        return isSameAsUsual(delta) ? "Same as usual" : delta.text
    }

    static func spoken(_ delta: LooprDelta) -> String {
        if case .usual = delta.kind { return "In your usual range" }
        return isSameAsUsual(delta) ? "Same as usual" : delta.spokenText
    }
}

extension TodayDashboard {
    static func contributors(values: TodayValues, context: TodayDayContext?, calendar: Calendar) -> [TodayMorningContributor] {
        let specs: [(TodayTrackedMetric?, OvernightVitalMetric?, String, String)] = [
            (.hrv, .heartRateVariability, "HRV", LooprMetricLinkID.rmssd),
            (.restingHeartRate, .restingHeartRate, "Resting heart rate", LooprMetricLinkID.restingHeartRate),
            (.respiratoryRate, .respiratoryRate, "Breathing rate", LooprMetricLinkID.respiratoryRate),
            (.sleep, nil, "Sleep", LooprMetricLinkID.sleepDuration),
            (nil, .skinTemperatureDeviation, "Skin temperature", LooprMetricLinkID.skinTemperatureDeviation)
        ]
        return specs.map { tracked, vital, title, link in
            let assessment = context?.overnightAssessment?.signals.first { $0.metric == vital }
            let scoringInput = tracked.flatMap { metric in context?.recovery?.inputs.first { $0.signal.metric == metric } }
            let contextOnly = tracked == .sleep || tracked == nil || scoringInput?.status == .flatBaseline
            let count = assessment?.scorableNights ?? tracked.map {
                (context?.measuredDaysBefore($0, calendar: calendar) ?? 0) + (values.value($0) == nil ? 0 : 1)
            } ?? 0
            let needed = 14
            let learning = count < needed ? LooprLearningText.progress(have: count, need: needed) : nil
            let range = assessment.flatMap { signal -> LooprContributorRange? in
                guard let value = signal.value, let band = signal.usualRange else { return nil }
                return .init(value: value, usual: band.low...band.high)
            }
            if tracked == nil {
                let delta = assessment?.delta
                let text = delta.flatMap(TodayMorningComparison.temperatureChange)
                let label = rangeLabel(assessment?.state)
                return TodayMorningContributor(id: link, title: title, value: text, unit: text == nil ? nil : "°C",
                    comparison: assessment?.value == nil ? context?.temperatureMissingReason : nil,
                    rangeLabel: label, isOutside: assessment?.outlier != nil, contextOnly: assessment?.value != nil, learning: context?.temperatureMissingReason == nil ? learning : nil, linkID: link, range: range)
            }
            let metric = tracked!
            let value = assessment == nil ? values.value(metric) : assessment?.value
            let formatted = value.map(metric.formatted)
            let delta = contributorDelta(metric, value: value, values: values, assessment: assessment)
            let band = value.flatMap { v in values.usual(metric).map { $0.position(of: v) } }
            let label = assessment.map { rangeLabel($0.state) } ?? band.map {
                switch $0 { case .within: "Within your usual range"; case .above: "Above your usual range"; case .below: "Below your usual range" }
            }
            let missing: String = switch metric {
            case .hrv: "No clean HRV last night. Wear your band snugly tonight."
            case .restingHeartRate: "No resting heart rate last night. Sync after sleep."
            case .respiratoryRate: "No clean breathing reading last night. Sync after sleep."
            default: "No sleep synced for this day. Sync after your next night."
            }
            let signedComparison = vital.flatMap { _ in
                LooprSignalFormatting.comparison(change: assessment?.delta, unit: metric.unit ?? "", digits: metric == .respiratoryRate ? 1 : 0)
            }
            let comparison: String? = value == nil ? missing : learning != nil ? nil : signedComparison ?? delta.map(TodayMorningComparison.text)
            return TodayMorningContributor(id: link, title: title, value: formatted?.value, unit: formatted?.unit,
                comparison: comparison,
                rangeLabel: label, isOutside: assessment?.outlier != nil || (band != nil && band != .within),
                contextOnly: contextOnly, learning: learning, linkID: link,
                range: range ?? LooprContributorRange(value: value, band: values.usual(metric)))
        }
    }

    private static func rangeLabel(_ state: OvernightVitalAssessment.State?) -> String? {
        switch state { case .within: "Within your usual range"; case .above: "Above your usual range"; case .below: "Below your usual range"; default: nil }
    }

    static func contributorDelta(_ metric: TodayTrackedMetric, value: Double?, values: TodayValues,
                                 assessment: OvernightVitalAssessment?) -> LooprDelta? {
        guard let value else { return nil }
        if let change = assessment?.delta {
            return LooprDelta(kind: .change(change), higherIsBetter: metric.higherIsBetter,
                unit: metric.unit ?? "", format: metric.deltaFormat)
        }
        if let usual = values.usual(metric)?.center ?? values.context?.recovery?.inputs.first(where: { $0.signal.metric == metric })?.usual {
            return LooprDelta(kind: .change(value - usual), higherIsBetter: metric.higherIsBetter,
                unit: metric.unit ?? "", format: metric.deltaFormat)
        }
        return nil
    }
}
