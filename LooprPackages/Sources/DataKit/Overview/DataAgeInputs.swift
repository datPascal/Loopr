import AnalyticsKit
import DesignSystem
import Foundation
import TrainKit

// LV-08b step 1: the three ages the Data tab's ruler pins, each worked out from stored data or absent with the
// reason. Nothing here fills a value in: a missing birth year, report, marker or VO₂max reading is an absence.

// MARK: - Real age

/// Real age from the profile's birth year. The profile keeps the year only, so Loopr counts from 1 July of that
/// year, as the Fitness tab does for the goals at 85. That puts the age at most half a year from the true one.
public enum DataRealAge {
    /// 1 July of `birthYear` at midnight in `timeZone`.
    public static func approximateDateOfBirth(birthYear: Int, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: birthYear, month: 7, day: 1))
    }

    /// Years since 1 July of `birthYear` on `date`, with the fraction of the year. Nil without a birth year, and
    /// outside 1 to 120 years, the profile's own limits.
    public static func years(birthYear: Int?, on date: Date, timeZone: TimeZone) -> Double? {
        guard let birthYear, let birth = approximateDateOfBirth(birthYear: birthYear, timeZone: timeZone),
              let years = PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: date, timeZone: timeZone),
              (1...120).contains(years) else { return nil }
        return years
    }

    /// Whole years since the birth year on `date`, as Body and Fitness count them.
    public static func wholeYears(birthYear: Int?, on date: Date, calendar: Calendar) -> Int? {
        guard let birthYear else { return nil }
        let age = calendar.component(.year, from: date) - birthYear
        return (1...120).contains(age) ? age : nil
    }
}

// MARK: - Blood age

/// One blood draw: a stored report and the values the lab printed for it.
public struct DataLabDraw: Equatable, Sendable {
    public let report: LabReport
    public let values: [LabValue]

    public init(report: LabReport, values: [LabValue]) {
        self.report = report
        self.values = values
    }

    /// The PhenoAge inputs this draw has no value for.
    public var missingPhenoAgeMarkers: [LabMarkerKey] {
        let present = Set(values.compactMap(\.subject.markerKey))
        return PhenoAge.inputMarkers.filter { !present.contains($0) }
    }
}

public struct DataBloodAgeReading: Equatable, Sendable {
    public let estimate: PhenoAgeEstimate
    public let report: LabReport
    /// The age PhenoAge was given: years on the day of the draw, counted from 1 July of the birth year.
    public let ageAtDraw: Double
    /// The blood age of the newest earlier complete draw on another day, when it calculates.
    public var previous: DataBloodAgePrevious? = nil
}

/// An earlier blood age, for the change between draws.
public struct DataBloodAgePrevious: Equatable, Sendable {
    public let years: Double
    public let report: LabReport

    /// Blood age now minus this one.
    public func change(to current: Double) -> Double { current - years }
}

/// The nine values blood age needs, in the words a lab report or a GP uses.
public enum DataBloodAgeMarkers {
    /// One name for each of the nine, on Data, on a report and in the value search alike: the catalog's own name, with
    /// the abbreviation a lab prints once beside it. Data said "CRP, MCV" while the report said "c-reactive protein,
    /// mean cell volume" for the same values (ICP R2-LAB-11).
    public static func name(_ key: LabMarkerKey) -> String {
        switch key {
        case .crp: "C-reactive protein (CRP)"
        case .meanCellVolume: "mean cell volume (MCV)"
        case .redCellDistributionWidth: "red cell distribution width (RDW)"
        default: key.marker.displayName.lowercasedFirst
        }
    }

    /// "albumin, creatinine, glucose, C-reactive protein (CRP), lymphocyte percent, ... and white blood cell count".
    public static var all: String { DataText.list(PhenoAge.inputMarkers.map(name)) }

    /// Which panels hold them.
    public static let panels = "A full blood count with differential and a chemistry panel with CRP cover them."
}

/// Why the blood age pin is absent.
public enum DataBloodAgeAbsence: Equatable, Sendable {
    /// Loopr could not read the stored blood tests.
    case unreadable
    case noReport
    /// No report holds all nine inputs. These are the ones the newest report lacks.
    case missingMarkers([LabMarkerKey], report: LabReport)
    case noBirthYear
    /// PhenoAge refused the newest complete report, with its reason.
    case notCalculated(PhenoAgeAbsence, report: LabReport)

    /// What the pin needs, in one or two sentences.
    public var sentence: String {
        switch self {
        case .unreadable:
            return "Loopr could not read your blood tests on this iPhone. Open Data again to retry."
        case .noReport:
            // The panels say what to ask the lab for; the nine names were eight lines of acronyms before a newcomer had
            // done anything (UX R2-NEW-07). The blood age method page still names each one.
            return "Blood age needs 9 values from one blood test. \(DataBloodAgeMarkers.panels)"
        case let .missingMarkers(markers, report):
            // Say what the draw still needs, not that the lab left it out: it is often on another page.
            let day = DataText.day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier)
            let missing = DataText.list(markers.map(DataBloodAgeMarkers.name))
            let present = PhenoAge.inputMarkers.filter { !markers.contains($0) }
            let page = markers.count == 1 ? "If it is on another page of that report, scan that page too." : "If they are on another page of that report, scan that page too."
            guard !present.isEmpty else {
                return "The \(day) report has none of the 9 values blood age needs: \(missing), all from one draw. \(DataBloodAgeMarkers.panels)"
            }
            return "The \(day) report has \(DataText.list(present.map(DataBloodAgeMarkers.name))). Blood age also needs \(missing) from the same draw. \(page)"
        case .noBirthYear:
            return "Blood age needs your birth year in Profile, to know your age on the day of the draw."
        case let .notCalculated(reason, report):
            let day = DataText.day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier)
            switch reason {
            case .outOfRangeInput(let key), .outsideReferenceRange(let key):
                return "\(key.marker.displayName) on the \(day) report is outside the range PhenoAge takes, so Loopr does not calculate from it."
            case .nonConvertibleUnit(let key, _):
                return "Loopr cannot convert the unit of \(key.marker.displayName.lowercasedFirst) on the \(day) report to the one PhenoAge uses."
            case .ambiguousMarker(let key):
                return "The \(day) report has two values for \(key.marker.displayName.lowercasedFirst). Keep one and blood age can be calculated."
            case .notFromOneDraw:
                return "The 9 markers on the \(day) report are not from one day."
            case .invalidChronologicalAge:
                return "Your birth year gives no valid age on the day of the \(day) draw."
            case .missingMarkers(let keys):
                return "Blood age still needs \(DataText.list(keys.map { $0.marker.displayName.lowercasedFirst })) from the \(day) draw."
            case .printedAsLimit(let key):
                return "\(key.marker.displayName) on the \(day) report is printed as a limit, such as <0.3, not an exact number. PhenoAge needs the exact number, so Loopr does not calculate from it."
            case .coefficientsUnverified, .nonFiniteResult:
                return "Loopr could not calculate blood age from the \(day) report."
            }
        }
    }
}

public enum DataBloodAge: Equatable, Sendable {
    case available(DataBloodAgeReading)
    case absent(DataBloodAgeAbsence)

    public var reading: DataBloodAgeReading? {
        if case .available(let reading) = self { return reading }
        return nil
    }

    public var absence: DataBloodAgeAbsence? {
        if case .absent(let absence) = self { return absence }
        return nil
    }
}

/// Blood age is PhenoAge (Levine 2018, DEC-12.7) from the newest report that holds all nine inputs, computed with the
/// age on the day of that draw.
public enum DataBloodAgeBuilder {
    public typealias Calculate = @Sendable (PhenoAgeInputs) -> PhenoAgeResult

    /// The engine Loopr ships.
    public static let published: Calculate = { PhenoAge.calculate(inputs: $0) }

    /// - Parameters:
    ///   - draws: every stored report with its values, in any order. Nil when the store could not be read.
    ///   - calculate: the PhenoAge engine. Tests pass their own to see what it was called with.
    public static func make(draws: [DataLabDraw]?, birthYear: Int?, calculate: Calculate = published) -> DataBloodAge {
        guard let draws else { return .absent(.unreadable) }
        let newestFirst = draws.sorted { ($0.report.collectedAt, $0.report.createdAt) > ($1.report.collectedAt, $1.report.createdAt) }
        guard let newest = newestFirst.first else { return .absent(.noReport) }
        guard let draw = newestFirst.first(where: { $0.missingPhenoAgeMarkers.isEmpty }) else {
            return .absent(.missingMarkers(newest.missingPhenoAgeMarkers, report: newest.report))
        }
        guard let birthYear else { return .absent(.noBirthYear) }
        let report = draw.report
        guard let zone = TimeZone(identifier: report.timeZoneIdentifier),
              let birth = DataRealAge.approximateDateOfBirth(birthYear: birthYear, timeZone: zone),
              let ageAtDraw = PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: report.collectedAt, timeZone: zone) else {
            return .absent(.notCalculated(.invalidChronologicalAge, report: report))
        }
        let readings = draw.values.map { PhenoAgeReading(value: $0, report: report) }
        switch calculate(PhenoAgeInputs(readings: readings, chronologicalAgeYears: ageAtDraw)) {
        case .available(let estimate):
            return .available(DataBloodAgeReading(estimate: estimate, report: report, ageAtDraw: ageAtDraw,
                                                  previous: previous(before: draw, in: newestFirst, birthYear: birthYear,
                                                                     calculate: calculate)))
        case .unavailable(let reason):
            return .absent(.notCalculated(reason, report: report))
        }
    }

    /// The blood age of the newest complete draw before `draw`, on an earlier day, that calculates.
    static func previous(before draw: DataLabDraw, in newestFirst: [DataLabDraw], birthYear: Int,
                         calculate: Calculate) -> DataBloodAgePrevious? {
        let day = DataText.dayKey(draw.report.collectedAt, timeZoneIdentifier: draw.report.timeZoneIdentifier)
        for earlier in newestFirst where earlier.report.collectedAt < draw.report.collectedAt && earlier.missingPhenoAgeMarkers.isEmpty {
            let report = earlier.report
            guard DataText.dayKey(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier) != day,
                  let zone = TimeZone(identifier: report.timeZoneIdentifier),
                  let birth = DataRealAge.approximateDateOfBirth(birthYear: birthYear, timeZone: zone),
                  let age = PhenoAge.chronologicalAgeYears(dateOfBirth: birth, on: report.collectedAt, timeZone: zone) else { continue }
            let readings = earlier.values.map { PhenoAgeReading(value: $0, report: report) }
            if let estimate = calculate(PhenoAgeInputs(readings: readings, chronologicalAgeYears: age)).estimate {
                return DataBloodAgePrevious(years: estimate.phenotypicAgeYears, report: report)
            }
        }
        return nil
    }
}

// MARK: - Cardio Age

/// VO₂max as Apple Health gave it, or why there is none.
public enum DataVO2MaxSource: Equatable, Sendable {
    case readings([VO2MaxReading])
    /// The person switched the VO₂max read off in Loopr.
    case switchedOff
    /// This iPhone has no Apple Health.
    case unavailable
}

public struct DataCardioAgeReading: Equatable, Sendable {
    public let result: CardioAgeResult
    public let years: Double
    /// "34", or "25 or younger" at the edge of the reference.
    public let valueText: String
    public let median: VO2MaxMedian
    public let referenceGroup: FriendReferenceGroup
}

public enum DataCardioAgeAbsence: Equatable, Sendable {
    case switchedOff
    case unavailable
    case noBirthYear
    /// No birth year and too few VO₂max readings: the row names both, so setting the year is not the last step
    /// (ICP R2-LAB-17).
    case noBirthYearNorReadings
    /// No sex in Profile, so no FRIEND curve. The readings are there.
    case noReferenceCurve
    /// No sex in Profile and too few VO₂max readings: the row keeps naming the readings once the birth year is in,
    /// so Cardio Age never looks one step away when it is two (ICP R3-LAB-3).
    case noReferenceCurveNorReadings
    case unsupportedAge
    case notEnoughSamples

    public var sentence: String {
        switch self {
        case .switchedOff:
            "Cardio Age reads VO₂max from Apple Health, and that read is switched off in Settings."
        case .unavailable:
            "This iPhone has no Apple Health, so there is no VO₂max for Cardio Age."
        case .noBirthYear:
            "Cardio Age needs your birth year in Profile."
        case .noBirthYearNorReadings:
            "Cardio Age needs your birth year in Profile and 3 VO₂max readings from outdoor workouts with an Apple Watch, at least 2 weeks apart."
        case .noReferenceCurve:
            "Cardio Age needs your sex in Profile. It compares your VO₂max with typical values for women or for men, so Loopr needs to know which."
        case .noReferenceCurveNorReadings:
            "Cardio Age still needs 3 VO₂max readings from outdoor workouts with an Apple Watch, at least 2 weeks apart. It also needs your sex in Profile, to compare you with typical values for women or for men."
        case .unsupportedAge:
            "Loopr's FRIEND reference runs from age 25 to 75, so Cardio Age is not available at your age."
        case .notEnoughSamples:
            "Cardio Age needs 3 VO₂max readings from outdoor workouts with an Apple Watch, at least 2 weeks apart."
        }
    }
}

extension DataCardioAgeAbsence {
    /// What Cardio Age needs from Profile besides the readings, for the readings guide. Nil when the readings are all.
    public var profileNeed: String? {
        switch self {
        case .noBirthYearNorReadings: "Cardio Age also needs your birth year in Profile."
        case .noReferenceCurveNorReadings: "Cardio Age also needs your sex in Profile."
        default: nil
        }
    }
}

public enum DataCardioAge: Equatable, Sendable {
    case available(DataCardioAgeReading)
    case absent(DataCardioAgeAbsence)

    public var reading: DataCardioAgeReading? {
        if case .available(let reading) = self { return reading }
        return nil
    }

    public var absence: DataCardioAgeAbsence? {
        if case .absent(let absence) = self { return absence }
        return nil
    }
}

/// Cardio Age (DEC-02.10) from `CardioAgeCalculator`, fed the 42-day VO₂max median that the Fitness gauge uses.
public enum DataCardioAgeBuilder {
    public static func make(source: DataVO2MaxSource, birthYear: Int?, referenceGroup: FriendReferenceGroup?,
                            now: Date, calendar: Calendar) -> DataCardioAge {
        let readings: [VO2MaxReading]
        switch source {
        case .switchedOff: return .absent(.switchedOff)
        case .unavailable: return .absent(.unavailable)
        case .readings(let values): readings = values
        }
        guard let age = DataRealAge.wholeYears(birthYear: birthYear, on: now, calendar: calendar) else {
            return .absent(VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar) == nil ? .noBirthYearNorReadings : .noBirthYear)
        }
        let median = VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar)
        guard let referenceGroup else { return .absent(median == nil ? .noReferenceCurveNorReadings : .noReferenceCurve) }
        guard let median else { return .absent(.notEnoughSamples) }
        let result = CardioAgeCalculator().calculate(vo2max: median.value, referenceGroup: referenceGroup, curve: .version1,
                                                     source: .healthKit, calculationAge: age)
        guard result.status == .available, let years = result.ageYears, years.isFinite else {
            return .absent(result.absenceReason == .declinedReferenceCurve ? .noReferenceCurve : .unsupportedAge)
        }
        let text = result.displayLabel ?? String(Int(years.rounded()))
        return .available(DataCardioAgeReading(result: result, years: years, valueText: text, median: median,
                                               referenceGroup: referenceGroup))
    }
}

// MARK: - Text

enum DataText {
    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// "12 Sep" in the report's own time zone.
    static func day(_ date: Date, timeZoneIdentifier: String) -> String {
        day(date, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .gmt)
    }

    /// The local calendar day in the report's own zone, to tell two draws apart.
    static func dayKey(_ date: Date, timeZoneIdentifier: String) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// One decimal in the app's number locale, the digits every other number on the page uses (ICP R2-LAB-18:
    /// "42,8" beside "11,432").
    static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return LooprUnitFormatter.number(rounded == 0 ? 0 : rounded, digits: 1) ?? "–"
    }

    /// "1 day", "2 days".
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

extension String {
    /// "C-reactive protein" becomes "c-reactive protein"; an acronym such as "HbA1c" or "TSH" stays as it is.
    var lowercasedFirst: String {
        guard let first = first, first.isUppercase else { return self }
        let second = dropFirst().first
        if let second, second.isUppercase || second.isNumber { return self }
        return first.lowercased() + dropFirst()
    }
}
