import Foundation

/// A unit conversion Loopr refused. Every refusal is typed; nothing is guessed.
public enum LabUnitError: Error, Equatable, Sendable {
    /// The printed unit text is not a spelling Loopr knows.
    case unknownUnit(String)
    /// The unit is known but this marker is never reported in it.
    case unitNotListedForMarker(marker: LabMarkerKey, unit: String)
    /// Both units are known for the marker but no conversion exists between them.
    case noConversion(marker: LabMarkerKey, from: String, to: String, reason: LabNoConversionReason)
    /// The value has no printed unit, and Loopr never fills one in.
    case missingUnit
    /// A value for a test outside the catalog has no known units to convert between.
    case otherValueHasNoUnits
    /// The marker is not one of the nine PhenoAge inputs.
    case notAPhenoAgeInput(LabMarkerKey)
}

/// A converted value with where it came from. The number keeps full precision; round it only for display.
public struct LabConversion: Sendable, Equatable {
    public let marker: LabMarkerKey
    public let value: Decimal
    public let unit: String
    public let sourceValue: Decimal
    /// The source digits as printed, when they differ from the plain number ("5.0").
    public let sourcePrintedValue: String?
    public let sourceUnit: String
    /// The factor citations used, empty when the units are the same.
    public let citations: [String]

    public var isUnchanged: Bool { citations.isEmpty }

    /// The converted number rounded to a count of decimal places, for a screen. The stored value is untouched.
    public func rounded(fractionDigits: Int) -> Decimal {
        LabUnitConverter.round(value, fractionDigits: fractionDigits)
    }
}

public enum LabUnitConverter {
    // MARK: Number conversion

    /// Converts `number` of `marker` between two units the catalog lists for it. Pass catalog symbols, or run
    /// printed text through `LabUnitText.symbol(forPrinted:)` first.
    public static func convert(_ number: Decimal, marker: LabMarkerKey, from: String, to: String) throws -> Decimal {
        try path(marker: marker, from: from, to: to).apply(number)
    }

    /// Converts a stored value to another unit, keeping the source digits and the factor citations with it.
    /// A value without a printed unit, and a value for a test outside the catalog, refuse.
    public static func convert(_ value: LabValue, to unit: String) throws -> LabConversion {
        guard case .marker(let marker) = value.subject else { throw LabUnitError.otherValueHasNoUnits }
        guard let printed = value.unit else { throw LabUnitError.missingUnit }
        let from = try symbol(forPrinted: printed)
        let target = try symbol(forPrinted: unit)
        let route = try path(marker: marker, from: from, to: target)
        return LabConversion(marker: marker, value: route.apply(value.value), unit: target,
                             sourceValue: value.value, sourcePrintedValue: value.printedValue,
                             sourceUnit: from, citations: route.citations)
    }

    // MARK: PhenoAge input units

    /// The unit each PhenoAge input is entered in (Levine 2018 and its supplement): albumin g/L, creatinine
    /// µmol/L, glucose mmol/L, C-reactive protein mg/dL (the engine takes the logarithm), lymphocyte percent,
    /// mean cell volume fL, red cell distribution width percent, alkaline phosphatase U/L, white blood cell
    /// count 10^3/µL.
    public static func phenoAgeUnit(for marker: LabMarkerKey) -> String? {
        switch marker {
        case .albumin: "g/L"
        case .creatinine: "µmol/L"
        case .glucose: "mmol/L"
        case .crp: "mg/dL"
        case .lymphocytePercent: "%"
        case .meanCellVolume: "fL"
        case .redCellDistributionWidth: "%"
        case .alkalinePhosphatase: "U/L"
        case .whiteBloodCellCount: "10^3/µL"
        default: nil
        }
    }

    /// The value in the unit PhenoAge needs, or a typed refusal.
    public static func phenoAgeValue(_ value: LabValue) throws -> LabConversion {
        guard case .marker(let marker) = value.subject else { throw LabUnitError.otherValueHasNoUnits }
        guard let unit = phenoAgeUnit(for: marker) else { throw LabUnitError.notAPhenoAgeInput(marker) }
        return try convert(value, to: unit)
    }

    // MARK: Factors for the method page

    /// Every cited factor, one per non-canonical unit that converts.
    public static var factors: [LabUnitFactor] {
        LabMarkerKey.allCases.flatMap { key -> [LabUnitFactor] in
            let canonical = key.marker.canonicalUnit
            return (LabUnitFamilies.families[key] ?? [:]).compactMap { unit, link in
                guard case .related(let relation) = link else { return nil }
                let offset = relation.offset == 0 ? "" : " \(relation.offset < 0 ? "-" : "+") \(abs(relation.offset))"
                let factor = relation.numerator / relation.denominator
                return LabUnitFactor(
                    marker: key, unit: unit, canonicalUnit: canonical,
                    statement: "\(key.marker.displayName): \(unit) = \(canonical) x \(factor)\(offset)",
                    citation: relation.citation)
            }
        }
        .sorted { ($0.marker.rawValue, $0.unit) < ($1.marker.rawValue, $1.unit) }
    }

    // MARK: Rounding

    public static func round(_ value: Decimal, fractionDigits: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, fractionDigits, .plain)
        return result
    }

    // MARK: Routing

    private struct Route {
        let steps: [(Decimal) -> Decimal]
        let citations: [String]
        func apply(_ number: Decimal) -> Decimal { steps.reduce(number) { $1($0) } }
    }

    private static func symbol(forPrinted printed: String) throws -> String {
        guard let symbol = LabUnitText.symbol(forPrinted: printed) else { throw LabUnitError.unknownUnit(printed) }
        return symbol
    }

    private static func path(marker: LabMarkerKey, from: String, to: String) throws -> Route {
        let listed = marker.marker.units
        let refusals = LabUnitFamilies.knownRefusals[marker] ?? [:]
        for unit in [from, to] where !listed.contains(unit) {
            if let reason = refusals[unit] {
                throw LabUnitError.noConversion(marker: marker, from: from, to: to, reason: reason)
            }
            throw LabUnitError.unitNotListedForMarker(marker: marker, unit: unit)
        }
        if from == to { return Route(steps: [], citations: []) }

        let canonical = marker.marker.canonicalUnit
        let family = LabUnitFamilies.families[marker] ?? [:]
        func relation(of unit: String) throws -> LabUnitRelation? {
            if unit == canonical { return nil }
            guard let link = family[unit] else {
                throw LabUnitError.noConversion(marker: marker, from: from, to: to, reason: .noCitedFactor)
            }
            switch link {
            case .related(let relation): return relation
            case .unrelated(let reason):
                throw LabUnitError.noConversion(marker: marker, from: from, to: to, reason: reason)
            }
        }
        let source = try relation(of: from)
        let target = try relation(of: to)
        var steps: [(Decimal) -> Decimal] = []
        var citations: [String] = []
        if let source {
            steps.append(source.toCanonical)
            citations.append(source.citation)
        }
        if let target {
            steps.append(target.fromCanonical)
            if !citations.contains(target.citation) { citations.append(target.citation) }
        }
        return Route(steps: steps, citations: citations)
    }
}
