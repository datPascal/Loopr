import Foundation

/// Loopr sets every label in sentence case (redesign of 2026-10-22). Labels used to be uppercase
/// mono, so some callers still hand over an all-caps string such as "LAST 3 MIN". This turns that
/// into "Last 3 min", keeping acronyms ("HRV", "GPS") and writing units the way they are written in
/// prose ("bpm", "ms", "kg"). A string that already has lowercase letters is left exactly as it is.
public enum LooprLabelCase {
    /// Words that stay uppercase.
    static let acronyms: Set<String> = [
        "HRV", "RPE", "GPS", "HR", "BJJ", "AI", "PR", "PRS", "AU", "VO2", "VO2MAX", "SPO2", "ECG", "UV", "BMI",
        "AM", "PM", "UTC", "GMT", "ID", "CSV", "GPX", "JSON", "FIT", "TCX", "PDF", "API", "USB", "RHR", "HRR",
        "1RM", "AMRAP", "EMOM", "WOD", "HIIT", "OK", "TV", "WHOOP", "II", "III", "IV", "SDNN", "RMSSD", "USDA"
    ]
    /// Units and abbreviations written in lowercase.
    static let lowercaseWords: [String: String] = [
        "BPM": "bpm", "MS": "ms", "KG": "kg", "LB": "lb", "LBS": "lb", "KM": "km", "MI": "mi", "M": "m", "H": "h",
        "MIN": "min", "MINS": "min", "SEC": "sec", "S": "s", "KCAL": "kcal", "ML": "ml", "G": "g", "CM": "cm",
        "BR/MIN": "br/min", "MMHG": "mmHg", "°C": "°C", "°F": "°F", "%": "%", "/KM": "/km", "/MI": "/mi"
    ]
    /// Words that keep a capital wherever they sit.
    static let properWords: Set<String> = [
        "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN",
        "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY",
        "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "SEPT", "OCT", "NOV", "DEC",
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER",
        "NOVEMBER", "DECEMBER", "LOOPR", "APPLE", "HEALTH", "I"
    ]

    /// Sentence case for an all-caps label; anything else unchanged.
    public static func sentence(_ text: String) -> String {
        // One letter is a weekday initial ("M", "T"), not a word.
        guard text.count > 1, text.contains(where: \.isLetter), !text.contains(where: \.isLowercase) else { return text }
        var result = ""
        var atSentenceStart = true
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            result += convert(word, first: atSentenceStart)
            if word.contains(where: \.isLetter) || word.contains(where: \.isNumber) { atSentenceStart = false }
            word = ""
        }
        for character in text {
            if character == " " || character == "\n" || character == "·" || character == "," || character == "(" || character == ")" {
                flush()
                result.append(character)
                if character == "·" || character == "\n" { atSentenceStart = true }
            } else if character == "." || character == ":" || character == "?" || character == "!" {
                flush()
                result.append(character)
                atSentenceStart = character != ":"
            } else {
                word.append(character)
            }
        }
        flush()
        return result
    }

    private static func convert(_ word: String, first: Bool) -> String {
        let upper = word.uppercased()
        if acronyms.contains(upper) { return word }
        if let unit = lowercaseWords[upper] { return first && unit.first?.isLetter == true && word.count > 2 ? unit.capitalized : unit }
        // A number with a unit glued on: "12KG", "45MIN", "6:18/KM".
        if let index = word.firstIndex(where: \.isLetter), word[word.startIndex..<index].contains(where: \.isNumber) {
            let suffix = String(word[index...])
            if let unit = lowercaseWords[suffix.uppercased()] { return word[..<index] + unit }
            if acronyms.contains(suffix.uppercased()) { return word }
            return word[..<index] + suffix.lowercased()
        }
        let lower = word.lowercased()
        if first || properWords.contains(upper) { return lower.prefix(1).uppercased() + lower.dropFirst() }
        // "WEEK-3" style compounds keep any acronym part.
        if word.contains("-") || word.contains("/") {
            let separator: Character = word.contains("-") ? "-" : "/"
            return word.split(separator: separator, omittingEmptySubsequences: false)
                .map { acronyms.contains(String($0)) ? String($0) : String($0).lowercased() }
                .joined(separator: String(separator))
        }
        return lower
    }
}

public extension String {
    /// This label in Loopr's sentence case. See `LooprLabelCase`.
    var looprLabelCased: String { LooprLabelCase.sentence(self) }
}
