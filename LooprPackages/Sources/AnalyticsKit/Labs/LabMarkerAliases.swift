import Foundation

/// The printed names, English and German, a lab report uses for each catalog marker. The parser matches whole
/// names after `LabNameMatcher.normalise`, so case, accents, spaces and punctuation do not matter. A name is never
/// matched loosely: a spelling that is not listed becomes an "other" value under its printed text.
enum LabMarkerAliases {
    struct Entry: Sendable {
        let marker: LabMarkerKey
        /// The assay note to store with the value (C-reactive protein only).
        let assay: String?
        /// When set, the name maps to the marker only if the printed unit is one of these catalog symbols.
        /// "Lymphozyten" alone is the percentage only when the unit is "%"; with a count unit it is another test.
        let onlyWithUnits: Set<String>?
    }

    private struct Group {
        let marker: LabMarkerKey
        let names: [String]
        var assay: String?
        var onlyWithUnits: Set<String>?
    }

    private static let groups: [Group] = [
        Group(marker: .albumin, names: ["Albumin", "Serum albumin", "Albumin i.S.", "Albumin im Serum"]),
        Group(marker: .creatinine, names: ["Kreatinin", "Kreatinin i.S.", "Creatinin", "Creatinine", "Serum creatinine"]),
        Group(marker: .glucose, names: [
            "Glukose", "Glucose", "Glukose nüchtern", "Glucose nüchtern", "Glukose (nüchtern)", "Glucose (nüchtern)",
            "Nüchternglukose", "Nüchternglucose", "Blutzucker", "Blutzucker nüchtern", "Glucose, fasting", "Glucose fasting",
            "Fasting glucose", "Glucose (fasting)", "Blood glucose", "Glucose, serum"
        ]),
        Group(marker: .crp, names: ["hs-CRP", "hsCRP", "hs CRP", "CRP hochsensitiv", "CRP (hochsensitiv)", "CRP, hochsensitiv",
                                     "High sensitivity CRP", "CRP, high sensitivity", "C-reactive protein, high sensitivity",
                                     "C-reaktives Protein hochsensitiv", "CRP-hs", "CRP hs"], assay: "hs-CRP"),
        Group(marker: .crp, names: ["CRP", "C-reaktives Protein", "C-reactive protein", "C-Reactive Protein", "C reaktives Protein"], assay: "CRP"),
        Group(marker: .lymphocytePercent, names: [
            "Lymphozyten %", "Lymphozyten (%)", "Lymphozyten rel.", "Lymphozyten relativ", "Lymphozyten, relativ",
            "Lymphocytes %", "Lymphocytes (%)", "Lymphocyte %", "Lymphocyte percent", "Lymphocytes, percent", "Lymphocytes, relative"
        ]),
        Group(marker: .lymphocytePercent, names: ["Lymphozyten", "Lymphocytes", "Lymphocyte"], onlyWithUnits: ["%"]),
        Group(marker: .meanCellVolume, names: ["MCV", "Mean corpuscular volume", "Mean cell volume",
                                                "Mittleres korpuskuläres Volumen", "Mittleres Erythrozytenvolumen"]),
        Group(marker: .redCellDistributionWidth, names: ["RDW", "RDW-CV", "RDW CV", "Red cell distribution width",
                                                          "Erythrozytenverteilungsbreite", "Ery-Verteilungsbreite"]),
        Group(marker: .alkalinePhosphatase, names: ["Alkalische Phosphatase", "Alkal. Phosphatase", "Alk. Phosphatase", "AP",
                                                     "ALP", "Alkaline phosphatase", "AP (alkalische Phosphatase)"]),
        Group(marker: .whiteBloodCellCount, names: ["Leukozyten", "Leukozytenzahl", "Leukocyten", "Leucozyten", "WBC",
                                                     "White blood cell count", "White blood cells", "Leukocytes", "Leucocytes",
                                                     "Leukocyte count", "WBC count"]),
        Group(marker: .apoB, names: ["Apolipoprotein B", "Apolipoprotein-B", "Apo B", "ApoB", "Apolipoprotein B100", "Apo B100",
                                      "Apolipoprotein B-100"]),
        Group(marker: .hba1c, names: ["HbA1c", "HbA 1c", "HbA1c (IFCC)", "HbA1c (NGSP)", "Hämoglobin A1c", "Haemoglobin A1c",
                                       "Hemoglobin A1c", "Glykohämoglobin", "Glycated hemoglobin", "Glycohemoglobin", "A1c"]),
        Group(marker: .ldlCholesterol, names: ["LDL-Cholesterin", "LDL Cholesterin", "LDL-Cholesterol", "LDL Cholesterol", "LDL",
                                                "LDL-C", "LDL cholesterol calc", "LDL-Cholesterin (berechnet)"]),
        Group(marker: .hdlCholesterol, names: ["HDL-Cholesterin", "HDL Cholesterin", "HDL-Cholesterol", "HDL Cholesterol", "HDL",
                                                "HDL-C"]),
        Group(marker: .triglycerides, names: ["Triglyzeride", "Triglyzeriden", "Triglyceride", "Triglyceriden", "Triglycerides",
                                               "Triacylglycerin", "TG"]),
        Group(marker: .totalCholesterol, names: ["Cholesterin gesamt", "Cholesterin, gesamt", "Gesamtcholesterin", "Gesamt-Cholesterin",
                                                  "Cholesterin", "Cholesterol", "Total cholesterol", "Cholesterol total",
                                                  "Cholesterol, total"]),
        Group(marker: .lipoproteinA, names: ["Lipoprotein(a)", "Lipoprotein (a)", "Lp(a)", "Lp (a)", "Lipoprotein a"]),
        Group(marker: .fastingInsulin, names: ["Insulin", "Insulin nüchtern", "Insulin (nüchtern)", "Insulin, nüchtern", "Fasting insulin",
                                                "Insulin, fasting", "Insulin (fasting)", "Insulin fasting"]),
        Group(marker: .ferritin, names: ["Ferritin", "Ferritin i.S."]),
        Group(marker: .vitaminD, names: ["25-OH-Vitamin D", "25-OH-Vitamin D3", "25-OH Vitamin D", "25 OH Vitamin D", "25-OH-D",
                                          "25-Hydroxy-Vitamin D", "25-Hydroxyvitamin D", "25-Hydroxy Vitamin D", "25(OH)D",
                                          "Vitamin D 25-OH", "Vitamin D (25-OH)", "Vitamin D3 25-OH", "Vitamin D, 25-hydroxy",
                                          "Vitamin D 25-hydroxy", "Vitamin D (25-hydroxy)", "Vitamin D, 25-Hydroxy"]),
        Group(marker: .tsh, names: ["TSH", "TSH basal", "TSH (basal)", "Thyreotropin", "Thyroid stimulating hormone",
                                     "Thyroid-stimulating hormone"]),
        Group(marker: .alt, names: ["ALT", "GPT", "GPT (ALT)", "ALT (GPT)", "GPT/ALT", "ALT/GPT", "ALAT", "SGPT",
                                     "Alanin-Aminotransferase", "Alanine aminotransferase", "Alanine transaminase"]),
        Group(marker: .ast, names: ["AST", "GOT", "GOT (AST)", "AST (GOT)", "GOT/AST", "AST/GOT", "ASAT", "SGOT",
                                     "Aspartat-Aminotransferase", "Aspartate aminotransferase", "Aspartate transaminase"]),
        Group(marker: .ggt, names: ["Gamma-GT", "Gamma GT", "γ-GT", "GGT", "GGT (Gamma-GT)", "Gamma-GT (GGT)",
                                     "Gamma-Glutamyltransferase", "Gamma-Glutamyl-Transferase", "Gamma-glutamyl transferase"]),
        Group(marker: .egfr, names: ["eGFR", "GFR", "eGFR (CKD-EPI)", "eGFR CKD-EPI", "GFR (CKD-EPI)", "eGFR (MDRD)",
                                      "Glomeruläre Filtrationsrate", "Estimated GFR"]),
        Group(marker: .uricAcid, names: ["Harnsäure", "Harnsaeure", "Uric acid", "Urate"]),
        Group(marker: .hemoglobin, names: ["Hämoglobin", "Haemoglobin", "Hemoglobin", "Hb", "HGB", "Hämoglobin (Hb)"]),
        Group(marker: .platelets, names: ["Thrombozyten", "Thrombozytenzahl", "Thrombocyten", "Thrombocytes", "Platelets",
                                           "Platelet count", "PLT"]),
        Group(marker: .homocysteine, names: ["Homocystein", "Homocysteine", "Homozystein"])
    ]

    static let table: [String: Entry] = {
        var table: [String: Entry] = [:]
        for group in groups {
            let entry = Entry(marker: group.marker, assay: group.assay, onlyWithUnits: group.onlyWithUnits)
            for name in group.names { table[LabNameMatcher.normalise(name)] = entry }
        }
        return table
    }()

    /// Normalised prefixes of every name, to spot the first line of a name that wraps over two lines.
    static let wrappedNamePrefixes: Set<String> = {
        var prefixes = Set<String>()
        for key in table.keys where key.count >= 6 {
            for length in 4..<key.count { prefixes.insert(String(key.prefix(length))) }
        }
        return prefixes
    }()
}

enum LabNameMatcher {
    /// Lower case, accents and ß folded, Greek gamma and the percent sign spelled out, everything but letters and digits removed.
    static func normalise(_ text: String) -> String {
        let spelled = text.lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "γ", with: "gamma")
            .replacingOccurrences(of: "%", with: "pct")
            .folding(options: .diacriticInsensitive, locale: nil)
        return String(spelled.unicodeScalars.filter { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7A) })
    }

    /// The longest run of up to six tokens, starting at `index`, whose normalised join is a known name.
    static func match(_ tokens: [String], from index: Int) -> (entry: LabMarkerAliases.Entry, length: Int)? {
        guard index < tokens.count else { return nil }
        for length in stride(from: min(6, tokens.count - index), through: 1, by: -1) {
            // A symbol such as "<" or "-" normalises to nothing; it must not be taken as the end of a name.
            guard !normalise(tokens[index + length - 1]).isEmpty else { continue }
            let joined = normalise(tokens[index..<(index + length)].joined())
            if let entry = LabMarkerAliases.table[joined] { return (entry, length) }
        }
        return nil
    }
}
