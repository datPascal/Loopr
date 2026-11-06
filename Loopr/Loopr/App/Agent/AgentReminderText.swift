import Foundation

/// The words of a reminder show on the lock screen, where anyone who picks up the phone can read them. A
/// reminder therefore never carries a health reading.
nonisolated enum AgentReminderText {
    /// What the model reads when its reminder is refused.
    static let refusal = "A reminder shows its title and body on the lock screen, so neither can carry a health reading: a number with a unit such as bpm, ms, %, kg, kcal, h or min, or a metric name with its value. Write the reminder without the number, for example \"Wind down for bed\"."

    private static let unit = #"(?:bpm|ms|kg|lbs?|kcal|cal|hrs?|h|hours?|mins?|minutes?|steps?|mmhg|km|mi)\b"#
    private static let number = #"\d+(?:[.,]\d+)?"#
    private static let metric = #"(?:hrv|rhr|resting heart rate|heart rate|pulse|spo2|blood oxygen|blood pressure|vo2(?: ?max)?|recovery|strain|readiness|sleep score|deep sleep|sleep|weight|bmi|stress|calories)"#

    private static let patterns: [NSRegularExpression] = [
        // 62 bpm, 45 ms, 7 h, 90%.
        try! NSRegularExpression(pattern: #"(?<![\d:])"# + number + #"\s?"# + unit, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"(?<![\d:])"# + number + #"\s?%"#, options: []),
        // HRV 42, recovery score: 71, heart rate is 58. A clock time after the name is not a reading.
        try! NSRegularExpression(
            pattern: #"\b"# + metric + #"\b(?:\s+(?:score|rate|level|reading|average))?\s*(?:is|was|at|of|reads?|:|=|-)?\s*"# + number + #"(?![\d:]|[.,]\d|\s?(?:am|pm)\b)"#,
            options: [.caseInsensitive]),
        // 42 HRV.
        try! NSRegularExpression(pattern: #"(?<![\d:])"# + number + #"\s?"# + metric + #"\b"#, options: [.caseInsensitive]),
    ]

    /// The first health reading in `text`, or nil when the text is safe to show on the lock screen.
    static func healthReading(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let match = pattern.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
                return String(text[swiftRange])
            }
        }
        return nil
    }
}
