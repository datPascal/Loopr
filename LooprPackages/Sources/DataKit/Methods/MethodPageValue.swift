import AnalyticsKit
import DesignSystem
import Foundation

/// The "What moved it" chart for a method whose result is a sum of terms.
public struct MethodWaterfall: Hashable, Sendable {
    /// What the chart is measured against, such as "years against real age".
    public let detail: String
    public let startLabel: String
    public let model: LooprWaterfallModel
    /// A sentence under the chart that says how to read the terms.
    public let note: String
    public let fractionDigits: Int
    /// The legend's words for a bar that raises the total and one that lowers it.
    public let increaseLabel: String
    public let decreaseLabel: String

    public init(detail: String, startLabel: String, model: LooprWaterfallModel, note: String, fractionDigits: Int,
                increaseLabel: String = "Raises the total", decreaseLabel: String = "Lowers the total") {
        self.detail = detail
        self.startLabel = startLabel
        self.model = model
        self.note = note
        self.fractionDigits = fractionDigits
        self.increaseLabel = increaseLabel
        self.decreaseLabel = decreaseLabel
    }

    /// Blood age against real age, read against a cited average (`PhenoAgeReference.liu2018NHANESIV`). The first bar
    /// is where the formula puts someone your age with every marker at the average; each next bar is one marker, your
    /// blood age minus the blood age with that marker at the average. PhenoAge is linear in each term, so the bars add
    /// up to `differenceYears` with nothing left over. Nil when the comparison cannot be made.
    public static func phenoAge(_ estimate: PhenoAgeEstimate,
                                reference: PhenoAgeReference = .liu2018NHANESIV) -> MethodWaterfall? {
        guard let comparison = estimate.compared(with: reference) else { return nil }
        let average = LooprWaterfallStep(id: "reference", label: "Average values at your age", value: comparison.referenceGapYears)
        let markers = comparison.shifts.map { shift in
            LooprWaterfallStep(id: shift.marker.rawValue, label: phenoAgeLabel(shift), value: shift.years)
        }
        return MethodWaterfall(
            detail: "years against real age", startLabel: "Real age",
            model: LooprWaterfallModel(start: estimate.chronologicalAgeYears, steps: [average] + markers, totalLabel: "Blood age"),
            note: phenoAgeNote(reference),
            fractionDigits: 1, increaseLabel: "Adds years", decreaseLabel: "Takes years off")
    }

    /// "Red cell distribution width · 12.9 % · average 12.7".
    static func phenoAgeLabel(_ shift: PhenoAgeMarkerShift) -> String {
        "\(shift.marker.marker.displayName) · \(number(shift.value)) \(shift.unit) · average \(number(shift.referenceValue))"
    }

    static func phenoAgeNote(_ reference: PhenoAgeReference) -> String {
        "Read against averages, not targets. Each marker bar is your blood age minus the blood age you would get with that one marker at the average of \(reference.population), from \(reference.citation). The first bar is where the formula puts someone your age with every marker at that average. The bars add up to your result."
    }

    static func number(_ value: Double) -> String {
        LooprSignedNumber.text(value, fractionLength: 0...(value.magnitude < 0.1 ? 3 : 2), plus: false)
    }

    /// Recovery's signals in score points from a usual morning (50). Only signals that took part are drawn; their points
    /// add up to `score - 50`. Nil when the split has no score or does not explain it.
    public static func recovery(_ split: RecoveryDecomposition) -> MethodWaterfall? {
        guard let score = split.score else { return nil }
        let steps = split.signals.compactMap { share -> LooprWaterfallStep? in
            guard share.status == .used, let points = share.points else { return nil }
            return LooprWaterfallStep(id: share.signal.rawValue, label: Self.label(share.signal), value: points)
        }
        guard !steps.isEmpty, split.agrees(withDisplayedScore: score) else { return nil }
        return MethodWaterfall(
            detail: "points against a usual morning", startLabel: "Usual morning",
            model: LooprWaterfallModel(start: RecoveryDecomposition.neutralScore, steps: steps, totalLabel: "Recovery"),
            note: "Each bar runs from the score before one signal to the score after it, on one scale. 50 is a morning when every signal sits at its usual.",
            fractionDigits: 0, increaseLabel: "Raises the score", decreaseLabel: "Lowers the score")
    }

    static func label(_ signal: RecoverySignal) -> String {
        switch signal {
        case .hrv: "Heart rate variability"
        case .restingHeartRate: "Resting heart rate"
        case .respiratoryRate: "Breathing rate"
        }
    }
}

/// One input as this result used it: the person's value, where it came from, and when.
public struct MethodInputReading: Equatable, Sendable {
    public let name: String
    /// "46 g/L", or "4.6 g/dL, used as 46 g/L" when the formula needed another unit.
    public let value: String
    /// The one source this value came from. Nil when `note` says it instead.
    public let provenance: LooprProvenance?
    /// Beside the chip: how and when, "typed in, 12 Sep". Without a chip: "From your birth year".
    public let note: String?

    public init(name: String, value: String, provenance: LooprProvenance?, note: String?) {
        self.name = name
        self.value = value
        self.provenance = provenance
        self.note = note
    }
}

/// The current value a caller shows at the top of a method page. A method page without one shows no hero.
public struct MethodPageValue: Equatable, Sendable {
    public let value: Double
    public let fractionDigits: Int
    public let provenance: LooprProvenance
    public let qualifier: String?
    public let waterfall: MethodWaterfall?
    /// The inputs this value used, shown instead of the catalog's list of possible sources. Nil keeps the catalog's.
    public let inputs: [MethodInputReading]?

    public init(value: Double, fractionDigits: Int = 0, provenance: LooprProvenance, qualifier: String? = nil,
                waterfall: MethodWaterfall? = nil, inputs: [MethodInputReading]? = nil) {
        self.value = value
        self.fractionDigits = fractionDigits
        self.provenance = provenance
        self.qualifier = qualifier
        self.waterfall = waterfall
        self.inputs = inputs
    }

    /// - Parameter report: the draw the estimate came from, for each input's source and date.
    public static func phenoAge(_ estimate: PhenoAgeEstimate, labName: String? = nil, report: LabReport? = nil) -> MethodPageValue {
        MethodPageValue(value: estimate.phenotypicAgeYears, fractionDigits: 1, provenance: .estimated(method: "PhenoAge"),
                        qualifier: labName ?? report?.labName, waterfall: MethodWaterfall.phenoAge(estimate),
                        inputs: phenoAgeInputs(estimate, labName: labName ?? report?.labName, report: report))
    }

    /// The nine values as the person's report gave them, with the unit the formula used, then the age.
    static func phenoAgeInputs(_ estimate: PhenoAgeEstimate, labName: String?, report: LabReport?) -> [MethodInputReading] {
        let note: String? = report.map { report in
            let how = report.source == .scan ? "scanned" : "typed in"
            return "\(how), \(DataText.day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier))"
        }
        let markers = estimate.inputs.map { input in
            let printed = input.sourcePrintedValue ?? MethodWaterfall.number(NSDecimalNumber(decimal: input.sourceValue).doubleValue)
            let given = "\(printed) \(input.sourceUnit)"
            let used = "\(MethodWaterfall.number(input.value)) \(input.unit)"
            let converted = !input.conversionCitations.isEmpty || input.sourceUnit != input.unit
            return MethodInputReading(name: input.marker.marker.displayName, value: converted ? "\(given), used as \(used)" : given,
                                      provenance: .lab(name: labName ?? ""), note: note)
        }
        let age = MethodInputReading(name: "Age at the blood draw", value: "\(DataText.oneDecimal(estimate.chronologicalAgeYears)) years",
                                     provenance: nil, note: "From your birth year")
        return markers + [age]
    }

    /// Nil when the split withholds a score.
    public static func recovery(_ split: RecoveryDecomposition) -> MethodPageValue? {
        guard let score = split.score else { return nil }
        return MethodPageValue(value: score, provenance: .onThisPhone, waterfall: .recovery(split))
    }
}
