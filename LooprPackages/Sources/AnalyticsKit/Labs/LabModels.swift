import Foundation

/// How a report or a value got into Loopr.
public enum LabEntrySource: String, Codable, CaseIterable, Sendable {
    case typed
    case scan
}

public enum LabValidationError: Error, Equatable, Sendable {
    case unknownTimeZone(String)
    case blankName
    case blankLabName
    case nonFiniteValue
    case scanConfidenceOutOfRange
    /// A typed value has no scan confidence and nothing to review.
    case typedValueCarriesScanFields
    case valueBelongsToAnotherReport
    /// The printed value is not dot-notation digits, or does not equal the stored value.
    case printedValueMismatch
}

/// One lab report: a blood draw and the values the lab printed for it. A report holds what the lab said and
/// nothing Loopr worked out.
public struct LabReport: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var collectedAt: Date
    public var timeZoneIdentifier: String
    public var labName: String?
    /// Nil when the report does not say.
    public var fasting: Bool?
    public var source: LabEntrySource
    public var createdAt: Date
    public var note: String?

    public init(
        id: UUID = UUID(),
        collectedAt: Date,
        timeZoneIdentifier: String,
        labName: String? = nil,
        fasting: Bool? = nil,
        source: LabEntrySource,
        createdAt: Date,
        note: String? = nil
    ) {
        self.id = id
        self.collectedAt = collectedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.labName = labName
        self.fasting = fasting
        self.source = source
        self.createdAt = createdAt
        self.note = note
    }

    /// The calendar day of collection in the report's own time zone, as `yyyy-MM-dd`. Nil for an unknown zone.
    public var collectedDay: String? {
        LabCalendar.day(of: collectedAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func validate() throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw LabValidationError.unknownTimeZone(timeZoneIdentifier)
        }
    }
}

enum LabCalendar {
    static func day(of date: Date, timeZoneIdentifier: String) -> String? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// What a value is: a marker from the catalog, or a test Loopr has no entry for, kept under the lab's own
/// name text. Values for unknown tests are never dropped.
public enum LabValueSubject: Sendable, Hashable {
    case marker(LabMarkerKey)
    case other(name: String)

    public var markerKey: LabMarkerKey? {
        if case .marker(let key) = self { return key }
        return nil
    }

    /// The catalog name, or the lab's own name text for an other value.
    public var displayName: String {
        switch self {
        case .marker(let key): key.marker.displayName
        case .other(let name): name
        }
    }
}

/// The lab's own reference range, exactly as printed. Either bound, both, or a text such as "<5.0" or
/// "negativ". Loopr never fills a missing range and never compares a value against it.
public struct LabReferenceRange: Sendable, Hashable {
    public var low: Decimal?
    public var high: Decimal?
    public var text: String?

    public static let none = LabReferenceRange()

    public init(low: Decimal? = nil, high: Decimal? = nil, text: String? = nil) {
        self.low = low
        self.high = high
        self.text = text
    }

    public var isEmpty: Bool { low == nil && high == nil && text == nil }
}

/// A result the lab printed as a limit rather than an exact number: "<0.3" below detection, ">200" above the
/// measuring range. The number beside it is the limit, not the result.
public enum LabValueComparator: String, Sendable, Hashable, CaseIterable {
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="

    /// The sign as a screen shows it before the digits.
    public var symbol: String {
        switch self {
        case .lessThan: "<"
        case .lessThanOrEqual: "≤"
        case .greaterThan: ">"
        case .greaterThanOrEqual: "≥"
        }
    }

    /// Reads a printed sign: "<", "<=", "≤", ">", ">=" or "≥". Nil for anything else.
    public init?(printed: String) {
        switch printed.trimmingCharacters(in: .whitespaces) {
        case "<": self = .lessThan
        case "<=", "≤", "=<": self = .lessThanOrEqual
        case ">": self = .greaterThan
        case ">=", "≥", "=>": self = .greaterThanOrEqual
        default: return nil
        }
    }

    /// Splits a leading sign off number text: "<0.3" gives `.lessThan` and "0.3", "< 0,3" gives `.lessThan` and "0,3".
    /// Text with no sign comes back whole with a nil sign.
    public static func split(_ text: String) -> (comparator: LabValueComparator?, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for sign in ["<=", ">=", "=<", "=>", "<", ">", "≤", "≥"] where trimmed.hasPrefix(sign) {
            let rest = String(trimmed.dropFirst(sign.count)).trimmingCharacters(in: .whitespaces)
            return (LabValueComparator(printed: sign), rest)
        }
        return (nil, trimmed)
    }
}

/// One printed result. The value keeps the digits the lab printed. The unit, range and flag are the lab's text.
public struct LabValue: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var reportID: UUID
    public var subject: LabValueSubject
    /// The assay note when the lab gives one, for example "hs-CRP" or "CRP" on the C-reactive protein marker.
    public var assay: String?
    public var value: Decimal
    /// The digits exactly as the lab printed or the person typed them, in dot notation, when they differ from
    /// the plain number: "5.0" for a value of 5. Nil when the plain number already reads the same.
    public var printedValue: String?
    /// The sign the lab printed before the number, for a result given as a limit ("<0.3", ">200"). `value` then holds
    /// the limit. Nil for an exact result.
    public var comparator: LabValueComparator?
    /// The unit as printed. Nil when the report prints none; Loopr never fills one in.
    public var unit: String?
    public var referenceRange: LabReferenceRange
    /// The lab's own flag text, such as "H" or "*", when printed. Loopr never sets this.
    public var flagText: String?
    public var source: LabEntrySource
    /// Reading confidence from 0 to 1. Only for scanned values.
    public var scanConfidence: Double?
    /// A scanned value the person has not checked yet. Always false for a typed value.
    public var needsReview: Bool

    public init(
        id: UUID = UUID(),
        reportID: UUID,
        subject: LabValueSubject,
        assay: String? = nil,
        value: Decimal,
        printedValue: String? = nil,
        comparator: LabValueComparator? = nil,
        unit: String? = nil,
        referenceRange: LabReferenceRange = .none,
        flagText: String? = nil,
        source: LabEntrySource,
        scanConfidence: Double? = nil,
        needsReview: Bool = false
    ) {
        self.id = id
        self.reportID = reportID
        self.subject = subject
        self.assay = assay
        self.value = value
        self.printedValue = printedValue
        self.comparator = comparator
        self.unit = unit
        self.referenceRange = referenceRange
        self.flagText = flagText
        self.source = source
        self.scanConfidence = scanConfidence
        self.needsReview = needsReview
    }

    /// What a screen shows for the number: the printed digits when there are any, else the plain number.
    /// Always dot notation; the screen localises the separator.
    public var displayValue: String { printedValue ?? value.description }

    /// The result as the lab printed it, sign included: "<0.3", ">200" or "5.0". Dot notation.
    public var printedText: String { (comparator?.symbol ?? "") + displayValue }

    /// True when the lab printed a limit, not an exact number.
    public var isLimit: Bool { comparator != nil }

    public func validate() throws {
        if case .other(let name) = subject, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LabValidationError.blankName
        }
        guard !value.isNaN else { throw LabValidationError.nonFiniteValue }
        if let printedValue {
            guard let parsed = LabNumberText.parse(printedValue), parsed.value == value else {
                throw LabValidationError.printedValueMismatch
            }
        }
        if referenceRange.low?.isNaN == true || referenceRange.high?.isNaN == true {
            throw LabValidationError.nonFiniteValue
        }
        if let scanConfidence, !(0...1).contains(scanConfidence) {
            throw LabValidationError.scanConfidenceOutOfRange
        }
        if source == .typed, scanConfidence != nil || needsReview {
            throw LabValidationError.typedValueCarriesScanFields
        }
    }
}

public enum LabClockKind: Sendable, Hashable {
    case dunedinPACE
    case grimAge
    case other(name: String)

    public var displayName: String {
        switch self {
        case .dunedinPACE: "DunedinPACE"
        case .grimAge: "GrimAge"
        case .other(let name): name
        }
    }
}

/// An epigenetic clock result a lab reported, typed in with the lab's name. Loopr stores it and never
/// computes one.
public struct LabClockResult: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var kind: LabClockKind
    public var value: Decimal
    /// The unit as printed, for example "years". Nil for a rate such as DunedinPACE that has none.
    public var unit: String?
    public var labName: String
    public var collectedAt: Date
    public var timeZoneIdentifier: String
    public var createdAt: Date
    public var note: String?

    public init(
        id: UUID = UUID(),
        kind: LabClockKind,
        value: Decimal,
        unit: String? = nil,
        labName: String,
        collectedAt: Date,
        timeZoneIdentifier: String,
        createdAt: Date,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.unit = unit
        self.labName = labName
        self.collectedAt = collectedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.note = note
    }

    public var collectedDay: String? {
        LabCalendar.day(of: collectedAt, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func validate() throws {
        if case .other(let name) = kind, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LabValidationError.blankName
        }
        guard !labName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LabValidationError.blankLabName
        }
        guard !value.isNaN else { throw LabValidationError.nonFiniteValue }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw LabValidationError.unknownTimeZone(timeZoneIdentifier)
        }
    }
}

/// Dot-notation number text, as typed into a field after the screen has turned the person's decimal separator
/// into a dot. It never guesses a separator: a comma, a thousands mark or any other character is refused.
public enum LabNumberText {
    /// The number, and the printed digits when they differ from the plain number ("5.0" for 5).
    public static func parse(_ text: String) -> (value: Decimal, printedValue: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsigned = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (value, trimmed == value.description ? nil : trimmed)
    }
}
