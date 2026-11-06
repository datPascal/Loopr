import Foundation

/// One lab value with the draw it came from. The engine needs the draw day to hold the nine inputs together.
public struct PhenoAgeReading: Sendable, Equatable {
    public let value: LabValue
    public let collectedAt: Date
    public let timeZoneIdentifier: String

    public init(value: LabValue, collectedAt: Date, timeZoneIdentifier: String) {
        self.value = value
        self.collectedAt = collectedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(value: LabValue, report: LabReport) {
        self.init(value: value, collectedAt: report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier)
    }
}

public struct PhenoAgeInputs: Sendable, Equatable {
    /// Any readings; values for other markers are ignored.
    public let readings: [PhenoAgeReading]
    /// Age in years at the draw date, with its fraction. See `PhenoAge.chronologicalAgeYears`.
    public let chronologicalAgeYears: Double

    public init(readings: [PhenoAgeReading], chronologicalAgeYears: Double) {
        self.readings = readings
        self.chronologicalAgeYears = chronologicalAgeYears
    }
}

/// Why blood age is absent. Each case is a fact about the inputs or the sources, never a judgement.
public enum PhenoAgeAbsence: Sendable, Equatable {
    case invalidChronologicalAge
    /// These PhenoAge inputs have no value.
    case missingMarkers([LabMarkerKey])
    /// Two values for one marker on the draw day; Loopr does not choose between them.
    case ambiguousMarker(LabMarkerKey)
    /// The nine inputs are not all from the same local calendar day.
    case notFromOneDraw
    /// The lab printed this input as a limit ("<0.3", ">200"), not an exact number. PhenoAge needs the exact number, so
    /// Loopr does not stand the limit in for it.
    case printedAsLimit(LabMarkerKey)
    /// A unit that cannot be converted to the unit PhenoAge needs, with the converter's typed reason.
    case nonConvertibleUnit(marker: LabMarkerKey, reason: LabUnitError)
    /// A value the formula cannot take: not a number, or not positive where it must be. CRP of zero or below is
    /// always here, never clamped, because the formula takes its logarithm.
    case outOfRangeInput(LabMarkerKey)
    /// The value is outside the range pyaging registers for this input (`PhenoAge.referenceRange(for:)`). Loopr
    /// does not compute from it. This says where the value sits against that range, nothing about the person.
    case outsideReferenceRange(LabMarkerKey)
    /// The coefficient set passed in is not cross-checked (its sources disagree), so no blood age is computed.
    /// `PhenoAgeCoefficients.published` is cross-checked and never returns this.
    case coefficientsUnverified
    case nonFiniteResult
}

public enum PhenoAgeResult: Sendable, Equatable {
    case available(PhenoAgeEstimate)
    case unavailable(PhenoAgeAbsence)

    public var estimate: PhenoAgeEstimate? {
        if case .available(let estimate) = self { return estimate }
        return nil
    }

    public var absence: PhenoAgeAbsence? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// One input as the formula used it, with the value as the lab gave it.
public struct PhenoAgeInputUsed: Sendable, Equatable {
    public let marker: LabMarkerKey
    /// The number in the unit PhenoAge needs. For CRP this is mg/dL before the logarithm.
    public let value: Double
    public let unit: String
    public let sourceValue: Decimal
    public let sourcePrintedValue: String?
    public let sourceUnit: String
    /// The unit-conversion factor citations used, empty when no conversion was needed.
    public let conversionCitations: [String]
    public let reportID: UUID
}

public struct PhenoAgeContribution: Sendable, Equatable {
    public enum Term: Sendable, Equatable {
        case marker(LabMarkerKey)
        /// What remains of `phenotypic age - chronological age` after the nine marker terms: the intercept, the age
        /// term and the mortality-to-years constants together.
        case baselineAndAge
    }

    public let term: Term
    /// The coefficient times the input in the linear predictor. Nil for the baseline term.
    public let linearPredictorTerm: Double?
    /// Years this term adds to the phenotypic age, or for the baseline term the years left over against
    /// chronological age.
    public let years: Double
}

public struct PhenoAgeEstimate: Sendable, Equatable {
    public let version: String
    public let phenotypicAgeYears: Double
    /// The ten-year mortality score from the Gompertz model, between 0 and 1.
    public let mortalityScore: Double
    public let linearPredictor: Double
    public let chronologicalAgeYears: Double
    /// `phenotypicAgeYears - chronologicalAgeYears`. A number, not a verdict.
    public let differenceYears: Double
    public let inputs: [PhenoAgeInputUsed]
    /// The nine marker terms followed by the baseline term. They add up to `differenceYears`.
    ///
    /// Phenotypic age is linear in the linear predictor: `phenotypic age = K + xb / divisor`. A marker's term is
    /// `coefficient * input / divisor` years, absolute and not measured against any reference group, because no
    /// cited reference population is bundled. The baseline term takes the rest of the gap to chronological age.
    public let contributions: [PhenoAgeContribution]
    public let coefficientsVerification: PhenoAgeCoefficients.Verification
}

public enum PhenoAge {
    public static let version = "loopr.phenoage.1"

    /// The nine inputs and the unit each is converted to before the formula (see `LabUnitConverter.phenoAgeUnit`).
    public static let inputMarkers: [LabMarkerKey] = LabMarkerCatalog.phenoAgeInputs.map(\.key)

    /// Computes phenotypic age, or says why it is absent.
    ///
    /// The nine PhenoAge markers must each have exactly one reading, all from the same local calendar day (each in
    /// its own report's time zone). Each is converted with `LabUnitConverter.phenoAgeValue`. Checks run in this order and
    /// the first failure is returned: age, missing markers, duplicates, one draw day, then for each input a result
    /// printed as a limit, its unit and its value (not a number, not positive, or outside the reference range), and
    /// last the coefficients' verification. Nothing is clamped or filled in: a result printed "<0.3" is not taken as 0.3.
    public static func calculate(
        inputs: PhenoAgeInputs,
        coefficients: PhenoAgeCoefficients = .published
    ) -> PhenoAgeResult {
        guard inputs.chronologicalAgeYears.isFinite, inputs.chronologicalAgeYears > 0,
              inputs.chronologicalAgeYears <= oldestRegisteredAgeYears else {
            return .unavailable(.invalidChronologicalAge)
        }

        var chosen: [LabMarkerKey: PhenoAgeReading] = [:]
        var duplicate: LabMarkerKey?
        for reading in inputs.readings {
            guard case .marker(let key) = reading.value.subject, inputMarkers.contains(key) else { continue }
            if chosen[key] != nil {
                duplicate = duplicate ?? key
            } else {
                chosen[key] = reading
            }
        }
        let missing = inputMarkers.filter { chosen[$0] == nil }
        if !missing.isEmpty { return .unavailable(.missingMarkers(missing)) }
        if let duplicate { return .unavailable(.ambiguousMarker(duplicate)) }

        let days = inputMarkers.map { key in
            chosen[key].flatMap { LabCalendar.day(of: $0.collectedAt, timeZoneIdentifier: $0.timeZoneIdentifier) }
        }
        guard !days.contains(where: { $0 == nil }), Set(days).count == 1 else {
            return .unavailable(.notFromOneDraw)
        }

        var used: [PhenoAgeInputUsed] = []
        for key in inputMarkers {
            guard let reading = chosen[key] else { continue }
            guard reading.value.comparator == nil else { return .unavailable(.printedAsLimit(key)) }
            let conversion: LabConversion
            do {
                conversion = try LabUnitConverter.phenoAgeValue(reading.value)
            } catch let error as LabUnitError {
                return .unavailable(.nonConvertibleUnit(marker: key, reason: error))
            } catch {
                return .unavailable(.nonConvertibleUnit(marker: key, reason: .unknownUnit(reading.value.unit ?? "")))
            }
            let number = NSDecimalNumber(decimal: conversion.value).doubleValue
            guard isAcceptable(number, for: key) else { return .unavailable(.outOfRangeInput(key)) }
            guard referenceRange(for: key).contains(number) else { return .unavailable(.outsideReferenceRange(key)) }
            used.append(PhenoAgeInputUsed(
                marker: key, value: number, unit: conversion.unit, sourceValue: conversion.sourceValue,
                sourcePrintedValue: conversion.sourcePrintedValue, sourceUnit: conversion.sourceUnit,
                conversionCitations: conversion.citations, reportID: reading.value.reportID))
        }

        guard coefficients.isVerified else { return .unavailable(.coefficientsUnverified) }
        return evaluate(inputs: inputs, used: used, coefficients: coefficients)
    }

    /// The formula applied to already validated inputs.
    static func evaluate(inputs: PhenoAgeInputs, used: [PhenoAgeInputUsed], coefficients: PhenoAgeCoefficients) -> PhenoAgeResult {
        var terms: [(LabMarkerKey, Double)] = []
        for input in used {
            guard let beta = coefficients.markerCoefficients[input.marker] else { return .unavailable(.coefficientsUnverified) }
            let x = input.marker == .crp ? log(input.value) : input.value
            terms.append((input.marker, beta * x))
        }
        let linearPredictor = coefficients.intercept
            + terms.reduce(0) { $0 + $1.1 }
            + coefficients.ageCoefficient * inputs.chronologicalAgeYears
        guard let age = phenotypicAge(linearPredictor: linearPredictor, coefficients: coefficients),
              let mortality = mortalityScore(linearPredictor: linearPredictor, coefficients: coefficients),
              age.isFinite else {
            return .unavailable(.nonFiniteResult)
        }

        var contributions = terms.map {
            PhenoAgeContribution(term: .marker($0.0), linearPredictorTerm: $0.1, years: $0.1 / coefficients.divisor)
        }
        let difference = age - inputs.chronologicalAgeYears
        contributions.append(PhenoAgeContribution(
            term: .baselineAndAge, linearPredictorTerm: nil,
            years: difference - contributions.reduce(0) { $0 + $1.years }))

        return .available(PhenoAgeEstimate(
            version: version, phenotypicAgeYears: age, mortalityScore: mortality, linearPredictor: linearPredictor,
            chronologicalAgeYears: inputs.chronologicalAgeYears, differenceYears: difference, inputs: used,
            contributions: contributions, coefficientsVerification: coefficients.verification))
    }

    /// `offset + (xb + ln(scale * expm1(horizon * gamma) / gamma)) / divisor`, which is
    /// `offset + ln(-scale * ln(1 - mortality)) / divisor` written in log space so a large `xb` cannot overflow.
    static func phenotypicAge(linearPredictor: Double, coefficients c: PhenoAgeCoefficients) -> Double? {
        let logScale = log(c.scale * expm1(c.horizonMonths * c.gamma) / c.gamma)
        let age = c.offsetYears + (linearPredictor + logScale) / c.divisor
        return age.isFinite ? age : nil
    }

    static func mortalityScore(linearPredictor: Double, coefficients c: PhenoAgeCoefficients) -> Double? {
        let cumulativeHazard = exp(linearPredictor) * expm1(c.horizonMonths * c.gamma) / c.gamma
        let score = -expm1(-cumulativeHazard)
        return score.isNaN ? nil : score
    }

    /// The range pyaging registers for each input, in the unit PhenoAge uses, ends included. Source: pyaging
    /// `src/pyaging/data/feature_ranges.json` at commit c15cf28347f5b7a984646a16f5f01b95a1e15c20 (package 0.5.7), the
    /// `features` entries albumin, creatinine, glucose, c_reactive_protein, lymphocyte_percent, mean_cell_volume,
    /// red_cell_distribution_width, alkaline_phosphatase and white_blood_cell_count. The file gives the numbers and
    /// units and no further description, so Loopr names them "pyaging's registered range", not a training range.
    public static func referenceRange(for marker: LabMarkerKey) -> ClosedRange<Double> {
        switch marker {
        case .albumin: 10...70
        case .creatinine: 10...3000
        case .glucose: 1...60
        case .crp: 0.01...50
        case .lymphocytePercent: 0...100
        case .meanCellVolume: 40...150
        case .redCellDistributionWidth: 8...40
        case .alkalinePhosphatase: 5...5000
        case .whiteBloodCellCount: 0.05...500
        default: -Double.infinity...Double.infinity
        }
    }

    /// The oldest age pyaging registers (122.5 years). Older input is treated as an invalid age.
    static let oldestRegisteredAgeYears = 122.5

    private static func isAcceptable(_ number: Double, for marker: LabMarkerKey) -> Bool {
        guard number.isFinite else { return false }
        switch marker {
        case .lymphocytePercent: return number >= 0 && number <= 100
        default: return number > 0
        }
    }

    /// Age in years at `date`, with the fraction of the year since the last birthday, in `timeZone`.
    /// Returns nil when the date of birth is after `date`.
    public static func chronologicalAgeYears(dateOfBirth: Date, on date: Date, timeZone: TimeZone) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let completed = RealAgeCalculator().completedYears(dateOfBirth: dateOfBirth, on: date, timeZone: timeZone),
              let lastBirthday = calendar.date(byAdding: .year, value: completed, to: calendar.startOfDay(for: dateOfBirth)),
              let nextBirthday = calendar.date(byAdding: .year, value: completed + 1, to: calendar.startOfDay(for: dateOfBirth)),
              let elapsed = calendar.dateComponents([.day], from: lastBirthday, to: calendar.startOfDay(for: date)).day,
              let span = calendar.dateComponents([.day], from: lastBirthday, to: nextBirthday).day,
              elapsed >= 0, span > 0 else { return nil }
        return Double(completed) + Double(elapsed) / Double(span)
    }
}
