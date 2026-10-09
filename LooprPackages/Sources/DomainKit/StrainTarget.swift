import Foundation

/// The strain range Loopr suggests for a day, worked out from that morning's
/// recovery score. Body draws it on the strain ring and Today draws the same
/// range on its strain ring, so both read this one type.
///
/// ## The mapping
///
/// The range follows the recovery band, with the band edges the rest of
/// Loopr uses (`LooprRecoveryBand`: the score is rounded to a whole number
/// first, then 67 to 100 is high, 34 to 66 is middle, 0 to 33 is low):
///
/// | Recovery | Band   | Suggested strain |
/// |----------|--------|------------------|
/// | 67-100   | high   | 14 to 18         |
/// | 34-66    | middle | 10 to 14         |
/// | 0-33     | low    | 4 to 10          |
///
/// WHOOP describes light as 0 to 9, moderate as 10 to 13, high as 14 to 17,
/// and all out as 18 to 21. It pairs low recovery with light strain, middle
/// with moderate, and high with high or all out. Loopr chooses inclusive
/// suggested ranges around those bands, with shared edges at 10 and 14 and
/// an upper end of 18. These are Loopr's fixed suggestions, not WHOOP's
/// personalised Strain Target algorithm. See
/// https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/ .
/// A step per band, not a slope, keeps the
/// range in step with the ring colour the person already sees: a recovery of
/// 66 and one of 67 land in different bands and get different ranges, exactly
/// as their rings are coloured differently.
///
/// After 42 consecutive recorded days, recent load above 110% of longer-term
/// load lowers both ends by 2. Positive form above 10% widens the top by 2
/// on high recovery only. The recovery score itself is never changed.
///
/// Strain is compared after rounding to one decimal, the precision every
/// screen prints, so a strain shown as "14.0" is inside a range that starts
/// at 14 and a strain shown as "18.1" is above one that ends at 18.
public struct StrainTarget: Equatable, Hashable, Sendable, Codable {
    /// The strain scale every range sits on.
    public static let scale: ClosedRange<Double> = 0...21

    /// The three recovery bands. The cut-offs match `LooprRecoveryBand` in
    /// DesignSystem, which DomainKit cannot import; a BodyKit test keeps the
    /// two in step.
    public enum RecoveryBand: String, CaseIterable, Hashable, Sendable, Codable {
        case low
        case middle
        case high

        /// The whole-number recovery scores in the band, inclusive.
        public var scores: ClosedRange<Int> {
            switch self {
            case .high: 67...100
            case .middle: 34...66
            case .low: 0...33
            }
        }

        /// The band for a 0 to 100 recovery score, or nil without a finite
        /// score. The score is rounded to a whole number and clamped first.
        public init?(recovery: Double?) {
            guard let recovery, recovery.isFinite else { return nil }
            let whole = min(max(Int(recovery.rounded()), 0), 100)
            if Self.high.scores.contains(whole) {
                self = .high
            } else if Self.middle.scores.contains(whole) {
                self = .middle
            } else {
                self = .low
            }
        }

        /// The strain range suggested for a day in this band.
        public var strainRange: ClosedRange<Double> {
            switch self {
            case .high: 14...18
            case .middle: 10...14
            case .low: 4...10
            }
        }
    }

    /// Where a day's strain sits against the range.
    public enum Position: String, Hashable, Sendable, Codable {
        case below
        case within
        case above
    }

    /// The recovery score the range came from, rounded to a whole number.
    public let recovery: Int
    public let band: RecoveryBand

    public var lower: Double { max(Self.scale.lowerBound, band.strainRange.lowerBound + (adjustment == .heavy ? -2 : 0)) }
    public var upper: Double { min(Self.scale.upperBound, band.strainRange.upperBound + (adjustment == .heavy ? -2 : adjustment == .lighter ? 2 : 0)) }
    public var range: ClosedRange<Double> { lower...upper }

    public enum Adjustment: String, Codable, Hashable, Sendable { case heavy, lighter }
    public let adjustment: Adjustment?
    public var reason: String? {
        switch adjustment {
        case .heavy: "Lower because your last 7 days were heavy."
        case .lighter: "More room because your last 7 days were lighter."
        case nil: nil
        }
    }

    /// The suggested range for a recovery score, or nil when there is no
    /// finite score. Without recovery there is nothing honest to suggest.
    public init?(recovery: Double?, trainingLoad: TrainingLoad? = nil) {
        guard let band = RecoveryBand(recovery: recovery), let recovery else { return nil }
        self.band = band
        self.recovery = min(max(Int(recovery.rounded()), 0), 100)
        // Use the same recovery bands as the unadjusted target. A lighter
        // week only widens the top on a high-recovery day, by at most 2.
        if let trainingLoad, trainingLoad.isEstablished,
           let ratio = trainingLoad.ratio, ratio.isFinite, ratio > 1.10 {
            adjustment = .heavy
        } else if let trainingLoad, trainingLoad.isEstablished, band == .high,
                  let form = trainingLoad.relativeForm, form.isFinite, form > 0.10 {
            adjustment = .lighter
        } else { adjustment = nil }
    }

    /// Where `strain` sits against the range, or nil without a finite strain.
    public func position(of strain: Double?) -> Position? {
        guard let strain, strain.isFinite else { return nil }
        let shown = (strain * 10).rounded() / 10
        if shown < lower { return .below }
        if shown > upper { return .above }
        return .within
    }

    /// How far `strain` sits outside the range, on the strain scale, rounded
    /// to one decimal. Zero inside the range, nil without a finite strain.
    public func distance(of strain: Double?) -> Double? {
        guard let strain, strain.isFinite else { return nil }
        let shown = (strain * 10).rounded() / 10
        let raw = shown < lower ? lower - shown : shown > upper ? shown - upper : 0
        return (raw * 10).rounded() / 10
    }

    /// The range as people read it: "14 to 18".
    public var text: String { "\(Int(lower)) to \(Int(upper))" }

    /// The range's ends as shares of the 0 to 21 scale, for drawing it on a
    /// ring or a bar.
    public var fractions: ClosedRange<Double> {
        let span = Self.scale.upperBound - Self.scale.lowerBound
        return (lower - Self.scale.lowerBound) / span...(upper - Self.scale.lowerBound) / span
    }
}
