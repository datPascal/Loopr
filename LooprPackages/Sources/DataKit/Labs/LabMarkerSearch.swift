import AnalyticsKit
import Foundation

/// Finds a marker in the catalog by the name a lab prints, in English or German. It matches the catalog's own
/// name and the other names labs use ("GPT" for ALT, "Leukozyten" for white blood cells). Accents and case do not
/// matter, and "Harnsaeure" finds the same marker as "Harnsäure".
public enum LabMarkerSearch {
    /// Other names a report prints for each marker, English and German.
    static let aliases: [LabMarkerKey: [String]] = [
        .albumin: ["albumin", "serum albumin"],
        .creatinine: ["kreatinin", "creatinine serum"],
        .glucose: ["glukose", "blutzucker", "nüchternglukose", "nuechternglukose", "blood sugar", "fasting glucose"],
        .crp: ["crp", "hs-crp", "hscrp", "c-reaktives protein", "c-reaktive protein", "c reactive protein"],
        .lymphocytePercent: ["lymphozyten", "lymphozyten %", "lymphocytes", "lymphs"],
        .meanCellVolume: ["mcv", "mittleres erythrozytenvolumen", "erythrozytenvolumen"],
        .redCellDistributionWidth: ["rdw", "rdw-cv", "erythrozytenverteilungsbreite"],
        .alkalinePhosphatase: ["alkalische phosphatase", "ap", "alp", "alk phos"],
        .whiteBloodCellCount: ["leukozyten", "wbc", "white cells", "white blood cells", "leukocytes"],
        .apoB: ["apob", "apo b", "apolipoprotein b"],
        .hba1c: ["hba1c", "a1c", "glykiertes hämoglobin", "glykiertes haemoglobin", "langzeitzucker", "glycated hemoglobin"],
        .ldlCholesterol: ["ldl", "ldl-cholesterin", "ldl cholesterol"],
        .hdlCholesterol: ["hdl", "hdl-cholesterin", "hdl cholesterol"],
        .triglycerides: ["triglyceride", "triglyzeride", "tg", "triglycerides"],
        .totalCholesterol: ["cholesterin", "gesamtcholesterin", "cholesterin gesamt", "total cholesterol"],
        .lipoproteinA: ["lp(a)", "lpa", "lipoprotein a", "lipoprotein(a)"],
        .fastingInsulin: ["insulin", "nüchterninsulin", "nuechterninsulin", "fasting insulin"],
        .ferritin: ["ferritin"],
        .vitaminD: ["vitamin d", "25-oh-vitamin d", "25-hydroxy-vitamin d", "25-oh vitamin d", "vitamin d3", "calcidiol"],
        .tsh: ["tsh", "thyreotropin", "thyroid stimulating hormone"],
        .alt: ["alt", "gpt", "alat", "alt (gpt)", "gpt (alt)"],
        .ast: ["ast", "got", "asat", "ast (got)", "got (ast)"],
        .ggt: ["ggt", "gamma-gt", "gamma gt", "γ-gt", "gamma-glutamyltransferase"],
        .egfr: ["egfr", "gfr", "glomeruläre filtrationsrate", "glomerulaere filtrationsrate"],
        .uricAcid: ["harnsäure", "harnsaeure", "urat", "uric acid"],
        .hemoglobin: ["hämoglobin", "haemoglobin", "hb", "hgb", "hemoglobin"],
        .platelets: ["thrombozyten", "plt", "platelets", "thrombocytes"],
        .homocysteine: ["homocystein", "homocysteine"]
    ]

    /// Lower case, accents removed, edges trimmed.
    public static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every name one marker answers to, folded.
    static func names(of marker: LabMarker) -> [String] {
        ([marker.displayName] + (aliases[marker.key] ?? [])).map(fold)
    }

    /// The markers that match, best match first and catalog order within a rank. An empty query returns the whole
    /// catalog in its own order.
    public static func results(for query: String) -> [LabMarker] {
        let wanted = fold(query)
        guard !wanted.isEmpty else { return LabMarkerCatalog.markers }
        var ranked: [(rank: Int, index: Int, marker: LabMarker)] = []
        for (index, marker) in LabMarkerCatalog.markers.enumerated() {
            var best: Int?
            for name in names(of: marker) {
                let rank: Int?
                if name == wanted { rank = 0 }
                else if name.hasPrefix(wanted) { rank = 1 }
                else if name.contains(" " + wanted) || name.contains("-" + wanted) { rank = 2 }
                else if name.contains(wanted) { rank = 3 }
                else { rank = nil }
                if let rank { best = min(best ?? rank, rank) }
            }
            if let best { ranked.append((best, index, marker)) }
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.marker)
    }
}
