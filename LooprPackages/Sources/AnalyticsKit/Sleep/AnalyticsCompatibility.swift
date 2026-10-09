import Foundation

// ANA-03..06 code uses the concise `inputs:` spelling while the existing
// AnalyticsKit core contract exposes the persisted field as `inputsUsed`.
// Keep this adapter local to the analytics family additions; it does not
// introduce a second metric or tier type.
public extension AnalyticsMetric {
    init(
        value: Value?,
        confidence: Double,
        tier: AnalyticsTier,
        inputs: [String],
        drivers: [AnalyticsDriver] = [],
        note: String? = nil,
        algorithmVersion: String
    ) {
        self.init(
            value: value,
            confidence: confidence,
            tier: tier,
            inputsUsed: inputs,
            drivers: drivers,
            note: note,
            algorithmVersion: algorithmVersion
        )
    }

    static func absent(
        tier: AnalyticsTier,
        inputs: [String],
        note: String? = nil,
        algorithmVersion: String
    ) -> Self {
        Self(
            value: nil,
            confidence: 0,
            tier: tier,
            inputsUsed: inputs,
            drivers: nil,
            note: note,
            algorithmVersion: algorithmVersion
        )
    }
}

public extension AnalyticsMath {
    /// Population SD is the appropriate within-window dispersion for staging
    /// and minute-level intensity estimates; it also gives a stable zero for
    /// a constant window so callers can abstain explicitly.
    static func standardDeviation(_ values: [Double]) -> Double? {
        populationStandardDeviation(values)
    }
}
