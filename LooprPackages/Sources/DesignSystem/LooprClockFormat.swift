import Foundation

/// The one way Loopr writes a clock time. It follows the locale, so a 12-hour locale gets "9:00 pm" and a 24-hour
/// locale gets "21:00". The Sleep hero, Sleep's "What was different" card, Today's timeline and the pattern copy all
/// go through it, so the same time never reads two ways on one screen.
public enum LooprClockFormat {
    private static let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// A time of day, in minutes after midnight. A value past 24 hours or below zero wraps around the clock.
    public static func text(minuteOfDay minutes: Int, locale: Locale = .current) -> String {
        let day = ((minutes % 1_440) + 1_440) % 1_440
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: day / 60, minute: day % 60)) ?? Date()
        // The locale's own hour and minute pattern ("HH:mm" in en_GB and de_DE, "h:mm a" in en_US). Date.FormatStyle's
        // shortened time drops the leading zero of a 24-hour hour ("7:05"), which is not how those locales write it.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = utc
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: reference)
    }

    /// Rewrites each 24-hour time in a stored sentence ("when you eat after 21:00", "Kitchen closed at 20:30") in the
    /// locale's own style. The stored text does not change. Only the display does. Anything that is not a time stays as it is.
    /// A time that already carries a day period is left alone, so a sentence that passes through twice reads "9:00 PM",
    /// not "9:00 AM PM" (UX R1-DES-17).
    public static func localizing(_ sentence: String, locale: Locale = .current) -> String {
        guard sentence.contains(":"),
              let expression = try? NSRegularExpression(pattern: #"(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])(?!\s*[AaPp]\.?[Mm])"#) else {
            return sentence
        }
        let whole = NSRange(sentence.startIndex..., in: sentence)
        var result = ""
        var cursor = sentence.startIndex
        for match in expression.matches(in: sentence, range: whole) {
            guard let range = Range(match.range, in: sentence),
                  let hourRange = Range(match.range(at: 1), in: sentence), let minuteRange = Range(match.range(at: 2), in: sentence),
                  let hour = Int(sentence[hourRange]), let minute = Int(sentence[minuteRange]) else { continue }
            result += sentence[cursor..<range.lowerBound]
            result += text(minuteOfDay: hour * 60 + minute, locale: locale)
            cursor = range.upperBound
        }
        return result + sentence[cursor...]
    }
}
