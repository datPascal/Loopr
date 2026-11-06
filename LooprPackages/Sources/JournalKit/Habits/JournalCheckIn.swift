import Foundation
import DomainKit

public enum JournalRating: Int, Codable, CaseIterable, Sendable {
    case one = 1, two, three, four, five
}

public enum JournalFeeling: String, CaseIterable, Sendable {
    case mood = "Mood", energy = "Energy", stress = "Stress"
}

public enum JournalSoreness: String, Codable, CaseIterable, Sendable {
    case legs = "Legs", back = "Back", chest = "Chest", shoulders = "Shoulders", arms = "Arms", other = "Other"
}

public struct JournalWellbeing: Codable, Equatable, Sendable {
    public var mood: JournalRating?
    public var energy: JournalRating?
    public var stress: JournalRating?
    public var firstAnsweredAt: [String: Date]?
    /// Nil is unanswered; an empty set is an explicit "None" answer.
    public var soreness: Set<JournalSoreness>?

    public init(mood: JournalRating? = nil, energy: JournalRating? = nil,
                stress: JournalRating? = nil, soreness: Set<JournalSoreness>? = nil,
                firstAnsweredAt: [String: Date]? = nil) {
        self.mood = mood; self.energy = energy; self.stress = stress; self.soreness = soreness
        self.firstAnsweredAt = firstAnsweredAt
    }

    public subscript(_ feeling: JournalFeeling) -> JournalRating? {
        get {
            switch feeling { case .mood: mood; case .energy: energy; case .stress: stress }
        }
        set {
            switch feeling { case .mood: mood = newValue; case .energy: energy = newValue; case .stress: stress = newValue }
        }
    }
}

public enum HabitQuestionPeriod: String, Codable, CaseIterable, Sendable {
    case evening = "Yesterday evening", today = "Today"
}

public extension HabitDefinition {
    var checkInTitle: String {
        guard case .preset(let id) = source, name == HabitCatalog.byID[id]?.name,
              question == HabitCatalog.byID[id]?.question else { return name }
        switch id {
        case "late_caffeine": return "Caffeine after 14:00"
        case "read_before_bed": return "Read before sleep"
        default: return name
        }
    }

    var checkInPeriod: HabitQuestionPeriod {
        if let questionPeriod { return questionPeriod }
        if case .preset(let id) = source, ["feeling_sick", "trained_today"].contains(id) { return .today }
        return .evening
    }
}

public extension HabitCheckInService {
    func rate(_ feeling: JournalFeeling, value: JournalRating?, day: DayIdentity, timeZoneID: String) async throws {
        try await updateWellbeing(day: day, timeZoneID: timeZoneID) { wellbeing, now in
            var dates = wellbeing.firstAnsweredAt ?? [:]
            if value == nil { dates.removeValue(forKey: feeling.rawValue) }
            else if wellbeing[feeling] == nil || dates[feeling.rawValue] == nil { dates[feeling.rawValue] = now }
            wellbeing[feeling] = value
            wellbeing.firstAnsweredAt = dates
        }
    }

    func setSoreness(_ value: Set<JournalSoreness>?, day: DayIdentity, timeZoneID: String) async throws {
        try await updateWellbeing(day: day, timeZoneID: timeZoneID) { wellbeing, _ in wellbeing.soreness = value }
    }
}
