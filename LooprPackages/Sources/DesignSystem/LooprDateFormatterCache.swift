import Foundation

/// Shared fixed-format date formatters.
///
/// Building a `DateFormatter` costs far more than using one, and header,
/// axis, scrub and calendar labels used to build a new one for every string,
/// several times per frame while a chart is scrubbed. Formatters here are
/// built once per format, locale, calendar and time zone, then reused.
/// `DateFormatter` is safe to use from several threads once configured; a
/// cached formatter is never reconfigured.
public enum LooprDateFormatterCache {
    /// Fixed English date words, so labels read "Tue 22 Sep" on every device.
    public static let posixLocale = Locale(identifier: "en_US_POSIX")

    private struct Key: Hashable {
        let format: String
        let locale: String
        let calendar: Calendar.Identifier
        let timeZone: String
        let firstWeekday: Int
    }

    private struct TemplateKey: Hashable {
        let template: String
        let locale: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [Key: DateFormatter] = [:]
    nonisolated(unsafe) private static var templates: [TemplateKey: String] = [:]

    public static func formatter(
        _ format: String,
        calendar: Calendar,
        locale: Locale = posixLocale
    ) -> DateFormatter {
        let key = Key(
            format: format,
            locale: locale.identifier,
            calendar: calendar.identifier,
            timeZone: calendar.timeZone.identifier,
            firstWeekday: calendar.firstWeekday
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }

    /// A formatter for a localized template such as "jmm", resolved once per
    /// template and locale.
    public static func formatter(
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> DateFormatter {
        let key = TemplateKey(template: template, locale: locale.identifier)
        lock.lock()
        let resolved = templates[key]
        lock.unlock()
        let format: String
        if let resolved {
            format = resolved
        } else {
            format = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
            lock.lock()
            templates[key] = format
            lock.unlock()
        }
        return formatter(format, calendar: calendar, locale: locale)
    }

    public static func string(
        from date: Date,
        format: String,
        calendar: Calendar,
        locale: Locale = posixLocale
    ) -> String {
        formatter(format, calendar: calendar, locale: locale).string(from: date)
    }
}
