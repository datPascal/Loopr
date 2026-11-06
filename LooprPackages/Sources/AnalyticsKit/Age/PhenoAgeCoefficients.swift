import Foundation

/// How a PhenoAge number compares across the sources it was read from.
public enum PhenoAgeAgreement: String, Sendable, Equatable {
    /// The sources print the same value, apart from the paper's own rounding.
    case agrees
    /// Another source prints a different value, and the primary source (Levine 2018 Supplement 1) settles it.
    /// The record keeps the other value so the difference stays visible; the engine does not use it.
    case otherSourceSuperseded
}

/// One row of the cross-check: a coefficient or constant with what Levine 2018, pyaging and BioAge print for it.
public struct PhenoAgeConstantRecord: Sendable, Equatable {
    public let name: String
    /// The unit the input is in, or nil for a constant.
    public let unit: String?
    /// Levine et al. 2018, Aging 10(4):573-591, Table 1 and Supplement 1 (Table S1 and the conversion section).
    public let levine2018: String
    /// pyaging 0.5.7, `clocks/notebooks/phenoage.ipynb`, commit c15cf28347f5b7a984646a16f5f01b95a1e15c20.
    public let pyaging: String
    /// BioAge `R/phenoage_calc.R`, `orig = TRUE` branch, commit b1f9fc02f086cd4aa74185f2335ab1366082e7fe.
    public let bioAge: String
    /// The equations printed in the 2019 PLoS Med correction to Liu et al. 2018, which share these inputs.
    public let liuCorrection: String
    public let agreement: PhenoAgeAgreement
    public let note: String?
}

/// The Levine 2018 phenotypic age coefficients and constants, with the verification state that decides whether
/// Loopr may show a blood age.
///
/// Primary source: Levine et al. 2018, Aging (Albany NY) 10(4):573-591, Table 1 and Supplement 1
/// (`PhenoAgeCrossCheck.primarySource`): Table S1 for the coefficients, the constant and gamma, and the conversion
/// section for the offset 141.50225, the scale 0.00553 and the divisor 0.090165.
///
/// The linear predictor is
/// `xb = intercept + sum(coefficient * input) + age coefficient * chronological age`,
/// with albumin in g/L, creatinine in µmol/L, glucose in mmol/L, the natural log of CRP in mg/dL, lymphocytes in
/// percent, MCV in fL, RDW in percent, ALP in U/L and WBC in 10^3/µL.
/// The ten-year mortality score is `1 - exp(-exp(xb) * (exp(120 * gamma) - 1) / gamma)`, and
/// `phenotypic age = offsetYears + ln(-scale * ln(1 - mortality)) / divisor`.
public struct PhenoAgeCoefficients: Sendable, Equatable {
    public enum Verification: Sendable, Equatable {
        /// Every value agrees across the paper and both implementations.
        case crossChecked
        /// At least one value differs between sources and none is settled. Blood age stays absent.
        case unverified(disagreement: String)
    }

    public let intercept: Double
    public let markerCoefficients: [LabMarkerKey: Double]
    public let ageCoefficient: Double
    public let gamma: Double
    public let horizonMonths: Double
    public let offsetYears: Double
    public let scale: Double
    public let divisor: Double
    public let verification: Verification

    /// Only the cross-check can produce a verified set; callers outside the module get `published`.
    init(
        intercept: Double,
        markerCoefficients: [LabMarkerKey: Double],
        ageCoefficient: Double,
        gamma: Double = 0.0076927,
        horizonMonths: Double = 120,
        offsetYears: Double = 141.50225,
        scale: Double = 0.00553,
        divisor: Double,
        verification: Verification
    ) {
        self.intercept = intercept
        self.markerCoefficients = markerCoefficients
        self.ageCoefficient = ageCoefficient
        self.gamma = gamma
        self.horizonMonths = horizonMonths
        self.offsetYears = offsetYears
        self.scale = scale
        self.divisor = divisor
        self.verification = verification
    }

    public var isVerified: Bool { verification == .crossChecked }

    /// Levine 2018 Table S1 coefficients to four decimals, the Table S1 constant -19.9067, gamma 0.0076927, and the
    /// conversion constants 141.50225, 0.00553 and 0.090165 from Supplement 1. pyaging 0.5.7 uses the same values and
    /// BioAge's seven-digit coefficients round to them. The 0.09165 divisor in the 2019 PLoS Med correction to Liu et
    /// al. 2018, and in BioAge before 2026-04-02, is superseded by the primary source and is not used.
    public static let published = PhenoAgeCoefficients(
        intercept: -19.9067,
        markerCoefficients: [
            .albumin: -0.0336,
            .creatinine: 0.0095,
            .glucose: 0.1953,
            .crp: 0.0954,
            .lymphocytePercent: -0.0120,
            .meanCellVolume: 0.0268,
            .redCellDistributionWidth: 0.3306,
            .alkalinePhosphatase: 0.0019,
            .whiteBloodCellCount: 0.0554
        ],
        ageCoefficient: 0.0804,
        divisor: 0.090165,
        verification: .crossChecked
    )
}

/// The cross-check of every coefficient and constant against Levine 2018 (Table 1 and Supplement 1), pyaging and
/// BioAge, kept as data so the method page can show it and a test can hold it to `PhenoAgeCoefficients.published`.
public enum PhenoAgeCrossCheck {
    /// The primary source for the intercept, gamma, offset, scale and divisor, and for the Table S1 coefficients.
    public static let primarySource = "Levine ME et al. 2018, Aging (Albany NY) 10(4):573-591, Supplement 1, Europe PMC PMC5940111, file aging-10-101414-s001.pdf, SHA-256 5a0b7bf66f1b08079a9ecaf036a26613c61e00f8a8e35e5c13f9bacb61d7cd2c"

    /// The one value another source prints differently.
    public static let divisorNote = "Supplement 1 prints 0.090165 twice (the conversion section and step 4 of the Gompertz details). The 2019 PLoS Med correction to Liu et al. 2018 prints 0.09165, and BioAge used 0.09165 until 2026-04-02; both are superseded. They differ from the primary source by about 1.6 years for a typical result."

    private static func coefficient(
        _ name: String, _ unit: String, paper: String, pyaging: String, bioAge: String, liu: String, note: String? = nil
    ) -> PhenoAgeConstantRecord {
        PhenoAgeConstantRecord(name: name, unit: unit, levine2018: paper, pyaging: pyaging, bioAge: bioAge,
                               liuCorrection: liu, agreement: .agrees, note: note)
    }

    /// Units: Levine 2018 Table 1 and Table S1 (Europe PMC PMC5940111) and each implementation's input names.
    public static let records: [PhenoAgeConstantRecord] = [
        PhenoAgeConstantRecord(name: "Intercept", unit: nil, levine2018: "-19.9067 (Supplement 1, Table S1 constant)",
            pyaging: "-19.9067", bioAge: "-19.90667", liuCorrection: "-19.907", agreement: .agrees,
            note: "All values round to -19.907."),
        coefficient("Albumin", "g/L", paper: "-0.0336", pyaging: "-0.0336 (albumin, g/L)", bioAge: "-0.03359355 (albumin_gL)", liu: "-0.0336"),
        coefficient("Creatinine", "µmol/L", paper: "0.0095", pyaging: "0.0095 (creatinine)", bioAge: "0.009506491 (creat_umol)", liu: "0.0095"),
        coefficient("Glucose", "mmol/L", paper: "0.1953", pyaging: "0.1953 (glucose)", bioAge: "0.1953192 (glucose_mmol)", liu: "0.1953"),
        coefficient("C-reactive protein, natural log", "mg/dL", paper: "0.0954 (log, mg/dL)", pyaging: "0.0954 (raw mg/dL in, log applied, floored at 0.01 mg/dL)",
                    bioAge: "0.09536762 (lncrp; units not stated in code)", liu: "0.0954 (ln CRP)",
                    note: "Loopr does not floor: a CRP of zero or below leaves blood age absent."),
        coefficient("Lymphocyte percent", "%", paper: "-0.0120", pyaging: "-0.0120", bioAge: "-0.01199984 (lymph)", liu: "-0.0120"),
        coefficient("Mean cell volume", "fL", paper: "0.0268", pyaging: "0.0268", bioAge: "0.02676401 (mcv)", liu: "0.0268"),
        coefficient("Red cell distribution width", "%", paper: "0.3306", pyaging: "0.3306", bioAge: "0.3306156 (rdw)", liu: "0.3306"),
        coefficient("Alkaline phosphatase", "U/L", paper: "0.0019", pyaging: "0.0019", bioAge: "0.001868778 (alp)", liu: "0.00188",
                    note: "Table 1 prints two significant digits. The three finer values differ in the third digit and move a typical result by about 0.01 years."),
        coefficient("White blood cell count", "10^3/µL", paper: "0.0554 (1000 cells/uL)", pyaging: "0.0554", bioAge: "0.05542406 (wbc)", liu: "0.0554"),
        coefficient("Chronological age", "years", paper: "0.0804", pyaging: "0.0804", bioAge: "0.08035356 (age)", liu: "0.0804"),
        PhenoAgeConstantRecord(name: "Gompertz gamma", unit: nil, levine2018: "0.0076927 (Supplement 1, Gompertz details; Table S1 rounds it to 0.0077)",
            pyaging: "0.0076927 (0.0192 in the paper is the Cox penalty, not gamma)", bioAge: "0.007692696", liuCorrection: "0.0076927",
            agreement: .agrees, note: nil),
        PhenoAgeConstantRecord(name: "Mortality horizon", unit: "months", levine2018: "120 months (10 years), Methods text and Supplement 1 CDF(120, xb)",
            pyaging: "120 (expm1(120 * gamma))", bioAge: "1.51714, which is exp(120 * 0.0076927) - 1", liuCorrection: "1.51714",
            agreement: .agrees, note: nil),
        PhenoAgeConstantRecord(name: "Age offset", unit: "years", levine2018: "141.50225 (Supplement 1, conversion section)",
            pyaging: "141.50225", bioAge: "141.50225", liuCorrection: "141.50", agreement: .agrees,
            note: "141.50 is the printed rounding of 141.50225."),
        PhenoAgeConstantRecord(name: "Age scale", unit: nil, levine2018: "0.00553 (Supplement 1, conversion section)",
            pyaging: "0.00553", bioAge: "0.0055305", liuCorrection: "0.00553", agreement: .agrees,
            note: "0.00553 is the printed rounding of 0.0055305; the difference moves a result by about 0.001 years."),
        PhenoAgeConstantRecord(name: "Age divisor", unit: "per year", levine2018: "0.090165 (Supplement 1, conversion section and Gompertz step 4)",
            pyaging: "0.090165", bioAge: "0.090165 since commit 1189096c (2026-04-02); 0.09165 before", liuCorrection: "0.09165",
            agreement: .otherSourceSuperseded, note: divisorNote)
    ]

    /// The records where another source prints a different value that the primary source supersedes.
    public static var supersededRecords: [PhenoAgeConstantRecord] { records.filter { $0.agreement == .otherSourceSuperseded } }
}
