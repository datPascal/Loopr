import DesignSystem
import Foundation
import WorkoutKit

// The Fitness tab's small decisions, kept out of the view so tests can read them: the week strip's dots and the
// selected day's caption, the start rail's order, and the words of the pending and This week rows.

/// One day of the week strip in dot mode.
public struct TrainWeekMarkDay: Equatable, Sendable {
    /// Filled dots first, then hollow ones.
    public let marks: [LooprWeekStripMark]
    /// The short form: "Lower A, done", "Upper A and Zone 2, 45 min".
    public let caption: String
    /// What was done that day: gym sessions by name, everything else by activity, "CrossFit", "cycling".
    public var done: [String] = []
    /// What is still planned that day.
    public var planned: [String] = []
    public var isSkipped = false

    /// The line under the strip while this day is selected (R2-DES-15): "Done today: CrossFit, cycling, stretching.
    /// Still planned: Upper A." `day` is "today" or "Thu 16 Nov".
    public func line(day: String) -> String {
        let on = day == "today" ? "today" : "on \(day)"
        let doneText = done.isEmpty ? nil : "Done \(on): \(done.joined(separator: ", "))."
        switch (doneText, planned.isEmpty) {
        case let (done?, false): return "\(done) Still planned: \(TrainWeekMarks.joined(planned))."
        case let (done?, true): return done
        case (nil, false): return "Planned \(day == "today" ? "today" : "for \(day)"): \(TrainWeekMarks.joined(planned))."
        case (nil, true):
            let start = day == "today" ? "Today" : day
            return "\(start): \(isSkipped ? "skipped" : "rest")."
        }
    }
}

/// The week strip's dots (R1-DES-15). A gym session counts once even though its workout record is in the list too.
/// Every other finished workout that day adds a filled dot. Only an endurance workout, a run or a ride, takes a
/// planned Zone 2 off the day; a WOD or a stretch leaves the plan as it is (R2-DES-06).
public enum TrainWeekMarks {
    public static func day(_ day: TrainWeekDay, workouts: [WorkoutRecord], gymWorkoutIDs: Set<UUID>,
                           calendar: Calendar) -> TrainWeekMarkDay {
        let others = workouts.filter { workout in
            workout.state == .completed && !gymWorkoutIDs.contains(workout.id)
                && localDay(workout.startedAt ?? workout.createdAt, calendar: calendar) == day.localDay
        }.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let done = day.doneNames + others.map(TrainRowText.noun)
        var planned = day.plannedNames
        var zone2 = day.zone2PlannedNames
        for _ in others.filter({ TrainRowText.isEndurance($0.activity) }) {
            guard let name = zone2.first, let index = planned.lastIndex(of: name) else { break }
            planned.remove(at: index)
            zone2.removeFirst()
        }
        let marks = Array(repeating: LooprWeekStripMark.done, count: done.count)
            + Array(repeating: LooprWeekStripMark.planned, count: planned.count)
        var result = TrainWeekMarkDay(marks: marks, caption: caption(done: done, planned: planned, skipped: day.isSkipped))
        result.done = done
        result.planned = planned
        result.isSkipped = day.isSkipped
        return result
    }

    static func caption(done: [String], planned: [String], skipped: Bool) -> String {
        let doneText = done.isEmpty ? nil : "\(joined(done)), done"
        let plannedText = planned.isEmpty ? nil : joined(planned)
        switch (doneText, plannedText) {
        case let (done?, planned?): return "\(done). \(planned) still planned."
        case let (done?, nil): return done
        case let (nil, planned?): return planned
        case (nil, nil): return skipped ? "Skipped" : "Rest"
        }
    }

    /// "Upper A", "Upper A and Zone 2", "Upper A, Lower B and Zone 2".
    static func joined(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// `2023-11-14` for a date in the calendar's time zone.
    public static func localDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One chip of the start rail.
public enum TrainRailItem: Equatable, Hashable, Sendable {
    /// A gym workout: the start sheet with an empty workout and every template.
    case gym
    /// The start screen of a recorded activity.
    case activity(ActivityType)
    /// The quick log of a session already done.
    case log
    /// The start sheet, with every way to start.
    case more

    /// `train-rail-gym`, `train-rail-run`, `train-rail-crossfit`.
    public var identifier: String {
        switch self {
        case .gym: "train-rail-gym"
        case .activity(let activity): "train-rail-\(activity.rawValue)"
        case .log: "train-rail-log"
        case .more: "train-rail-more"
        }
    }

    /// The identifier this start had before the rail, kept so older tests and tours still find it.
    public var legacyIdentifier: String? {
        switch self {
        case .gym: "train-start-gym"
        case .activity(.run): "workouts-start"
        case .activity(.cycle): "train-start-cycle"
        case .activity: nil
        case .log: "workouts-manual-entry"
        case .more: "train-start-more"
        }
    }

    public var title: String {
        switch self {
        case .gym: "Gym"
        case .activity(let activity): activity.shortName
        case .log: "Log"
        case .more: "More"
        }
    }

    public var symbol: String {
        switch self {
        case .gym: ActivityType.strength.symbolName
        case .activity(let activity): activity.symbolName
        case .log: "clock.arrow.circlepath"
        case .more: "ellipsis"
        }
    }

    public var spokenLabel: String {
        switch self {
        case .gym: "Start a gym workout"
        case .activity(.crossfit): "Start a WOD"
        case .activity(let activity): "Start \(activity.displayName.lowercased())"
        case .log: "Log a session you already did"
        case .more: "More ways to start"
        }
    }
}

/// The start rail (R1-DES-07, R1-NEW-02, R2-NEW-01): Gym, Walk and Log pinned in that order, then the newest
/// activities you did, then Run, Ride, WOD and Mobility to fill the slots, then More last. Gym leads in every state
/// (R1-LIFT-12).
public enum TrainStartRail {
    public static let pinned: [ActivityType] = [.walk]
    public static let fixed: [ActivityType] = [.run, .cycle, .crossfit, .mobility]
    /// Activity chips after the pinned ones.
    public static let slots = 5

    /// `workouts` in any order. Gym sessions, "Other", the pinned activities and workouts that never started are left
    /// out of the recents.
    public static func items(recent workouts: [WorkoutRecord]) -> [TrainRailItem] {
        let ordered = workouts.sorted { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) }
        var activities: [ActivityType] = []
        for workout in ordered where workout.startedAt != nil {
            let activity = workout.activity
            guard activity != .strength, activity != .other, !pinned.contains(activity), !activities.contains(activity),
                  activities.count < slots else { continue }
            activities.append(activity)
        }
        for activity in fixed where activities.count < slots && !activities.contains(activity) { activities.append(activity) }
        return [.gym] + pinned.map(TrainRailItem.activity) + [.log] + activities.map(TrainRailItem.activity) + [.more]
    }
}

/// The words of the Fitness tab's rows.
public enum TrainRowText {
    /// "Band saw a 10 min run" (R1-DES-14).
    public static func pendingTitle(_ detection: DetectedWorkout) -> String {
        let minutes = Int((detection.endedAt.timeIntervalSince(detection.startedAt) / 60).rounded())
        let noun = pendingNoun(detection.activity)
        return minutes > 0 ? "Band saw a \(minutes) min \(noun)" : "Band saw a \(noun)"
    }

    static func pendingNoun(_ activity: ActivityType) -> String {
        switch activity {
        case .run: "run"
        case .cycle: "ride"
        case .walk: "walk"
        case .hike: "hike"
        case .swim: "swim"
        case .rowing: "row"
        case .hiit: "HIIT session"
        case .crossfit: "WOD"
        case .other, .cardio: "workout"
        default: "\(activity.displayName.lowercased()) session"
        }
    }

    /// The numbers on the right of a This week row: "30 min · 5.2 km". The day leaves the line, it has its own place.
    public static func numbers(fromDetailLine line: String?) -> String? {
        guard let line else { return nil }
        let segments = line.components(separatedBy: " · ")
        guard segments.count > 1 else { return nil }
        return segments.dropFirst().joined(separator: " · ")
    }

    /// The note on an unsaved row (R1-DES-16): it is not in the week's totals until it is saved.
    public static let unsavedNote = "Not counted until you finish saving it."

    /// "6:20, not saved yet" under the pending row's title (R2-DES-02). The time follows the phone's 12 or 24 hour
    /// setting.
    public static func pendingCaption(_ detection: DetectedWorkout) -> String {
        detection.startedAt.formatted(date: .omitted, time: .shortened) + ", not saved yet"
    }

    /// A session row's title (R2-WOD-03): the WOD's name with its score, "Fran · 5:06 Rx", or the title you gave, the
    /// imported activity's name, or the type.
    public static func title(_ workout: WorkoutRecord) -> String {
        if let wod = workout.wod, let name = WorkoutLogEntry.cleaned(wod.name) {
            return wod.scoreLine.map { "\(name) · \($0)" } ?? name
        }
        return workout.displayTitle
    }

    /// The numbers on the right of a session row: "52 min · 24.6 km". The source and the day sit on the left, so
    /// "Apple Watch · 35 min" never wraps (R2-VET-04).
    public static func numbers(_ workout: WorkoutRecord, system: LooprMeasurementSystem) -> String? {
        var parts: [String] = []
        if let duration = workout.duration, duration >= 60 { parts.append("\(Int((duration / 60).rounded(.down))) min") }
        let distance = workout.samples.last { $0.distanceMeters != nil }?.distanceMeters ?? workout.resolvedDistanceMeters
        if let distance, distance > 0 {
            let measure = LooprUnitFormatter.distance(meters: distance, system: system)
            parts.append("\(measure.value) \(measure.unit)")
        } else if let calories = workout.loggedCalories {
            parts.append("\(calories) kcal")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The caption under a session row's title: the day, what the numbers leave out, then the app that saved it:
    /// "Mon 13 Nov · 5:38 /km", "Thu 9 Nov · 48 lengths", "Mon 13 Nov · Apple Watch". The numbers on the right stay
    /// short so the title is never squeezed.
    public static func caption(day: String, workout: WorkoutRecord, system: LooprMeasurementSystem = .metric) -> String {
        var parts = [day]
        if let lengths = workout.lengths {
            parts.append("\(lengths) lengths")
        } else if workout.activity.recordsRoute, let distance = workout.samples.last(where: { $0.distanceMeters != nil })?.distanceMeters ?? workout.resolvedDistanceMeters,
                  let speed = WorkoutPagePresentation.speedCompanion(activity: workout.activity, meters: distance, seconds: workout.duration, system: system) {
            parts.append([speed.value, speed.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let source = workout.importedSummary?.source, !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// A workout's activity as a word in a sentence (R2-DES-15): "CrossFit", "cycling", "stretching".
    public static func noun(_ workout: WorkoutRecord) -> String {
        switch workout.activity {
        case .run: "running"
        case .cycle: "cycling"
        case .walk: "walking"
        case .hike: "hiking"
        case .swim: "swimming"
        case .rowing: "rowing"
        case .crossfit: "CrossFit"
        case .hiit: "HIIT"
        case .yoga: "yoga"
        case .pilates: "Pilates"
        case .mobility: "stretching"
        case .strength: "strength"
        case .climbing: "climbing"
        case .dance: "dance"
        case .cardio: "cardio"
        case .sport: WorkoutLogEntry.cleaned(workout.title) ?? "sport"
        case .other: WorkoutLogEntry.cleaned(workout.title) ?? "workout"
        }
    }

    /// Activities that can be a Zone 2 session.
    public static func isEndurance(_ activity: ActivityType) -> Bool {
        [.run, .cycle, .walk, .hike, .swim, .rowing, .cardio].contains(activity)
    }
}

/// The one card for today (R2-NEW-03, R2-VET-01, R2-DES-06, R2-WOD-04). Once the day has sessions it reads "Done today"
/// with what counted, and the planned session becomes an optional line with Start. A protocol Zone 2 rule that today's
/// measured minutes already meet reads done, with the minutes ("Zone 2, 45 min · done, 48 min measured today"), instead
/// of a second plan.
public struct TrainTodayCard: Equatable, Sendable {
    /// "Fran 30 min, cycling 52 min, stretching 10 min." Nil while nothing is done today.
    public let doneLine: String?
    /// "Counted: 2 strength sessions, 1 mobility session, 48 Zone 2 min." Nil while nothing is done today.
    public let countedLine: String?
    /// The protocol's daily Zone 2, done or still to do. Nil without the rule, or when today's plan is itself Zone 2.
    public let rule: String?
    public let ruleIsDone: Bool
    /// The planned session, optional once the day has sessions.
    public let plan: TrainTodayPlan?

    public var isDone: Bool { doneLine != nil }

    public static let doneTitle = "Done today"

    /// - Parameters:
    ///   - workouts: every listed workout; today's completed ones count.
    ///   - todayZone2Minutes: today's measured Zone 2 minutes, from the dose's day list. Nil when nothing measured today.
    public static func make(overview: TrainOverview, workouts: [WorkoutRecord], todayZone2Minutes: Int?) -> TrainTodayCard? {
        guard let today = overview.week.first(where: \.isToday) else { return nil }
        let calendar = overview.calendar
        let gymIDs = Set(overview.sessionsByWorkoutID.keys)
        let gym = overview.thisWeek.filter { $0.localDay == today.localDay }.sorted { $0.id.uuidString < $1.id.uuidString }
        let others = workouts.filter { workout in
            workout.state == .completed && !gymIDs.contains(workout.id)
                && TrainWeekMarks.localDay(workout.startedAt ?? workout.createdAt, calendar: calendar) == today.localDay
        }.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }

        var doneItems = gym.map { session in session.minutes.map { "\(session.name) \($0) min" } ?? session.name }
        for workout in others {
            let name = WorkoutLogEntry.cleaned(workout.wod?.name) ?? WorkoutLogEntry.cleaned(workout.title) ?? TrainRowText.noun(workout)
            let minutes = workout.duration.map { Int(($0 / 60).rounded(.down)) }.flatMap { $0 > 0 ? $0 : nil }
            doneItems.append(minutes.map { "\(name) \($0) min" } ?? name)
        }
        var strength = gym.count, mobility = 0
        for workout in others {
            switch DoseSessionKind.classify(activity: workout.importedSummary?.activityName ?? "")
                ?? DoseSessionKind.classify(activity: workout.activity.rawValue) {
            case .strength: strength += 1
            case .mobility: mobility += 1
            case nil: break
            }
        }
        var counted: [String] = []
        if strength > 0 { counted.append("\(strength) strength \(strength == 1 ? "session" : "sessions")") }
        if mobility > 0 { counted.append("\(mobility) mobility \(mobility == 1 ? "session" : "sessions")") }
        if let minutes = todayZone2Minutes, minutes > 0 { counted.append("\(minutes) Zone 2 min") }

        let plan: TrainTodayPlan? = { if case .plan(let plan) = overview.today { return plan } else { return nil } }()
        var rule: String?
        var ruleIsDone = false
        // A plan that is itself Zone 2 carries no chip, and the rule is that plan.
        if let zone2 = overview.dailyZone2, plan.map({ $0.dailyChip != nil }) ?? true {
            let measured = todayZone2Minutes ?? 0
            if measured >= zone2.minutes {
                // Done from measured minutes only, and said that way: the day's minutes can come from the band or
                // from several workouts, so no single session is named (R3-VET-01, R3-DES-01).
                ruleIsDone = true
                rule = "\(zone2.title) · done, \(measured) min measured today"
            } else {
                var text = zone2.startMinute.map { "\(zone2.title) at \(TrainClockText.time(minute: $0))" } ?? zone2.title
                if measured > 0 { text += " · \(measured) min so far" }
                rule = text
            }
        }
        if doneItems.isEmpty, plan == nil, rule == nil { return nil }
        return TrainTodayCard(
            doneLine: doneItems.isEmpty ? nil : doneItems.joined(separator: ", ") + ".",
            countedLine: doneItems.isEmpty || counted.isEmpty ? nil : "Counted: \(counted.joined(separator: ", ")).",
            rule: rule, ruleIsDone: ruleIsDone, plan: plan)
    }
}
