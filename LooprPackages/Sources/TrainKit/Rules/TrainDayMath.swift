import Foundation

/// Whole-day arithmetic on `yyyy-MM-dd` local days. Pure integer math, so no calendar,
/// time zone or clock is involved and a result never depends on where the code runs.
enum TrainDayMath {
    /// Days since 1970-01-01 for a valid local-day string.
    static func ordinal(_ text: String) -> Int? {
        guard TrainDay.isValid(text) else { return nil }
        let pieces = text.split(separator: "-")
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func string(ordinal: Int) -> String {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// ISO weekday of an ordinal day. 1970-01-01 was a Thursday.
    static func weekday(ordinal: Int) -> TrainWeekday {
        let index = ((ordinal + 3) % 7 + 7) % 7
        return TrainWeekday(rawValue: index + 1) ?? .monday
    }
}

extension TrainWeekday {
    /// English name used in rule messages.
    var ruleName: String {
        switch self {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }
}
