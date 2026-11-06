import DomainKit
import Foundation

/// The limits every note uses. They are stated here so a test can name them and a change is one line.
public struct NoteThresholds: Equatable, Sendable {
    /// A factor is named only when both of its groups have at least this many nights with an outcome.
    public let minimumNightsPerGroup: Int
    /// The usual needs this many nights with data. Under it the note says what it is learning.
    public let minimumUsualNights: Int
    /// An evening note names at most this many rules in a list. The rest are counted.
    public let maximumListedRules: Int
    /// A weekly count is stated from this many kept days.
    public let minimumWeekCount: Int

    public init(minimumNightsPerGroup: Int = 7, minimumUsualNights: Int = 7, maximumListedRules: Int = 4, minimumWeekCount: Int = 2) {
        self.minimumNightsPerGroup = minimumNightsPerGroup; self.minimumUsualNights = minimumUsualNights
        self.maximumListedRules = maximumListedRules; self.minimumWeekCount = minimumWeekCount
    }

    public static let standard = NoteThresholds()
}

/// The locale and calendar a note is written in. Tests inject both, so a note never reads the device.
public struct NoteContext: Sendable {
    public let locale: Locale
    public let calendar: Calendar
    public let thresholds: NoteThresholds

    public init(locale: Locale = .current, calendar: Calendar = .current, thresholds: NoteThresholds = .standard) {
        self.locale = locale; self.calendar = calendar; self.thresholds = thresholds
    }

    /// A time of day in minutes after midnight, written in this context's locale and calendar. It reads nothing from the
    /// device: not `Locale.current`, not the 12-hour or 24-hour setting. Date.FormatStyle drops the leading zero of a
    /// 24-hour time ("7:00"), so this uses a `DateFormatter`, which gives "07:00" in en_GB and de_DE and "7:00 AM" in
    /// en_US.
    func clockText(minuteOfDay minutes: Int) -> String {
        let day = ((minutes % 1_440) + 1_440) % 1_440
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var parts = DateComponents()
        parts.year = 2001; parts.month = 1; parts.day = 1; parts.hour = day / 60; parts.minute = day % 60
        let reference = utc.date(from: parts) ?? Date(timeIntervalSinceReferenceDate: 0)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: reference)
    }

    /// Rewrites each 24-hour time in a sentence ("after 21:00") in this context's clock. Anything that is not a time stays.
    func localizingClock(_ sentence: String) -> String {
        guard sentence.contains(":") else { return sentence }
        var result = ""
        var cursor = sentence.startIndex
        for range in NoteDigits.ranges(in: sentence) {
            let token = sentence[range]
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count <= 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  hour < 24, minute < 60, parts[0].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isASCII) else { continue }
            result += sentence[cursor..<range.lowerBound]
            result += clockText(minuteOfDay: hour * 60 + minute)
            cursor = range.upperBound
        }
        return result + sentence[cursor...]
    }

    func weekday(of day: DayIdentity) -> String? {
        var parts = DateComponents()
        parts.year = day.year; parts.month = day.month; parts.day = day.day; parts.hour = 12
        guard let date = calendar.date(from: parts) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }
}

/// The words a coach sentence may not contain. A cause is a claim the person's own nights cannot make.
enum NoteGuard {
    private static let bannedWords: Set<String> = ["cause", "causes", "caused", "causing", "because"]

    static func isClean(_ text: String) -> Bool {
        if text.contains("!") || text.contains("\u{2014}") || text.contains("\u{2013}") { return false }
        let lowered = text.lowercased()
        if lowered.contains("due to") { return false }
        let words = lowered.split { !$0.isLetter }
        return !words.contains { bannedWords.contains(String($0)) }
    }
}

struct NoteFormatter {
    let context: NoteContext
    var locale: Locale { context.locale }

    func integer(_ value: Int) -> String {
        IntegerFormatStyle<Int>(locale: locale).grouping(.automatic).format(value)
    }

    func padded(_ value: Int) -> String {
        IntegerFormatStyle<Int>(locale: locale).precision(.integerLength(2...)).grouping(.never).format(value)
    }

    /// A value as the text will state it. Nil for a value that is not finite or is below zero, so no note states one.
    func number(_ value: Double, unit: NoteUnit) -> NoteNumber? {
        guard value.isFinite, value >= 0, value < 1_000_000_000 else { return nil }
        let rounded = Int(value.rounded())
        switch unit {
        case .bpm: return NoteNumber(displayed: "\(integer(rounded)) bpm", value: Double(rounded), unit: unit)
        case .milliseconds: return NoteNumber(displayed: "\(integer(rounded)) ms", value: Double(rounded), unit: unit)
        case .minutes: return NoteNumber(displayed: duration(minutes: rounded), value: Double(rounded), unit: unit)
        case .clock:
            guard (0..<1_440).contains(rounded) else { return nil }
            return NoteNumber(displayed: context.clockText(minuteOfDay: rounded), value: Double(rounded), unit: unit)
        case .nights: return count(rounded, noun: "night", unit: unit)
        case .days: return count(rounded, noun: "day", unit: unit)
        case .percent: return NoteNumber(displayed: "\(integer(rounded))%", value: Double(rounded), unit: unit)
        case .count, .literal: return NoteNumber(displayed: integer(rounded), value: Double(rounded), unit: unit)
        }
    }

    /// "4 h 04 m", "4 h", "48 min".
    func duration(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(integer(rest)) min" }
        if rest == 0 { return "\(integer(hours)) h" }
        return "\(integer(hours)) h \(padded(rest)) m"
    }

    func count(_ value: Int, noun: String, unit: NoteUnit) -> NoteNumber {
        NoteNumber(displayed: "\(integer(value)) \(noun)\(value == 1 ? "" : "s")", value: Double(value), unit: unit)
    }

    /// The number as a chip writes it: "49" for a heart rate, "4 h 04 m" for a length of time.
    func bare(_ number: NoteNumber) -> String {
        switch number.unit {
        case .bpm: String(number.displayed.dropLast(" bpm".count))
        case .milliseconds: String(number.displayed.dropLast(" ms".count))
        default: number.displayed
        }
    }

    func factorValue(_ value: NoteFactorValue) -> NoteNumber? {
        switch value {
        case .duration(let minutes): number(minutes, unit: .minutes)
        case .clock(let minute): number(Double(minute), unit: .clock)
        case .quantity(let amount, let unit):
            number(amount, unit: .count).map { NoteNumber(displayed: "\($0.displayed) \(unit)", value: $0.value, unit: .count) }
        case .flag: nil
        }
    }
}

/// Builds the runs of one note. Every digit group that reaches the text becomes a number run, so the text cannot
/// state a number the note does not carry.
struct NoteBuilder {
    private(set) var runs: [NoteRun] = []
    let context: NoteContext

    init(context: NoteContext) { self.context = context }

    /// Text from the templates or from the app (a rule title, a group label). A 24-hour time in it is rewritten in the
    /// locale's clock, and every digit group becomes a number run.
    mutating func text(_ source: String, protected: Bool = false) {
        let text = context.localizingClock(source)
        var cursor = text.startIndex
        for range in NoteDigits.ranges(in: text) {
            appendPlain(String(text[cursor..<range.lowerBound]), protected: protected)
            let token = String(text[range])
            runs.append(NoteRun(text: token, number: NoteNumber(displayed: token, value: NoteDigits.value(of: token) ?? 0, unit: .literal),
                                isProtected: protected))
            cursor = range.upperBound
        }
        appendPlain(String(text[cursor...]), protected: protected)
    }

    mutating func number(_ number: NoteNumber, highlighted: Bool = false) {
        runs.append(NoteRun(text: number.displayed, number: number, isHighlighted: highlighted))
    }

    private mutating func appendPlain(_ text: String, protected: Bool) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.number == nil, last.isProtected == protected {
            runs[runs.count - 1] = NoteRun(text: last.text + text, isProtected: protected)
        } else {
            runs.append(NoteRun(text: text, isProtected: protected))
        }
    }
}
