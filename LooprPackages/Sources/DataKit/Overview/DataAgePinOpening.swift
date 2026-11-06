import DesignSystem
import Foundation

// LV-08b integration: what a tap on a pin of the age ruler opens. Blood age and Cardio Age open their real method
// pages with the pin's current value, so the page shows the same number the ruler does. Blood age also carries its
// PhenoAge terms, and the page draws them as a waterfall. Real age is a birth year, so its pin opens Profile.

public enum DataAgePinOpening: Equatable, Sendable {
    /// The method page, with the pin's value. Nil when the pin is not on the ruler, and the page then explains what
    /// the number needs.
    case method(MethodID, MethodPageValue?)
    /// The birth year in Profile.
    case profile
    /// The blood tests list, where a report is added: blood age is absent because no report holds the nine values.
    case bloodTests
    /// How to get VO₂max readings: Cardio Age is absent because there are too few.
    case vo2MaxGuide
}

extension DataAgeRuler {
    /// True while blood age is absent because no report holds the nine values.
    public var needsBloodTest: Bool {
        switch blood {
        case .absent(.noReport), .absent(.missingMarkers): true
        default: false
        }
    }

    public func opening(for kind: DataAgePinKind) -> DataAgePinOpening {
        switch kind {
        case .blood:
            if needsBloodTest { return .bloodTests }
            if blood.absence == .noBirthYear { return .profile }
            guard let reading = blood.reading else { return .method(.phenoAge, nil) }
            return .method(.phenoAge, MethodPageValue.phenoAge(reading.estimate, labName: reading.report.labName,
                                                               report: reading.report))
        case .cardio:
            if cardio.reading == nil, vo2MaxProgress != nil { return .vo2MaxGuide }
            guard let reading = cardio.reading else { return .method(.cardioAge, nil) }
            let source = reading.median.sourceLabels.first ?? "Apple Health"
            // "25 or younger" at the edge of the reference keeps its words beside the number.
            let isPlain = reading.valueText.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
            let qualifier = isPlain ? "42-day median" : "\(reading.valueText), 42-day median"
            return .method(.cardioAge, MethodPageValue(value: reading.years, provenance: .appleHealth(source: source),
                                                       qualifier: qualifier))
        case .real:
            return .profile
        }
    }

    /// The person's own value for a method page, the one its pin opens with: blood age for PhenoAge, Cardio Age for
    /// its page. "How the numbers work" reads it here too, so the method page and the ruler show one result
    /// (ICP R2-LAB-19). Nil for other pages and while there is no reading.
    public func methodValue(for id: MethodID) -> MethodPageValue? {
        let kind: DataAgePinKind
        switch id {
        case .phenoAge: kind = .blood
        case .cardioAge: kind = .cardio
        default: return nil
        }
        if case .method(_, let value) = opening(for: kind) { return value }
        return nil
    }
}
