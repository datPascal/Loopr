import Foundation

/// The body system a marker belongs to. It groups the star map in the Data tab. It says nothing about a value.
public enum LabBodySystem: String, Codable, CaseIterable, Sendable {
    case cardiovascular
    case metabolic
    case inflammation
    case blood
    case kidney
    case liver
    case hormones
    case nutrients

    public var displayName: String {
        switch self {
        case .cardiovascular: "Cardiovascular"
        case .metabolic: "Metabolic"
        case .inflammation: "Inflammation"
        case .blood: "Blood"
        case .kidney: "Kidney"
        case .liver: "Liver"
        case .hormones: "Hormones"
        case .nutrients: "Nutrients"
        }
    }
}

/// Stable keys for the markers Loopr knows by name. The raw value is durable database data: never rename or
/// remove a case, add a new one.
public enum LabMarkerKey: String, Codable, CaseIterable, Sendable, Hashable {
    // The nine PhenoAge inputs (Levine 2018).
    case albumin
    case creatinine
    case glucose
    case crp
    case lymphocytePercent = "lymphocyte-percent"
    case meanCellVolume = "mean-cell-volume"
    case redCellDistributionWidth = "red-cell-distribution-width"
    case alkalinePhosphatase = "alkaline-phosphatase"
    case whiteBloodCellCount = "white-blood-cell-count"
    // The markers this audience tracks.
    case apoB = "apob"
    case hba1c
    case ldlCholesterol = "ldl-cholesterol"
    case hdlCholesterol = "hdl-cholesterol"
    case triglycerides
    case totalCholesterol = "total-cholesterol"
    case lipoproteinA = "lpa"
    case fastingInsulin = "fasting-insulin"
    case ferritin
    case vitaminD = "vitamin-d-25-hydroxy"
    case tsh
    case alt
    case ast
    case ggt
    case egfr
    case uricAcid = "uric-acid"
    case hemoglobin
    case platelets
    case homocysteine

    public var marker: LabMarker { LabMarkerCatalog.marker(for: self) }
}

/// What Loopr knows about one named marker: its name, body system and the units labs commonly print for it.
/// Units are the strings as labs print them, canonical first. Reference ranges are not here on purpose: each
/// lab's own range travels with each value. The catalog never says what is optimal, normal or abnormal.
public struct LabMarker: Sendable, Hashable, Identifiable {
    public let key: LabMarkerKey
    public let displayName: String
    public let bodySystem: LabBodySystem
    /// Units labs commonly report this marker in. The first one is canonical.
    public let units: [String]
    public let isPhenoAgeInput: Bool

    public var id: LabMarkerKey { key }
    public var canonicalUnit: String { units[0] }

    public init(
        key: LabMarkerKey,
        displayName: String,
        bodySystem: LabBodySystem,
        units: [String],
        isPhenoAgeInput: Bool = false
    ) {
        precondition(!units.isEmpty, "A marker needs at least its canonical unit")
        self.key = key
        self.displayName = displayName
        self.bodySystem = bodySystem
        self.units = units
        self.isPhenoAgeInput = isPhenoAgeInput
    }
}

public enum LabMarkerCatalog {
    /// Every marker, in a stable display order. The micro sign in unit strings is U+00B5.
    public static let markers: [LabMarker] = [
        LabMarker(key: .albumin, displayName: "Albumin", bodySystem: .liver, units: ["g/dL", "g/L"], isPhenoAgeInput: true),
        LabMarker(key: .creatinine, displayName: "Creatinine", bodySystem: .kidney, units: ["mg/dL", "µmol/L"], isPhenoAgeInput: true),
        LabMarker(key: .glucose, displayName: "Glucose", bodySystem: .metabolic, units: ["mg/dL", "mmol/L"], isPhenoAgeInput: true),
        LabMarker(key: .crp, displayName: "C-reactive protein", bodySystem: .inflammation, units: ["mg/L", "mg/dL", "nmol/L"], isPhenoAgeInput: true),
        LabMarker(key: .lymphocytePercent, displayName: "Lymphocyte percent", bodySystem: .blood, units: ["%"], isPhenoAgeInput: true),
        LabMarker(key: .meanCellVolume, displayName: "Mean cell volume", bodySystem: .blood, units: ["fL", "µm³"], isPhenoAgeInput: true),
        LabMarker(key: .redCellDistributionWidth, displayName: "Red cell distribution width", bodySystem: .blood, units: ["%"], isPhenoAgeInput: true),
        LabMarker(key: .alkalinePhosphatase, displayName: "Alkaline phosphatase", bodySystem: .liver, units: ["U/L", "µkat/L"], isPhenoAgeInput: true),
        LabMarker(key: .whiteBloodCellCount, displayName: "White blood cell count", bodySystem: .blood, units: ["10^3/µL", "10^9/L"], isPhenoAgeInput: true),
        LabMarker(key: .apoB, displayName: "Apolipoprotein B", bodySystem: .cardiovascular, units: ["mg/dL", "g/L"]),
        LabMarker(key: .hba1c, displayName: "HbA1c", bodySystem: .metabolic, units: ["%", "mmol/mol"]),
        LabMarker(key: .ldlCholesterol, displayName: "LDL cholesterol", bodySystem: .cardiovascular, units: ["mg/dL", "mmol/L"]),
        LabMarker(key: .hdlCholesterol, displayName: "HDL cholesterol", bodySystem: .cardiovascular, units: ["mg/dL", "mmol/L"]),
        LabMarker(key: .triglycerides, displayName: "Triglycerides", bodySystem: .cardiovascular, units: ["mg/dL", "mmol/L"]),
        LabMarker(key: .totalCholesterol, displayName: "Total cholesterol", bodySystem: .cardiovascular, units: ["mg/dL", "mmol/L"]),
        LabMarker(key: .lipoproteinA, displayName: "Lipoprotein(a)", bodySystem: .cardiovascular, units: ["nmol/L", "mg/dL"]),
        LabMarker(key: .fastingInsulin, displayName: "Fasting insulin", bodySystem: .metabolic, units: ["µIU/mL", "mIU/L", "pmol/L"]),
        LabMarker(key: .ferritin, displayName: "Ferritin", bodySystem: .nutrients, units: ["ng/mL", "µg/L", "pmol/L"]),
        LabMarker(key: .vitaminD, displayName: "Vitamin D (25-hydroxy)", bodySystem: .nutrients, units: ["ng/mL", "nmol/L"]),
        LabMarker(key: .tsh, displayName: "TSH", bodySystem: .hormones, units: ["mIU/L", "µIU/mL"]),
        LabMarker(key: .alt, displayName: "ALT", bodySystem: .liver, units: ["U/L", "µkat/L"]),
        LabMarker(key: .ast, displayName: "AST", bodySystem: .liver, units: ["U/L", "µkat/L"]),
        LabMarker(key: .ggt, displayName: "GGT", bodySystem: .liver, units: ["U/L", "µkat/L"]),
        LabMarker(key: .egfr, displayName: "eGFR", bodySystem: .kidney, units: ["mL/min/1.73 m²"]),
        LabMarker(key: .uricAcid, displayName: "Uric acid", bodySystem: .metabolic, units: ["mg/dL", "µmol/L", "mmol/L"]),
        LabMarker(key: .hemoglobin, displayName: "Hemoglobin", bodySystem: .blood, units: ["g/dL", "g/L", "mmol/L"]),
        LabMarker(key: .platelets, displayName: "Platelets", bodySystem: .blood, units: ["10^3/µL", "10^9/L"]),
        LabMarker(key: .homocysteine, displayName: "Homocysteine", bodySystem: .cardiovascular, units: ["µmol/L", "mg/L"])
    ]

    private static let byKey: [LabMarkerKey: LabMarker] = Dictionary(uniqueKeysWithValues: markers.map { ($0.key, $0) })

    public static func marker(for key: LabMarkerKey) -> LabMarker {
        guard let marker = byKey[key] else { preconditionFailure("LabMarkerCatalog is missing \(key.rawValue)") }
        return marker
    }

    /// The marker for a durable key string, or nil when this build does not know it.
    public static func marker(forRawKey rawKey: String) -> LabMarker? {
        LabMarkerKey(rawValue: rawKey).map(marker(for:))
    }

    public static func markers(in system: LabBodySystem) -> [LabMarker] {
        markers.filter { $0.bodySystem == system }
    }

    /// The nine inputs PhenoAge (Levine 2018) needs besides age.
    public static var phenoAgeInputs: [LabMarker] { markers.filter(\.isPhenoAgeInput) }
}
