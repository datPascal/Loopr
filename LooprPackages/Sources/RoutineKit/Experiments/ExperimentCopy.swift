import DesignSystem
import DomainKit
import Foundation

/// Every sentence an experiment shows. Wording says what differed between the person's own nights and never what
/// caused it. Sentence case, no exclamation marks, no em dashes. Numbers are written the same way for every locale so
/// tests and screens agree.
public enum ExperimentCopy {
    public static let footnote = "These compare your own nights. They do not show cause."
    public static let outcomeChip = "outcome fixed on day 1"
    public static let tooEarlyHeadline = "Too early to say."

    // MARK: Numbers

    /// "14", "7.5". One decimal at most.
    public static func amount(_ value: Double) -> String {
        let rounded = (abs(value) * 10).rounded() / 10
        let text = String(format: "%.1f", rounded)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// "+14", "−3", "0". The minus is U+2212, as every signed number on screen. Use `spokenSigned` for a label.
    public static func signed(_ value: Double) -> String {
        let text = amount(value)
        if text == "0" { return text }
        return (value > 0 ? LooprSignedNumber.plusSign : LooprSignedNumber.minusSign) + text
    }

    /// "plus 14", "minus 3", "0", for VoiceOver.
    public static func spokenSigned(_ value: Double) -> String { LooprSignedNumber.spoken(text: signed(value)) }

    /// A unit in words for a sentence, so a result reads before its abbreviation does (ICP R2-SEN-13): "minutes",
    /// "beats a minute", "milliseconds". Other units stay as printed.
    static func unitWords(_ unit: String, for value: Double) -> String {
        let one = amount(value) == "1"
        switch unit {
        case "min": return one ? "minute" : "minutes"
        case "bpm": return one ? "beat a minute" : "beats a minute"
        case "ms": return one ? "millisecond" : "milliseconds"
        default: return unit
        }
    }

    /// "95% range", the name for a result's likely range wherever it shows (ICP R2-VET-10).
    public static func rangeName(policy: ExperimentPolicy = .standard) -> String {
        "\(Int((policy.confidence * 100).rounded()))% range"
    }

    static func nights(_ count: Int) -> String { count == 1 ? "1 night" : "\(count) nights" }

    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    private static func article(before word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    private static func lowercasedKeepingAcronyms(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word == word.uppercased() && word.count > 1 ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }

    private static func cleaned(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    // MARK: Today and the protocol card

    /// "Tonight is a magnesium night." Nil outside the experiment, so Today says nothing.
    public static func tonight(role: ExperimentNightRole, interventionName: String) -> String? {
        let name = cleaned(interventionName)
        switch role {
        case .on: return "Tonight is \(article(before: name)) \(name) night."
        case .off: return "Tonight is an off night. No \(name)."
        case .washout(.on): return "Tonight is \(article(before: name)) \(name) night. Loopr leaves it out of the result while the effect settles."
        case .washout(.off): return "Tonight is an off night. No \(name). Loopr leaves it out of the result while the effect settles."
        case .outside: return nil
        }
    }

    /// "Running · night 9 of 14", "Finished · 28 nights", "Stopped · 6 nights".
    public static func progress(experiment: Experiment, report: ExperimentReport) -> String {
        switch experiment.status {
        case .running: "Running · night \(min(report.nightsCompleted + 1, report.plannedNights)) of \(report.plannedNights)"
        case .finished: "Finished · \(nights(report.nightsCompleted))"
        case .stopped: "Stopped · \(nights(report.nightsCompleted))"
        }
    }

    /// "Alternating days in a fixed order, not random, decided before night 1".
    public static func designLine(_ design: ExperimentDesign) -> String {
        switch design {
        case .alternatingDays: "Alternating days in a fixed order, not random, decided before night 1"
        case .blocks(let length): "Blocks of \(nights(length)), decided before night 1"
        case .beforeAndAfter(let baseline): "Before and after, \(nights(baseline)) first, decided before night 1"
        }
    }

    /// "1 night left out after each switch". Nil without a washout.
    public static func washoutLine(_ washout: Int) -> String? {
        washout > 0 ? "\(nights(washout)) left out after each switch" : nil
    }

    /// "Deep sleep, fixed on day 1".
    public static func outcomeLine(_ metric: ExperimentMetric) -> String { "\(metric.title), fixed on day 1" }

    // MARK: Sentences by state

    /// The sentence under the card or on the result page, chosen by the report's state.
    public static func summary(report: ExperimentReport, interventionName: String,
                               policy: ExperimentPolicy = .standard) -> String {
        switch report.state {
        case .cannotReport(let shortfall): cannotReport(shortfall, metric: report.outcome, policy: policy)
        case .tooEarlyToSay: running(report: report, interventionName: interventionName)
        case .notEnoughNights: notEnoughNights(report: report)
        case .notCalled: notCalled(report: report, policy: policy)
        case .result(let label): finished(label: label, report: report, interventionName: interventionName, policy: policy)
        }
    }

    static func cannotReport(_ shortfall: NoiseBand.Shortfall, metric: ExperimentMetric, policy: ExperimentPolicy) -> String {
        let name = lowercasedKeepingAcronyms(metric.title)
        let window = policy.baselineWindowNights
        switch shortfall {
        case .tooFewNights(let have, let need):
            return "Loopr cannot show a result for this one. It needs \(nights(need)) of \(name) in the \(window) nights before day 1 to learn your usual spread, and found \(have)."
        case .tooFewConsecutivePairs(let have, let need):
            return "Loopr cannot show a result for this one. It needs \(need) pairs of back-to-back nights of \(name) in the \(window) nights before day 1 to learn your usual spread, and found \(have)."
        }
    }

    /// "Too early to say. Magnesium nights are 6 minutes ahead, inside your usual night-to-night spread of 9. Loopr
    /// shows a result after night 14, and only if it clears that spread."
    static func running(report: ExperimentReport, interventionName: String) -> String {
        let name = capitalized(cleaned(interventionName))
        guard let spread = report.spread else { return tooEarlyHeadline }
        let unit = report.outcome.unit
        guard let difference = report.difference else {
            return "\(tooEarlyHeadline) Loopr needs a night on and a night off before it can compare them. It shows a result after night \(report.plannedNights), and only if it clears your usual night-to-night spread of \(amount(spread))."
        }
        let size = amount(difference) == "0"
            ? "level with the other nights"
            : "\(amount(difference)) \(unitWords(unit, for: difference)) \(report.favors == .worse ? "behind" : "ahead")"
        if abs(difference) > spread {
            return "\(tooEarlyHeadline) \(name) nights are \(size), outside your usual night-to-night spread of \(amount(spread)). Loopr shows a result after night \(report.plannedNights)."
        }
        return "\(tooEarlyHeadline) \(name) nights are \(size), inside your usual night-to-night spread of \(amount(spread)). Loopr shows a result after night \(report.plannedNights), and only if it clears that spread."
    }

    static func notEnoughNights(report: ExperimentReport) -> String {
        let need = report.minimumNightsPerArm
        var text = "Not enough nights to show a result. Loopr needs \(need) counted nights on and \(need) off, and has \(report.on.nights) on and \(report.off.nights) off."
        if let left = exclusionsLine(report) { text += " " + left }
        return text
    }

    static func notCalled(report: ExperimentReport, policy: ExperimentPolicy = .standard) -> String {
        guard let range = report.range, let spread = report.spread else { return tooEarlyHeadline }
        return "Loopr does not call this one. The \(rangeName(policy: policy)) is \(rangeText(range, unit: report.outcome.unit, magnitude: false)), wider than your usual spread of \(amount(spread)), so these nights cannot tell a change from noise."
    }

    static func finished(label: ExperimentLabel, report: ExperimentReport, interventionName: String,
                         policy: ExperimentPolicy = .standard) -> String {
        guard let difference = report.difference, let range = report.range, let spread = report.spread else { return footnote }
        let metric = report.outcome
        let name = cleaned(interventionName)
        let spreadText = amount(spread)
        let change = changeSentence(metric: metric, difference: difference, name: name)
        switch label {
        case .strong, .clear:
            return "\(change) The \(rangeName(policy: policy)) is \(rangeText(range, unit: metric.unit, magnitude: true)), and the whole range sits outside your usual spread. \(footnote)"
        case .early:
            let lead = report.stoppedEarly ? "You stopped early, so this is a first look only." : "A first look only."
            let reach = report.rangeOutsideSpread
                ? "You stopped before the plan finished."
                : "It still reaches into your usual spread of \(spreadText)."
            return "\(lead) \(change) The \(rangeName(policy: policy)) is \(rangeText(range, unit: metric.unit, magnitude: false)). \(reach) Loopr does not call it a difference."
        case .noChange:
            return "\(metric.title) looked about the same on \(name) nights and the other nights. The \(rangeName(policy: policy)) is \(rangeText(range, unit: metric.unit, magnitude: false)), inside your usual spread of \(spreadText). \(footnote)"
        }
    }

    /// "Deep sleep was 14 minutes higher on magnesium nights than on the other nights.", "Sleep heart rate was 4 beats a
    /// minute lower on cool bedroom nights than on the other nights." The result page leads with it, in words, before
    /// the number with its unit (ICP R2-SEN-13).
    public static func changeSentence(metric: ExperimentMetric, difference: Double, name: String) -> String {
        if amount(difference) == "0" { return "\(metric.title) was the same on \(name) nights and the other nights." }
        return "\(metric.title) was \(amount(difference)) \(unitWords(metric.unit, for: difference)) \(difference > 0 ? "higher" : "lower") on \(name) nights than on the other nights."
    }

    /// The result page's headline in words: the change sentence for a finished result, nil while running, when stopped
    /// early or with nothing to compare.
    public static func resultSentence(report: ExperimentReport, interventionName: String) -> String? {
        guard !report.stoppedEarly, let difference = report.difference else { return nil }
        switch report.state {
        case .result, .notCalled: return changeSentence(metric: report.outcome, difference: difference, name: cleaned(interventionName))
        default: return nil
        }
    }

    /// "6 to 22 minutes". With `magnitude` the sign is dropped, for a range that sits on one side of zero and a
    /// sentence that already says higher or lower.
    static func rangeText(_ range: ClosedRange<Double>, unit: String, magnitude: Bool) -> String {
        let low: Double, high: Double
        if magnitude, range.upperBound < 0 {
            low = -range.upperBound; high = -range.lowerBound
        } else {
            low = range.lowerBound; high = range.upperBound
        }
        let lowText = magnitude ? amount(low) : signedOrPlain(low)
        let highText = magnitude ? amount(high) : signedOrPlain(high)
        return "\(lowText) to \(highText) \(unitWords(unit, for: high))"
    }

    private static func signedOrPlain(_ value: Double) -> String {
        let text = amount(value)
        return text != "0" && value < 0 ? LooprSignedNumber.minusSign + text : text
    }

    /// "Left out 2 washout nights, 1 night you did not do it and 3 nights with no reading." Nil when nothing was left out.
    public static func exclusionsLine(_ report: ExperimentReport) -> String? {
        let on = report.on.exclusions, off = report.off.exclusions
        var parts: [String] = []
        let washout = on.washout + off.washout
        if washout > 0 { parts.append("\(washout) washout \(washout == 1 ? "night" : "nights")") }
        if on.notAdherent > 0 { parts.append("\(nights(on.notAdherent)) you did not do it") }
        if on.adherenceUnknown > 0 { parts.append("\(nights(on.adherenceUnknown)) with no tick") }
        let absent = on.outcomeAbsent + off.outcomeAbsent
        if absent > 0 { parts.append("\(nights(absent)) with no \(lowercasedKeepingAcronyms(report.outcome.title)) reading") }
        guard !parts.isEmpty else { return nil }
        let joined = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "Left out \(joined)."
    }

    // MARK: Result page and list

    /// "+14 min". Nil until there is a difference to show.
    public static func resultHeadline(report: ExperimentReport) -> String? {
        report.difference.map { "\(signed($0)) \(report.outcome.unit)" }
    }

    /// The part of a finished row after the label: the effect with its 95% range and the counted nights on each side,
    /// "Sleep heart rate −4 bpm, 95% range −7 to −1 · 7 nights each" (ICP R1-VET-11, R2-VET-10). A state without a range says why,
    /// "Not enough nights · 14 nights". The trailing "kept" depends on the protocol, so the screen adds it.
    public static func listSubtitle(report: ExperimentReport) -> String {
        let count = nights(report.nightsCompleted)
        switch report.state {
        case .result, .notCalled:
            guard let effect = effectWithRange(report: report) else { return "\(report.outcome.title) · \(count)" }
            return "\(report.outcome.title) \(effect) · \(nightsPerSide(report))"
        case .notEnoughNights: return "Not enough nights · \(count)"
        case .cannotReport: return "No baseline · \(count)"
        case .tooEarlyToSay: return "Too early to say · \(count)"
        }
    }

    /// "−4 bpm, 95% range −7 to −1". Nil until the report has both a difference and a likely range.
    public static func effectWithRange(report: ExperimentReport) -> String? {
        guard let difference = report.difference, let range = report.range else { return nil }
        return "\(signed(difference))\(unitSuffix(report.outcome.unit)), \(rangeName()) \(signed(range.lowerBound)) to \(signed(range.upperBound))"
    }

    /// The result page's line under the effect: "95% range −7 to −1 bpm · 7 nights each". Nil without a likely range.
    public static func rangeLine(report: ExperimentReport) -> String? {
        guard let range = report.range else { return nil }
        return "\(rangeName()) \(signed(range.lowerBound)) to \(signed(range.upperBound))\(unitSuffix(report.outcome.unit)) · \(nightsPerSide(report))"
    }

    /// "7 nights each", or "8 nights with, 6 without" when the sides differ. Counted nights only.
    public static func nightsPerSide(_ report: ExperimentReport) -> String {
        let on = report.on.nights, off = report.off.nights
        return on == off ? "\(nights(on)) each" : "\(nights(on)) with, \(off) without"
    }

    private static func unitSuffix(_ unit: String) -> String { unit.isEmpty ? "" : " \(unit)" }

    // MARK: How this works

    /// The usual spread with its statistic named (ICP R1-VET-12): what the band is, which nights it comes from and how
    /// Loopr computes it. The size is the band's half width, the number it is drawn with.
    public static func spreadExplanation(spread: Double, unit: String, policy: ExperimentPolicy = .standard) -> String {
        "The shaded band is your usual spread, \(amount(spread))\(unitSuffix(unit)) either side of the other nights' average. "
            + "Loopr measures it on the \(policy.baselineWindowNights) nights before night 1. "
            + "It is one standard deviation of a single night. Loopr works it out from the changes between back-to-back "
            + "nights with a scaled median absolute deviation, so one odd night does not widen it."
    }

    /// Why the measure cannot change: "Loopr fixed the measure, deep sleep, on day 1. Nobody can swap it later for one
    /// that looks better."
    public static func outcomeFixed(_ metric: ExperimentMetric) -> String {
        "Loopr fixed the measure, \(lowercasedKeepingAcronyms(metric.title)), on day 1. Nobody can swap it later for one that looks better."
    }

    /// How the 95% range is made and what Clear needs.
    public static func rangeExplanation(policy: ExperimentPolicy = .standard) -> String {
        let level = Int((policy.confidence * 100).rounded())
        return "Loopr gets the \(rangeName(policy: policy)) by resampling both groups of nights \(policy.bootstrapResamples) times, "
            + "a \(level) percent bootstrap range. A result is Clear only when the whole range sits outside your usual spread."
    }

    /// The running card's link to its rule: "Tests your rule Magnesium, 300 mg" (ICP R2-VET-08). Nil without a title.
    public static func testsRule(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return "Tests your rule \(title)"
    }

    /// Why a new experiment cannot start yet, with the day it can (ICP R2-SEN-12, R2-DES-13): "You can start this after
    /// the magnesium test ends on 20 Nov." The test ends the morning after its last planned night.
    public static func startsAfter(_ start: ExperimentStart) -> String {
        let name = cleaned(start.interventionName)
        let end = start.lastPlannedDay.adding(days: 1) ?? start.lastPlannedDay
        return name.isEmpty
            ? "You can start this after the current test ends on \(dayAndMonth(end))."
            : "You can start this after the \(name) test ends on \(dayAndMonth(end))."
    }

    /// "20 Nov", the same in every locale so tests and screens agree.
    public static func dayAndMonth(_ day: DayIdentity) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day.day) \((1...12).contains(day.month) ? months[day.month - 1] : "\(day.month)")"
    }

    /// "Fell asleep 8 min sooner. Not the outcome, so shown, not claimed."
    public static func alsoMoved(_ moved: AlsoMoved) -> String {
        let size = "\(amount(moved.difference)) \(moved.metric.unit)"
        let lead: String
        if let phrase = moved.difference < 0 ? moved.metric.lowerPhrase : moved.metric.higherPhrase {
            lead = phrase.replacingOccurrences(of: "{amount}", with: size)
        } else {
            lead = "\(moved.metric.title) was \(size) \(moved.difference < 0 ? "lower" : "higher")"
        }
        return "\(lead). Not the outcome, so shown, not claimed."
    }
}
