import AnalyticsKit
import DesignSystem
import Foundation

/// Why a typed report, value or lab clock result does not save. Each case carries the words the entry screen shows.
public enum LabEntryError: Error, Equatable, Sendable {
    case noValues
    case futureDate
    case blankLabName
    case blankTestName
    case missingNumber(String)
    case unreadableNumber(String)
    case unitNotListed(marker: String, unit: String)
    case unreadableRange(String)
    case rangeOutOfOrder(String)
    case rangeMixed(String)
    case flagTooLong(String)
    case duplicateMarker(String)
    /// The model refused what the draft built.
    case model(LabValidationError)

    /// The value the error is about, by the name the form shows, so the form can show it under that value.
    public var valueName: String? {
        switch self {
        case .missingNumber(let name), .unreadableNumber(let name), .unreadableRange(let name), .rangeOutOfOrder(let name),
             .rangeMixed(let name), .flagTooLong(let name), .duplicateMarker(let name):
            name
        case .unitNotListed(let marker, _): marker
        case .noValues, .futureDate, .blankLabName, .blankTestName, .model: nil
        }
    }

    public var message: String {
        switch self {
        case .noValues: "Add at least one value to save this report."
        case .futureDate: "That date is still ahead. Pick the day the blood was drawn."
        case .blankLabName: "Add the lab's name. Loopr shows every result with it."
        case .blankTestName: "Name the test."
        case .missingNumber(let name): "Type the value for \(name)."
        case .unreadableNumber(let name): "\(name) needs a number, like 5.4 or 5,4, or a limit, like <0.3. Type it the way the lab printed it."
        case let .unitNotListed(marker, unit): "\(unit) is not one of the units listed for \(marker)."
        case .unreadableRange(let name): "The range for \(name) needs plain numbers, like 3.5 or 3,5."
        case .rangeOutOfOrder(let name): "The range for \(name) starts above where it ends."
        case .rangeMixed(let name): "For \(name), use either the range numbers or the range text, not both."
        case .flagTooLong(let name): "The flag for \(name) is longer than a lab prints. Type it as printed, like H or *."
        case .duplicateMarker(let name): "\(name) is in this report twice. Keep one."
        case .model(let error): Self.message(for: error)
        }
    }

    private static func message(for error: LabValidationError) -> String {
        switch error {
        case .blankName: "Name the test."
        case .blankLabName: "Add the lab's name. Loopr shows every result with it."
        case .unknownTimeZone: "Loopr does not know this time zone. Check the date and try again."
        case .nonFiniteValue: "One of the numbers is not a number Loopr can store."
        case .printedValueMismatch: "The digits you typed and the stored number do not match. Type the value again."
        case .scanConfidenceOutOfRange, .typedValueCarriesScanFields, .valueBelongsToAnotherReport:
            "Loopr could not save this. Try again."
        }
    }
}

/// Number text as a person types it. A single decimal comma is a decimal point; a comma beside a dot, two
/// commas or a thousands mark is refused, because Loopr never guesses what a separator meant. The digits the person
/// typed survive in `printed` when they differ from the plain number ("5,0" keeps "5.0").
public enum LabEntryNumber {
    public static func parse(_ text: String) -> (value: Decimal, printed: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commas = trimmed.filter { $0 == "," }.count
        let dots = trimmed.filter { $0 == "." }.count
        guard commas <= 1, commas == 0 || dots == 0 else { return nil }
        guard let parsed = LabNumberText.parse(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (parsed.value, parsed.printedValue)
    }

    /// A result as the lab printed it: a number, or a limit with its sign ("<0.3", "> 200", "≤5"). The number follows
    /// the same rules as `parse`.
    public static func parseResult(_ text: String) -> (comparator: LabValueComparator?, value: Decimal, printed: String?)? {
        let split = LabValueComparator.split(text)
        guard let number = parse(split.rest) else { return nil }
        return (split.comparator, number.value, number.printed)
    }

    /// Dot-notation digits written with `locale`'s decimal separator, by default the app's number locale. Typing accepts
    /// "4,5" and "4.5" (`parse`); showing uses one separator.
    public static func localized(_ dotText: String, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        guard let separator = locale.decimalSeparator, separator != "." else { return dotText }
        return dotText.replacingOccurrences(of: ".", with: separator)
    }
}

/// The day a blood draw happened, as a date on the calendar and not an instant. The form keeps this, the picker
/// shows it in the same zone, and the report stores midday of it, so the day saved is the day picked. The picker
/// used to show the day in the phone's zone while the save read it in the report's zone, which moved a draw picked
/// on 15 Nov to 14 Nov (ICP R2-LAB-5).
public struct LabCalendarDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// The calendar day `date` falls on in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone) {
        let parts = LabCalendarDay.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Midday of the day in `timeZone`, the instant a report stores.
    public func noon(in timeZone: TimeZone) -> Date? {
        LabCalendarDay.calendar(timeZone).date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// `yyyy-MM-dd`, as `LabReport.collectedDay` writes it.
    public var text: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: LabCalendarDay, rhs: LabCalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// A picked day as the report's collection time: midday on that day in the report's zone, so the day reads the same
/// in every zone Loopr later shows it in.
enum LabEntryDates {
    static func collectionTime(of day: LabCalendarDay, timeZone: TimeZone, now: Date) -> Result<Date, LabEntryError> {
        guard day <= LabCalendarDay(now, timeZone: timeZone) else { return .failure(.futureDate) }
        guard let noon = day.noon(in: timeZone) else { return .failure(.model(.unknownTimeZone(timeZone.identifier))) }
        return .success(noon)
    }

    /// Midday today in `timeZone`, or `now` when that is later: the last day the date pickers allow.
    static func latestPickable(now: Date, timeZone: TimeZone) -> Date {
        max(now, LabCalendarDay(now, timeZone: timeZone).noon(in: timeZone) ?? now)
    }
}

/// One value on the typed entry form. The number stays text until `build`, so the digits typed are the digits kept.
public struct LabValueDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var subject: LabValueSubject
    public var numberText: String
    /// The unit the person picked, or nil when the report prints none.
    public var unit: String?
    public var rangeLowText: String
    public var rangeHighText: String
    public var rangeText: String
    public var flagText: String
    /// Kept when a stored value is edited: its source and scan confidence stay, and an edit counts as checked.
    var source: LabEntrySource
    var scanConfidence: Double?
    /// The stored unit, so an edit that leaves it alone is never refused for its spelling.
    var keptUnit: String?
    var assay: String?

    public static let maximumFlagLength = 24
    public static let maximumRangeTextLength = 48

    public init(id: UUID = UUID(), subject: LabValueSubject, numberText: String = "", unit: String? = nil,
                rangeLowText: String = "", rangeHighText: String = "", rangeText: String = "", flagText: String = "") {
        self.id = id
        self.subject = subject
        self.numberText = numberText
        self.unit = unit ?? (subject.markerKey.map { $0.marker.canonicalUnit })
        self.rangeLowText = rangeLowText
        self.rangeHighText = rangeHighText
        self.rangeText = rangeText
        self.flagText = flagText
        source = .typed
        scanConfidence = nil
        keptUnit = nil
        assay = nil
    }

    /// A draft that starts from a stored value, to edit it.
    public init(editing value: LabValue, locale: Locale = LooprUnitFormatter.displayLocale) {
        id = value.id
        subject = value.subject
        numberText = (value.comparator?.symbol ?? "") + LabEntryNumber.localized(value.displayValue, locale: locale)
        unit = value.unit
        rangeLowText = value.referenceRange.low.map { LabEntryNumber.localized($0.description, locale: locale) } ?? ""
        rangeHighText = value.referenceRange.high.map { LabEntryNumber.localized($0.description, locale: locale) } ?? ""
        rangeText = value.referenceRange.text ?? ""
        flagText = value.flagText ?? ""
        source = value.source
        scanConfidence = value.scanConfidence
        keptUnit = value.unit
        assay = value.assay
    }

    public var name: String { subject.displayName }

    /// The sign at the front of the typed number, for a result the lab printed as a limit. Setting it rewrites the
    /// front of `numberText` and keeps the digits.
    public var comparator: LabValueComparator? {
        get { LabValueComparator.split(numberText).comparator }
        set { numberText = (newValue?.symbol ?? "") + LabValueComparator.split(numberText).rest }
    }

    /// The values left blank are not an error until the person saves.
    public var hasNumber: Bool { !numberText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func build(reportID: UUID) throws -> LabValue {
        let name = self.name
        if case .other(let typed) = subject, typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LabEntryError.blankTestName
        }
        guard hasNumber else { throw LabEntryError.missingNumber(name) }
        guard let number = LabEntryNumber.parseResult(numberText) else { throw LabEntryError.unreadableNumber(name) }

        let cleanUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedUnit = (cleanUnit?.isEmpty ?? true) ? nil : cleanUnit
        if let storedUnit, let key = subject.markerKey, !key.marker.units.contains(storedUnit), storedUnit != keptUnit {
            throw LabEntryError.unitNotListed(marker: name, unit: storedUnit)
        }

        let range = try buildRange(name: name)
        let flag = flagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flag.count <= Self.maximumFlagLength else { throw LabEntryError.flagTooLong(name) }

        let subject: LabValueSubject
        if case .other(let typed) = self.subject {
            subject = .other(name: typed.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            subject = self.subject
        }
        let value = LabValue(
            id: id, reportID: reportID, subject: subject, assay: assay, value: number.value,
            printedValue: number.printed, comparator: number.comparator, unit: storedUnit, referenceRange: range,
            flagText: flag.isEmpty ? nil : flag, source: source, scanConfidence: scanConfidence, needsReview: false)
        do { try value.validate() } catch let error as LabValidationError { throw LabEntryError.model(error) }
        return value
    }

    private func buildRange(name: String) throws -> LabReferenceRange {
        let low = rangeLowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let high = rangeHighText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = rangeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !low.isEmpty || !high.isEmpty { throw LabEntryError.rangeMixed(name) }
        if !text.isEmpty {
            guard text.count <= Self.maximumRangeTextLength else { throw LabEntryError.unreadableRange(name) }
            return LabReferenceRange(text: text)
        }
        var lowNumber: Decimal?
        var highNumber: Decimal?
        if !low.isEmpty {
            guard let parsed = LabEntryNumber.parse(low) else { throw LabEntryError.unreadableRange(name) }
            lowNumber = parsed.value
        }
        if !high.isEmpty {
            guard let parsed = LabEntryNumber.parse(high) else { throw LabEntryError.unreadableRange(name) }
            highNumber = parsed.value
        }
        if let lowNumber, let highNumber, lowNumber > highNumber { throw LabEntryError.rangeOutOfOrder(name) }
        return LabReferenceRange(low: lowNumber, high: highNumber)
    }
}

/// The typed report form: a day, the lab, whether the person fasted, and the values.
public struct LabTypedReportDraft: Equatable, Sendable {
    public enum Fasting: String, CaseIterable, Sendable {
        case unknown, fasting, notFasting

        public var title: String {
            switch self {
            case .unknown: "Not stated"
            case .fasting: "Fasting"
            case .notFasting: "Not fasting"
            }
        }

        public init(_ stored: Bool?) {
            self = switch stored {
            case true?: .fasting
            case false?: .notFasting
            case nil: .unknown
            }
        }

        public var stored: Bool? {
            switch self {
            case .unknown: nil
            case .fasting: true
            case .notFasting: false
            }
        }
    }

    /// The day drawn, as the person picked it.
    public var collectedDay: LabCalendarDay
    public var timeZoneIdentifier: String
    public var labName: String
    public var fasting: Fasting
    public var note: String
    public var values: [LabValueDraft]

    /// The report's zone, the one the date picker shows the day in.
    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The picked day for a date picker: midday of it in the report's zone. Setting it keeps the day the picker shows
    /// in that zone. Show the picker with `.environment(\.timeZone, timeZone)`.
    public var collectedOn: Date {
        get { collectedDay.noon(in: timeZone) ?? Date(timeIntervalSince1970: 0) }
        set { collectedDay = LabCalendarDay(newValue, timeZone: timeZone) }
    }

    public init(collectedOn: Date, timeZoneIdentifier: String = TimeZone.current.identifier, labName: String = "",
                fasting: Fasting = .unknown, note: String = "", values: [LabValueDraft] = []) {
        collectedDay = LabCalendarDay(collectedOn, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.labName = labName
        self.fasting = fasting
        self.note = note
        self.values = values
    }

    /// Whether a marker already has a row, so the search can say so instead of adding a second one.
    public func contains(_ key: LabMarkerKey) -> Bool { values.contains { $0.subject.markerKey == key } }

    /// The report and its values as the model stores them, source typed. Nothing is saved here.
    public func build(now: Date, id: UUID = UUID()) throws -> (report: LabReport, values: [LabValue]) {
        guard !values.isEmpty else { throw LabEntryError.noValues }
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw LabEntryError.model(.unknownTimeZone(timeZoneIdentifier))
        }
        let collectedAt = try LabEntryDates.collectionTime(of: collectedDay, timeZone: zone, now: now).get()

        var seen: Set<LabMarkerKey> = []
        for draft in values {
            if let key = draft.subject.markerKey, !seen.insert(key).inserted { throw LabEntryError.duplicateMarker(draft.name) }
        }
        let built = try values.map { try $0.build(reportID: id) }

        let lab = labName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = LabReport(
            id: id, collectedAt: collectedAt, timeZoneIdentifier: timeZoneIdentifier, labName: lab.isEmpty ? nil : lab,
            fasting: fasting.stored, source: .typed, createdAt: now, note: trimmedNote.isEmpty ? nil : trimmedNote)
        do { try report.validate() } catch let error as LabValidationError { throw LabEntryError.model(error) }
        return (report, built)
    }
}

/// The lab clock form: which clock, the number and unit the lab printed, who ran it, and when.
public struct LabClockDraft: Equatable, Sendable {
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case dunedinPACE, grimAge, other

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .dunedinPACE: "DunedinPACE"
            case .grimAge: "GrimAge"
            case .other: "Another clock"
            }
        }
    }

    public var choice: Choice
    public var otherName: String
    public var valueText: String
    public var unit: String
    public var labName: String
    /// The day the lab drew the sample, as the person picked it.
    public var collectedDay: LabCalendarDay
    public var timeZoneIdentifier: String
    public var note: String

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The picked day for a date picker, as `LabTypedReportDraft.collectedOn`.
    public var collectedOn: Date {
        get { collectedDay.noon(in: timeZone) ?? Date(timeIntervalSince1970: 0) }
        set { collectedDay = LabCalendarDay(newValue, timeZone: timeZone) }
    }

    public init(choice: Choice = .dunedinPACE, otherName: String = "", valueText: String = "", unit: String = "",
                labName: String = "", collectedOn: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
                note: String = "") {
        self.choice = choice
        self.otherName = otherName
        self.valueText = valueText
        self.unit = unit
        self.labName = labName
        collectedDay = LabCalendarDay(collectedOn, timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.note = note
    }

    public var kind: LabClockKind {
        switch choice {
        case .dunedinPACE: .dunedinPACE
        case .grimAge: .grimAge
        case .other: .other(name: otherName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The result as the model stores it. The number is the lab's: Loopr never works a clock out.
    public func build(now: Date, id: UUID = UUID()) throws -> LabClockResult {
        if choice == .other, otherName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LabEntryError.blankTestName
        }
        let lab = labName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lab.isEmpty else { throw LabEntryError.blankLabName }
        let name = kind.displayName
        guard !valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LabEntryError.missingNumber(name) }
        guard let number = LabEntryNumber.parse(valueText) else { throw LabEntryError.unreadableNumber(name) }
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw LabEntryError.model(.unknownTimeZone(timeZoneIdentifier))
        }
        let collectedAt = try LabEntryDates.collectionTime(of: collectedDay, timeZone: zone, now: now).get()
        let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = LabClockResult(
            id: id, kind: kind, value: number.value, unit: cleanUnit.isEmpty ? nil : cleanUnit, labName: lab,
            collectedAt: collectedAt, timeZoneIdentifier: timeZoneIdentifier, createdAt: now,
            note: cleanNote.isEmpty ? nil : cleanNote)
        do { try result.validate() } catch let error as LabValidationError { throw LabEntryError.model(error) }
        return result
    }
}
