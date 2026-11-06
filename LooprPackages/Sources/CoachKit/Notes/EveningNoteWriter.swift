import Foundation
import RoutineKit

/// The evening note. It reads today's protocol state: the rules already kept with their times, a count for the week
/// when it is real, and the rules still to come. A rule whose check is unknown, and a rule that was missed, get no
/// sentence. The note says only what the checks say.
enum EveningNoteWriter {
    static func write(_ input: EveningNoteInput, context: NoteContext) -> CoachNote? {
        let formatter = NoteFormatter(context: context)
        let thresholds = context.thresholds
        let rules = input.rules.filter { day in
            NoteGuard.isClean(day.rule.title) && (day.keptLabel.map(NoteGuard.isClean) ?? true)
                && !day.rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted(by: ordered)
        guard !rules.isEmpty else { return nil }
        let kept = rules.filter { $0.state == .kept }
        let pending = rules.filter { $0.state == .pending }
        guard !kept.isEmpty || !pending.isEmpty else { return nil }

        var builder = NoteBuilder(context: context)

        // 1. What is kept.
        if !kept.isEmpty {
            if kept.count == 1, let only = kept.first, let label = only.keptLabel {
                builder.text(label, protected: true)
                appendTime(only, formatter: formatter, highlighted: true, to: &builder)
            } else {
                builder.text("So far today you have kept ")
                appendList(kept, limit: thresholds.maximumListedRules, formatter: formatter,
                           highlightTimes: kept.count == 1, to: &builder)
            }
            builder.text(".")
        }

        // 2. A count for the week, when it is real.
        var weekDays: NoteNumber?
        if let lead = weekLead(kept, minimum: thresholds.minimumWeekCount),
           let count = lead.keptDaysThisWeek, let days = lead.daysThisWeek {
            let countNumber = formatter.number(Double(count), unit: .count)
            let daysNumber = formatter.count(days, noun: "day", unit: .days)
            if let countNumber {
                builder.text(builder.runs.isEmpty ? "" : " ")
                // With one rule kept, the sentence before already names it.
                if kept.count == 1, kept.first?.rule.key == lead.rule.key {
                    builder.text("That is ")
                } else {
                    if let label = lead.keptLabel {
                        builder.text(label, protected: true)
                    } else {
                        builder.text("You kept ")
                        builder.text(lead.rule.title, protected: true)
                    }
                    builder.text(" on ")
                }
                builder.number(countNumber)
                builder.text(" of ")
                builder.number(daysNumber)
                builder.text(" this week.")
                weekDays = daysNumber
            }
        }

        // 3. What is still to come.
        if !pending.isEmpty {
            builder.text(builder.runs.isEmpty ? "" : " ")
            if pending.count == 1, let last = pending.first {
                builder.text(last.rule.title, protected: true)
                appendTime(last, formatter: formatter, highlighted: false, to: &builder)
                builder.text(kept.isEmpty ? " is the only rule left today." : " is the last rule left.")
            } else {
                builder.text("Still to come before bed: ")
                appendList(pending, limit: thresholds.maximumListedRules, formatter: formatter, highlightTimes: false, to: &builder)
                builder.text(".")
            }
        } else if kept.count > 1, rules.allSatisfy({ $0.state == .kept }) {
            builder.text(" Every rule for today is kept.")
        }

        var days = "Today"
        var comparison: String?
        if let weekDays {
            days += ", and the days so far this week"
            comparison = "The \(weekDays.displayed) of this week so far"
        }
        var chips: [NoteChip] = []
        if !pending.isEmpty { chips.append(NoteChip(action: .startWindDown, label: "Start wind-down")) }
        chips.append(NoteChip(action: .ask, label: "Ask"))

        let note = CoachNote(kind: .evening, runs: builder.runs, daysCovered: days + ".", comparisonGroup: comparison,
                             chips: chips)
        return NoteGuard.isClean(note.text) ? note : nil
    }

    /// By the time the rule is kept or due, then by title and key, so equal times never reorder between runs.
    private static func ordered(_ lhs: NoteRuleDay, _ rhs: NoteRuleDay) -> Bool {
        let left = time(lhs) ?? Int.max, right = time(rhs) ?? Int.max
        if left != right { return left < right }
        if lhs.rule.title != rhs.rule.title { return lhs.rule.title < rhs.rule.title }
        return lhs.rule.key < rhs.rule.key
    }

    private static func time(_ day: NoteRuleDay) -> Int? {
        let minute = day.state == .kept ? (day.keptAtMinuteOfDay ?? day.rule.timeOfDayMinutes) : day.rule.timeOfDayMinutes
        guard let minute, (0..<1_440).contains(minute) else { return nil }
        return minute
    }

    private static func appendTime(_ day: NoteRuleDay, formatter: NoteFormatter, highlighted: Bool, to builder: inout NoteBuilder) {
        guard let minute = time(day), let clock = formatter.number(Double(minute), unit: .clock) else { return }
        // "Screens off by 21:45" already names its time, so it never reads "Screens off by 21:45 at 21:45" (R3-OPT-15).
        let plain = String(format: "%02d:%02d", minute / 60, minute % 60)
        if day.state != .kept, day.rule.title.contains(clock.displayed) || day.rule.title.contains(plain) { return }
        builder.text(" at ")
        builder.number(clock, highlighted: highlighted)
    }

    /// "A at 7:10 am, B and C at 6:20 pm". More than `limit` rules end with "and 2 more".
    private static func appendList(_ days: [NoteRuleDay], limit: Int, formatter: NoteFormatter, highlightTimes: Bool,
                                   to builder: inout NoteBuilder) {
        let shown = Array(days.prefix(max(1, limit)))
        let hidden = days.count - shown.count
        for (index, day) in shown.enumerated() {
            if index > 0 { builder.text(index == shown.count - 1 && hidden == 0 ? " and " : ", ") }
            builder.text(day.rule.title, protected: true)
            appendTime(day, formatter: formatter, highlighted: highlightTimes, to: &builder)
        }
        if hidden > 0 {
            builder.text(" and ")
            if let more = formatter.number(Double(hidden), unit: .count) { builder.number(more) }
            builder.text(" more")
        }
    }

    /// The kept rule with the longest run this week. A count is real when it is at least the minimum, never above the
    /// days that count, and the week has at most seven days. Ties go to the rule that comes last in the day.
    private static func weekLead(_ kept: [NoteRuleDay], minimum: Int) -> NoteRuleDay? {
        let real = kept.filter { day in
            guard let count = day.keptDaysThisWeek, let days = day.daysThisWeek else { return false }
            return count >= minimum && count <= days && days <= 7
        }
        var best: NoteRuleDay?
        for day in real where (day.keptDaysThisWeek ?? 0) >= (best?.keptDaysThisWeek ?? 0) { best = day }
        return best
    }
}
