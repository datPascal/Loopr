import AnalyticsKit
import DesignSystem
import Foundation

/// Words and formats the blood test screens share. Nothing here judges a value: ranges and flags come back as the
/// lab printed them.
public enum LabsDisplay {
    /// The day in the person's own date order, "12 Sep 2026" in en_GB and "Sep 12, 2026" in en_US, on the calendar
    /// day in the report's own zone. The date picker on the entry form writes the day the same way; a fixed
    /// pattern beside it read like a second date (ICP R2-LAB-4).
    public static func day(_ date: Date, timeZoneIdentifier: String, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return day(date, calendar: calendar, locale: locale)
    }

    public static func day(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        LooprDateFormatterCache.formatter(template: "dMMMyyyy", calendar: calendar, locale: locale).string(from: date)
    }

    /// "Lab report · 12 Sep 2026 · fasting".
    public static func reportHeader(_ report: LabReport) -> String {
        var parts = ["Lab report", day(report.collectedAt, timeZoneIdentifier: report.timeZoneIdentifier)]
        switch report.fasting {
        case true?: parts.append("fasting")
        case false?: parts.append("not fasting")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// The small label over a report's day: "Your report · fasting". The title bar already says Lab report, so the
    /// eyebrow does not say it a second time (ICP R2-LAB-7).
    public static func reportEyebrow(_ report: LabReport) -> String {
        switch report.fasting {
        case true?: "Your report · fasting"
        case false?: "Your report · not fasting"
        case nil: "Your report"
        }
    }

    /// Where an exact value sits against the range the lab printed beside it: "Inside the lab's range" or "Outside
    /// the lab's range". Nil unless the lab printed both ends and the value is a plain number. This repeats what the
    /// lab printed and adds no judgement of Loopr's own.
    public static func rangePosition(_ value: LabValue) -> String? {
        guard value.comparator == nil, let low = value.referenceRange.low, let high = value.referenceRange.high, low <= high else { return nil }
        return (low...high).contains(value.value) ? "Inside the lab's range" : "Outside the lab's range"
    }

    /// True when `rangePosition` says the value is outside the lab's printed range.
    public static func isOutsideRange(_ value: LabValue) -> Bool {
        rangePosition(value) == "Outside the lab's range"
    }

    /// The lab's name, or "Lab report" when the report does not give one.
    public static func labName(_ report: LabReport) -> String {
        let name = report.labName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Lab report" : name
    }

    public static func sourceText(_ source: LabEntrySource) -> String {
        switch source {
        case .typed: "Typed in"
        case .scan: "Scanned"
        }
    }

    /// The value as printed, with the lab's sign for a limit ("<0.3"), in the app's number locale. A value typed as
    /// "4,5" is stored as 4.5 and shows as "4.5" in the hero, the rows, the list, the chart and the edit sheet alike
    /// (ICP R3-LAB-2, R3-UPG-2).
    public static func valueText(_ value: LabValue, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        (value.comparator?.symbol ?? "") + LabEntryNumber.localized(value.displayValue, locale: locale)
    }

    /// The value with its unit: "<0.3 mg/L", "46 g/L", or the number alone when no unit was printed.
    public static func valueWithUnit(_ value: LabValue, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        [valueText(value, locale: locale), value.unit].compactMap { $0 }.joined(separator: " ")
    }

    /// What VoiceOver says for a limit: "below 0.3", "above 200". The plain number for an exact result.
    public static func spokenValue(_ value: LabValue, locale: Locale = LooprUnitFormatter.displayLocale) -> String {
        let number = LabEntryNumber.localized(value.displayValue, locale: locale)
        switch value.comparator {
        case .lessThan?: return "below \(number)"
        case .lessThanOrEqual?: return "at most \(number)"
        case .greaterThan?: return "above \(number)"
        case .greaterThanOrEqual?: return "at least \(number)"
        case nil: return number
        }
    }

    /// The lab's own flag as printed ("H", "*"), or nil when it printed none.
    public static func flagText(_ value: LabValue) -> String? {
        guard let flag = value.flagText?.trimmingCharacters(in: .whitespaces), !flag.isEmpty else { return nil }
        return flag
    }

    /// The lab's range in words: "3.5 to 5.2", "from 3.5", "up to 5.2" or the text as printed.
    public static func rangeText(_ range: LabReferenceRange, locale: Locale = LooprUnitFormatter.displayLocale) -> String? {
        func number(_ value: Decimal) -> String { LabEntryNumber.localized(value.description, locale: locale) }
        if let text = range.text, !text.isEmpty { return text }
        switch (range.low, range.high) {
        case let (low?, high?): return "\(number(low)) to \(number(high))"
        case let (low?, nil): return "from \(number(low))"
        case let (nil, high?): return "up to \(number(high))"
        case (nil, nil): return nil
        }
    }

    /// Who set the range, for a marker page. Loopr sets none and adds none of its own (ICP R2-LAB-9).
    public static func rangeSourceLine(hasRange: Bool) -> String {
        hasRange ? "Your lab printed this range on the report. Loopr does not set ranges or add its own."
            : "Loopr does not set ranges or add its own, so with none printed there is nothing to compare with."
    }

    /// "8 values", "1 value".
    public static func valueCount(_ count: Int) -> String { count == 1 ? "1 value" : "\(count) values" }

    public static func reportCount(_ count: Int) -> String { count == 1 ? "1 report" : "\(count) reports" }

    public static let notAMedicalDevice = LooprMedicalLine.text + " Ranges and flags are the lab's own."
}
