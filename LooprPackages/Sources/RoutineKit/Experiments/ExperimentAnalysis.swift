import DomainKit
import Foundation

/// The four labels, matching DEC-06.4. Strong and Clear claim a difference between the person's own nights. Early
/// says a first look only and never claims one. No change says the whole likely range sits inside the noise band.
public enum ExperimentLabel: String, Codable, CaseIterable, Sendable {
    case strong, clear, early, noChange

    public var title: String {
        switch self {
        case .strong: "Strong"
        case .clear: "Clear"
        case .early: "Early"
        case .noChange: "No change"
        }
    }

    /// Strong and Clear are the labels that say the nights differed.
    public var claimsDifference: Bool { self == .strong || self == .clear }
}

/// What the evidence says before it is given a label.
public enum ExperimentCall: Equatable, Sendable {
    case effect(ExperimentLabel)
    case noChange
    /// The difference sits inside the band but the range is wider than the band, so the nights cannot tell a change
    /// from noise. Loopr shows no label.
    case notCalled
}

public enum ExperimentFavor: String, Sendable {
    /// The difference points the way the person said is better when they fixed the outcome.
    case better
    case worse
}

/// Nights left out, each counted once. A night is counted under the first reason that applies, in this order: it was
/// a washout night, the person did not do the intervention on an on night, Loopr could not tell whether they did, the
/// outcome was absent.
public struct ExperimentExclusions: Equatable, Sendable {
    public let washout: Int
    public let notAdherent: Int
    public let adherenceUnknown: Int
    public let outcomeAbsent: Int
    public var total: Int { washout + notAdherent + adherenceUnknown + outcomeAbsent }
}

public struct ExperimentArmSummary: Equatable, Sendable {
    public let arm: ExperimentArm
    /// Nights that count.
    public let nights: Int
    public let mean: Double?
    public let exclusions: ExperimentExclusions
}

public enum ExperimentState: Equatable, Sendable {
    /// The baseline was too short to learn the person's spread. The experiment cannot report a result.
    case cannotReport(NoiseBand.Shortfall)
    /// Running, and the planned nights are not over.
    case tooEarlyToSay
    /// Over, but an arm has fewer included nights than the minimum.
    case notEnoughNights
    /// Over, enough nights, and the evidence does not support any label.
    case notCalled
    case result(ExperimentLabel)
}

public struct AlsoMoved: Equatable, Sendable {
    public let metric: ExperimentMetric
    public let difference: Double
    public let range: ClosedRange<Double>
    public let favors: ExperimentFavor?
    /// Always true. Another metric moving is shown, never claimed as the outcome.
    public let claimed = false
}

public struct ExperimentReport: Equatable, Sendable {
    public let experimentID: ExperimentID
    public let outcome: ExperimentMetric
    public let state: ExperimentState
    public let on: ExperimentArmSummary
    public let off: ExperimentArmSummary
    /// Mean of on nights minus mean of off nights, once each arm has one included night.
    public let difference: Double?
    /// The likely range of the difference. Present once the planned nights are over and both arms reached the minimum.
    public let range: ClosedRange<Double>?
    /// True when the whole likely range sits beyond the noise band on one side.
    public let rangeOutsideSpread: Bool
    public let noiseBand: NoiseBand
    public let favors: ExperimentFavor?
    public let alsoMoved: [AlsoMoved]
    /// Scheduled nights up to the last complete night.
    public let nightsCompleted: Int
    public let plannedNights: Int
    public let minimumNightsPerArm: Int
    public let stoppedEarly: Bool
    public let policyVersion: String

    public var label: ExperimentLabel? {
        if case .result(let label) = state { return label }
        return nil
    }
    public var spread: Double? { noiseBand.spread }
    /// Included nights across both arms.
    public var includedNights: Int { on.nights + off.nights }
}

public enum ExperimentAnalyzer {
    /// Maps the evidence to a call. Pure, so the mapping is tested on its own.
    ///
    /// - The range inside the band is No change, whatever else is true.
    /// - A difference inside the band, with a range that is not, is not called.
    /// - A difference beyond the band is an effect. Early never claims one, and it is the most an experiment that was
    ///   stopped early can say.
    /// - The whole range beyond the band is Clear. It is Strong when the cautious end of the range is at least
    ///   `strongSpreadMultiple` spreads from zero and each arm has `strongNightsMultiple` times the minimum nights.
    /// - A difference beyond the band whose range still reaches inside it is Early.
    public static func call(difference: Double, range: ClosedRange<Double>, spread: Double, onNights: Int, offNights: Int,
                            minimumNightsPerArm: Int, stoppedEarly: Bool, policy: ExperimentPolicy = .standard) -> ExperimentCall {
        if range.lowerBound >= -spread, range.upperBound <= spread { return .noChange }
        guard abs(difference) > spread else { return .notCalled }
        if stoppedEarly { return .effect(.early) }
        let wholeRangeOutside = range.lowerBound > spread || range.upperBound < -spread
        guard wholeRangeOutside else { return .effect(.early) }
        let cautiousEnd = range.lowerBound > spread ? range.lowerBound : -range.upperBound
        let enoughNights = min(onNights, offNights) >= policy.strongNightsMultiple * minimumNightsPerArm
        if cautiousEnd >= policy.strongSpreadMultiple * spread, enoughNights { return .effect(.strong) }
        return .effect(.clear)
    }

    /// The report for one experiment as of the last complete night.
    ///
    /// - Parameters:
    ///   - nights: the stored nights of this experiment.
    ///   - baseline: the outcome on each night before day 1, by the local day the night started on.
    ///   - otherBaselines: the same for the other metrics in `alsoMetrics`, by metric key.
    ///   - alsoMetrics: metrics to check for "also moved".
    ///   - lastNight: the latest night that is over. The night that starts today is not.
    ///   - seed: for the bootstrap; defaults to a stable seed from the experiment id.
    public static func report(experiment: Experiment, nights: [ExperimentNight], baseline: [DayIdentity: Double],
                              otherBaselines: [String: [DayIdentity: Double]] = [:], alsoMetrics: [ExperimentMetric] = [],
                              lastNight: DayIdentity, policy: ExperimentPolicy = .standard,
                              seed: UInt64? = nil) -> ExperimentReport {
        let start = experiment.start
        let schedule = experiment.schedule
        let seed = seed ?? ExperimentStatistics.seed(for: start.id)
        let completed = schedule.nights.filter { night in
            guard let offset = night.day.days(until: lastNight) else { return false }
            return offset >= 0
        }
        let recorded = Dictionary(nights.map { ($0.day, $0) }, uniquingKeysWith: { _, latest in latest })
        let over = experiment.status != .running
            || (start.lastPlannedDay.days(until: lastNight).map { $0 >= 0 } ?? false)

        func arms(value: (ExperimentNight) -> Double?) -> (on: ArmData, off: ArmData) {
            var onData = ArmData(), offData = ArmData()
            for night in completed {
                let arm: ExperimentArm
                switch night.role {
                case .on: arm = .on
                case .off: arm = .off
                case .washout(let washoutArm):
                    if washoutArm == .on { onData.washout += 1 } else { offData.washout += 1 }
                    continue
                case .outside: continue
                }
                var data = arm == .on ? onData : offData
                if let record = recorded[night.day] {
                    if arm == .on, record.adherence == .missed { data.notAdherent += 1 }
                    else if arm == .on, record.adherence == .unknown { data.adherenceUnknown += 1 }
                    else if let measured = value(record) { data.values.append(measured) }
                    else { data.outcomeAbsent += 1 }
                } else {
                    data.outcomeAbsent += 1
                }
                if arm == .on { onData = data } else { offData = data }
            }
            return (onData, offData)
        }

        let outcomeArms = arms { $0.outcomeValue }
        let onSummary = outcomeArms.on.summary(.on)
        let offSummary = outcomeArms.off.summary(.off)
        let difference: Double? = {
            guard let onMean = onSummary.mean, let offMean = offSummary.mean else { return nil }
            return onMean - offMean
        }()
        func favor(_ difference: Double?, _ benefit: ExperimentBenefit) -> ExperimentFavor? {
            guard let difference, difference != 0 else { return nil }
            return (difference > 0) == (benefit == .higher) ? .better : .worse
        }

        let band = NoiseBand.make(baseline: baseline, startDay: start.startDay, policy: policy)
        let minimum = start.minimumNightsPerArm
        let state: ExperimentState
        var range: ClosedRange<Double>?
        var outside = false
        if let shortfall = band.shortfall {
            state = .cannotReport(shortfall)
        } else if !over {
            state = .tooEarlyToSay
        } else if onSummary.nights < minimum || offSummary.nights < minimum {
            state = .notEnoughNights
        } else if let spread = band.spread, let difference,
                  let interval = ExperimentStatistics.bootstrapInterval(on: outcomeArms.on.values, off: outcomeArms.off.values,
                                                                         seed: seed, resamples: policy.bootstrapResamples,
                                                                         confidence: policy.confidence) {
            range = interval
            outside = interval.lowerBound > spread || interval.upperBound < -spread
            switch call(difference: difference, range: interval, spread: spread, onNights: onSummary.nights,
                        offNights: offSummary.nights, minimumNightsPerArm: minimum,
                        stoppedEarly: experiment.stoppedEarly, policy: policy) {
            case .effect(let label): state = .result(label)
            case .noChange: state = .result(.noChange)
            case .notCalled: state = .notCalled
            }
        } else {
            state = .notEnoughNights
        }

        var moved: [AlsoMoved] = []
        switch state {
        case .result, .notCalled:
            for (index, metric) in alsoMetrics.enumerated() where metric.key != start.outcome.key {
                let metricBand = NoiseBand.make(baseline: otherBaselines[metric.key] ?? [:], startDay: start.startDay, policy: policy)
                guard let spread = metricBand.spread else { continue }
                let both = arms { $0.otherValues[metric.key] }
                guard both.on.values.count >= minimum, both.off.values.count >= minimum,
                      let onMean = ExperimentStatistics.mean(both.on.values),
                      let offMean = ExperimentStatistics.mean(both.off.values),
                      let interval = ExperimentStatistics.bootstrapInterval(
                        on: both.on.values, off: both.off.values, seed: seed &+ UInt64(index + 1),
                        resamples: policy.bootstrapResamples, confidence: policy.confidence) else { continue }
                let metricDifference = onMean - offMean
                let verdict = call(difference: metricDifference, range: interval, spread: spread,
                                   onNights: both.on.values.count, offNights: both.off.values.count,
                                   minimumNightsPerArm: minimum, stoppedEarly: experiment.stoppedEarly, policy: policy)
                if case .effect(let label) = verdict, label.claimsDifference {
                    moved.append(AlsoMoved(metric: metric, difference: metricDifference, range: interval,
                                           favors: favor(metricDifference, metric.benefit)))
                }
            }
        default: break
        }

        return ExperimentReport(
            experimentID: start.id, outcome: start.outcome, state: state, on: onSummary, off: offSummary,
            difference: difference, range: range, rangeOutsideSpread: outside, noiseBand: band,
            favors: favor(difference, start.outcome.benefit), alsoMoved: moved,
            nightsCompleted: completed.count, plannedNights: start.plannedNights,
            minimumNightsPerArm: minimum, stoppedEarly: experiment.stoppedEarly, policyVersion: policy.version)
    }

    private struct ArmData {
        var values: [Double] = []
        var washout = 0
        var notAdherent = 0
        var adherenceUnknown = 0
        var outcomeAbsent = 0

        func summary(_ arm: ExperimentArm) -> ExperimentArmSummary {
            ExperimentArmSummary(
                arm: arm, nights: values.count, mean: ExperimentStatistics.mean(values),
                exclusions: ExperimentExclusions(washout: washout, notAdherent: notAdherent,
                                                 adherenceUnknown: adherenceUnknown, outcomeAbsent: outcomeAbsent))
        }
    }
}
