import Foundation

/// A cited set of average marker values to read a blood age against: "what moved it" compares each of the person's
/// values with this average, never with an optimal value.
public struct PhenoAgeReference: Sendable, Equatable {
    /// Short name for the page, such as "NHANES IV averages".
    public let name: String
    /// Where the numbers are printed.
    public let citation: String
    /// Who the averages describe, as a phrase: "11,432 US adults aged 20 to 84 in NHANES IV".
    public let population: String
    /// Each marker's value in the unit PhenoAge uses (`LabUnitConverter.phenoAgeUnit`). CRP is in mg/dL, before the log.
    public let values: [LabMarkerKey: Double]
    /// Anything a reader must know to check the numbers against the source.
    public let note: String

    /// The weighted means of the 11,432 adults aged 20 to 84 in Liu et al. 2018, PLoS Med 15(12):e1002718, S1 Table
    /// "Characteristics of the study participants, NHANES IV, 1999-2010" (doi 10.1371/journal.pmed.1002718.s005,
    /// SHA-256 cf38b36f12e4cee83a33ae9ca99e4d09f8382ed2b497809df475a65c00158a09). The table labels albumin "mg/dL" and
    /// CRP "g/L"; the printed means (42.7 and 0.4) only fit g/L and mg/dL, the units the formula uses, so they are read
    /// that way.
    public static let liu2018NHANESIV = PhenoAgeReference(
        name: "NHANES IV averages",
        citation: "Liu and colleagues 2018, PLoS Medicine 15(12):e1002718, S1 Table",
        population: "11,432 US adults aged 20 to 84 in NHANES IV, 1999 to 2010",
        values: [
            .albumin: 42.7,
            .creatinine: 75.2,
            .glucose: 5.4,
            .crp: 0.4,
            .lymphocytePercent: 30.0,
            .meanCellVolume: 90.0,
            .redCellDistributionWidth: 12.7,
            .alkalinePhosphatase: 69.4,
            .whiteBloodCellCount: 6.8
        ],
        note: "The table prints albumin as mg/dL and CRP as g/L. The means 42.7 and 0.4 fit g/L and mg/dL, the units the formula uses.")
}

/// One marker's share of a blood age, measured against the reference value.
public struct PhenoAgeMarkerShift: Sendable, Equatable {
    public let marker: LabMarkerKey
    /// The person's value in the unit PhenoAge uses.
    public let value: Double
    public let referenceValue: Double
    public let unit: String
    /// Blood age with the person's value minus blood age with the reference value, everything else unchanged.
    /// PhenoAge is linear in each term, so this is `coefficient * (x - reference) / divisor` (logs for CRP), and the
    /// shifts add up with no remainder.
    public let years: Double
}

/// A blood age split into the reference person's gap at the same age and one shift per marker. The parts add up to
/// `PhenoAgeEstimate.differenceYears`.
public struct PhenoAgeReferenceComparison: Sendable, Equatable {
    public let reference: PhenoAgeReference
    /// The blood age of someone with every marker at the reference value, at the person's age.
    public let referenceBloodAgeYears: Double
    /// `referenceBloodAgeYears - chronologicalAgeYears`: where the formula puts average values at this age.
    public let referenceGapYears: Double
    /// In `PhenoAge.inputMarkers` order.
    public let shifts: [PhenoAgeMarkerShift]

    public var totalYears: Double { referenceGapYears + shifts.reduce(0) { $0 + $1.years } }
}

extension PhenoAgeEstimate {
    /// The estimate read against a reference set. Nil when a marker has no reference value or no coefficient, or the
    /// reference blood age is not finite.
    public func compared(with reference: PhenoAgeReference = .liu2018NHANESIV,
                         coefficients: PhenoAgeCoefficients = .published) -> PhenoAgeReferenceComparison? {
        var shifts: [PhenoAgeMarkerShift] = []
        var predictorShift = 0.0
        for input in inputs {
            guard let beta = coefficients.markerCoefficients[input.marker],
                  let referenceValue = reference.values[input.marker], referenceValue > 0 || input.marker != .crp else { return nil }
            let x = input.marker == .crp ? log(input.value) : input.value
            let r = input.marker == .crp ? log(referenceValue) : referenceValue
            let term = beta * (x - r)
            guard term.isFinite else { return nil }
            predictorShift += term
            shifts.append(PhenoAgeMarkerShift(marker: input.marker, value: input.value, referenceValue: referenceValue,
                                              unit: input.unit, years: term / coefficients.divisor))
        }
        guard let referenceAge = PhenoAge.phenotypicAge(linearPredictor: linearPredictor - predictorShift, coefficients: coefficients),
              referenceAge.isFinite else { return nil }
        return PhenoAgeReferenceComparison(reference: reference, referenceBloodAgeYears: referenceAge,
                                           referenceGapYears: referenceAge - chronologicalAgeYears, shifts: shifts)
    }
}
