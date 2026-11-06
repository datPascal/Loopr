import Foundation

/// RFC 4180 text: fields with a comma, quote or line break are quoted, quotes doubled, lines end in CRLF.
public enum CSV {
    public static func text(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func field(_ value: String) -> String {
        // A leading =, +, - or @ makes spreadsheets run the cell as a formula; a quote mark stops that.
        let safe = value.first.map { "=+-@".contains($0) && Double(value) == nil } == true ? "'" + value : value
        guard safe.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        let rounded = (value * 1_000).rounded() / 1_000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// "18:05" in the entry's own zone.
    public static func time(_ date: Date, zone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// ISO 8601 in UTC.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
