import Foundation
import DesignSystem

// What the app puts on Today beyond the recovery numbers: rows for the Your day card, moments for the
// timeline and one pattern card. TodayKit does not depend on Food, Train, Journal or Patterns. The app
// reads those stores and hands over these plain values, and TodayKit only draws and sorts them.

/// One row of the Your day card that the app supplies: Food, Train or Journal.
public struct TodayYourDayRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The line under the title, such as "Protein 82 of 150 g".
    public let caption: String?
    /// The number on the right, such as "1,240". Nil when the row has none.
    public let value: String?
    /// What follows the number, such as "of 2,450 kcal".
    public let unit: String?
    /// A short status instead of a number, such as "Planned".
    public let chip: String?
    public let accessibilityLabel: String

    public init(id: String, title: String, caption: String? = nil, value: String? = nil, unit: String? = nil,
                chip: String? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.title = title
        self.caption = caption
        self.value = value
        self.unit = unit
        self.chip = chip
        self.accessibilityLabel = accessibilityLabel ?? Self.spoken(title: title, caption: caption, value: value, unit: unit, chip: chip)
    }

    public var identifier: String { "today-your-day-\(id)" }

    static func spoken(title: String, caption: String?, value: String?, unit: String?, chip: String?) -> String {
        var parts = [title]
        if let value { parts.append([value, unit].compactMap { $0 }.joined(separator: " ")) }
        if let chip { parts.append(chip) }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}

public enum TodayTimelineKind: String, Equatable, Sendable {
    case wake, alarm, meal, workout, reminder, bedtime

    /// Breaks a tie between two moments in the same minute.
    var order: Int {
        switch self {
        case .wake: 0
        case .alarm: 1
        case .meal: 2
        case .workout: 3
        case .reminder: 4
        case .bedtime: 5
        }
    }
}

/// One moment on Today's timeline. `minuteOfDay` is the local clock time in minutes after midnight.
public struct TodayTimelineItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let minuteOfDay: Int
    public let kind: TodayTimelineKind
    public let title: String
    public let detail: String?
    /// True when a tap opens something, such as the meal or the workout.
    public let isInteractive: Bool
    /// A moment of tomorrow morning, such as the next alarm. It sorts after tonight's bedtime.
    public let isNextDay: Bool
    /// Something that happened and was logged, such as a meal or a finished workout. It is never "upcoming", whatever
    /// the clock says, because Food and Fitness already count it (ICP R2-OPT-1).
    public let isRecord: Bool

    public init(id: String, minuteOfDay: Int, kind: TodayTimelineKind, title: String, detail: String? = nil,
                isInteractive: Bool = false, isNextDay: Bool = false, isRecord: Bool = false) {
        self.id = id
        self.minuteOfDay = min(max(minuteOfDay, 0), 1_439)
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isInteractive = isInteractive
        self.isNextDay = isNextDay
        self.isRecord = isRecord
    }
}

/// The one pattern the card on Today shows. The app builds it from the strongest pattern that Patterns found.
public struct TodayPatternCard: Equatable, Sendable {
    public let id: String
    /// "Strong" or "Clear".
    public let strengthLabel: String
    public let title: String
    public let detail: String
    /// "From your last 41 nights"
    public let nightsLine: String
    /// False while another test runs, because Patterns runs one test at a time.
    public let canStartTest: Bool

    public init(id: String, strengthLabel: String, title: String, detail: String, nightsLine: String, canStartTest: Bool) {
        self.id = id
        self.strengthLabel = strengthLabel
        self.title = title
        self.detail = detail
        self.nightsLine = nightsLine
        self.canStartTest = canStartTest
    }
}

/// Everything the app injects into the new Today sections.
public struct TodayAgentContent: Equatable, Sendable {
    public var yourDayRows: [TodayYourDayRow]
    public var timeline: [TodayTimelineItem]
    public var pattern: TodayPatternCard?
    /// The clock time now in minutes after midnight, on the same clock the timeline times use. Nil lets
    /// TodayKit read the shared day's clock. Fixture launches pin it so what is ahead never drifts.
    public var nowMinute: Int?

    public init(yourDayRows: [TodayYourDayRow] = [], timeline: [TodayTimelineItem] = [], pattern: TodayPatternCard? = nil,
                nowMinute: Int? = nil) {
        self.yourDayRows = yourDayRows
        self.timeline = timeline
        self.pattern = pattern
        self.nowMinute = nowMinute
    }

    public static let empty = TodayAgentContent()
}

/// A tap on one of the injected sections.
public enum TodayAgentAction: Equatable, Sendable {
    case yourDayRow(String)
    case timelineItem(String)
    /// "All" in the Pattern this week header, and Show the nights.
    case patterns
    case startPatternTest(String)
}

// MARK: - Timeline rules

/// One row of the timeline, ready to draw.
public struct TodayTimelineRowContent: Identifiable, Equatable, Sendable {
    public let id: String
    public let time: String
    public let title: String
    public let detail: String?
    public let isDimmed: Bool
    public let isInteractive: Bool
}

public enum TodayTimelineRules {
    /// A bedtime in the first hours after midnight belongs to the end of the day, not the start.
    static let lateNightCutoff = 3 * 60

    /// Orders the app's moments with tonight's bedtime and marks what is still ahead.
    /// - Parameters:
    ///   - nowMinute: The clock time now, or nil for a day that is over. Nil dims nothing.
    ///   - tonight: Tonight's bedtime plan. Past days pass nil.
    ///   - locale: Writes each time the way the Sleep hero does, so a 12-hour locale reads "6:52 am" and a 24-hour one "06:52".
    public static func rows(items: [TodayTimelineItem], tonight: TodayTonightPlan?, nowMinute: Int?,
                            locale: Locale = .current) -> [TodayTimelineRowContent] {
        var all = items
        // The app supplies Sleep's own bedtime when Sleep has a plan. Today's rule only fills in when it has none.
        if let tonight, !items.contains(where: { $0.kind == .bedtime }) {
            all.append(TodayTimelineItem(id: "bedtime", minuteOfDay: tonight.bedtimeMinute, kind: .bedtime, title: "Bedtime",
                detail: "For \(LooprUnitFormatter.duration(minutes: tonight.needMinutes) ?? "") of sleep", isInteractive: true))
        }
        func sortKey(_ item: TodayTimelineItem) -> Int {
            if item.isNextDay { return item.minuteOfDay + 2 * 1_440 }
            return item.kind == .bedtime && item.minuteOfDay < lateNightCutoff ? item.minuteOfDay + 1_440 : item.minuteOfDay
        }
        let ordered = all.sorted { lhs, rhs in
            (sortKey(lhs), lhs.kind.order, lhs.id) < (sortKey(rhs), rhs.kind.order, rhs.id)
        }
        return ordered.map { item in
            TodayTimelineRowContent(id: item.id, time: clock(item.minuteOfDay, locale: locale), title: item.title, detail: item.detail,
                isDimmed: !item.isRecord && (nowMinute.map { sortKey(item) > $0 } ?? false), isInteractive: item.isInteractive)
        }
    }

    public static func clock(_ minute: Int, locale: Locale = .current) -> String {
        LooprClockFormat.text(minuteOfDay: minute, locale: locale)
    }
}

// MARK: - Prompt chips

/// The three questions under the Ask field on Today. Each one opens Ask with the question in the message
/// field. Nothing is sent until the person taps Send.
public enum TodayAskPrompts {
    public static let placeholder = "Ask about your data"
    /// The field's text on a day that is over.
    public static let pastDayPlaceholder = "Ask about this day"

    /// The three questions on a day that is over. They read as questions about that day, so none says
    /// "today" or "tonight".
    public static let pastDay = [
        "How did I sleep the night before?",
        "How did this day compare with my usual?",
        "What changed from the day before?",
    ]

    public static func placeholder(isToday: Bool) -> String { isToday ? placeholder : pastDayPlaceholder }

    /// The chips on a day the band has not filled yet. None asks about a band reading that is not there.
    public static func withoutBandData(isToday: Bool) -> [String] {
        isToday ? ["What should I eat tonight?", "How did I eat this week?", "Plan a workout for today"]
                : ["What did I eat this day?", "How did this day compare with my usual?"]
    }

    /// The chips for the selected day. A past day gets its own three, whatever the HRV did.
    public static func prompts(hrvChange: Double?, isToday: Bool) -> [String] {
        isToday ? prompts(hrvChange: hrvChange) : pastDay
    }

    /// The HRV question follows the direction of the reading, so the chip never claims a rise that did not happen.
    public static func prompts(hrvChange: Double?) -> [String] {
        let hrv: String
        if let hrvChange, hrvChange.isFinite, abs(hrvChange) >= 0.5 {
            hrv = hrvChange > 0 ? "Why is my HRV up?" : "Why is my HRV down?"
        } else {
            hrv = "How is my HRV doing?"
        }
        return [hrv, "What should I eat tonight?", "Train hard today?"]
    }
}
