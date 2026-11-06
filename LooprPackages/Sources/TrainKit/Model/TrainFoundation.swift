import Foundation

public enum TrainError: Error, Equatable, Sendable, LocalizedError {
    case invalidRecord, unsupportedVersion(Int), staleRevision, missingRecord

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "Check the sets, reps, loads and dates before saving."
        case .unsupportedVersion: "This training record needs a newer version of Loopr."
        case .staleRevision: "This changed since you opened it. Open it again before saving your edits."
        case .missingRecord: "This training record is no longer available."
        }
    }
}

/// ISO weekday numbering: Monday is 1, Sunday is 7.
public enum TrainWeekday: Int, CaseIterable, Codable, Comparable, Sendable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Local-day helpers shared by the store and the models. A local day is the
/// `yyyy-MM-dd` string in the zone the person was in when the record was made.
public enum TrainDay {
    public static func string(at date: Date, timeZoneIdentifier: String) throws -> String {
        guard date.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timeZoneIdentifier) else { throw TrainError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year), let month = parts.month, let day = parts.day else { throw TrainError.invalidRecord }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// True when the text is a real calendar date written as `yyyy-MM-dd`.
    public static func isValid(_ text: String) -> Bool { weekday(of: text) != nil }

    /// The weekday of a local-day string, independent of any time zone.
    public static func weekday(of text: String) -> TrainWeekday? {
        guard let components = parse(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard back.year == components.year, back.month == components.month, back.day == components.day, let weekday = back.weekday else { return nil }
        // Calendar weekday: Sunday is 1. Convert to ISO.
        return TrainWeekday(rawValue: weekday == 1 ? 7 : weekday - 1)
    }

    /// The local day `days` after (or before, when negative) a local-day string.
    public static func adding(days: Int, to text: String) -> String? {
        guard let components = parse(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: components), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: moved)
        guard let year = parts.year, let month = parts.month, let day = parts.day, (1...9999).contains(year) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parse(_ text: String) -> DateComponents? {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), year >= 1 else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}

/// The schema version every Train record is written with today.
public enum TrainRecordSchema {
    public static let currentVersion = 1
}

/// Text limits shared by every Train record so one bad import cannot grow a payload without bound.
enum TrainLimits {
    static let name = 80
    static let note = 500
    static let request = 2_000
    static let maxSets = 20
    /// Reps in one set of a loaded lift.
    static let maxReps = 100
    /// Reps in one bodyweight set, high enough for double-unders and skips.
    static let maxBodyweightReps = 1_000
    /// The longest hold one time set records.
    static let maxSetSeconds = 3_600
    /// The longest distance one set records, in metres.
    static let maxSetMetres = 50_000.0
    static let maxLoadKg = 1_000.0
    static let maxRestSeconds = 3_600
    static let maxExercisesPerTemplate = 40
    static let maxProgramWeeks = 52
    static let currentSchemaVersion = TrainRecordSchema.currentVersion

    static func validText(_ text: String, limit: Int, allowEmpty: Bool = false) -> Bool {
        text.count <= limit && (allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func validLoad(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= maxLoadKg
    }

    static func validMetres(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value > 0 && value <= maxSetMetres
    }
}

public enum TrainRecordSource: String, CaseIterable, Codable, Sendable {
    case manual, agent
}
