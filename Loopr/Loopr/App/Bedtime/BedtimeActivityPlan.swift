import DomainKit
import Foundation
import RoutineKit

// The bedtime Live Activity (DEC-12.17) decides everything here, with no ActivityKit and no clock of its own, so the
// start window, the steps and the start, update and end choices can be tested with a fixed instant.

/// The evening a countdown belongs to: from 18:00 to the bedtime.
nonisolated struct BedtimeEvening: Equatable, Sendable {
    /// The calendar day the evening starts on. A bedtime after midnight still belongs to this day.
    let day: DayIdentity
    /// 18:00 on `day`.
    let start: Date
    let bedtime: Date
    /// The bedtime as minutes after local midnight of the day it falls on.
    let bedtimeMinuteOfDay: Int

    /// The activity stays up this long after bedtime, then it is stale and the app ends it.
    var endsAt: Date { bedtime.addingTimeInterval(BedtimeActivityWindow.grace) }
}

nonisolated enum BedtimeActivityWindow {
    /// The countdown starts at 18:00.
    static let startMinute = 18 * 60
    /// A bedtime before noon is after midnight. One between noon and 18:00 has no countdown to give.
    static let afterMidnightLimit = 12 * 60
    static let grace: TimeInterval = 15 * 60

    enum Phase: Equatable, Sendable {
        /// No bedtime to count down to.
        case noBedtime
        /// Today's evening has not reached 18:00.
        case before(BedtimeEvening)
        /// Between 18:00 and bedtime. The only phase an activity starts in.
        case running(BedtimeEvening)
        /// Bedtime has passed and the grace has not. A running activity stays, nothing starts.
        case grace(BedtimeEvening)
        /// Today's evening is over.
        case over
    }

    /// A bedtime minute that has a countdown: 18:00 to 23:59, or 00:00 to 11:59 after midnight.
    static func isCountdownMinute(_ minute: Int) -> Bool {
        (0..<afterMidnightLimit).contains(minute) || (startMinute..<1_440).contains(minute)
    }

    /// The evening that starts on `day` with the bedtime at `minute`. Nil when the minute has no countdown.
    static func evening(startingOn day: Date, bedtimeMinute minute: Int, calendar: Calendar) -> BedtimeEvening? {
        guard isCountdownMinute(minute) else { return nil }
        let midnight = calendar.startOfDay(for: day)
        guard let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: midnight,
                                        matchingPolicy: .nextTime),
              let bedDay = minute < afterMidnightLimit ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight,
              let bedtime = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: bedDay,
                                          matchingPolicy: .nextTime, repeatedTimePolicy: .first),
              bedtime > start else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: midnight)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        return BedtimeEvening(day: DayIdentity(year: year, month: month, day: dayOfMonth), start: start,
                              bedtime: bedtime, bedtimeMinuteOfDay: minute)
    }

    /// Where `now` sits against the evening. Yesterday's evening counts while a bedtime after midnight has not come,
    /// and no earlier evening ever does, so the activity never shows for a past day.
    static func phase(now: Date, bedtimeMinute: Int?, calendar: Calendar) -> Phase {
        guard let bedtimeMinute, isCountdownMinute(bedtimeMinute) else { return .noBedtime }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return .noBedtime }
        for day in [yesterday, today] {
            guard let evening = evening(startingOn: day, bedtimeMinute: bedtimeMinute, calendar: calendar) else { continue }
            if now >= evening.start && now < evening.bedtime { return .running(evening) }
            if now >= evening.bedtime && now < evening.endsAt { return .grace(evening) }
        }
        guard let tonight = evening(startingOn: today, bedtimeMinute: bedtimeMinute, calendar: calendar) else { return .noBedtime }
        return now < tonight.start ? .before(tonight) : .over
    }
}

/// Which bedtime the countdown uses. The protocol's in-bed rule wins over tonight's plan, the same order the day dial
/// uses.
nonisolated enum BedtimeActivityBedtime {
    /// Minutes after midnight from the rule that checks the time the person gets into bed. Nil without one, or when
    /// the rule carries no time.
    static func inBedRuleMinute(in rules: [ProtocolRule]) -> Int? {
        guard let rule = rules.first(where: { $0.target.metric == RoutineMetric.inBedTime.rawValue }),
              let value = rule.target.value, value.isFinite, value >= 0 else { return nil }
        let minute = Int(value.rounded())
        // A rule written as 25:00 means 01:00.
        return ((minute % 1_440) + 1_440) % 1_440
    }

    static func minuteOfDay(rules: [ProtocolRule], plannedMinute: Int?) -> Int? {
        inBedRuleMinute(in: rules) ?? plannedMinute.map { (($0 % 1_440) + 1_440) % 1_440 }
    }

    /// Whether a rule is the in-bed rule itself. It is the destination, so it is not a step.
    static func isInBedRule(_ rule: ProtocolRule) -> Bool { rule.target.metric == RoutineMetric.inBedTime.rawValue }
}

nonisolated enum BedtimeActivitySteps {
    typealias Step = LooprBedtimeActivityAttributes.ContentState.Step
    /// ActivityKit caps a content state at 4 KB.
    static let maximumSteps = 8

    /// The evening rules as steps, in time order. A done step is a kept check. A pending, unknown or unchecked rule is
    /// still to do. A rule already missed cannot be done any more, so it leaves the list rather than sitting there
    /// as the next step all night. Only the rule's title and time appear, never a measured value.
    static func steps(rules: [ProtocolRule], checks: [RuleCheck], evening: BedtimeEvening, calendar: Calendar) -> [Step] {
        let states = Dictionary(checks.map { ($0.ruleKey, $0.state) }, uniquingKeysWith: { _, latest in latest })
        let midnight = calendar.startOfDay(for: evening.start)
        let ordered = rules.enumerated()
            .filter { $0.element.isEvening && !BedtimeActivityBedtime.isInBedRule($0.element) }
            .sorted { lhs, rhs in
                let left = sortKey(lhs.element.timeOfDayMinutes), right = sortKey(rhs.element.timeOfDayMinutes)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
        let mapped: [Step] = ordered.compactMap { item in
            let rule = item.element
            let state = states[rule.key]
            if state == .missed { return nil }
            return Step(id: rule.key.rawValue, title: rule.displayTitle(), minuteOfDay: rule.timeOfDayMinutes,
                        at: rule.timeOfDayMinutes.flatMap { date(minute: $0, on: midnight, calendar: calendar) },
                        status: state == .kept ? .done : .pending)
        }
        return Array(mapped.prefix(maximumSteps))
    }

    static func contentState(steps: [Step], evening: BedtimeEvening, now: Date) -> LooprBedtimeActivityAttributes.ContentState {
        let span = evening.bedtime.timeIntervalSince(evening.start)
        let progress = span > 0 ? min(max(now.timeIntervalSince(evening.start) / span, 0), 1) : 1
        return .init(steps: steps, nextStep: steps.first(where: { !$0.isDone }), progress: progress)
    }

    /// A time after midnight sorts after the late evening. Rules without a time go last.
    private static func sortKey(_ minute: Int?) -> Int {
        guard let minute else { return Int.max }
        return minute < BedtimeActivityWindow.afterMidnightLimit ? minute + 1_440 : minute
    }

    private static func date(minute: Int, on midnight: Date, calendar: Calendar) -> Date? {
        guard (0..<1_440).contains(minute),
              let day = minute < BedtimeActivityWindow.afterMidnightLimit
                ? calendar.date(byAdding: .day, value: 1, to: midnight) : midnight else { return nil }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day, matchingPolicy: .nextTime)
    }
}

/// What the runtime does with the activities that exist right now. Pure, so every start, update and end is a test.
nonisolated enum BedtimeActivityDecision {
    struct Existing: Equatable, Sendable {
        let id: String
        let windowStart: Date
        let bedtime: Date
        let isScheduled: Bool
    }

    enum Start: Equatable, Sendable {
        case now
        /// iOS 26 starts it at 18:00 with the app closed.
        case scheduled(Date)

        var scheduledDate: Date? {
            if case .scheduled(let date) = self { return date }
            return nil
        }
    }

    struct Plan: Equatable, Sendable {
        var ends: [String] = []
        var updateID: String?
        var start: Start?
    }

    static func decide(enabled: Bool, authorized: Bool, asleep: Bool, phase: BedtimeActivityWindow.Phase,
                       existing: [Existing], canSchedule: Bool) -> Plan {
        let all = existing.map(\.id)
        guard enabled else { return Plan(ends: all) }
        let evening: BedtimeEvening
        let canStartNow: Bool
        switch phase {
        case .noBedtime, .over: return Plan(ends: all)
        case .before(let value): evening = value; canStartNow = false
        case .running(let value): evening = value; canStartNow = true
        case .grace(let value): evening = value; canStartNow = false
        }
        // Once the person is in bed the countdown has done its job. It does not come back that night.
        if asleep { return Plan(ends: all) }
        let matching = existing.filter { $0.windowStart == evening.start && $0.bedtime == evening.bedtime }
        let keeper = matching.sorted { $0.id < $1.id }.first
        var plan = Plan(ends: existing.filter { $0.id != keeper?.id }.map(\.id).sorted())
        if let keeper {
            // A scheduled activity that has not started is not updated. It starts with what it was given.
            if !keeper.isScheduled { plan.updateID = keeper.id }
            return plan
        }
        guard authorized else { return plan }
        if canStartNow { plan.start = .now }
        else if case .before = phase, canSchedule { plan.start = .scheduled(evening.start) }
        return plan
    }
}

nonisolated extension LooprBedtimeActivityAttributes.ContentState {
    /// Whether a person would see a difference. The progress figure moves with the clock and the bar draws itself from
    /// a timer, so a new progress alone is not worth an update.
    func differsVisibly(from other: Self) -> Bool { steps != other.steps || nextStep != other.nextStep }
}
