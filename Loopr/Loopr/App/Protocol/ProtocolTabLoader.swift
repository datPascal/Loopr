import DomainKit
import Foundation
import JournalKit
import RoutineKit

/// Feeds the Protocol tab from RoutineKit. It reads the active protocol, evaluates the days of this week that can
/// still change through `RoutineDayEvaluation` with the app's source snapshots, reads last week as stored, and writes
/// every answer back through `RoutineDayEvaluation.tick`, `override` and `untick`. It decides no rule itself.
///
/// With an `ExperimentStore` it also reads every experiment with a design and its report through
/// `ExperimentAnalyzer`, and keeps a result through `RoutineStore.keep`, which saves the next protocol version.
nonisolated struct ProtocolTabLoader: ProtocolTabSource {
    let store: RoutineStore
    let timeZone: @Sendable () -> TimeZone
    /// What Food, Fitness, the band and Apple Health hold for a day.
    let snapshots: @Sendable (DayIdentity, TimeZone, Date) async throws -> RoutineSourceSnapshots
    /// Runs when there is no protocol yet: moves the Journal's questions into version 1 if there are any.
    var prepare: (@Sendable (Date) async -> Void)?
    var patterns: @Sendable (Date) async -> (ProtocolPatternsState, [ProtocolExperimentRow]?) = { _ in (.unavailable, nil) }
    var locale: Locale = .current
    /// The experiments with a design. Nil leaves the Experiments segment without them.
    var experiments: ExperimentStore?
    /// The baselines and other measures a report needs for one experiment.
    var experimentInputs: @Sendable (Experiment) async -> ProtocolExperimentInputs = { _ in .none }
    /// The Journal's habits. A person's answer on a rule that was a habit question is written back to the habit's
    /// history (ICP R1-UPG-1). Nil leaves the Journal alone.
    var habits: (any HabitStore)?
    /// Marks every answer this loader writes as given somewhere other than Loopr's screens: `.reminder` for Done or Skip
    /// today on a rule reminder. Nil for the deck and the day sheet.
    var answeredFrom: AnswerOrigin?
    /// Runs after every answer this loader writes, so the rule reminders can clear and be planned again (ICP round 4,
    /// Q5 and HAB). Nil in fixture launches, which schedule nothing.
    var answered: (@Sendable (RuleKey) async -> Void)?

    static let unavailableMessage = "Loopr could not read your protocol on this iPhone. Try again in a moment."

    func load(now: Date) async -> ProtocolTabContent {
        async let found = patterns(now)
        let routine = await routineState(now: now)
        let designed = await experimentState(now: now)
        let (patternState, experiments) = await found
        return ProtocolTabContent(routine: routine, patterns: patternState, experiments: experiments,
                                  designedExperiments: designed)
    }

    // MARK: Experiments

    /// The night that starts today is not over, so a report reads up to last night.
    func lastNight(now: Date) -> DayIdentity {
        let today = ProtocolWeekCalendar(timeZone: timeZone(), locale: locale).day(now)
        return today.adding(days: -1) ?? today
    }

    /// Every stored experiment as the segment shows it: the running one, then the rest newest first.
    func experimentState(now: Date) async -> ProtocolExperimentsState? {
        guard let experiments else { return nil }
        do {
            let night = lastNight(now: now)
            var running: ProtocolExperimentItem?
            var finished: [ProtocolExperimentItem] = []
            for experiment in try experiments.experiments() {
                let item = try await self.item(for: experiment, store: experiments, lastNight: night)
                if experiment.status == .running { running = item } else { finished.append(item) }
            }
            return .ready(ProtocolExperimentsData(running: running, finished: finished))
        } catch {
            return .unavailable(ProtocolExperimentText.unavailable)
        }
    }

    /// One experiment with its nights, its report, the version that kept it and whether Keep is open.
    func item(for experiment: Experiment, store experiments: ExperimentStore,
              lastNight: DayIdentity) async throws -> ProtocolExperimentItem {
        let (nights, report) = try await self.report(for: experiment, store: experiments, lastNight: lastNight)
        let versions = try store.versions(protocolID: experiment.start.protocolID)
        let kept = ExperimentKeep.keptVersion(of: experiment, report: report, in: versions)
        // The rule as the newest version names it, for "Tests your rule Magnesium, 300 mg" (ICP R2-VET-08).
        let rule = versions.max(by: { $0.number < $1.number })?.rule(for: experiment.start.ruleKey)
        return ProtocolExperimentItem(experiment: experiment, report: report, nights: nights, keptVersion: kept?.number,
                                      canKeep: ExperimentKeep.canKeep(experiment, report: report, versions: versions),
                                      ruleTitle: rule?.displayTitle(locale: locale))
    }

    private func report(for experiment: Experiment, store experiments: ExperimentStore,
                        lastNight: DayIdentity) async throws -> ([ExperimentNight], ExperimentReport) {
        let nights = try experiments.nights(experimentID: experiment.id)
        let inputs = await experimentInputs(experiment)
        let report = ExperimentAnalyzer.report(experiment: experiment, nights: nights, baseline: inputs.baseline,
                                               otherBaselines: inputs.otherBaselines, alsoMetrics: inputs.alsoMetrics,
                                               lastNight: lastNight)
        return (nights, report)
    }

    func keepExperiment(_ id: ExperimentID, now: Date) async throws {
        guard let experiments else { throw ProtocolTabError.experimentsUnavailable }
        guard let experiment = try experiments.experiment(id: id) else { throw ExperimentError.missingExperiment }
        let (_, report) = try await self.report(for: experiment, store: experiments, lastNight: lastNight(now: now))
        _ = try store.keep(experiment, report: report, at: now)
    }

    func routineState(now: Date) async -> ProtocolRoutineState {
        do {
            var active = try store.activeProtocol()
            if active == nil, let prepare {
                await prepare(now)
                active = try store.activeProtocol()
            }
            guard let active else { return .noProtocol }
            return .ready(try await data(for: active, now: now))
        } catch is CancellationError {
            return .unavailable(Self.unavailableMessage)
        } catch {
            return .unavailable(Self.unavailableMessage)
        }
    }

    private func data(for active: ActiveProtocol, now: Date) async throws -> ProtocolRoutineData {
        let zone = timeZone()
        let week = ProtocolWeekCalendar(timeZone: zone, locale: locale)
        let today = week.day(now)
        let protocolID = active.routineProtocol.id
        let versions = try store.versions(protocolID: protocolID)
        let byNumber = Dictionary(versions.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        // A protocol moved over from the Journal carries answers from before the day it was made. Its day count starts
        // at the first of them, so months of history never read as "day 1" (ICP R1-UPG-11).
        var start = week.day(active.routineProtocol.createdAt)
        if let first = try store.firstCheckDay(protocolID: protocolID), Self.key(first) < Self.key(start) { start = first }
        let days = week.week(containing: today)
        guard days.count == 7, let lastMonday = week.adding(-7, to: days[0]) else { throw RoutineError.invalidCheck }
        let latest = active.latestVersion
        let evaluation = RoutineDayEvaluation(store: store)
        let tests = runningTests(protocolID: protocolID)

        var reasons: [RuleKey: UnknownReason] = [:]
        var inputs: [ProtocolDayInput] = []
        for day in days {
            if Self.key(day) > Self.key(today) {
                inputs.append(ProtocolDayInput(day: day, phase: .future, rules: latest.rules.filter { $0.isDue(on: day) }.map {
                    ProtocolRuleDay(rule: $0, state: nil, offNightTest: Self.offNightTest(for: $0.key, on: day, tests: tests))
                }, version: latest.number))
                continue
            }
            let phase: ProtocolDayPhase = day == today ? .today : (Self.key(day) < Self.key(start) ? .beforeProtocol : .past)
            var checks = try store.checks(protocolID: protocolID, day: day)
            if phase != .beforeProtocol, Self.needsEvaluation(checks, phase: phase, versions: byNumber, latest: latest) {
                do {
                    let sources = try await snapshots(day, zone, now)
                    if let result = try evaluation.evaluate(day: day, now: now, timeZone: zone, sources: sources) {
                        checks = result.checks
                        if phase == .today { reasons = result.unknownReasons }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A source that cannot be read leaves the stored checks as they are.
                }
            }
            inputs.append(Self.input(day: day, phase: phase, checks: checks, versions: byNumber, fallback: latest, tests: tests))
        }

        var lastWeek: [ProtocolDayInput] = []
        for day in week.week(containing: lastMonday) {
            let checks = try store.checks(protocolID: protocolID, day: day)
            let phase: ProtocolDayPhase = Self.key(day) < Self.key(start) ? .beforeProtocol : .past
            lastWeek.append(Self.input(day: day, phase: phase, checks: checks, versions: byNumber, fallback: latest, tests: tests))
        }

        let dayNumber = (week.days(from: start, to: today) ?? 0) + 1
        let nowMinute = RoutineDayClock(day: today, timeZone: zone)?.wholeMinute(of: now) ?? 0
        let progress = await ProtocolRuleProgressLoader.progress(store: store, protocolID: protocolID, rules: latest.rules, week: days,
                                                                 today: today, timeZone: zone, now: now, snapshots: snapshots)
        return ProtocolRoutineData(protocolName: active.routineProtocol.name, version: latest.number, versionNote: latest.note,
                                   versionCreatedAt: latest.createdAt, dayNumber: max(dayNumber, 1), rules: latest.rules,
                                   week: inputs, lastWeek: lastWeek, today: today, nowMinute: nowMinute, unknownReasons: reasons,
                                   author: active.routineProtocol.author, lineage: active.routineProtocol.lineage,
                                   habitRuleIDs: Set(versions.flatMap(\.rules).compactMap { RoutineHabitMigration.habitID(forRuleKey: $0.key) }),
                                   progress: progress, versions: versions)
    }

    /// Today always runs. A past day runs again while it has a rule without a check, a pending rule, or a rule a source
    /// could not answer yet, since a late band sync or food log can still settle it. A day the sources settled is read.
    static func needsEvaluation(_ checks: [RuleCheck], phase: ProtocolDayPhase, versions: [Int: ProtocolVersion],
                                latest: ProtocolVersion) -> Bool {
        if phase == .today { return true }
        guard !checks.isEmpty else { return true }
        let version = checks.first.flatMap { versions[$0.version] } ?? latest
        // A rule on chosen weekdays has no check on its off days, so it does not keep the day open.
        let day = checks.first?.day
        if checks.count < version.rules.filter({ rule in day.map(rule.isDue(on:)) ?? true }).count { return true }
        return checks.contains { $0.state == .pending || ($0.state == .unknown && $0.source != .manual) }
    }

    /// The day's rules in their version's order, with what is stored for each, and that version's number so the day sheet
    /// can say when the list changed (ICP R4 Q6). A check from another version keeps its own rule. A rule a running test keeps off that night reads as skipped by design (ICP R1-VET-02).
    static func input(day: DayIdentity, phase: ProtocolDayPhase, checks: [RuleCheck], versions: [Int: ProtocolVersion],
                      fallback: ProtocolVersion, tests: [Experiment] = []) -> ProtocolDayInput {
        if phase == .beforeProtocol && checks.isEmpty { return ProtocolDayInput(day: day, phase: phase, rules: []) }
        let version = checks.first.flatMap { versions[$0.version] } ?? fallback
        let byKey = Dictionary(checks.map { ($0.ruleKey, $0) }, uniquingKeysWith: { first, _ in first })
        func item(_ rule: ProtocolRule, _ check: RuleCheck?) -> ProtocolRuleDay {
            ProtocolRuleDay(rule: rule, check: check, offNightTest: offNightTest(for: rule.key, on: day, tests: tests))
        }
        // A rule on chosen weekdays is left out of its off days, so the deck and the rosette never ask it (ICP R1-HAB-02).
        var rules = version.rules
            .filter { phase != .beforeProtocol || byKey[$0.key] != nil }
            .filter { $0.isDue(on: day) || byKey[$0.key] != nil }
            .map { item($0, byKey[$0.key]) }
        for check in checks where version.rule(for: check.ruleKey) == nil {
            if let rule = versions[check.version]?.rule(for: check.ruleKey) { rules.append(item(rule, check)) }
        }
        return ProtocolDayInput(day: day, phase: phase, rules: rules, version: version.number)
    }

    /// The running experiments of the protocol. None without an experiment store or when it cannot be read: the tab
    /// then scores every rule as stored.
    func runningTests(protocolID: ProtocolID) -> [Experiment] {
        guard let experiments else { return [] }
        return ((try? experiments.experiments()) ?? []).filter { $0.status == .running && $0.start.protocolID == protocolID }
    }

    /// The name of the running test that keeps `key` off on `day`, such as "magnesium": an off night, or a washout night
    /// after a switch to off. Nil on its on nights and outside it.
    static func offNightTest(for key: RuleKey, on day: DayIdentity, tests: [Experiment]) -> String? {
        for test in tests where test.start.ruleKey == key {
            switch test.schedule.role(on: day) {
            case .off, .washout(.off): return test.start.interventionName
            case .on, .washout(.on), .outside: continue
            }
        }
        return nil
    }

    static func key(_ day: DayIdentity) -> String { day.routineDayKey ?? "" }

    // MARK: Writes

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        _ = try RoutineDayEvaluation(store: store).tick(ruleKey: key, day: day, at: now, answeredFrom: answeredFrom)
        await mirror(key, day: day)
    }

    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {
        _ = try RoutineDayEvaluation(store: store).override(ruleKey: key, day: day, state: kept ? .kept : .missed, at: now,
                                                            answeredFrom: answeredFrom)
        await mirror(key, day: day)
    }

    func skip(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        _ = try RoutineDayEvaluation(store: store).override(ruleKey: key, day: day, state: .skipped, at: now,
                                                            answeredFrom: answeredFrom)
        await mirror(key, day: day)
    }

    /// Keeps the Journal copy of a habit rule in step, then tells the rule reminders.
    private func mirror(_ key: RuleKey, day: DayIdentity) async {
        await RoutineHabitAnswerMirror.ruleChanged(key, day: day, store: store, habits: habits, timeZoneID: timeZone().identifier)
        await answered?(key)
    }

    // MARK: Rules (LV-07.4)

    func saveRules(_ rules: [ProtocolRule], now: Date) async throws -> ProtocolVersion {
        try await saveRules(rules, reason: nil, now: now)
    }

    func saveRules(_ rules: [ProtocolRule], reason: String?, now: Date) async throws -> ProtocolVersion {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        return try store.saveEdit(protocolID: active.routineProtocol.id, rules: rules, reason: reason, at: now)
    }

    func versions() async throws -> [ProtocolVersion] {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        return try store.versions(protocolID: active.routineProtocol.id)
    }

    func protocolFile() async throws -> ProtocolFile {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        return try store.exportFile(protocolID: active.routineProtocol.id, experiments: experiments)
    }

    func installTemplate(_ template: ProtocolTemplate, now: Date) async throws {
        _ = try store.installTemplate(template, at: now)
    }

    /// "Use my questions" on an empty tab: the questions RoutineKit can turn into rules become version 1, and their
    /// answers its history, the way the first launch moves them over (ICP R3-UPG-5).
    func startFromQuestions(_ habits: [JournalHabit], responses: [JournalHabitResponse], now: Date) async throws {
        guard try store.activeProtocol() == nil else { throw ProtocolEditError.protocolExists }
        let plan = try RoutineHabitMigration.plan(habits: habits, responses: responses)
        guard !plan.rules.isEmpty else { throw ProtocolTabError.noRuleInQuestions }
        let routineProtocol = RoutineProtocol(name: RoutineHabitMigration.protocolName, createdAt: now)
        _ = try store.createProtocol(routineProtocol, rules: plan.rules, note: RoutineHabitMigration.versionNote)
        if !plan.checks.isEmpty { _ = try store.recordChecks(plan.checks, protocolID: routineProtocol.id) }
    }

    func adoptFile(_ preview: ProtocolImportPreview, now: Date) async throws -> ProtocolVersion {
        try store.adoptFile(preview, at: now)
    }

    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        let zone = timeZone()
        let sources = (try? await snapshots(day, zone, now)) ?? RoutineSourceSnapshots()
        _ = try RoutineDayEvaluation(store: store).untick(ruleKey: key, day: day, now: now, timeZone: zone, sources: sources)
        await mirror(key, day: day)
    }
}
