import AIKit
import DesignSystem
import Foundation
import TodayKit

/// Where the person opened Ask from. The screen and day go into the consent preview and are
/// saved with the chat. The prompt only fills the message field. Opening Ask sends nothing.
nonisolated struct AskOrigin: Equatable, Sendable {
    let screen: String
    let day: String
    let date: Date
    /// A question to put in the message field, or nil. The person still taps Send.
    let prompt: String?
    /// The day in the words the chip uses: "Today", "Tue 13 Oct", "Mon night".
    let dayLabel: String
    /// True when the selected day is before today. Ask then reads that day, not the current one.
    let isPastDay: Bool

    init(screen: String, day: String, date: Date, prompt: String? = nil, dayLabel: String? = nil, isPastDay: Bool = false) {
        self.screen = screen
        self.day = day
        self.date = date
        self.isPastDay = isPastDay
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = trimmed?.isEmpty == false ? trimmed : nil
        self.dayLabel = dayLabel ?? day
    }

    /// The origin for the day the person is looking at. The label and the past-day flag come from the shared day.
    init(screen: String, navigation: LooprDayNavigation, day: String, date: Date, prompt: String? = nil) {
        self.init(screen: screen, day: day, date: date, prompt: prompt,
                  dayLabel: Self.dayLabel(screen: screen, day: navigation.day, today: navigation.today, calendar: navigation.calendar),
                  isPastDay: navigation.day != navigation.today)
    }

    var contextLine: String { "Opened from \(screen), selected day \(day)." }

    /// "From Sleep · Mon night". The chip uppercases it. A day that repeats the screen's name, as
    /// "Today" does on Today, is left out.
    var chipText: String {
        dayLabel.caseInsensitiveCompare(screen) == .orderedSame ? "From \(screen)" : "From \(screen) · \(dayLabel)"
    }

    /// Sleep belongs to the night that ends on the selected day, so Sleep says "Mon night" for
    /// the night that ran from Monday evening, and "Last night" when that morning is today.
    /// Every other screen uses the shared day title.
    static func dayLabel(screen: String, day: LooprDay, today: LooprDay, calendar: Calendar) -> String {
        guard screen.hasPrefix("Sleep") else {
            return LooprDayLabel.title(for: day, today: today, calendar: calendar)
        }
        if day == today { return "Last night" }
        guard let evening = day.adding(days: -1, calendar: calendar), let noon = evening.noon(in: calendar) else {
            return LooprDayLabel.title(for: day, today: today, calendar: calendar)
        }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = calendar.component(.weekday, from: noon)
        return names[(weekday - 1 + 7) % 7] + " night"
    }
}

/// The prompt chips on an empty Ask. They name the screen the person came from, and each one
/// only fills the message field.
nonisolated enum AskPrompts {
    static let general = [
        "How should I train today?",
        "What can I do to sleep better?",
        "Help me understand my recovery",
        "What changed this week?",
    ]

    static func suggestions(for origin: AskOrigin?) -> [String] {
        guard let screen = origin?.screen else { return general }
        var list: [String]
        switch true {
        case screen.hasPrefix("Sleep"):
            list = ["Why did I sleep worse this week?", "What was different about this night?", "What helps me fall asleep sooner?"]
        case screen.hasPrefix("Food"):
            list = ["Did late dinners change my sleep?", "How is my protein this week?", "What did I eat on my best recovery days?"]
        case screen.hasPrefix("Fitness") || screen.hasPrefix("Train") || screen.hasPrefix("Program") || screen.hasPrefix("Template"):
            list = ["Should I train hard today?", "How is my training load this week?", "Does my plan fit my recovery?"]
        case screen.hasPrefix("Protocol") || screen.hasPrefix("Journal"):
            list = ["What do my check-ins say about my sleep?", "Which rules go with better recovery?"]
        case screen.hasPrefix("Heart") || screen.hasPrefix("HRV") || screen.hasPrefix("Resting"):
            list = ["Why is my HRV lower than usual?", "What changed in my resting heart rate?"]
        case screen == "Today" && origin?.isPastDay == true:
            // A day that is over: three questions about that day, and none of the general "today" chips.
            list = TodayAskPrompts.pastDay
        default:
            list = []
        }
        if let prompt = origin?.prompt { list.removeAll { $0 == prompt } }
        if screen == "Today" && origin?.isPastDay == true { return list }
        return Array((list + general).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(4))
    }
}

/// Origin and selected day appear in the existing consent preview and are
/// persisted with the conversation. Opening a sheet never sends a request.
nonisolated struct OriginCoachContext: LooprCoachContextSource {
    let base: any LooprCoachContextSource
    let origin: AskOrigin

    func summary(sharing: CoachSharing, at date: Date) async throws -> String {
        try await summaryResult(sharing: sharing, at: date).text
    }

    func summaryResult(sharing: CoachSharing, at date: Date) async throws -> LooprCoachSummary {
        var result = try await base.summaryResult(sharing: sharing, at: origin.date)
        result.text = origin.contextLine + "\n" + result.text
        return result
    }

    func saveAdvice(message: CoachChatMessage, at date: Date) async throws -> UUID {
        try await base.saveAdvice(message: message, at: date)
    }
}
