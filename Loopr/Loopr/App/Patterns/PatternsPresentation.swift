import DesignSystem
import DomainKit
import Foundation
import JournalKit
import NotificationKit
import RoutineKit

/// Every sentence on the Patterns screen that the package does not already write. The wording compares a
/// person's own nights and never says what caused a difference.
nonisolated enum PatternsCopy {
    static let title = "Patterns"
    static let foundHeader = "Found in your data"
    static let foundDetail = "Each one can become a test"
    static let reviewHeader = "Weekly review"
    static let onDevice = "On device"
    static let morningTitle = "Morning briefing"
    static let morningSubtitle = "After the night is scored"
    static let discoveryTitle = "Look for new patterns"
    static let discoverySubtitle = "Weekly, on this iPhone"
    static let keepToday = "Mark today as kept"
    static let stopTest = "Stop test"
    static let restore = "Show again"
    /// Hides a pattern from Today and the Found list. Nothing is deleted (ICP R1-SEN-20).
    static let dismiss = "Not now"
    static let dismissNote = "Not now hides this pattern from Today and moves it to Hidden. You can show it again from there."
    static let dismissedHeader = "Hidden"
    static let tryFor14Days = "Try for 14 days"
    static let oneTestAtATime = "One test runs at a time. Finish or stop the current one to start another."
    static let dismissedNote = "They stay off Today until you show them again."
    static let loading = "Loading patterns"

    /// "Deep sleep is 14 min lower after a late dinner", "Deep sleep is 19 min lower when you eat after 21:00"
    static func headline(_ pattern: FoundPattern, locale: Locale = .current) -> String {
        let amount = PatternCopy.amount(pattern.effect.difference)
        let clause = pattern.predicate.clause
        let text = amount == "0" ? "\(pattern.metric.title) is the same \(clause)"
            : "\(pattern.metric.title) is \(amount) \(pattern.effect.unit.label) \(pattern.effect.difference > 0 ? "higher" : "lower") \(clause)"
        return LooprClockFormat.localizing(text, locale: locale)
    }

    /// A stored sentence for display: each 24-hour time is written in the locale's clock style. Nothing stored changes.
    static func display(_ stored: String, locale: Locale = .current) -> String {
        LooprClockFormat.localizing(stored, locale: locale)
    }

    /// The test's title, for example "Kitchen closed at 8:30 pm" in a 12-hour locale.
    static func title(_ test: PatternTest, locale: Locale = .current) -> String { display(test.title, locale: locale) }

    /// "9 nights with, 14 without · usual spread 11 ms". The counts replace "Strong" and "Clear" (ICP R1-VET-13), and the
    /// spread lets the gap be read against a normal night (ICP R2-VET-09).
    static func caption(_ pattern: FoundPattern) -> String {
        guard let spread = pattern.effect.spread, spread.isFinite, spread > 0 else { return pattern.nightsLabel }
        return "\(pattern.nightsLabel) \u{00B7} usual spread \(PatternCopy.amount(spread)) \(pattern.effect.unit.label)"
    }

    /// Why Try cannot start while another test runs, without naming a day: the engine's refusal when a start slips past
    /// the disabled button (ICP R1-VET-10). The detail sheet says the day (`startsAfter`).
    static func experimentBlocks(_ title: String) -> String {
        "\(display(title)) is still running. \(oneAtATime)"
    }

    static let oneAtATime = "Loopr runs one test at a time, so two results never mix."

    /// Why a disabled Try cannot start yet and when it can, for a running pattern test (ICP R2-SEN-12, R2-DES-13): "You
    /// can start this after your current test, Kitchen closed at 20:30, ends on 20 Nov." The test ends the morning
    /// after its last day.
    static func startsAfter(_ test: PatternTest, locale: Locale = .current) -> String {
        let end = DayIdentity(habitKey: test.startDay).flatMap { $0.adding(days: test.testDays) }
        let title = display(test.title, locale: locale)
        guard let end else { return "You can start this after your current test, \(title), ends. \(oneAtATime)" }
        return "You can start this after your current test, \(title), ends on \(ExperimentCopy.dayAndMonth(end)). \(oneAtATime)"
    }

    /// The same for a protocol experiment: "You can start this after the magnesium test ends on 20 Nov."
    static func startsAfter(_ experiment: PatternsRunningExperiment) -> String {
        guard let line = experiment.startsAfter else { return experimentBlocks(experiment.title) }
        return "\(line) \(oneAtATime)"
    }

    /// The gap's 95% range in plain words: "95% range 5 to 11 ms lower" (ICP R2-VET-10). Nil without an interval.
    static func likelyRange(_ pattern: FoundPattern) -> String? {
        guard let low = pattern.effect.intervalLower, let high = pattern.effect.intervalUpper, low.isFinite, high.isFinite else { return nil }
        let unit = pattern.effect.unit.label
        let name = ExperimentCopy.rangeName()
        if high < 0 { return "\(name) \(PatternCopy.amount(high)) to \(PatternCopy.amount(low)) \(unit) lower" }
        if low > 0 { return "\(name) \(PatternCopy.amount(low)) to \(PatternCopy.amount(high)) \(unit) higher" }
        let lowText = low < 0 ? "\u{2212}\(PatternCopy.amount(low))" : PatternCopy.amount(low)
        return "\(name) \(lowText) to +\(PatternCopy.amount(high)) \(unit)"
    }

    /// The person's usual night-to-night spread under the pattern's sentence, so a gap can be read against it (ICP
    /// R2-VET-09): "Your usual spread is 11 min from one night to the next." Nil for a pattern found before Loopr kept
    /// the spread, or with too few back-to-back nights to measure it.
    static func usualSpread(_ pattern: FoundPattern) -> String? {
        guard let spread = pattern.effect.spread, spread.isFinite, spread > 0 else { return nil }
        return "Your usual spread is \(PatternCopy.amount(spread)) \(pattern.effect.unit.label) from one night to the next."
    }

    /// The bar a gap clears before Loopr lists it: "Loopr lists a gap only when it is 5 ms or more." Nil when the stored
    /// pattern has no threshold.
    static func threshold(_ pattern: FoundPattern) -> String? {
        let threshold = pattern.effect.practicalThreshold
        guard threshold > 0, threshold.isFinite else { return nil }
        return "Loopr lists a gap only when it is \(PatternCopy.amount(threshold)) \(pattern.effect.unit.label) or more."
    }

    static func dayChip(_ progress: PatternTestProgress, test: PatternTest) -> String {
        test.state == .running ? "Day \(progress.dayNumber) of \(test.testDays)" : "Finished"
    }

    /// "Kept on 5 of 6 nights. Too early to tell. A reminder comes at 20:15."
    static func status(test: PatternTest, progress: PatternTestProgress, verdict: PatternTestVerdict?, locale: Locale = .current) -> String {
        var parts = ["Kept on \(progress.keptCount) of \(progress.elapsedDays) nights."]
        if let verdict {
            if verdict.isConclusive {
                parts.append(verdict.headline + ".")
                let body = verdict.detail.replacingOccurrences(of: " " + PatternTestVerdict.footnote, with: "")
                    .replacingOccurrences(of: PatternTestVerdict.footnote, with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { parts.append(body) }
                parts.append(PatternTestVerdict.footnote)
            } else {
                parts.append(verdict.headline + ".")
            }
        } else {
            parts.append(PatternTestVerdict.tooEarlyHeadline + ".")
        }
        if test.state == .running, let reminder = test.reminder, reminder.enabled {
            parts.append("A reminder comes at \(clock(reminder.minuteOfDay, locale: locale)).")
        } else if test.state == .running, let problem = test.reminderProblem {
            parts.append(reminderProblem(problem))
        }
        return parts.joined(separator: " ")
    }

    /// Why a running test has no reminder.
    static func reminderProblem(_ problem: PatternReminderProblem) -> String {
        switch problem {
        case .notAllowed: "No reminder was set, because notifications are off for Loopr."
        case .full: "No reminder was set. \(NotificationFamily.userReminderLimit) reminders are already waiting. Cancel one in Settings > Notifications."
        case .familyOff: "No reminder was set. Reminders you set are turned off in Settings > Notifications."
        case .failed: "No reminder was set. Loopr could not schedule it."
        case .cancelled: "You cancelled the reminder in Settings."
        }
    }

    static func clock(_ minuteOfDay: Int, locale: Locale = .current) -> String { LooprClockFormat.text(minuteOfDay: minuteOfDay, locale: locale) }

    /// "Deep sleep now"
    static func nowLabel(_ metric: HabitOutcomeMetricID) -> String { "\(metric.title) now" }

    static func unit(_ unit: HabitMetricUnitID) -> String? {
        switch unit {
        case .minutes: "min"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .scorePoints, .percentagePoints: nil
        }
    }

    /// "Sun 11 Oct", from the last day of the review week.
    static func reviewDate(_ review: WeeklyReview) -> String {
        guard let day = DayIdentity(habitKey: review.weekEndDay) else { return review.weekEndDay }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else { return review.weekEndDay }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    /// "Hidden 4 Oct"
    static func dismissedCaption(_ item: DismissedPattern, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM"
        return "Hidden \(formatter.string(from: item.dismissedAt))"
    }
}
