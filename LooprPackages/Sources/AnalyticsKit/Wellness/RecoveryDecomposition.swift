import Foundation

/// One of the three overnight signals the recovery score is built from.
public enum RecoverySignal: String, Codable, Sendable, CaseIterable {
    case hrv
    case restingHeartRate
    case respiratoryRate

    /// The label `readinessComposite` gives the matching driver.
    var driverLabel: String {
        switch self {
        case .hrv: "HRV"
        case .restingHeartRate: "RHR"
        case .respiratoryRate: "RR"
        }
    }
}

/// A night's reading for one signal and the earlier nights it is compared
/// with, in the signal's own unit (milliseconds, bpm, breaths per minute).
public struct RecoverySignalReading: Sendable, Equatable {
    public let signal: RecoverySignal
    public let value: Double?
    public let baseline: [Double]

    public init(signal: RecoverySignal, value: Double?, baseline: [Double]) {
        self.signal = signal
        self.value = value
        self.baseline = baseline
    }
}

/// How one signal moved the recovery score.
public struct RecoverySignalShare: Codable, Sendable, Equatable {
    public enum Status: Codable, Sendable, Equatable {
        /// The signal took part in the score.
        case used
        /// No reading for this night.
        case noReading
        /// A reading, but too few earlier nights to compare it with.
        case learning(have: Int, need: Int)
        /// A reading and enough nights, but the nights are identical, so no
        /// spread to measure against.
        case flatBaseline
    }

    public let signal: RecoverySignal
    public let status: Status
    /// Last night's reading, in the signal's own unit.
    public let value: Double?
    /// The value the score compares against: the median of the earlier
    /// nights (for HRV, the median on the log scale, turned back into ms).
    public let usual: Double?
    /// Earlier nights with a reading.
    public let baselineNights: Int
    /// The weight the formula gives this signal before renormalising.
    public let nominalWeight: Double
    /// Standardised distance from usual, signed so that positive is good for
    /// recovery. Nil unless `status == .used`.
    public let orientedZ: Double?
    /// This signal's term in the composite: weight times oriented z, divided
    /// by the summed weight of the signals present. The composite is the sum
    /// of these terms, exactly.
    public let contribution: Double?
    /// This signal's share of the distance between 50 (every signal at its
    /// usual) and the score, in score points. The points of all used signals
    /// add up to `score - 50`.
    public let points: Double?
}

/// The recovery score split into its inputs.
///
/// Built by calling the same `readinessComposite` the Today score uses, with
/// the same inputs, so the split is the formula's own and not a separate
/// estimate. The composite z is a weighted mean of each signal's oriented z,
/// so each signal's term in it is exact. The score is a logistic of that
/// composite; points are split in proportion to the terms, which keeps their
/// sum exactly equal to `score - 50`.
public struct RecoveryDecomposition: Codable, Sendable, Equatable {
    /// The 0 to 100 score, or nil when the formula withholds one.
    public let score: Double?
    /// The composite z the score is a logistic of.
    public let compositeZ: Double?
    /// True when the composite is past the smallest worthwhile change, so the
    /// day really differs from usual.
    public let isMeaningful: Bool
    /// True when the formula produced a composite so large it carries no
    /// information (the recent nights are too alike). The score is withheld.
    public let isSaturated: Bool
    public let signals: [RecoverySignalShare]
    /// Earlier nights each signal needs before it counts.
    public let nightsNeeded: Int

    /// Score of a night where every signal sits exactly at its usual.
    public static let neutralScore = 50.0

    public func share(_ signal: RecoverySignal) -> RecoverySignalShare? {
        signals.first { $0.signal == signal }
    }

    /// The most earlier nights any signal with a reading has, for a
    /// "2 of 3 nights" countdown while the score is still learning.
    public var baselineNightsSoFar: Int {
        signals.filter { $0.value != nil && $0.status != .flatBaseline }.map(\.baselineNights).sorted(by: >).dropFirst().first ?? 0
    }

    /// Whether this split explains a score shown elsewhere: the same score
    /// within rounding. A split that does not agree must not be presented as
    /// the reason for that number.
    public func agrees(withDisplayedScore displayed: Double?) -> Bool {
        guard let score, let displayed, displayed.isFinite else { return false }
        return abs(score - displayed) <= 1.0
    }
}

extension WellnessAnalytics {
    /// Splits the recovery score into its three overnight signals.
    ///
    /// Pass raw readings (HRV in milliseconds). HRV is compared on the log
    /// scale, exactly as the Today score does, because RMSSD is log-normal.
    public static func recoveryDecomposition(_ readings: [RecoverySignalReading],
                                             minBaseline: Int = readinessCompositeMinBaseline) -> RecoveryDecomposition {
        func prepared(_ reading: RecoverySignalReading) -> (value: Double?, baseline: [Double]) {
            let baseline = reading.baseline.filter(\.isFinite)
            let value = reading.value.flatMap { $0.isFinite ? $0 : nil }
            guard reading.signal == .hrv else { return (value, baseline) }
            return (value.flatMap { $0 > 0 ? log($0) : nil }, baseline.filter { $0 > 0 }.map { log($0) })
        }
        let ordered = RecoverySignal.allCases.compactMap { signal in readings.first { $0.signal == signal } }
        let inputs: [ReadinessInput] = ordered.map { reading in
            let (value, baseline) = prepared(reading)
            switch reading.signal {
            case .hrv: return .hrv(value, baseline: baseline)
            case .restingHeartRate: return .restingHeartRate(value, baseline: baseline)
            case .respiratoryRate: return .respiration(value, baseline: baseline)
            }
        }
        let composite = readinessComposite(inputs, minBaseline: minBaseline)
        let headline = headlineReadinessScore(composite)
        let compositeZ = composite.value?.compositeZ
        let saturated = composite.value != nil && headline == nil
        let drivers = Dictionary((composite.drivers ?? []).map { ($0.label, $0.contribution) }, uniquingKeysWith: { first, _ in first })

        let signals = zip(ordered, inputs).map { reading, input -> RecoverySignalShare in
            let (value, baseline) = prepared(reading)
            let usual: Double? = AnalyticsMath.median(baseline).map { reading.signal == .hrv ? exp($0) : $0 }
            let status: RecoverySignalShare.Status
            let contribution = drivers[reading.signal.driverLabel]
            if value == nil {
                status = .noReading
            } else if baseline.count < minBaseline {
                status = .learning(have: baseline.count, need: minBaseline)
            } else if WellnessAnalytics.readinessZ(input) == nil {
                status = .flatBaseline
            } else {
                status = .used
            }
            var points: Double?
            if let contribution, let compositeZ, let headline {
                points = compositeZ == 0 ? 0 : (headline - RecoveryDecomposition.neutralScore) * contribution / compositeZ
            }
            let weightShare = input.weight
            return RecoverySignalShare(
                signal: reading.signal,
                status: status,
                value: reading.value.flatMap { $0.isFinite ? $0 : nil },
                usual: usual,
                baselineNights: baseline.count,
                nominalWeight: weightShare,
                orientedZ: contribution.flatMap { term in
                    // term = weight * z / summed weight, so z = term * summed / weight.
                    let summed = ordered.enumerated().reduce(0.0) { total, pair in
                        drivers[pair.element.signal.driverLabel] == nil ? total : total + inputs[pair.offset].weight
                    }
                    return input.weight > 0 ? term * summed / input.weight : nil
                },
                contribution: contribution,
                points: points
            )
        }
        return RecoveryDecomposition(
            score: headline,
            compositeZ: compositeZ,
            isMeaningful: composite.value?.meaningful ?? false,
            isSaturated: saturated,
            signals: signals,
            nightsNeeded: minBaseline
        )
    }
}
