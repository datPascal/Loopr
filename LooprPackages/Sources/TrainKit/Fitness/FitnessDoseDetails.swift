import DomainKit
import Foundation

// Round 2 of the Fitness review: what sits behind the dose card's two taps and its title. The zone line says what
// Zone 2 is and where the maximum heart rate came from (R2-VET-02). The basis says what "on pace" means (R2-DES-07,
// R2-NEW-04, R2-VET-08). The day list says, day by day, where the minutes came from and what each session added
// (R2-VET-03, R2-WOD-08). A day nothing measured stays blank, never zero.

/// One finished session as the day list names it. The app builds these from gym sessions and workout records; a gym
/// session and its workout record share an id and appear once.
public struct FitnessDaySession: Equatable, Sendable {
    public let id: UUID?
    public let date: Date
    /// "Fran · 5:06 Rx", "Lower A", "Cycling".
    public let title: String
    /// The activity name the dose classifies, as `DoseSession.activity`.
    public let activity: String
    public let minutes: Int?
    /// The app that saved it to Apple Health, "Garmin Connect". Nil for a session Loopr recorded or you logged.
    public let appName: String?
    /// Zone minutes worked out from this session's own heart rate. Nil without heart rate or without zones.
    public let zones: BandZoneMinutes?

    public init(id: UUID?, date: Date, title: String, activity: String, minutes: Int? = nil, appName: String? = nil,
                zones: BandZoneMinutes? = nil) {
        self.id = id; self.date = date; self.title = title; self.activity = activity; self.minutes = minutes
        self.appName = appName; self.zones = zones
    }
}

/// The line under the dose title on what Zone 2 is (R2-VET-02), from the zone settings the dose's minutes use.
public enum FitnessZoneLine {
    public static let unset = "Zone 2 needs a max heart rate. Add your birth year or a max heart rate in Heart."

    /// "Zone 2 is 109 to 126 bpm, from an estimated max of 181." "Estimated" when the maximum comes from age, "your
    /// max" when you set it, "measured" when the band saw a higher one.
    public static func text(_ zones: HeartRateZones?) -> String {
        guard let zones, let range = zones.bpmRange(for: 2) else { return unset }
        let maximum = Int(zones.maximum.rounded())
        let source: String = switch zones.source {
        case .estimated: "an estimated max of \(maximum)"
        case .manual: "your max of \(maximum)"
        case .observed: "a measured max of \(maximum)"
        }
        let resting = zones.restingHeartRate.map { " and a resting rate of \(Int($0.rounded()))" } ?? ""
        return "Zone 2 is \(range.lowerBound) to \(range.upperBound) bpm, from \(source)\(resting)."
    }
}

/// What "on pace" means, behind the dose card's info button (R2-DES-07, R2-NEW-04, R2-VET-08).
public struct FitnessDoseBasis: Equatable, Sendable {
    public static let title = "How the week is read"
    public static let explanation = "On pace means your weekly target spread evenly over 7 days. The targets are yours, from Protocol, not an optimum."
    public static let hardFromHeartRate = "Hard minutes come from heart rate. A timer alone adds none."

    /// "Even pace by the end of Tuesday: 90 Zone 2 minutes, 6 hard minutes, 1 strength session and 1 mobility
    /// session." Nil without a target.
    public let paceLine: String?
    /// One line per row on what counts toward it.
    public let definitions: [String]

    static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// The share of a target that keeps pace after `daysIn` of `daysInWeek` days, rounded up to a whole unit.
    public static func pace(target: Double, daysIn: Int, daysInWeek: Int) -> Int {
        Int((target * Double(max(daysIn, 0)) / Double(max(daysInWeek, 1)) - 1e-9).rounded(.up))
    }

    static func make(_ dose: WeeklyDose, daysIn: Int) -> FitnessDoseBasis {
        let days = dose.week.days.count
        var parts: [String] = []
        if let target = dose.zone2.target { parts.append("\(pace(target: target, daysIn: daysIn, daysInWeek: days)) Zone 2 minutes") }
        if let target = dose.hard.target { parts.append("\(pace(target: target, daysIn: daysIn, daysInWeek: days)) hard minutes") }
        if let target = dose.strength.target {
            let value = pace(target: Double(target), daysIn: daysIn, daysInWeek: days)
            parts.append("\(value) strength \(value == 1 ? "session" : "sessions")")
        }
        if let target = dose.mobility.target {
            let value = pace(target: Double(target), daysIn: daysIn, daysInWeek: days)
            parts.append("\(value) mobility \(value == 1 ? "session" : "sessions")")
        }
        let day = dayNames.indices.contains(daysIn - 1) ? dayNames[daysIn - 1] : "today"
        let line = parts.isEmpty ? nil : "Even pace by the end of \(day): \(FitnessDoseVerdict.list(parts, lowercaseAfterFirst: false))."
        return FitnessDoseBasis(paceLine: line, definitions: [
            FitnessDose.zone2Counts, FitnessDose.hardCounts + " " + hardFromHeartRate, FitnessDose.strengthCounts,
            FitnessDose.mobilityCounts, FitnessDose.scale + "."
        ])
    }
}

/// One day of the day list behind the Zone 2 and Hard minutes rows (R2-VET-03, R2-WOD-08).
public struct FitnessDoseDayRow: Equatable, Sendable, Identifiable {
    /// One session that day and what it added.
    public struct Session: Equatable, Sendable {
        public let title: String
        /// "1 strength session. No heart rate, so no minutes."
        public let added: String
    }

    /// `2023-11-14`
    public let id: String
    /// "Today", "Mon 13 Nov".
    public let title: String
    /// Whole minutes in zone 2 and in zones 4 and 5. Nil when nothing measured the day.
    public let zone2Minutes: Int?
    public let hardMinutes: Int?
    /// "From the band, across the whole day", "From Apple Health: Garmin Connect". Nil when nothing measured it.
    public let source: String?
    public let sessions: [Session]

    public static let notMeasured = "No minutes measured"

    /// "Zone 2 48 min · hard 0 min", or "No minutes measured".
    public var minutesLine: String {
        guard let zone2Minutes, let hardMinutes else { return Self.notMeasured }
        return "Zone 2 \(zone2Minutes) min · hard \(hardMinutes) min"
    }

    public var spokenLabel: String {
        ([title, minutesLine, source].compactMap { $0 } + sessions.map { "\($0.title): \($0.added)" })
            .joined(separator: ". ")
    }
}

public enum FitnessDoseDays {
    public static let bandSource = "From the band, across the whole day"

    /// The week's days up to today, newest first.
    static func rows(week: ISOWeek, days: [DoseDay], sessions: [FitnessDaySession], now: Date,
                     calendar: Calendar) -> [FitnessDoseDayRow] {
        let today = FitnessOverview.dayIdentity(now, calendar: calendar)
        guard let index = week.days.firstIndex(of: today) else { return [] }
        var latest: [DayIdentity: DoseDay] = [:]
        for day in days where week.days.contains(day.day) { latest[day.day] = day }
        var seen = Set<UUID>()
        let unique = sessions.sorted { $0.date > $1.date }.filter { session in
            guard let id = session.id else { return true }
            return seen.insert(id).inserted
        }
        let byDay = Dictionary(grouping: unique) { FitnessOverview.dayIdentity($0.date, calendar: calendar) }
        return week.days.prefix(index + 1).reversed().map { day in
            let entry = latest[day]
            let zones = entry?.zones
            let daySessions = byDay[day] ?? []
            let source: String?
            switch (zones, entry?.source) {
            case (nil, _): source = nil
            case (_, .band?): source = bandSource
            default:
                let apps = daySessions.filter { $0.zones != nil }.compactMap(\.appName)
                var unique: [String] = []
                for app in apps where !unique.contains(app) { unique.append(app) }
                source = unique.isEmpty ? "From Apple Health" : "From Apple Health: \(unique.joined(separator: ", "))"
            }
            return FitnessDoseDayRow(
                id: String(format: "%04ld-%02ld-%02ld", day.year, day.month, day.day),
                title: day == today ? "Today" : label(day, calendar: calendar),
                zone2Minutes: zones.map { Int($0.zone2.rounded(.down)) },
                hardMinutes: zones.map { Int($0.hard.rounded(.down)) },
                source: source,
                sessions: daySessions.map { Self.session($0, dayFromBand: entry?.source == .band && zones != nil) })
        }
    }

    /// What one session added: its strength or mobility session, then its minutes. On a day the band measured, the
    /// band's total already holds every activity's minutes.
    static func session(_ session: FitnessDaySession, dayFromBand: Bool) -> FitnessDoseDayRow.Session {
        var sentences: [String] = []
        switch DoseSessionKind.classify(activity: session.activity) {
        case .strength: sentences.append("1 strength session.")
        case .mobility: sentences.append("1 mobility session.")
        case nil: break
        }
        if dayFromBand {
            sentences.append("Its minutes are in the band's total.")
        } else if let zones = session.zones {
            let zone2 = Int(zones.zone2.rounded(.down)), hard = Int(zones.hard.rounded(.down))
            let hardText = hard == 0 ? "no hard minutes" : "\(hard) hard \(hard == 1 ? "minute" : "minutes")"
            sentences.append("Its heart rate gave \(zone2) Zone 2 \(zone2 == 1 ? "minute" : "minutes") and \(hardText).")
        } else {
            sentences.append("No heart rate, so no minutes.")
        }
        let title = session.minutes.map { "\(session.title) · \($0) min" } ?? session.title
        return FitnessDoseDayRow.Session(title: title, added: sentences.joined(separator: " "))
    }

    /// "Mon 13 Nov".
    static func label(_ day: DayIdentity, calendar: Calendar) -> String {
        var components = DateComponents()
        components.era = day.era; components.year = day.year; components.month = day.month; components.day = day.day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}
