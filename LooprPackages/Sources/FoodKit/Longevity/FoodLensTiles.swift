import DesignSystem
import Foundation

/// One tile of the longevity lens on the Food tab (contract p-food): a value with its unit and a small bar, or a
/// sentence saying what is missing. A missing value is never drawn as 0.
public struct FoodLensTile: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case protein, fibre, upf, alcoholFree = "alcohol-free"
    }

    public let kind: Kind
    public let title: String
    /// Nil when absent. `note` then says what is missing.
    public let value: Double?
    public let fractionDigits: Int
    public let unit: String
    /// What VoiceOver says for the unit.
    public let spokenUnit: String
    /// The bar's fill, 0 to 1. Nil when there is nothing to measure against.
    public let bar: Double?
    /// Under the value: the days it covers, its coverage, or what is missing.
    public let note: String
    /// Where the value came from, drawn as a chip when set.
    public let provenance: LooprProvenance?
    public let provenanceQualifier: String?
    /// True while the number rests on too little to lead with, so the tile draws it quietly.
    public var isProvisional = false
    public var id: String { kind.rawValue }
    public var identifier: String { "food-lens-\(kind.rawValue)" }
    public var isAbsent: Bool { value == nil }

    /// What VoiceOver reads for the tile.
    public var accessibilityLabel: String {
        guard let value else { return "\(title). \(note)." }
        let number = LooprHeroNumberFormat.text(value, fractionDigits: fractionDigits, locale: Locale(identifier: "en_US"))
        return "\(title), \(number) \(spokenUnit). \(note)."
    }
}

/// Builds the four lens tiles from a week's lens.
public enum FoodLensTiles {
    /// - Parameters:
    ///   - bodyWeightKilograms: the seven-day weight average, as the lens used it.
    ///   - barcodedItems: scanned items on the week's finished days (`barcodedItems(week:data:)`).
    ///   - proteinTarget: grams a day, from Food's targets or the protocol. The bar fills at the target per kilogram.
    ///   - fibreTarget: grams a day from the protocol. Without one the fibre tile has no bar.
    public static func tiles(lens: FoodLongevityLens?, bodyWeightKilograms: Double?, barcodedItems: Int,
                             proteinTarget: Double?, fibreTarget: Double?) -> [FoodLensTile] {
        let finished = lens?.completeDays ?? 0
        // A weekly lens from one or two finished days reads like an average and is not one.
        let enough = finished >= minimumFinishedDays
        let needsDays = finished == 0 ? "Needs \(minimumFinishedDays) finished days"
            : "\(finished) of \(minimumFinishedDays) finished days so far"
        func over(_ days: Int) -> String { days == 1 ? "Over 1 finished day" : "Over \(days) finished days" }
        func fill(_ value: Double, of full: Double?) -> Double? {
            guard let full, full > 0, value.isFinite else { return nil }
            return min(max(value / full, 0), 1)
        }
        let weight = bodyWeightKilograms.flatMap { $0.isFinite && FoodWeightEntry.validRange.contains($0) ? $0 : nil }

        let protein: FoodLensTile
        if enough, let value = lens?.proteinPerKilogram, let weight {
            protein = .init(kind: .protein, title: "Protein", value: value.value, fractionDigits: 1, unit: "g/kg",
                spokenUnit: "grams per kilogram", bar: fill(value.value, of: proteinTarget.map { $0 / weight }),
                note: over(value.days), provenance: nil, provenanceQualifier: nil)
        } else {
            let note = weight == nil ? "Needs your weight" : !enough ? needsDays : "No protein on finished days"
            protein = .init(kind: .protein, title: "Protein", value: nil, fractionDigits: 1, unit: "g/kg",
                spokenUnit: "grams per kilogram", bar: nil, note: note, provenance: nil, provenanceQualifier: nil)
        }

        let fibre: FoodLensTile
        if enough, let value = lens?.fibrePerDay {
            fibre = .init(kind: .fibre, title: "Fibre", value: value.value, fractionDigits: 0, unit: "g/day", spokenUnit: "grams a day",
                bar: fill(value.value, of: fibreTarget), note: over(value.days), provenance: nil, provenanceQualifier: nil)
        } else {
            fibre = .init(kind: .fibre, title: "Fibre", value: nil, fractionDigits: 0, unit: "g/day", spokenUnit: "grams a day",
                bar: nil, note: !enough ? needsDays : "No fibre on finished days", provenance: nil, provenanceQualifier: nil)
        }

        let upf: FoodLensTile
        if enough, let share = lens?.ultraProcessed {
            let coverage = LooprHeroNumberFormat.text(share.coverage * 100, locale: Locale(identifier: "en_US"))
            let items = "\(share.classifiedItems) of \(max(barcodedItems, share.classifiedItems)) barcoded items"
            if share.classifiedItems < minimumUltraProcessedItems {
                // Two scanned items give a percentage that moves with one more. The count leads and the share follows.
                let percent = LooprHeroNumberFormat.text(share.share * 100, locale: Locale(identifier: "en_US"))
                upf = .init(kind: .upf, title: "Ultra-processed", value: Double(share.classifiedItems), fractionDigits: 0,
                    unit: share.classifiedItems == 1 ? "item" : "items", spokenUnit: share.classifiedItems == 1 ? "item" : "items",
                    bar: nil, note: "\(percent)% so far. Needs \(minimumUltraProcessedItems) scanned items for a share",
                    provenance: .food(.barcode), provenanceQualifier: "\(coverage)% of kcal", isProvisional: true)
            } else {
                upf = .init(kind: .upf, title: "Ultra-processed", value: share.share * 100, fractionDigits: 0, unit: "%", spokenUnit: "percent",
                    bar: min(max(share.share, 0), 1), note: "\(items) · \(coverage)% of kcal",
                    provenance: .food(.barcode), provenanceQualifier: "\(coverage)% of kcal")
            }
        } else {
            let note = !enough ? needsDays
                : barcodedItems == 0 ? "No barcoded items this week"
                : barcodedItems == 1 ? "No group for 1 barcoded item" : "No group for \(barcodedItems) barcoded items"
            upf = .init(kind: .upf, title: "Ultra-processed", value: nil, fractionDigits: 0, unit: "%", spokenUnit: "percent",
                bar: nil, note: note, provenance: nil, provenanceQualifier: nil)
        }

        let alcohol: FoodLensTile
        if enough, let days = lens?.alcoholFree {
            alcohol = .init(kind: .alcoholFree, title: "Alcohol-free", value: Double(days.alcoholFree), fractionDigits: 0,
                unit: days.alcoholFree == 1 ? "day" : "days", spokenUnit: days.alcoholFree == 1 ? "day" : "days",
                bar: fill(Double(days.alcoholFree), of: Double(days.answered)),
                note: days.answered == days.completeDays
                    ? (days.completeDays == 1 ? "Of 1 finished day" : "Of \(days.completeDays) finished days")
                    : "Answered on \(days.answered) of \(days.completeDays) finished days",
                provenance: nil, provenanceQualifier: nil)
        } else {
            // A day with no drink logged is not an alcohol-free day until the person says so.
            alcohol = .init(kind: .alcoholFree, title: "Alcohol-free", value: nil, fractionDigits: 0, unit: "days", spokenUnit: "days",
                bar: nil, note: !enough ? needsDays : "Not logged. Tap None today under Drinks.", provenance: nil, provenanceQualifier: nil)
        }
        return [protein, fibre, upf, alcohol]
    }

    /// Finished days the weekly numbers need before they show.
    public static let minimumFinishedDays = 3
    /// Classified barcoded items the ultra-processed share needs before it leads.
    public static let minimumUltraProcessedItems = 5

    /// Scanned items on the week's finished days, the base the ultra-processed share's coverage reads against.
    public static func barcodedItems(week: FoodISOWeek, data: FoodOverviewData) -> Int {
        let finished = Set(data.days.filter { $0.completedAt != nil && week.contains(localDay: $0.localDay) }.map(\.localDay))
        return data.meals.filter { finished.contains($0.localDay) }.flatMap(\.items)
            .filter { $0.provenance.contains { $0.source == .barcode } }.count
    }
}
