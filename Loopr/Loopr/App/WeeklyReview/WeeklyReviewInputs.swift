import CoachKit
import DomainKit
import Foundation
import JournalKit
import RoutineKit

// Reads the weekly review's plain input from the stores: the active protocol's checks for the week, the band's nights
// against the person's usual, each slipped rule's history with the night after each check, the running experiment and
// the proposals already declined. CoachKit's `WeeklyStoryWriter` writes every sentence from it. A store that cannot be
// read throws; a metric with no nights leaves its outcome out. Nothing here fills in a zero.

/// The reads behind one review. A nil reader is a source this composition does not have.
nonisolated struct WeeklyReviewSources: Sendable {
    var routine: RoutineStore?
    var experiments: ExperimentStore?
    /// One metric's daily history: `days` days ending on the day of `endingOn`. Each point sits on the day the person
    /// woke, so night `d` reads from `d + 1`.
    var history: (@Sendable (MetricKey, _ days: Int, _ endingOn: Date) async -> [MetricHistoryPoint])?
    var declined: @Sendable () -> [WeeklyProposalDecision] = { [] }
}

nonisolated enum WeeklyReviewInputs {
    /// The usual is the median of this many nights before the week.
    static let usualWindowDays = 30
    /// A slipped rule's history reaches back this far, so the change page can compare enough nights.
    static let slipHistoryDays = 120

    /// The outcomes the moved page reads, with the series each comes from.
    static let outcomeMetrics: [(NoteOutcomeKind, MetricKey)] = [
        (.sleepHeartRate, .sleepingHeartRate), (.hrv, .rmssd), (.restingHeartRate, .restingHeartRate)
    ]
    /// The outcomes a slip is measured against. Each one can also be an experiment's outcome.
    static let slipOutcomes: [(NoteOutcomeKind, MetricKey)] = [(.sleepHeartRate, .sleepingHeartRate), (.hrv, .rmssd)]

    static func read(week: WeeklyReviewWeek, now: Date, calendar: Calendar,
                     sources: WeeklyReviewSources) async throws -> WeeklyStoryInput {
        let days = week.days
        guard let routine = sources.routine, let active = try routine.activeProtocol() else {
            return WeeklyStoryInput(days: days, versionNumber: nil, rules: [])
        }
        let protocolID = active.routineProtocol.id
        let rules = active.latestVersion.rules
        let sunday = week.sunday
        let today = dayIdentity(now, calendar: calendar)
        let start = try startDay(of: active, store: routine, calendar: calendar)
        let tests = ((try? sources.experiments?.experiments()) ?? [])
            .filter { $0.status == .running && $0.start.protocolID == protocolID }
        let weeks = try ruleWeeks(week: week, today: today, start: start, store: routine, active: active, tests: tests)

        // One read per metric, long enough for the week, the usual before it and the slips' history.
        var series: [MetricKey: [DayIdentity: Double]] = [:]
        if let history = sources.history, let end = noon(of: sunday.adding(days: 1) ?? sunday, calendar: calendar) {
            for metric in Set(outcomeMetrics.map { $0.1 } + slipOutcomes.map { $0.1 }) {
                var byDay: [DayIdentity: Double] = [:]
                for point in await history(metric, slipHistoryDays + 8, end) where point.value.isFinite && point.value > 0 {
                    byDay[dayIdentity(point.day, calendar: calendar)] = point.value
                }
                series[metric] = byDay
            }
        }

        let outcomes = outcomeMetrics.compactMap { kind, metric -> WeeklyOutcomeWeek? in
            guard let values = series[metric] else { return nil }
            return outcome(kind, values: values, week: week)
        }

        var running: WeeklyRunningExperiment?
        var runningUnreadable = false
        if let experiments = sources.experiments, let experiment = try experiments.running() {
            running = runningExperiment(experiment, today: dayIdentity(now, calendar: calendar))
            runningUnreadable = running == nil
        }

        var slips: [WeeklySlip] = []
        // A running experiment Loopr cannot describe still blocks a second one, so no slip is offered then.
        if !runningUnreadable {
            let from = sunday.adding(days: -(slipHistoryDays - 1)) ?? week.monday
            let missedKeys = Set(weeks.filter { $0.days.contains { $0.state == .missed } }.map(\.rule.key))
            for rule in rules where missedKeys.contains(rule.key) {
                let history = try routine.history(protocolID: protocolID, ruleKey: rule.key, from: from, through: sunday)
                for (kind, metric) in slipOutcomes {
                    guard let values = series[metric] else { continue }
                    slips.append(WeeklySlip(rule: rule, outcome: kind, history: slipNights(history, outcomes: values)))
                }
            }
        }

        return WeeklyStoryInput(days: days, protocolName: active.routineProtocol.name,
                                versionNumber: active.latestVersion.number, rules: weeks, outcomes: outcomes, slips: slips,
                                runningExperiment: running, declined: sources.declined(), startDay: start)
    }

    /// The week's checks as the check-in reads them, so the review and the hero count the same week the same way (ICP
    /// R2-DES-04, R2-VET-02): each day's rules come from the version in force that day (`ProtocolTabLoader.input`), and
    /// a rule a running test keeps off that night reads as skipped by design. Days after today are left out. A rule
    /// that left the protocol during the week keeps the days it had. A rule with a longer period comes with no days when
    /// the week has no check for it.
    static func ruleWeeks(week: WeeklyReviewWeek, today: DayIdentity, start: DayIdentity, store: RoutineStore,
                          active: ActiveProtocol, tests: [Experiment]) throws -> [WeeklyRuleWeek] {
        let protocolID = active.routineProtocol.id
        let versions = try store.versions(protocolID: protocolID)
        let byNumber = Dictionary(versions.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [RuleKey] = []
        var rules: [RuleKey: ProtocolRule] = [:]
        var days: [RuleKey: [WeeklyRuleDay]] = [:]
        for day in week.days where ProtocolTabLoader.key(day) <= ProtocolTabLoader.key(today) {
            let phase: ProtocolDayPhase = day == today ? .today
                : (ProtocolTabLoader.key(day) < ProtocolTabLoader.key(start) ? .beforeProtocol : .past)
            let checks = try store.checks(protocolID: protocolID, day: day)
            let input = ProtocolTabLoader.input(day: day, phase: phase, checks: checks, versions: byNumber,
                                                fallback: active.latestVersion, tests: tests)
            for item in input.rules {
                if rules[item.rule.key] == nil { rules[item.rule.key] = item.rule; order.append(item.rule.key) }
                if let state = item.state { days[item.rule.key, default: []].append(WeeklyRuleDay(day: day, state: state)) }
            }
        }
        // The newest version's rules first, in its order and with today's names, so the review lists them as Rules does.
        // A weekly or quarterly rule is listed even in a week it had no check, so the list shows every rule the
        // person follows (ICP R3-VET-02).
        let latest = active.latestVersion.rules.filter { rules[$0.key] != nil || RuleProgressReader.hasProgress($0) }
        let older = order.filter { key in !latest.contains { $0.key == key } }.compactMap { rules[$0] }
        // A rule every few weeks or months carries the day it was last kept before the week, so the review leaves out
        // the days it was not due on, as Today and the check-in do (ICP R4 Q3).
        let before = week.days.first.flatMap { $0.adding(days: -1) }
        return try (latest + older).map { rule in
            var lastDone: DayIdentity?
            if RuleProgressReader.hasProgress(rule), let before {
                lastDone = try store.history(protocolID: protocolID, ruleKey: rule.key, through: before)
                    .filter { $0.state == .kept }.map(\.day).max { ProtocolTabLoader.key($0) < ProtocolTabLoader.key($1) }
            }
            return WeeklyRuleWeek(rule: rule, days: days[rule.key] ?? [], lastDone: lastDone)
        }
    }

    /// The protocol's first day: the day it was made, or its first stored answer when the Journal's history came with it
    /// (as `ProtocolTabLoader` counts it).
    static func startDay(of active: ActiveProtocol, store: RoutineStore, calendar: Calendar) throws -> DayIdentity {
        var start = dayIdentity(active.routineProtocol.createdAt, calendar: calendar)
        if let first = try store.firstCheckDay(protocolID: active.routineProtocol.id),
           ProtocolTabLoader.key(first) < ProtocolTabLoader.key(start) { start = first }
        return start
    }

    /// The week's nights (Monday's to Sunday's) against the median of the 30 nights before Monday's.
    static func outcome(_ kind: NoteOutcomeKind, values: [DayIdentity: Double], week: WeeklyReviewWeek) -> WeeklyOutcomeWeek? {
        let weekNights = week.days.compactMap { night in night.adding(days: 1).flatMap { values[$0] } }
        let usualNights = (1...usualWindowDays).compactMap { back in
            week.monday.adding(days: -back).flatMap { $0.adding(days: 1) }.flatMap { values[$0] }
        }
        guard !weekNights.isEmpty || !usualNights.isEmpty else { return nil }
        let mean = weekNights.isEmpty ? nil : weekNights.reduce(0, +) / Double(weekNights.count)
        let usual = median(usualNights).map { NoteUsual(median: $0, nights: usualNights.count, windowDays: usualWindowDays) }
        return WeeklyOutcomeWeek(kind: kind, weekMean: mean, nights: weekNights.count, usual: usual)
    }

    /// Each decided check with the outcome of the night that followed it. A night with no outcome stays in with none,
    /// so it counts for neither group.
    static func slipNights(_ checks: [RuleCheck], outcomes: [DayIdentity: Double]) -> [WeeklySlipNight] {
        checks.compactMap { check in
            guard check.state == .kept || check.state == .missed else { return nil }
            return WeeklySlipNight(day: check.day, missed: check.state == .missed,
                                   outcome: check.day.adding(days: 1).flatMap { outcomes[$0] })
        }
    }

    /// The running experiment as the next-week page names it. Nil when its outcome is not one the review can name.
    static func runningExperiment(_ experiment: Experiment, today: DayIdentity) -> WeeklyRunningExperiment? {
        guard let outcome = WeeklyReviewExperimentStart.outcome(experiment.start.outcome) else { return nil }
        let total = experiment.start.plannedNights
        let elapsed = (experiment.start.startDay.days(until: today) ?? 0) + 1
        let day = experiment.schedule.nightNumber(on: today) ?? min(max(elapsed, 1), total)
        return WeeklyRunningExperiment(title: experiment.start.title, outcome: outcome, dayNumber: day, totalDays: total)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func dayIdentity(_ date: Date, calendar: Calendar) -> DayIdentity {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DayIdentity(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func noon(of day: DayIdentity, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }
}

/// Turns a weekly proposal into an experiment start, the one RoutineKit's `ExperimentStore` keeps (LV-07.3). The
/// design, the outcome and the length come from the proposal; night 1 is tonight. The protocol's version does not
/// change: keeping the result later saves the next version, as for any experiment.
nonisolated enum WeeklyReviewExperimentStart {
    enum Failure: Error, Equatable, LocalizedError {
        case noProtocol
        case outcomeNotMeasured

        var errorDescription: String? {
            switch self {
            case .noProtocol: "There is no protocol to run it in."
            case .outcomeNotMeasured: "Loopr cannot measure this outcome in an experiment yet."
            }
        }
    }

    static func metric(_ outcome: NoteOutcomeKind) -> ExperimentMetric? {
        switch outcome {
        case .sleepHeartRate: .sleepHeartRate
        case .hrv: .hrv
        case .deepSleep: .deepSleep
        case .timeToFallAsleep: .timeToFallAsleep
        case .restingHeartRate, .sleepDuration: nil
        }
    }

    static func outcome(_ metric: ExperimentMetric) -> NoteOutcomeKind? {
        switch metric.key {
        case ExperimentMetric.sleepHeartRate.key: .sleepHeartRate
        case ExperimentMetric.hrv.key: .hrv
        case ExperimentMetric.deepSleep.key: .deepSleep
        case ExperimentMetric.timeToFallAsleep.key: .timeToFallAsleep
        default: nil
        }
    }

    /// Half the nights on, half off: alternating nights, two blocks, or the first half as the before.
    static func design(_ design: WeeklyExperimentDesign, nights: Int) -> ExperimentDesign {
        switch design {
        case .alternatingDays: .alternatingDays
        case .blocks: .blocks(length: max(nights / 2, 1))
        case .beforeAndAfter: .beforeAndAfter(baselineNights: max(nights / 2, 1))
        }
    }

    static func makeStart(_ proposal: WeeklyReviewProposal, protocolID: ProtocolID, tonight: DayIdentity,
                          timeZone: TimeZone, now: Date) throws -> ExperimentStart {
        guard let outcome = metric(proposal.outcome) else { throw Failure.outcomeNotMeasured }
        let nights = max(proposal.experimentDays, 2)
        return try ExperimentStart(
            protocolID: protocolID, title: proposal.changeTitle, interventionName: proposal.ruleTitle,
            ruleKey: proposal.ruleKey, design: design(proposal.design, nights: nights), washout: 0,
            minimumNightsPerArm: max(nights / 2, ExperimentStart.smallestMinimumNightsPerArm), plannedNights: nights,
            outcome: outcome, startDay: tonight, timeZoneIdentifier: timeZone.identifier, createdAt: now)
    }

    /// Saves the experiment. The store refuses a second one while one runs, so a repeated tap starts nothing more.
    @discardableResult
    static func start(_ proposal: WeeklyReviewProposal, routine: RoutineStore, experiments: ExperimentStore,
                      now: Date, timeZone: TimeZone) throws -> Experiment {
        guard let active = try routine.activeProtocol() else { throw Failure.noProtocol }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tonight = ExperimentCalendar(calendar: calendar).tonight(at: now)
        return try experiments.start(makeStart(proposal, protocolID: active.routineProtocol.id, tonight: tonight,
                                               timeZone: timeZone, now: now))
    }
}
