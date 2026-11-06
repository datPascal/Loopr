import DesignSystem
import DomainKit
import Foundation
import RoutineKit

/// Writes the weekly review from stored values. Same input and same context give the same story. The writer reads, it
/// never saves, and it starts nothing: the proposal it returns is a value the person has to tap.
public struct WeeklyStoryWriter: Sendable {
    public let context: NoteContext
    public let thresholds: WeeklyStoryThresholds

    public init(context: NoteContext = NoteContext(), thresholds: WeeklyStoryThresholds = .standard) {
        self.context = context
        self.thresholds = thresholds
    }

    public func write(_ input: WeeklyStoryInput) -> WeeklyStoryResult {
        let days = Self.orderedDays(input.days)
        let rules = input.rules.filter { NoteGuard.isClean($0.rule.title) && !Self.isBlank($0.rule.title) }
        guard let weekKey = days.first?.routineDayKey, !rules.isEmpty else { return .absent(.noRules) }
        let weeks = rules.map { WeekRule($0, days: days) }.sorted(by: Self.ordered)
        let decided = weeks.reduce(0) { $0 + $1.decided }
        guard decided >= thresholds.minimumDecidedRuleDays else {
            return .absent(.tooFewDecidedRuleDays(have: decided, need: thresholds.minimumDecidedRuleDays))
        }

        var drafts: [Draft] = [keptPage(weeks, days: days, startDay: input.startDay)]
        if let moved = movedPage(input.outcomes, days: days) { drafts.append(moved) }
        let change = strongestChange(input, weeks: weeks)
        if let change { drafts.append(changePage(change)) }
        var proposal: WeeklyReviewProposal?
        if let change, let made = makeProposal(for: change, input: input, weekKey: weekKey) {
            proposal = made
            drafts.append(proposalPage(made))
        }
        if let next = nextWeekPage(weeks, input: input) { drafts.append(next) }

        let total = drafts.count
        let formatter = NoteFormatter(context: context)
        let title = weekTitle(days)
        let pages = drafts.enumerated().map { index, draft in
            draft.page(position: index + 1, total: total, formatter: formatter, weekTitle: title)
        }
        return .story(WeeklyStory(weekKey: weekKey, pages: pages, proposal: proposal))
    }

    // MARK: Days and rules

    private static func orderedDays(_ days: [DayIdentity]) -> [DayIdentity] {
        var seen = Set<DayIdentity>()
        let unique = days.filter { $0.routineDayKey != nil && seen.insert($0).inserted }
        let sorted = unique.sorted { ($0.year, $0.month, $0.day) < ($1.year, $1.month, $1.day) }
        return Array(sorted.prefix(7))
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// One rule's week: the state of each day of the week, in day order. A day with no check is not in `states`, and
    /// neither is a day the rule was not due on and had no answer, so the review counts what Today and the check-in
    /// count (`RuleDueTest`, ICP R4 Q3).
    private struct WeekRule {
        let rule: ProtocolRule
        let states: [(day: DayIdentity, state: CheckState)]
        var kept: Int { states.filter { $0.state == .kept }.count }
        var missed: Int { states.filter { $0.state == .missed }.count }
        var unknown: Int { states.filter { $0.state == .unknown }.count }
        var decided: Int { kept + missed }

        /// The days of the week the rule was due on, or had an answer on.
        let due: Set<DayIdentity>

        /// Days of `counted` the rule was due and had no answer: no check, pending or not known. Days before its first
        /// check of the week are left out, so a rule added on Thursday is not "3 not known".
        func notKnown(in counted: [DayIdentity]) -> Int {
            guard let first = states.first?.day else { return 0 }
            let byDay = Dictionary(states.map { ($0.day, $0.state) }, uniquingKeysWith: { first, _ in first })
            return counted.filter { day in
                guard WeeklyStoryWriter.key(day) >= WeeklyStoryWriter.key(first), due.contains(day) else { return false }
                let state = byDay[day]
                return state == nil || state == .pending || state == .unknown
            }.count
        }

        init(_ week: WeeklyRuleWeek, days: [DayIdentity]) {
            rule = week.rule
            var byDay: [DayIdentity: CheckState] = [:]
            for entry in week.days where byDay[entry.day] == nil { byDay[entry.day] = entry.state }
            let counted = RuleDueTest.counted(week.rule, days: days.map { ($0, byDay[$0]) }, lastDone: week.lastDone)
            let dueDays = Set(zip(days, counted).filter { $0.1 }.map { $0.0 })
            due = dueDays
            states = days.compactMap { day in dueDays.contains(day) ? byDay[day].map { (day, $0) } : nil }
        }

        /// Days kept in a row ending at the last decided day. A day still pending at the end does not break it.
        var streak: Int {
            var count = 0
            var trailing = true
            for entry in states.reversed() {
                if trailing && entry.state == .pending { continue }
                trailing = false
                guard entry.state == .kept else { break }
                count += 1
            }
            return count
        }
    }

    private static func ordered(_ lhs: WeekRule, _ rhs: WeekRule) -> Bool {
        let left = lhs.rule.timeOfDayMinutes ?? Int.max, right = rhs.rule.timeOfDayMinutes ?? Int.max
        if left != right { return left < right }
        if lhs.rule.title != rhs.rule.title { return lhs.rule.title < rhs.rule.title }
        return lhs.rule.key < rhs.rule.key
    }

    // MARK: Drafts

    /// A page before its place in the story is known. The kicker needs the place, so the note is made at the end.
    private struct Draft {
        let kind: WeeklyStoryPageKind
        let title: String
        let runs: [NoteRun]
        let daysCovered: String
        let comparisonGroup: String?
        let receipt: NoteReceiptChart?
        let detail: WeeklyStoryDetail
        /// Numbers the page shows but its paragraph does not state.
        let supporting: [NoteNumber]

        /// `weekTitle` is "Week of 6 to 12 Nov", the dates the Protocol row names (ICP R2-DES-04).
        func page(position: Int, total: Int, formatter: NoteFormatter, weekTitle: String) -> WeeklyStoryPage {
            let kicker = "\(weekTitle) \u{00B7} \(formatter.integer(position)) of \(formatter.integer(total))"
            let strings = [kicker] + chrome
            let note = CoachNote(kind: .weeklyPage, runs: runs, receipt: receipt, daysCovered: daysCovered,
                                 comparisonGroup: comparisonGroup,
                                 supportingNumbers: supporting + NoteNumber.literals(in: strings))
            return WeeklyStoryPage(kind: kind, position: position, total: total, kicker: kicker, title: title, note: note,
                                   detail: detail)
        }

        /// Strings beside the paragraph whose digits count as supporting numbers.
        private var chrome: [String] {
            var strings = [title]
            switch detail {
            case .kept(let kept): strings += kept.rules.map(\.title) + [kept.share.displayed, kept.dayCountText]
            case .moved(let rows): strings += rows.flatMap { [$0.title, $0.comparison] }
            case .change(let change): strings += [change.ruleTitle]
            case .proposal(let proposal): strings += [proposal.label, proposal.changeTitle]
            case .nextWeek(let next): strings += next.rules.flatMap { [$0.title, $0.time ?? ""] } + [next.experiment?.title ?? ""]
            }
            return strings
        }
    }

    private func builder() -> NoteBuilder { NoteBuilder(context: context) }

    private func plain(_ value: Int) -> NoteNumber {
        NoteNumber(displayed: NoteFormatter(context: context).integer(value), value: Double(value), unit: .count)
    }

    /// "Monday to Sunday". Nil for one day or a day the calendar cannot place.
    private func weekdayRange(_ days: [DayIdentity]) -> String? {
        guard let first = days.first, let last = days.last, first != last,
              let from = context.weekday(of: first), let to = context.weekday(of: last) else { return nil }
        return "\(from) to \(to)"
    }

    /// "Week of 6 to 12 Nov", the review's title in every page's kicker. "Your week" when the calendar cannot place the
    /// days.
    func weekTitle(_ days: [DayIdentity]) -> String {
        dateRange(days).map { "Week of \($0)" } ?? "Your week"
    }

    /// "6 to 12 Nov", or "30 Oct to 5 Nov" across a month, as the Protocol row writes it. In a month-first locale both
    /// dates are whole: "Nov 6 to Nov 12". Nil for no days or a day the calendar cannot place.
    func dateRange(_ days: [DayIdentity]) -> String? {
        guard let start = days.first, let end = days.last, let first = noon(start), let last = noon(end) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        let endText = formatter.string(from: last)
        if start == end { return endText }
        if start.month == end.month && start.year == end.year && endText.hasPrefix("\(end.day)") {
            return "\(start.day) to \(endText)"
        }
        return "\(formatter.string(from: first)) to \(endText)"
    }

    private func noon(_ day: DayIdentity) -> Date? {
        context.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }

    // MARK: Page 1, what you kept

    /// Counts with `RoutineWeekCount`, the function the check-in's hero and the share pass use, so one week gives one
    /// number everywhere (ICP R2-DES-04, R2-VET-02).
    private func keptPage(_ weeks: [WeekRule], days: [DayIdentity], startDay: DayIdentity?) -> Draft {
        let formatter = NoteFormatter(context: context)
        let count = RoutineWeekCount(states: weeks.flatMap { $0.states.map { Optional($0.state) } })
        let kept = count.kept
        let decided = count.decided
        let unknown = count.unknown
        let share = formatter.number(Double(count.percent ?? 0), unit: .percent)
            ?? NoteNumber(displayed: "0%", value: 0, unit: .percent)

        var text = builder()
        text.text("You kept ")
        text.number(plain(kept), highlighted: true)
        text.text(" of the ")
        text.number(plain(decided))
        text.text(" rule checks that had an answer.")
        if unknown > 0 {
            text.text(" ")
            text.number(plain(unknown))
            text.text(unknown == 1 ? " check had no answer and is left out." : " checks had no answer and are left out.")
        }
        if count.skipped > 0 {
            text.text(" ")
            text.number(plain(count.skipped))
            text.text(count.skipped == 1 ? " skipped check is left out too." : " skipped checks are left out too.")
        }

        let counted = days.filter { day in startDay.map { Self.key($0) <= Self.key(day) } ?? true }
        // Every rule, weekly and quarterly ones too, so the list adds up to the share (ICP R3-VET-02).
        let rows = weeks.map { week in
            var row = WeeklyRuleRow(key: week.rule.key, title: week.rule.title, keptDays: week.kept,
                                    decidedDays: week.decided, streak: week.streak, missedDays: week.missed)
            row.isLongerPeriod = RuleProgressReader.hasProgress(week.rule)
            row.notKnownDays = row.isLongerPeriod ? 0 : week.notKnown(in: counted)
            return row
        }
        let lead = rows.filter { $0.streak >= 2 }.min { lhs, rhs in
            if lhs.streak != rhs.streak { return lhs.streak > rhs.streak }
            if lhs.keptDays != rhs.keptDays { return lhs.keptDays > rhs.keptDays }
            return lhs.key < rhs.key
        }
        if let lead {
            text.text(" ")
            text.text(lead.title, protected: true)
            text.text(" was kept ")
            text.number(formatter.count(lead.streak, noun: "day", unit: .days))
            text.text(" in a row, the longest run this week.")
        }
        let slipped = rows.filter { $0.missedDays > 0 }.min { lhs, rhs in
            if lhs.missedDays != rhs.missedDays { return lhs.missedDays > rhs.missedDays }
            return lhs.key < rhs.key
        }
        if let slipped, slipped.key != lead?.key {
            text.text(" ")
            text.text(slipped.title, protected: true)
            text.text(" was not kept on ")
            text.number(formatter.count(slipped.missedDays, noun: "day", unit: .days))
            text.text(", more than any other rule.")
        }

        let cells = days.map { day -> WeeklyDayCell in
            let states = weeks.compactMap { week in week.states.first { $0.day == day }?.state }
            let counted = startDay.map { ($0.year, $0.month, $0.day) <= (day.year, day.month, day.day) } ?? true
            var cell = WeeklyDayCell(day: day, weekday: context.weekday(of: day),
                                     kept: states.filter { $0 == .kept }.count,
                                     decided: states.filter { $0 == .kept || $0 == .missed }.count, counted: counted)
            cell.skipped = states.filter { $0 == .skipped }.count
            cell.shortWeekday = shortWeekday(day)
            return cell
        }
        var detail = WeeklyKeptDetail(share: share, keptRuleDays: kept, decidedRuleDays: decided, days: cells, rules: rows)
        detail.skippedRuleDays = count.skipped
        detail.dayCount = cells.filter(\.counted).count
        detail.key = dayKey(cells)
        let range = dateRange(days)
        return Draft(kind: .kept, title: "What you kept.", runs: text.runs,
                     daysCovered: range.map { "\($0), \(detail.dayCountText)." } ?? "This week.",
                     comparisonGroup: "Your rules, checked against what each source decided",
                     receipt: nil, detail: .kept(detail), supporting: [share])
    }

    /// The key under the dots, one entry per mark the week shows (ICP R3-DES-05, R3-SEN-07, R3-HAB-07): "All kept",
    /// then the days of each other mark, "Fri and Sat: a rule not kept", "Sun: nothing to answer".
    func dayKey(_ cells: [WeeklyDayCell]) -> [WeeklyDayKeyEntry] {
        let shown = cells.filter { $0.mark != .none }
        var entries: [WeeklyDayKeyEntry] = []
        for mark in [WeeklyDayMark.kept, .notKept, .skipped, .open] {
            let marked = shown.filter { $0.mark == mark }
            guard !marked.isEmpty else { continue }
            let meaning: String = switch mark {
            case .kept: "all kept"
            case .notKept: "a rule not kept"
            case .skipped: "skipped"
            case .open: "nothing to answer"
            case .none: ""
            }
            if mark == .kept {
                entries.append(WeeklyDayKeyEntry(mark: mark, text: marked.count == shown.count ? "Every day: all kept" : "All kept"))
                continue
            }
            let names = marked.compactMap(\.shortWeekday)
            let formatter = ListFormatter()
            formatter.locale = context.locale
            let list = formatter.string(from: names) ?? names.joined(separator: ", ")
            entries.append(WeeklyDayKeyEntry(mark: mark, text: list.isEmpty ? meaning : "\(list): \(meaning)"))
        }
        return entries
    }

    /// "Fri", in the context's locale.
    private func shortWeekday(_ day: DayIdentity) -> String? {
        guard let date = noon(day) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.timeZone = context.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    private static func key(_ day: DayIdentity) -> Int { day.year * 10_000 + day.month * 100 + day.day }

    // MARK: Page 2, what moved

    private func movedPage(_ outcomes: [WeeklyOutcomeWeek], days: [DayIdentity]) -> Draft? {
        let formatter = NoteFormatter(context: context)
        let notes = thresholds.notes
        struct Candidate { let row: WeeklyMovedRow; let usualNights: NoteNumber; let size: NoteNumber?; let relative: Double }
        var candidates: [Candidate] = []
        for outcome in outcomes {
            guard let mean = outcome.weekMean, mean.isFinite, mean >= 0, outcome.nights >= thresholds.minimumOutcomeNights,
                  let usual = outcome.usual, usual.median.isFinite, usual.median >= 0,
                  usual.nights >= notes.minimumUsualNights,
                  let value = formatter.number(mean, unit: outcome.unit) else { continue }
            let nights = formatter.count(outcome.nights, noun: "night", unit: .nights)
            let usualNights = formatter.count(usual.nights, noun: "night", unit: .nights)
            let delta = mean - usual.median
            let size = formatter.number(abs(delta), unit: outcome.unit)
            let direction: WeeklyMoveDirection = (size?.value ?? 0) > 0 ? (delta > 0 ? .above : .below) : .inLine
            let comparison: String
            switch direction {
            case .inLine: comparison = "in line with your usual"
            case .above, .below: comparison = "\(size?.displayed ?? "") \(direction == .above ? "above" : "below") your usual"
            }
            let row = WeeklyMovedRow(kind: outcome.kind, title: outcome.kind.title, weekValue: value, nights: nights,
                                     direction: direction, comparison: comparison)
            candidates.append(Candidate(row: row, usualNights: usualNights, size: direction == .inLine ? nil : size,
                                        relative: abs(delta) / max(usual.median, 1)))
        }
        let chosen = candidates.sorted { lhs, rhs in
            if lhs.relative != rhs.relative { return lhs.relative > rhs.relative }
            return lhs.row.kind.rawValue < rhs.row.kind.rawValue
        }.prefix(thresholds.maximumMovedOutcomes)
        guard !chosen.isEmpty else { return nil }

        var text = builder()
        for (index, candidate) in chosen.enumerated() {
            let row = candidate.row
            text.text(index == 0 ? "" : " ")
            text.text("\(row.title) averaged ")
            text.number(row.weekValue, highlighted: index == 0)
            text.text(" over ")
            text.number(row.nights)
            if let size = candidate.size {
                text.text(", ")
                text.number(size)
                text.text(row.direction == .above ? " above your usual over " : " below your usual over ")
            } else {
                text.text(", in line with your usual over ")
            }
            text.number(candidate.usualNights)
            text.text(".")
        }
        let range = weekdayRange(days)
        return Draft(kind: .moved, title: "What moved.", runs: text.runs,
                     daysCovered: range.map { "The nights from \($0)." } ?? "This week's nights.",
                     comparisonGroup: "Each outcome against your usual for it",
                     receipt: nil, detail: .moved(chosen.map(\.row)), supporting: [])
    }

    // MARK: Page 3, one change worth trying

    private struct Change {
        let slip: WeeklySlip
        let missed: NoteReceiptGroup
        let kept: NoteReceiptGroup
        /// Mean on the nights the rule was missed minus the mean on the nights it was kept.
        let difference: Double
        let size: NoteNumber
        let missedDays: [DayIdentity]
    }

    private func strongestChange(_ input: WeeklyStoryInput, weeks: [WeekRule]) -> Change? {
        let formatter = NoteFormatter(context: context)
        let minimum = thresholds.notes.minimumNightsPerGroup
        let candidates = input.slips.compactMap { slip -> Change? in
            guard let week = weeks.first(where: { $0.rule.key == slip.rule.key }) else { return nil }
            let missedDays = week.states.filter { $0.state == .missed }.map(\.day)
            guard !missedDays.isEmpty else { return nil }
            func nights(missed: Bool) -> [NoteReceiptNight] {
                slip.history.compactMap { night in
                    guard night.missed == missed, let value = night.outcome, value.isFinite else { return nil }
                    return NoteReceiptNight(day: night.day, value: value)
                }
            }
            let missedNights = nights(missed: true), keptNights = nights(missed: false)
            guard missedNights.count >= minimum, keptNights.count >= minimum else { return nil }
            let missedMean = missedNights.map(\.value).reduce(0, +) / Double(missedNights.count)
            let keptMean = keptNights.map(\.value).reduce(0, +) / Double(keptNights.count)
            let difference = missedMean - keptMean
            // Only a slip that coincided with a worse outcome is a change worth trying.
            guard slip.outcome.higherIsBetter ? difference < 0 : difference > 0,
                  let size = formatter.number(abs(difference), unit: slip.unit), size.value > 0 else { return nil }
            let missedCount = formatter.count(missedNights.count, noun: "night", unit: .nights)
            let keptCount = formatter.count(keptNights.count, noun: "night", unit: .nights)
            return Change(
                slip: slip,
                missed: NoteReceiptGroup(id: "missed", label: "\(missedCount.displayed), not kept", nightCount: missedNights.count,
                                         mean: missedMean, nights: missedNights, isLikeLastNight: true),
                kept: NoteReceiptGroup(id: "kept", label: "\(keptCount.displayed), kept", nightCount: keptNights.count,
                                       mean: keptMean, nights: keptNights, isLikeLastNight: false),
                difference: difference, size: size, missedDays: missedDays)
        }
        return candidates.min { lhs, rhs in
            let left = abs(lhs.difference), right = abs(rhs.difference)
            if left != right { return left > right }
            let leftSmall = min(lhs.missed.nightCount, lhs.kept.nightCount)
            let rightSmall = min(rhs.missed.nightCount, rhs.kept.nightCount)
            if leftSmall != rightSmall { return leftSmall > rightSmall }
            return lhs.slip.id < rhs.slip.id
        }
    }

    private func changePage(_ change: Change) -> Draft {
        let formatter = NoteFormatter(context: context)
        let title = change.slip.rule.title
        let names = change.missedDays.compactMap { context.weekday(of: $0) }
        let missedCount = formatter.count(change.missed.nightCount, noun: "night", unit: .nights)
        let keptCount = formatter.count(change.kept.nightCount, noun: "night", unit: .nights)

        var text = builder()
        text.text(title, protected: true)
        text.text(" was not kept ")
        let named = change.missedDays.count <= 3 && names.count == change.missedDays.count
        if named {
            text.text("on ")
            text.text(Self.list(names), protected: true)
            text.text(".")
        } else {
            text.text("on ")
            text.number(formatter.count(change.missedDays.count, noun: "day", unit: .days))
            text.text(" this week.")
        }
        text.text(" On the ")
        text.number(missedCount)
        text.text(" it was not kept, \(change.slip.outcome.phrase) averaged ")
        text.number(change.size, highlighted: true)
        text.text(" \(change.slip.outcome.direction(higher: change.difference > 0)) than on the ")
        text.number(keptCount)
        text.text(" it was kept.")

        let chart = NoteReceiptChart(outcome: change.slip.outcome, unit: change.slip.unit,
                                     groups: [change.missed, change.kept], lastNightValue: nil)
        let detail = WeeklyChangeDetail(ruleKey: change.slip.rule.key, ruleTitle: title,
                                        missedWeekdays: named ? names : [], missedDays: change.missedDays.count, receipt: chart)
        return Draft(kind: .change, title: "One change worth trying.", runs: text.runs,
                     daysCovered: "The days this week it was not kept, and earlier nights it was not kept.",
                     comparisonGroup: "\(missedCount.displayed) not kept, against \(keptCount.displayed) kept",
                     receipt: chart, detail: .change(detail), supporting: [])
    }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Page 4, the proposal

    private func makeProposal(for change: Change, input: WeeklyStoryInput, weekKey: String) -> WeeklyReviewProposal? {
        // One experiment at a time, and a version to move on from.
        guard input.runningExperiment == nil, let from = input.versionNumber, from >= 1 else { return nil }
        let formatter = NoteFormatter(context: context)
        let slip = change.slip
        let gap = change.size.value
        if let decision = input.declined.last(where: { $0.ruleKey == slip.rule.key && $0.outcome == slip.outcome }),
           !isRenewed(decision, missedNights: change.missed.nightCount, gap: gap) { return nil }
        var changeTitle = slip.changeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if changeTitle.isEmpty || !NoteGuard.isClean(changeTitle) { changeTitle = "Keep \(slip.rule.title) every day" }
        return WeeklyReviewProposal(
            weekKey: weekKey,
            ruleKey: slip.rule.key, ruleTitle: slip.rule.title,
            changeTitle: context.localizingClock(changeTitle),
            outcome: slip.outcome, design: slip.design, experimentDays: thresholds.experimentDays,
            fromVersion: from, toVersion: from + 1,
            label: "Proposed for version \(formatter.integer(from + 1))",
            missedNights: change.missed.nightCount, keptNights: change.kept.nightCount, gap: gap)
    }

    /// A declined proposal comes back when the missed group has `renewalNights` more nights, or the gap has grown by
    /// `renewalGapGrowth` of what it was. Otherwise it is the same evidence and stays declined.
    private func isRenewed(_ decision: WeeklyProposalDecision, missedNights: Int, gap: Double) -> Bool {
        missedNights >= decision.missedNights + thresholds.renewalNights
            || gap >= decision.gap * (1 + thresholds.renewalGapGrowth)
    }

    private func proposalPage(_ proposal: WeeklyReviewProposal) -> Draft {
        var text = builder()
        text.text("Run it as a ")
        text.number(plain(proposal.experimentDays))
        text.text("-day experiment first. Outcome: \(proposal.outcome.phrase). Version ")
        text.number(plain(proposal.fromVersion))
        text.text(" stays until you decide.")
        return Draft(kind: .proposal, title: "One proposal.", runs: text.runs,
                     daysCovered: "The nights behind the change on the page before.",
                     comparisonGroup: nil, receipt: nil, detail: .proposal(proposal), supporting: [])
    }

    // MARK: Page 5, next week

    private func nextWeekPage(_ weeks: [WeekRule], input: WeeklyStoryInput) -> Draft? {
        let formatter = NoteFormatter(context: context)
        let rules = weeks.map(\.rule)
        let experiment = input.runningExperiment.flatMap { running -> WeeklyRunningExperiment? in
            guard running.totalDays > 0, (1...running.totalDays).contains(running.dayNumber),
                  NoteGuard.isClean(running.title), !Self.isBlank(running.title) else { return nil }
            return running
        }
        guard !rules.isEmpty else { return nil }

        func appendTimed(_ rule: ProtocolRule, to text: inout NoteBuilder) {
            text.text(rule.title, protected: true)
            if let minute = rule.timeOfDayMinutes, let clock = formatter.number(Double(minute), unit: .clock) {
                text.text(" at ")
                text.number(clock)
            }
        }
        var text = builder()
        text.text(input.versionNumber.map { _ in "Version " } ?? "Your protocol")
        if let version = input.versionNumber, version >= 1 {
            text.number(plain(version))
        }
        text.text(" carries on with ")
        text.number(formatter.count(rules.count, noun: "rule", unit: .count))
        if rules.count == 1, let only = rules.first {
            text.text(", ")
            appendTimed(only, to: &text)
        } else if let first = rules.first, let last = rules.last {
            text.text(", from ")
            appendTimed(first, to: &text)
            text.text(" to ")
            appendTimed(last, to: &text)
        }
        text.text(".")
        if let experiment {
            text.text(" Your experiment, ")
            text.text(experiment.title, protected: true)
            text.text(", is on day ")
            text.number(plain(experiment.dayNumber))
            text.text(" of ")
            text.number(plain(experiment.totalDays))
            text.text(". It measures \(experiment.outcome.phrase).")
        }
        let nextRules = rules.map { rule in
            WeeklyNextRule(key: rule.key, title: rule.title,
                           time: rule.timeOfDayMinutes.flatMap { formatter.number(Double($0), unit: .clock)?.displayed })
        }
        return Draft(kind: .nextWeek, title: "Next week.", runs: text.runs, daysCovered: "The week ahead.",
                     comparisonGroup: nil, receipt: nil,
                     detail: .nextWeek(WeeklyNextWeekDetail(versionNumber: input.versionNumber, rules: nextRules, experiment: experiment)),
                     supporting: [])
    }
}

extension NoteNumber {
    /// One literal number for each digit group in `strings`, once each. They are the numbers a screen shows around the
    /// paragraph, such as the digits in a rule title.
    static func literals(in strings: [String]) -> [NoteNumber] {
        var seen = Set<String>()
        var result: [NoteNumber] = []
        for string in strings {
            for token in NoteDigits.tokens(in: string) where seen.insert(token).inserted {
                result.append(NoteNumber(displayed: token, value: NoteDigits.value(of: token) ?? 0, unit: .literal))
            }
        }
        return result
    }
}
