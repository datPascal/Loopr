import DesignSystem
import Foundation

/// The one status line under the hero legend, and the one-line summary of a finished day. Both are rules over the
/// person's own targets and totals: no score, no judgement, no idea of an "optimal" amount, and alcohol never appears in
/// the status line (UX R1-NEW-04, R2-DES-01, R2-VET-13, R2-NEW-04).
public enum FoodDayStatus {
    /// Names whichever of protein and fibre is furthest behind its target, by the share of the target eaten:
    /// "Fibre is furthest behind at 17 of 35 g." With only one of them behind, or only one with a target, that one:
    /// "Protein is at 82 of 150 g." With both reached, says so. A total that misses some foods says "known".
    ///
    /// Nil with no meal logged, or when neither nutrient has both a target and a known total: nothing logged is not
    /// zero, and a line without a target would have nothing to measure against.
    public static func gapLine(day: FoodDaySummary, proteinTarget: Double?, fibreTarget: Double?) -> String? {
        guard !day.meals.isEmpty else { return nil }
        struct Candidate { let name: String; let value: Double; let target: Double; let complete: Bool }
        let candidates: [Candidate] = [("Protein", FoodNutrient.protein, proteinTarget), ("Fibre", .fibre, fibreTarget)]
            .compactMap { name, nutrient, target in
                let total = day.total(nutrient)
                guard let target, target > 0, target.isFinite, let value = total.knownValue, value.isFinite else { return nil }
                return Candidate(name: name, value: value, target: target, complete: total.isComplete)
            }
        guard !candidates.isEmpty else { return nil }
        let behind = candidates.filter { ($0.target - $0.value).rounded() > 0 }
        guard let furthest = behind.min(by: { $0.value / $0.target < $1.value / $1.target }) else {
            return candidates.count == 2 ? "Protein and fibre have reached their targets."
                : "\(candidates[0].name) has reached its target."
        }
        let amount = "\(number(furthest.value)) of \(number(furthest.target)) g"
        let figure = furthest.complete ? "at \(amount)" : "with \(amount) known"
        return behind.count == 2 ? "\(furthest.name) is furthest behind \(figure)." : "\(furthest.name) is \(figure)."
    }

    /// One line for a finished day, no score: "Protein 82 of 150 g · fibre 18 of 35 g · no alcohol". Alcohol shows
    /// only when it was logged or answered.
    public static func finishedSummary(day: FoodDaySummary, proteinTarget: Double?, fibreTarget: Double?) -> String {
        func grams(_ nutrient: FoodNutrient, _ target: Double?) -> String {
            guard let value = day.total(nutrient).knownValue, value.isFinite else { return "not known" }
            guard let target, target > 0, target.isFinite else { return "\(number(value)) g" }
            return "\(number(value)) of \(number(target)) g"
        }
        var parts = ["Protein \(grams(.protein, proteinTarget))", "fibre \(grams(.fibre, fibreTarget))"]
        if day.logsAlcohol, let units = day.total(.alcoholUnits).knownValue, units.isFinite {
            let shown = units.formatted(.number.precision(.fractionLength(0...1)).locale(LooprUnitFormatter.displayLocale))
            parts.append("\(shown) \(units == 1 ? "unit" : "units") of alcohol")
        } else if day.record?.noAlcoholAt != nil {
            parts.append("no alcohol")
        }
        return parts.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String { LooprUnitFormatter.number(value, digits: 0) ?? "–" }
}
