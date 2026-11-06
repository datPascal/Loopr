import Foundation

/// Why a pair of units has no conversion. A refusal is a typed answer; Loopr never guesses a factor.
public enum LabNoConversionReason: String, Sendable, Equatable {
    /// The two units measure different things, so no fixed factor exists. Lipoprotein(a) in nmol/L counts
    /// particles; in mg/dL it weighs protein whose size differs between people and assays.
    case differentQuantities
    /// A percentage and an absolute count need a second measurement (the white cell count) that a unit
    /// conversion does not have.
    case percentageAgainstAbsoluteCount
    /// The pair is physically convertible, but the molar mass or calibration it depends on varies by assay or
    /// source, and no single factor is cited. Ferritin pmol/L, C-reactive protein nmol/L and haemoglobin mmol/L.
    case noCitedFactor
}

/// How one unit relates to the marker's canonical unit:
/// `value in this unit = value in canonical unit × numerator ÷ denominator + offset`.
struct LabUnitRelation: Sendable {
    let numerator: Decimal
    let denominator: Decimal
    let offset: Decimal
    let citation: String

    func fromCanonical(_ value: Decimal) -> Decimal { value * numerator / denominator + offset }
    func toCanonical(_ value: Decimal) -> Decimal { (value - offset) * denominator / numerator }
}

enum LabUnitLink: Sendable {
    case related(LabUnitRelation)
    case unrelated(LabNoConversionReason)
}

/// A cited factor, listed for the method page.
public struct LabUnitFactor: Sendable, Equatable {
    public let marker: LabMarkerKey
    public let unit: String
    public let canonicalUnit: String
    /// The factor as a sentence, for example "1 mmol/L = 18.016 mg/dL".
    public let statement: String
    public let citation: String
}

/// The unit families, one per marker. Each factor sits beside its citation. A unit that is listed for a marker but
/// absent from its family has no relation to the canonical unit and refuses.
enum LabUnitFamilies {
    private static func d(_ text: String) -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            preconditionFailure("Bad factor literal \(text)")
        }
        return value
    }

    private static func ratio(_ numerator: String, per denominator: String = "1", offset: String = "0", _ citation: String) -> LabUnitLink {
        .related(LabUnitRelation(numerator: d(numerator), denominator: d(denominator), offset: d(offset), citation: citation))
    }

    // MARK: Citations

    private static let labcorp = "Labcorp, SI Unit Conversion Table, labcorp.com/resource/si-unit-conversion-table"
    private static let mayo = "Mayo Clinic Laboratories, SI Unit Conversion, mayocliniclabs.com/order-tests/si-unit-conversion.html"
    private static let schwartzKohl = "Schwartz S, Kohl BA. Diabetes Metab Syndr Obes 2010;3:227-242, Table 1 (conversion table), PMC3047965"
    private static let knopp = "Knopp JL, Holder-Pearson L, Chase JG. Insulin units and conversion factors. J Diabetes Sci Technol 2019;13(3):597-600, PMC6501531"
    private static let hoelzel = "Hoelzel W et al. Clin Chem 2004;50(1):166-174 (NGSP % = 0.0915 x IFCC mmol/mol + 2.15)"
    private static let katal = "IUPAC/IFCC, Pure Appl Chem 2001;73(6):927-931 and CGPM 1999 Resolution 12 (katal): 1 U = 1 µmol/min = 1/60 µmol/s = 16.67 nkat"
    private static let prefixes = "SI prefix arithmetic (1 dL = 0.1 L, 1 g = 1000 mg), no molar mass involved"

    // MARK: Families

    /// The relations for each marker, keyed by the unit symbol used in `LabMarkerCatalog`. A canonical unit
    /// is implied; only the other units are listed. Markers with a single unit have no entry.
    static let families: [LabMarkerKey: [String: LabUnitLink]] = [
        .albumin: [
            // Labcorp lists albumin g/dL x 10 = g/L.
            "g/L": ratio("10", "\(labcorp); \(prefixes)")
        ],
        .creatinine: [
            // Labcorp: serum creatinine mg/dL x 88.4 = µmol/L. Molar mass 113.12 g/mol (PubChem CID 588) gives 88.40.
            "µmol/L": ratio("88.4", "\(labcorp); molar mass of creatinine 113.12 g/mol, PubChem CID 588")
        ],
        .glucose: [
            // Molar mass of D-glucose 180.16 g/mol (PubChem CID 5793): 1 mmol/L = 18.016 mg/dL. Labcorp lists the
            // rounded inverse, glucose mg/dL x 0.0555 = mmol/L.
            "mmol/L": ratio("1", per: "18.016", "Molar mass of D-glucose 180.16 g/mol, PubChem CID 5793; \(labcorp) lists the rounded inverse 0.0555")
        ],
        .crp: [
            // mg/L is canonical. mg/dL = mg/L ÷ 10.
            "mg/dL": ratio("1", per: "10", "\(prefixes); Sciensano EEQ chimie, rapport global 2024-1: CRP mg/dL x 10 = mg/L"),
            // CRP nmol/L is deliberately absent: sources give 8.69 and 9.52 nmol/L per mg/L (different molar masses).
            "nmol/L": .unrelated(.noCitedFactor)
        ],
        .meanCellVolume: [
            "µm³": ratio("1", "SI definition: 1 µm³ = 10^-18 m³ = 10^-15 L = 1 fL")
        ],
        .alkalinePhosphatase: [
            // 1 U/L = 1/60 µkat/L.
            "µkat/L": ratio("1", per: "60", katal)
        ],
        .whiteBloodCellCount: [
            "10^9/L": ratio("1", "SI prefix arithmetic: 10^3/µL = 10^3 x 10^6 /L = 10^9/L; the same count, written differently")
        ],
        .apoB: [
            // 1 g/L = 100 mg/dL, so mg/dL (canonical) = g/L x 100.
            "g/L": ratio("1", per: "100", prefixes)
        ],
        .hba1c: [
            // IFCC mmol/mol = (NGSP % - 2.15) x 10.929 = 10.929 x NGSP % - 23.49735. NGSP's current page uses
            // 0.09148 and 2.152; the two agree within 0.03 mmol/mol from 4 % to 12 %.
            "mmol/mol": ratio("10.929", offset: "-23.49735", "\(hoelzel); NGSP, ngsp.org/ifccngsp.asp (current equation 0.09148 and 2.152); the (% - 2.15) x 10.929 form is the one printed in the German-language pharmacy literature (Pharmazeutische Zeitung 33/2009)")
        ],
        .ldlCholesterol: [
            "mmol/L": ratio("1", per: "38.67", "\(schwartzKohl): TC, LDL-C, HDL-C multiply mmol/L by 38.67; molar mass of cholesterol 386.7 g/mol, PubChem CID 5997; \(labcorp) lists 0.0259")
        ],
        .hdlCholesterol: [
            "mmol/L": ratio("1", per: "38.67", "\(schwartzKohl): TC, LDL-C, HDL-C multiply mmol/L by 38.67; molar mass of cholesterol 386.7 g/mol, PubChem CID 5997; \(labcorp) lists 0.0259")
        ],
        .totalCholesterol: [
            "mmol/L": ratio("1", per: "38.67", "\(schwartzKohl): TC, LDL-C, HDL-C multiply mmol/L by 38.67; molar mass of cholesterol 386.7 g/mol, PubChem CID 5997; \(labcorp) lists 0.0259")
        ],
        .triglycerides: [
            // A triglyceride mixture has no single molar mass; 88.57 is the published convention.
            "mmol/L": ratio("1", per: "88.57", "\(schwartzKohl): triglycerides multiply mmol/L by 88.57; \(labcorp) lists 0.0113")
        ],
        .lipoproteinA: [
            "mg/dL": .unrelated(.differentQuantities)
        ],
        .fastingInsulin: [
            "mIU/L": ratio("1", "\(labcorp): insulin µIU/mL x 1 = mIU/L; the same unit under two names"),
            // Convention: 1 µIU/mL = 6.00 pmol/L. The older factor 6.945 is not used.
            "pmol/L": ratio("6", "\(knopp): 1 µIU/mL = 6.00 pmol/L, and 6.945 'should not be used'; NHANES also converts with 6.0")
        ],
        .ferritin: [
            "µg/L": ratio("1", "\(labcorp): ferritin ng/mL x 1 = µg/L; the same unit under two names"),
            // Ferritin's molar mass depends on its iron content and assay calibration, so pmol/L has no cited factor.
            "pmol/L": .unrelated(.noCitedFactor)
        ],
        .vitaminD: [
            "nmol/L": ratio("2.496", "\(mayo): 25-hydroxyvitamin D (total and D3) CF 2.496; molar mass of 25-hydroxyvitamin D3 400.6 g/mol, PubChem CID 5283731")
        ],
        .tsh: [
            "µIU/mL": ratio("1", "\(labcorp): TSH µIU/mL x 1 = mIU/L; the same unit under two names")
        ],
        .alt: ["µkat/L": ratio("1", per: "60", katal)],
        .ast: ["µkat/L": ratio("1", per: "60", katal)],
        .ggt: ["µkat/L": ratio("1", per: "60", katal)],
        .uricAcid: [
            // 10 000 ÷ 168.11 g/mol (PubChem CID 1175) = 59.48 µmol/L per mg/dL. Labcorp lists the rounded 0.059 mmol/L.
            "µmol/L": ratio("59.48", "Molar mass of uric acid 168.11 g/mol, PubChem CID 1175: 10 000 / 168.11 = 59.48; \(labcorp) lists the rounded 0.059 mmol/L per mg/dL"),
            "mmol/L": ratio("0.05948", "Molar mass of uric acid 168.11 g/mol, PubChem CID 1175: 59.48 µmol/L = 0.05948 mmol/L; \(labcorp) lists the rounded 0.059")
        ],
        .hemoglobin: [
            "g/L": ratio("10", prefixes),
            // Haemoglobin mmol/L depends on whether the monomer or the tetramer is counted (a factor of four);
            // no authoritative factor was found, so the pair refuses.
            "mmol/L": .unrelated(.noCitedFactor)
        ],
        .platelets: [
            "10^9/L": ratio("1", "SI prefix arithmetic: 10^3/µL = 10^9/L; the same count, written differently")
        ],
        .homocysteine: [
            "mg/L": ratio("0.13519", "Molar mass of L-homocysteine 135.19 g/mol, PubChem CID 91552: 1 µmol/L = 0.13519 mg/L")
        ]
    ]

    /// Units that must refuse for a marker even though they are not in its catalog list, with the reason.
    static let knownRefusals: [LabMarkerKey: [String: LabNoConversionReason]] = [
        .lymphocytePercent: [
            "10^9/L": .percentageAgainstAbsoluteCount,
            "10^3/µL": .percentageAgainstAbsoluteCount
        ]
    ]
}
