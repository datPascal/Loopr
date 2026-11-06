import AnalyticsKit
import DesignSystem
import Foundation
import TrainKit

// LV-08b step 1: the age ruler, Data's signature object (DESIGN_LANGUAGE premium check 1). Three pins on one
// precision ruler: blood age (PhenoAge), real age and Cardio Age. Each pin carries its method. A pin without its
// inputs is not drawn; it says what it needs instead. Loopr Age is never on the ruler (DEC-02.12).

/// The three pins, top lane first.
public enum DataAgePinKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case blood
    case real
    case cardio

    public var id: String { rawValue }

    /// `data-age-pin-blood`, `data-age-pin-real`, `data-age-pin-cardio`.
    public var identifier: String { "data-age-pin-\(rawValue)" }

    public var title: String {
        switch self {
        case .blood: "Blood age"
        case .real: "Real age"
        case .cardio: "Cardio Age"
        }
    }

    /// The word on the ruler before the value.
    public var shortName: String {
        switch self {
        case .blood: "blood"
        case .real: "real"
        case .cardio: "cardio"
        }
    }

    /// The method the pin carries on the ruler.
    public var method: String {
        switch self {
        case .blood: "PhenoAge"
        case .real: "birth year"
        case .cardio: "VO₂max"
        }
    }

    public var accent: LooprColorToken {
        switch self {
        case .blood: .brand
        case .real: .ink
        case .cardio: .strain
        }
    }
}

public struct DataAgePin: Equatable, Sendable, Identifiable {
    public let kind: DataAgePinKind
    public let years: Double
    /// "34.6", "38.3", "34" or "25 or younger".
    public let valueText: String

    public var id: DataAgePinKind { kind }
    /// "blood 34.6 · PhenoAge".
    public var label: String { "\(kind.shortName) \(valueText) · \(kind.method)" }
    /// "blood 34.6", for a crowded ruler.
    public var shortLabel: String { "\(kind.shortName) \(valueText)" }
    public var spokenLabel: String { "\(kind.title) \(valueText), \(kind.method)" }
}

/// A pin on the ruler, or what it needs.
public enum DataAgePinState: Equatable, Sendable {
    case present(DataAgePin)
    case absent(String)

    public var pin: DataAgePin? {
        if case .present(let pin) = self { return pin }
        return nil
    }

    public var absenceSentence: String? {
        if case .absent(let sentence) = self { return sentence }
        return nil
    }
}

public struct DataAgeRulerTick: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case quarter
        case year
        case decade
    }

    public let value: Double
    public let kind: Kind
    /// Set on the labelled ticks.
    public let label: String?
}

/// The ruler's span: fitted to the pins with 4 years either side, at least 16 years wide, with both ends on even
/// years. Without pins it spans 20 to 60, so the empty ruler keeps its shape.
public struct DataAgeRulerScale: Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public static let margin = 4.0
    public static let minimumSpan = 16.0
    public static let empty = DataAgeRulerScale(lower: 20, upper: 60)
    /// The scrub reads to a tenth of a year.
    public static let step = 0.1

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = max(upper, lower + 1)
    }

    public static func fitted(to values: [Double]) -> DataAgeRulerScale {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return empty }
        var lower = low - margin
        var upper = high + margin
        if upper - lower < minimumSpan {
            let pad = (minimumSpan - (upper - lower)) / 2
            lower -= pad
            upper += pad
        }
        lower = (lower / 2).rounded(.down) * 2
        upper = (upper / 2).rounded(.up) * 2
        if lower < 0 {
            upper -= lower
            lower = 0
        }
        return DataAgeRulerScale(lower: lower, upper: upper)
    }

    public var span: Double { upper - lower }

    /// Where `years` sits from 0 at the left end to 1 at the right, clamped.
    public func fraction(for years: Double) -> Double {
        guard years.isFinite else { return 0 }
        return min(max((years - lower) / span, 0), 1)
    }

    /// The age at `fraction` along the ruler.
    public func years(atFraction fraction: Double) -> Double {
        lower + min(max(fraction, 0), 1) * span
    }

    /// The scrub's stops, a tenth of a year apart.
    public var detent: LooprDetent { LooprDetent(range: lower...upper, step: Self.step) }

    /// Quarter-year ticks on a ruler up to 24 years wide, year ticks, and taller decade ticks. Labels sit every
    /// two years up to 16 years, every five beyond, so they never bunch on a phone-wide ruler.
    public var ticks: [DataAgeRulerTick] {
        let fine = span <= 24
        let every = fine ? 0.25 : 1
        let labelEvery = span <= DataAgeRulerScale.minimumSpan ? 2 : 5
        var ticks: [DataAgeRulerTick] = []
        let count = Int((span / every).rounded())
        for index in 0...count {
            let value = lower + Double(index) * every
            let whole = value.rounded()
            let isYear = abs(value - whole) < 0.001
            let year = Int(whole)
            let kind: DataAgeRulerTick.Kind = isYear ? (year % 10 == 0 ? .decade : .year) : .quarter
            let label = isYear && year % labelEvery == 0 ? String(year) : nil
            ticks.append(DataAgeRulerTick(value: isYear ? whole : value, kind: kind, label: label))
        }
        return ticks
    }
}

/// Where a pin sits: its share along the ruler, its lane (0 is the top), which side its label runs to, and whether
/// the label carries the method.
///
/// A pin's stem runs from its head down to the baseline, so it crosses every lane below its own. A label is placed so
/// it crosses no such stem: on its preferred side (right of a pin in the left 60 % of the ruler, left past that), else
/// on the other side when that one is clear and fits, else without the method words ("cardio 32"), which is shorter.
public struct DataAgePinPlacement: Equatable, Sendable {
    public let kind: DataAgePinKind
    public let fraction: Double
    public let lane: Int
    /// True when the label runs to the right of the pin.
    public let labelTrailsPin: Bool
    /// False on a crowded ruler: the label drops "· method".
    public var showsMethod: Bool = true

    public static let flipFraction = 0.6
    /// The ruler width the placement assumes when the screen has not measured it yet.
    public static let assumedWidth = 354.0
    /// Points from the pin to where its words start, and a caption character's width, for the label's reach.
    static let labelInset = 9.0
    static let characterWidth = 6.6

    static func reach(_ text: String, width: Double) -> Double {
        (labelInset + Double(text.count) * characterWidth) / max(width, 1)
    }

    /// One lane per present pin, in `DataAgePinKind` order, so labels never share a row.
    public static func place(_ pins: [DataAgePin], on scale: DataAgeRulerScale,
                             width: Double = assumedWidth) -> [DataAgePinPlacement] {
        let ordered = DataAgePinKind.allCases.compactMap { kind in pins.first { $0.kind == kind } }
        var placed: [DataAgePinPlacement] = []
        for (lane, pin) in ordered.enumerated() {
            let fraction = scale.fraction(for: pin.years)
            let above = placed.map(\.fraction)
            func clear(_ trails: Bool, _ text: String) -> Bool {
                let extent = Self.reach(text, width: width)
                // A label may run a few points into the card's padding.
                let fits = trails ? fraction + extent <= 1.04 : fraction - extent >= -0.04
                let crosses = above.contains { stem in
                    let distance = stem - fraction
                    return trails ? distance > 0 && distance <= extent : distance < 0 && -distance <= extent
                }
                return fits && !crosses
            }
            let preferred = fraction <= flipFraction
            let choice: (trails: Bool, method: Bool) = if clear(preferred, pin.label) { (preferred, true) }
                else if clear(!preferred, pin.label) { (!preferred, true) }
                else if clear(preferred, pin.shortLabel) { (preferred, false) }
                else if clear(!preferred, pin.shortLabel) { (!preferred, false) }
                else { (preferred, false) }
            placed.append(DataAgePinPlacement(kind: pin.kind, fraction: fraction, lane: lane, labelTrailsPin: choice.trails,
                                              showsMethod: choice.method))
        }
        return placed
    }
}

/// The big number over the ruler: blood age when there is one, else Cardio Age, else real age, else a designed empty
/// state. It is built from the same pin states the ruler draws, so the headline never says "No age yet" over a pin
/// (ICP R3-LAB-1, R3-NEW-2, R3-UPG-3).
public struct DataAgeHero: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blood
        case cardio
        case real
        case empty
    }

    public let kind: Kind
    /// "Blood age · PhenoAge · 12 Sep".
    public let eyebrow: String
    public let value: Double?
    public let fractionDigits: Int
    /// Set beside the number at the reference's edge: "or younger".
    public let suffix: String?
    /// What the number means, or for the empty state what the ruler needs.
    public let sentence: String
    /// The empty state's lines, one per pin that is missing. The section lists them under the ruler.
    public let needs: [String]
    public let provenance: LooprProvenance
    public let provenanceQualifier: String?
    /// The change since the previous draw: "Since 3 Jul: −1.2 years". Nil without one.
    public var change: String? = nil
    /// "years", set small beside the number.
    public var unit: String? = nil

    public var spokenLabel: String {
        var parts = [eyebrow]
        if let value {
            parts.append(DataText.oneDecimalOrWhole(value, fractionDigits: fractionDigits) + (unit.map { " \($0)" } ?? "")
                + (suffix.map { " \($0)" } ?? ""))
        }
        if let change { parts.append(LooprSignedNumber.spoken(text: change)) }
        parts.append(sentence)
        return parts.joined(separator: ". ")
    }
}

/// Everything the age section draws.
public struct DataAgeRuler: Equatable, Sendable {
    public let blood: DataBloodAge
    public let cardio: DataCardioAge
    /// Real age today, from the birth year.
    public let realYears: Double?
    public let birthYear: Int?
    public let states: [DataAgePinKind: DataAgePinState]
    public let scale: DataAgeRulerScale
    public let placements: [DataAgePinPlacement]
    public let hero: DataAgeHero
    /// The VO₂max readings so far while Cardio Age has too few. Nil once there are enough, and while Apple Health is
    /// off or missing.
    public var vo2MaxProgress: VO2MaxReadingProgress? = nil

    public static let notAMedicalDevice = LooprMedicalLine.text
    public static let realAgeAbsence = "Real age needs your birth year in Profile."
    /// The hero sentence before any age can be shown. Every age needs the birth year, so that is the first step.
    public static let emptySentence = "Add your birth year in Profile, the round button at the top right, to see your real age here."
    /// The hero sentence when real age is the only pin.
    public static let realOnlySentence = "Your age today, from the birth year in Profile. Blood age and Cardio Age join it on the ruler once each row below has what it needs."
    /// Real age is counted from 1 July of the birth year, so it can be up to half a year out.
    public static let birthYearCaveat = "Your age counts from your birth year only, so it can be off by about six months."

    /// The ruler while its inputs are read: the empty scale with no pins and no absence rows, so the object keeps its
    /// shape from the first frame.
    public static let loading = DataAgeRuler(
        blood: .absent(.noReport), cardio: .absent(.notEnoughSamples), realYears: nil, birthYear: nil, states: [:],
        scale: .empty, placements: [],
        hero: DataAgeHero(kind: .empty, eyebrow: "Your ages", value: nil, fractionDigits: 0, suffix: nil,
                          sentence: "Reading your blood tests, VO₂max and profile on this iPhone.", needs: [],
                          provenance: .absent, provenanceQualifier: nil))

    /// True for `loading`: no pin has been worked out yet.
    public var isLoading: Bool { states.isEmpty }

    public var pins: [DataAgePin] { DataAgePinKind.allCases.compactMap { states[$0]?.pin } }
    public func state(_ kind: DataAgePinKind) -> DataAgePinState { states[kind] ?? .absent("") }

    /// What VoiceOver reads for the ruler.
    public var spokenSummary: String {
        if isLoading { return "Age ruler, loading." }
        var parts = ["Age ruler"]
        for kind in DataAgePinKind.allCases {
            switch state(kind) {
            case .present(let pin): parts.append(pin.spokenLabel)
            case .absent: parts.append("\(kind.title) is not on the ruler")
            }
        }
        return parts.joined(separator: ". ") + "."
    }

    public static func make(birthYear: Int?, draws: [DataLabDraw]?, vo2Max: DataVO2MaxSource,
                            referenceGroup: FriendReferenceGroup?, now: Date, calendar: Calendar,
                            calculate: DataBloodAgeBuilder.Calculate = DataBloodAgeBuilder.published) -> DataAgeRuler {
        let blood = DataBloodAgeBuilder.make(draws: draws, birthYear: birthYear, calculate: calculate)
        let cardio = DataCardioAgeBuilder.make(source: vo2Max, birthYear: birthYear, referenceGroup: referenceGroup,
                                               now: now, calendar: calendar)
        let real = DataRealAge.years(birthYear: birthYear, on: now, timeZone: calendar.timeZone)

        var states: [DataAgePinKind: DataAgePinState] = [:]
        if let reading = blood.reading {
            let years = reading.estimate.phenotypicAgeYears
            states[.blood] = .present(DataAgePin(kind: .blood, years: years, valueText: DataText.oneDecimal(years)))
        } else {
            states[.blood] = .absent(blood.absence?.sentence ?? DataBloodAgeAbsence.noReport.sentence)
        }
        if let real {
            states[.real] = .present(DataAgePin(kind: .real, years: real, valueText: DataText.oneDecimal(real)))
        } else {
            states[.real] = .absent(realAgeAbsence)
        }
        if let reading = cardio.reading {
            states[.cardio] = .present(DataAgePin(kind: .cardio, years: reading.years, valueText: reading.valueText))
        } else {
            states[.cardio] = .absent(cardio.absence?.sentence ?? DataCardioAgeAbsence.notEnoughSamples.sentence)
        }

        let pins = DataAgePinKind.allCases.compactMap { states[$0]?.pin }
        let scale = DataAgeRulerScale.fitted(to: pins.map(\.years))
        var progress: VO2MaxReadingProgress?
        if cardio.reading == nil, case .readings(let readings) = vo2Max {
            let made = VO2MaxReadingProgress.make(readings: readings, asOf: now, calendar: calendar)
            progress = made.isComplete ? nil : made
        }
        return DataAgeRuler(blood: blood, cardio: cardio, realYears: real, birthYear: birthYear, states: states, scale: scale,
                            placements: DataAgePinPlacement.place(pins, on: scale),
                            hero: hero(blood: blood, cardio: cardio, states: states), vo2MaxProgress: progress)
    }

    static func hero(blood: DataBloodAge, cardio: DataCardioAge, states: [DataAgePinKind: DataAgePinState]) -> DataAgeHero {
        // The pins the ruler draws decide the hero, so the two cannot disagree.
        let bloodPin = states[.blood]?.pin, cardioPin = states[.cardio]?.pin, realPin = states[.real]?.pin
        if bloodPin != nil, let reading = blood.reading {
            let report = reading.report
            let day = DataText.day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier)
            let gap = reading.estimate.differenceYears
            let years = Int(abs(gap).rounded())
            let atDraw = DataText.oneDecimal(reading.ageAtDraw)
            let lead = years == 0
                ? "Within half a year of your age on the day of the draw, \(atDraw)."
                : "About \(DataText.count(years, "year", "years")) \(gap < 0 ? "under" : "over") your age on the day of the draw, \(atDraw)."
            let change = reading.previous.map { previous in
                let previousDay = DataText.day(previous.report.collectedAt, timeZoneIdentifier: previous.report.timeZoneIdentifier)
                let delta = LooprSignedNumber.text(previous.change(to: reading.estimate.phenotypicAgeYears), fractionDigits: 1)
                return "Since \(previousDay): \(delta) years"
            }
            // One decimal, as the ruler's pin prints it ("blood 29.2"), with its unit (ICP R3-LAB-1).
            return DataAgeHero(kind: .blood, eyebrow: "Blood age · PhenoAge estimate · \(day)", value: reading.estimate.phenotypicAgeYears,
                               fractionDigits: 1, suffix: nil,
                               sentence: "\(lead) An estimate from \(PhenoAge.inputMarkers.count) standard blood markers. \(birthYearCaveat)",
                               needs: [], provenance: .lab(name: report.labName ?? ""), provenanceQualifier: day, change: change,
                               unit: "years")
        }
        if cardioPin != nil, let reading = cardio.reading {
            let source = reading.median.sourceLabels.first ?? "Apple Health"
            let person = reading.referenceGroup == .female ? "woman" : "man"
            var suffix: String?
            if let label = reading.result.displayLabel {
                if label.hasSuffix("or younger") { suffix = "or younger" } else if label.hasSuffix("or older") { suffix = "or older" }
            }
            return DataAgeHero(kind: .cardio, eyebrow: "Cardio Age · VO₂max · \(source)", value: reading.years,
                               fractionDigits: 0, suffix: suffix,
                               sentence: "The age at which a typical \(person) has your VO₂max of \(DataText.oneDecimal(reading.median.value)), your median over the last 42 days. The typical values come from the FRIEND fitness registry.",
                               needs: [], provenance: .appleHealth(source: source), provenanceQualifier: "42-day median",
                               unit: "years")
        }
        let needs = DataAgePinKind.allCases.compactMap { states[$0]?.absenceSentence }
        if let realPin {
            return DataAgeHero(kind: .real, eyebrow: "Real age · birth year", value: realPin.years, fractionDigits: 1, suffix: nil,
                               sentence: "\(realOnlySentence) \(birthYearCaveat)", needs: needs, provenance: .typedIn,
                               provenanceQualifier: "Profile", unit: "years")
        }
        return DataAgeHero(kind: .empty, eyebrow: "Your ages", value: nil, fractionDigits: 0, suffix: nil,
                           sentence: emptySentence,
                           needs: needs, provenance: .absent, provenanceQualifier: nil)
    }
}

extension DataText {
    static func oneDecimalOrWhole(_ value: Double, fractionDigits: Int) -> String {
        fractionDigits == 0 ? String(Int(value.rounded())) : oneDecimal(value)
    }
}
