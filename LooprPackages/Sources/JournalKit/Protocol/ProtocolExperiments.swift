import DomainKit
import Foundation
import RoutineKit

// The Experiments segment and the result screen (contract phones p-proto, Experiments, and p-result). The loader reads
// each stored experiment, its nights and its report; the pure types here turn that into the strip, the call text and
// the rows, so every state is tested without a store or a screen.

/// One experiment with a design, as the loader read it.
public struct ProtocolExperimentItem: Equatable, Sendable, Identifiable {
    public var id: ExperimentID { experiment.id }
    public let experiment: Experiment
    /// The report as of the last night that is over.
    public let report: ExperimentReport
    /// Every stored night, oldest first.
    public let nights: [ExperimentNight]
    /// The protocol version that kept this result. Nil until it is kept.
    public let keptVersion: Int?
    /// True when Keep would add the result to the protocol now.
    public let canKeep: Bool
    /// The title of the rule the experiment tests, as the protocol names it now: "Magnesium, 300 mg". Nil when the rule
    /// is gone from the protocol.
    public let ruleTitle: String?

    public init(experiment: Experiment, report: ExperimentReport, nights: [ExperimentNight], keptVersion: Int? = nil,
                canKeep: Bool = false, ruleTitle: String? = nil) {
        self.experiment = experiment; self.report = report; self.nights = nights
        self.keptVersion = keptVersion; self.canKeep = canKeep && keptVersion == nil; self.ruleTitle = ruleTitle
    }

    /// The result file to share. Nil while the experiment runs.
    public var resultFile: ExperimentResultFile? { try? ExperimentResultFile.make(experiment: experiment, report: report) }

    /// The row identifier suffix: the id in lower case.
    public var identifierSuffix: String { experiment.id.rawValue.uuidString.lowercased() }
}

public struct ProtocolExperimentsData: Equatable, Sendable {
    public let running: ProtocolExperimentItem?
    /// Finished and stopped experiments, newest first.
    public let finished: [ProtocolExperimentItem]

    public init(running: ProtocolExperimentItem?, finished: [ProtocolExperimentItem]) {
        self.running = running; self.finished = finished
    }

    public var isEmpty: Bool { running == nil && finished.isEmpty }
}

public enum ProtocolExperimentsState: Equatable, Sendable {
    case ready(ProtocolExperimentsData)
    /// The store could not be read. The message says so in plain words.
    case unavailable(String)
}

// MARK: - Copy

/// Sentences the Experiments segment adds to `ExperimentCopy`. Every number sentence about a result comes from
/// `ExperimentCopy`; these cover the empty, stopped and still-counting states and the screen's labels.
///
/// One vocabulary (ICP R1-NEW-13): an experiment is anything the person changes on purpose to see what it does,
/// whether they designed it or started it from a pattern. A pattern is something Loopr noticed in their nights.
public enum ProtocolExperimentText {
    /// What an experiment is, in one go. It opens the segment and is the whole of the empty state (ICP R1-NEW-12,
    /// R1-DES-19).
    public static let intro = "Change one thing for a couple of weeks. Loopr tells you if your sleep moved more than it usually does."
    public static let noExperiment = intro
    /// The empty state's one button. It opens Patterns.
    public static let findSomething = "Find something to test"
    public static let noneRunning = "Nothing is running. Start one below."
    public static let unavailable = "Loopr could not read your experiments on this iPhone. Try again in a moment."
    public static let notKeepable = "Loopr keeps a result in your protocol only when it is Strong or Clear and went the way you wanted."
    public static let nothingElseMoved = "Nothing else moved past its usual spread."
    public static let notChecked = "Loopr checks other measures only once a result is in."
    public static let keep = "Keep it in my protocol"
    public static let share = "Share the result file"
    public static let fromPattern = "From a pattern"
    public static let fromGitHub = "More ideas on the web"
    public static let fromGitHubDetail = "Experiments other people shared on GitHub. Opens in Safari."
    public static let noPattern = "Nothing to suggest yet. Loopr offers one here when it finds a pattern in your nights."
    public static let offTitle = "Other nights"
    public static let howItWorks = "How this works"
    /// The heading over the running pattern test, which is an experiment started from a pattern.
    public static let patternTestHeader = "Started from a pattern"
    public static let openInPatterns = "Open in Patterns"
    /// Said once on a screen that shows "HRV" (ICP R1-SEN-18).
    public static let hrvGloss = "HRV is heart rate variability, a sign of recovery."

    /// True when `text` uses "HRV" as a word, so the screen adds `hrvGloss` once.
    public static func mentionsHRV(_ text: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter }).contains("HRV")
    }

    /// The pattern a test can start from, named by what it links: "Alcohol and HRV" (ICP R1-VET-19). Without an
    /// outcome the factor alone.
    public static func fromPattern(title: String, outcome: String?) -> String {
        let factor = capitalized(title)
        guard !factor.isEmpty else { return noPattern }
        guard let outcome = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !outcome.isEmpty else { return factor }
        let lowered = outcome.count > 1 && outcome.dropFirst().first?.isUppercase == true ? outcome : outcome.lowercased()
        return "\(factor) and \(lowered)"
    }

    /// What the strip measures, under the card's title: "Minutes to fall asleep" (ICP R1-SEN-19). HRV gets its gloss.
    public static func measures(_ metric: ExperimentMetric) -> String {
        switch metric.key {
        case ExperimentMetric.timeToFallAsleep.key: return "Minutes to fall asleep"
        case ExperimentMetric.deepSleep.key: return "Minutes of deep sleep"
        case ExperimentMetric.sleepHeartRate.key: return "Heart rate while asleep, in beats per minute"
        case ExperimentMetric.hrv.key: return "HRV in milliseconds. \(hrvGloss)"
        default: return metric.unit.isEmpty ? metric.title : "\(metric.title), in \(metric.unit)"
        }
    }

    /// "You started this on Mon 6 Nov." The first night is the day the person started it.
    public static func started(_ day: DayIdentity) -> String {
        "You started this on \(shortDate(day))."
    }

    /// "Mon 6 Nov", the same in every locale so tests and screens agree.
    static func shortDate(_ day: DayIdentity) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let month = (1...12).contains(day.month) ? months[day.month - 1] : "\(day.month)"
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else {
            return "\(day.day) \(month)"
        }
        return "\(weekdays[calendar.component(.weekday, from: date) - 1]) \(day.day) \(month)"
    }

    /// "You stopped this one after 6 of 14 nights, so Loopr does not claim a result."
    public static func stopped(nights: Int, planned: Int) -> String {
        "You stopped this one after \(nights) of \(planned) nights, so Loopr does not claim a result."
    }

    /// "So far 4 magnesium nights and 4 other nights count. Each side needs 7."
    public static func stillNeeded(on: Int, off: Int, minimum: Int, interventionName: String) -> String {
        let name = interventionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "So far \(on) \(name) \(on == 1 ? "night" : "nights") and \(off) other \(off == 1 ? "night" : "nights") count. Each side needs \(minimum)."
    }

    /// "Kept in version 3".
    public static func kept(version: Int) -> String { "Kept in version \(version)" }

    /// "Experiment finished · 28 nights".
    public static func resultHeader(_ progress: String) -> String {
        guard let first = progress.first else { return "Experiment" }
        return "Experiment \(first.lowercased())\(progress.dropFirst())"
    }

    static func nightCount(_ count: Int) -> String { count == 1 ? "1 night" : "\(count) nights" }

    static func capitalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

// MARK: - Call

/// The plain call under the strip: a bold lead such as "Too early to say." and the rest of the sentence, plus how many
/// counted nights each side still needs while the experiment runs.
public struct ProtocolExperimentCall: Equatable, Sendable {
    public let lead: String?
    public let sentence: String
    public let stillNeeded: String?

    public init(lead: String?, sentence: String, stillNeeded: String? = nil) {
        self.lead = lead; self.sentence = sentence; self.stillNeeded = stillNeeded
    }

    /// The call as one string, for VoiceOver and tests.
    public var text: String {
        [lead, sentence.isEmpty ? nil : sentence, stillNeeded].compactMap { $0 }.joined(separator: " ")
    }

    public static func make(_ item: ProtocolExperimentItem, policy: ExperimentPolicy = .standard) -> ProtocolExperimentCall {
        let experiment = item.experiment
        let report = item.report
        if experiment.stoppedEarly {
            return ProtocolExperimentCall(lead: nil, sentence: ProtocolExperimentText.stopped(
                nights: report.nightsCompleted, planned: report.plannedNights))
        }
        let summary = ExperimentCopy.summary(report: report, interventionName: experiment.start.interventionName, policy: policy)
        var needed: String?
        if experiment.status == .running, report.state == .tooEarlyToSay,
           report.on.nights < report.minimumNightsPerArm || report.off.nights < report.minimumNightsPerArm {
            needed = ProtocolExperimentText.stillNeeded(on: report.on.nights, off: report.off.nights,
                                                        minimum: report.minimumNightsPerArm,
                                                        interventionName: experiment.start.interventionName)
        }
        let lead = ExperimentCopy.tooEarlyHeadline
        if summary.hasPrefix(lead) {
            let rest = summary.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
            return ProtocolExperimentCall(lead: lead, sentence: rest, stillNeeded: needed)
        }
        return ProtocolExperimentCall(lead: nil, sentence: summary, stillNeeded: needed)
    }
}

// MARK: - Strip

/// The experiment's object: every counted night as a dot on a value axis, on nights in one row and off nights in the
/// other, drawn against the person's noise band around the off nights' average. On nights are filled and off nights
/// are rings, so the two read apart without colour. Positions are fractions of the axis, 0 at the left.
public struct ProtocolExperimentStrip: Equatable, Sendable {
    public struct Dot: Equatable, Sendable, Identifiable {
        public var id: String { day.routineDayKey ?? "\(night)" }
        public let night: Int
        public let day: DayIdentity
        public let arm: ExperimentArm
        public let value: Double
        public let position: Double
    }

    public let dots: [Dot]
    public let onTitle: String
    public let offTitle: String
    public let unit: String
    public let lowerBound: Double
    public let upperBound: Double
    public let onMean: Double?
    public let offMean: Double?
    /// The noise band in outcome values: the off nights' average plus and minus the spread.
    public let band: ClosedRange<Double>?
    /// The likely range of the on nights' average, drawn on a result. Nil while running.
    public let likelyRange: ClosedRange<Double>?
    public let spread: Double?
    public let difference: Double?
    public let accessibilitySummary: String

    public var onDots: [Dot] { dots.filter { $0.arm == .on } }
    public var offDots: [Dot] { dots.filter { $0.arm == .off } }
    public var isEmpty: Bool { dots.isEmpty }

    /// Where a value sits on the axis, from 0 to 1.
    public func position(_ value: Double) -> Double {
        let width = upperBound - lowerBound
        guard width > 0 else { return 0.5 }
        return min(max((value - lowerBound) / width, 0), 1)
    }

    /// The left, middle and right tick values.
    public var ticks: [Double] { [lowerBound, (lowerBound + upperBound) / 2, upperBound] }

    private var unitSuffix: String { unit.isEmpty ? "" : " \(unit)" }

    /// What the shaded band is, in the same number the band is drawn with: the band runs `spread` either side of the
    /// other nights' average, so its full width is twice the spread. It names the statistic behind the spread.
    public var bandCaption: String? {
        guard let spread, band != nil else { return nil }
        // The window and the statistic are named, so two cards on one outcome with two spreads say why (ICP R2-OPT-12,
        // R1-VET-12).
        return ExperimentCopy.spreadExplanation(spread: spread, unit: unit)
    }

    /// What the bracket under the on row is. The 95% range belongs to the on nights' average, measured against the
    /// other nights' average, so only that row has one.
    public var likelyRangeCaption: String? {
        guard let likelyRange else { return nil }
        return "The bracket under \(onTitle) is the \(ExperimentCopy.rangeName()) for its average, "
            + "\(ExperimentCopy.amount(likelyRange.lowerBound)) to \(ExperimentCopy.amount(likelyRange.upperBound))\(unitSuffix), "
            + "worked out from both groups of nights. "
            + "It is measured against the other nights' average, so that row has no bracket."
    }

    /// A lane for each dot so dots closer than `minimumGap` on the axis stack instead of covering each other, like a
    /// small beeswarm. Lane 0 is the row's line; then 1, -1, 2, -2 and so on, alternating above and below. Dots are placed
    /// left to right, each in the first lane where it clears every dot already there. `positions` are axis fractions,
    /// and the result keeps their order. The same input always gives the same lanes.
    public static func lanes(positions: [Double], minimumGap: Double) -> [Int] {
        guard minimumGap > 0, minimumGap.isFinite, positions.allSatisfy(\.isFinite) else {
            return Array(repeating: 0, count: positions.count)
        }
        let order = positions.indices.sorted { (positions[$0], $0) < (positions[$1], $1) }
        var placed: [Int: [Double]] = [:]
        var result = Array(repeating: 0, count: positions.count)
        for index in order {
            let position = positions[index]
            var step = 0
            while true {
                let lane = step == 0 ? 0 : (step % 2 == 1 ? (step + 1) / 2 : -(step / 2))
                if (placed[lane] ?? []).allSatisfy({ abs($0 - position) >= minimumGap }) {
                    placed[lane, default: []].append(position)
                    result[index] = lane
                    break
                }
                step += 1
            }
        }
        return result
    }

    /// The nights that count, the way `ExperimentAnalyzer` counts them: not washout, a reading present, and on an on
    /// night the intervention kept. Nights after a stop are outside.
    public static func countedNights(_ item: ProtocolExperimentItem) -> [ExperimentNight] {
        let schedule = item.experiment.schedule
        return item.nights.filter { night in
            guard !night.isWashout, night.outcomeValue != nil else { return false }
            switch schedule.role(on: night.day) {
            case .on: return night.arm == .on && night.adherence == .kept
            case .off: return night.arm == .off
            case .washout, .outside: return false
            }
        }
    }

    public static func make(_ item: ProtocolExperimentItem, showsRange: Bool) -> ProtocolExperimentStrip {
        let experiment = item.experiment
        let report = item.report
        let schedule = experiment.schedule
        let counted = countedNights(item).sorted { (schedule.nightNumber(on: $0.day) ?? 0) < (schedule.nightNumber(on: $1.day) ?? 0) }
        let values = counted.compactMap(\.outcomeValue)
        let onValues = counted.filter { $0.arm == .on }.compactMap(\.outcomeValue)
        let offValues = counted.filter { $0.arm == .off }.compactMap(\.outcomeValue)
        let onMean = ExperimentStatistics.mean(onValues)
        let offMean = ExperimentStatistics.mean(offValues)
        let spread = report.spread
        let center = offMean ?? onMean
        let band = center.flatMap { center in spread.map { (center - $0)...(center + $0) } }
        var likely: ClosedRange<Double>?
        if showsRange, experiment.status != .running, let range = report.range, let offMean {
            likely = (offMean + range.lowerBound)...(offMean + range.upperBound)
        }

        var extent = values
        if let band { extent += [band.lowerBound, band.upperBound] }
        if let likely { extent += [likely.lowerBound, likely.upperBound] }
        var low = extent.min() ?? 0
        var high = extent.max() ?? 0
        if high - low < 2 { low -= 1; high += 1 }
        let pad = (high - low) * 0.08
        low = (low - pad).rounded(.down)
        high = (high + pad).rounded(.up)
        if Int(high - low) % 2 != 0 { high += 1 }

        let onTitle = ProtocolExperimentText.capitalized(experiment.start.interventionName)
        let difference = onMean.flatMap { on in offMean.map { on - $0 } }
        let strip = Partial(lowerBound: low, upperBound: high)
        let dots = counted.compactMap { night -> Dot? in
            guard let value = night.outcomeValue, let number = schedule.nightNumber(on: night.day) else { return nil }
            return Dot(night: number, day: night.day, arm: night.arm, value: value, position: strip.position(value))
        }
        let summary = accessibility(onTitle: onTitle, on: onValues, off: offValues, onMean: onMean, offMean: offMean,
                                    difference: difference, spread: spread, likely: showsRange ? report.range : nil,
                                    metric: report.outcome)
        return ProtocolExperimentStrip(dots: dots, onTitle: onTitle, offTitle: ProtocolExperimentText.offTitle,
                                       unit: report.outcome.unit, lowerBound: low, upperBound: high, onMean: onMean,
                                       offMean: offMean, band: band, likelyRange: likely, spread: spread,
                                       difference: difference, accessibilitySummary: summary)
    }

    private struct Partial {
        let lowerBound: Double
        let upperBound: Double
        func position(_ value: Double) -> Double {
            let width = upperBound - lowerBound
            guard width > 0 else { return 0.5 }
            return min(max((value - lowerBound) / width, 0), 1)
        }
    }

    /// "Magnesium: 4 nights, average 84 min. Other nights: 4 nights, average 78 min. Difference +6 min, inside your
    /// usual spread of 9 min."
    static func accessibility(onTitle: String, on: [Double], off: [Double], onMean: Double?, offMean: Double?,
                              difference: Double?, spread: Double?, likely: ClosedRange<Double>?,
                              metric: ExperimentMetric) -> String {
        let unit = metric.unit.isEmpty ? "" : " \(metric.unit)"
        guard !on.isEmpty || !off.isEmpty else {
            let name = metric.title == metric.title.uppercased() ? metric.title : metric.title.lowercased()
            return "No counted nights with a \(name) reading yet."
        }
        func arm(_ title: String, _ values: [Double], _ mean: Double?) -> String {
            guard let mean else { return "\(title): no counted nights yet." }
            return "\(title): \(ProtocolExperimentText.nightCount(values.count)), average \(ExperimentCopy.amount(mean))\(unit)."
        }
        var parts = [arm(onTitle, on, onMean), arm(ProtocolExperimentText.offTitle, off, offMean)]
        if let difference {
            var line = "Difference \(ExperimentCopy.spokenSigned(difference))\(unit)"
            if let spread {
                line += abs(difference) > spread
                    ? ", outside your usual spread of \(ExperimentCopy.amount(spread))\(unit)."
                    : ", inside your usual spread of \(ExperimentCopy.amount(spread))\(unit)."
            } else {
                line += "."
            }
            parts.append(line)
        } else if let spread {
            parts.append("Your usual spread is \(ExperimentCopy.amount(spread))\(unit).")
        }
        if let likely {
            let level = Int((ExperimentPolicy.standard.confidence * 100).rounded())
            parts.append("\(level) percent range \(ExperimentCopy.spokenSigned(likely.lowerBound)) to \(ExperimentCopy.spokenSigned(likely.upperBound))\(unit).")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Rows and the result page

/// What a running card, a finished row and the result page show for one experiment.
public struct ProtocolExperimentPresentation: Equatable, Sendable {
    public let id: ExperimentID
    public let identifierSuffix: String
    public let title: String
    /// "Running · night 9 of 14", "Finished · 28 nights".
    public let progress: String
    /// "Experiment finished · 28 nights".
    public let resultHeader: String
    /// "Clear", "No change", "No clear change", "Stopped" or "No result".
    public let chip: String
    /// True for Strong and Clear, the labels that say the nights differed.
    public let claimsDifference: Bool
    /// "Deep sleep +14 min, 95% range +8 to +20 · 7 nights each · kept".
    public let rowSubtitle: String
    public let call: ProtocolExperimentCall
    /// The result page's headline in words, before the number and its unit (ICP R2-SEN-13): "Sleep heart rate was 4
    /// beats a minute lower on cool bedroom nights than on the other nights." Nil while running or stopped early.
    public let headline: String?
    /// The call under the number on the result page, without the headline it would repeat.
    public let resultCall: ProtocolExperimentCall
    /// The running card's link to the rule it tests: "Tests your rule Magnesium, 300 mg" (ICP R2-VET-08).
    public let testsRule: String?
    /// The running card's lead: "Too early to say. Night 9 of 14." (ICP R1-NEW-12).
    public let verdict: String
    /// What the strip measures: "Minutes to fall asleep" (ICP R1-SEN-19).
    public let measuresLine: String
    /// "You started this on Mon 6 Nov."
    public let startedLine: String
    /// The result page's line under the effect: "95% range −7 to −1 bpm · 7 nights each". Nil without a range.
    public let rangeLine: String?
    /// The statistical detail behind "How this works", in reading order (ICP R1-VET-12, R1-DES-19).
    public let howItWorks: [String]
    public let designLine: String
    public let washoutLine: String?
    public let outcomeLine: String
    /// Left-out nights, when there were any.
    public let exclusionsLine: String?
    /// Nil when the result has not been checked for other measures.
    public let alsoMoved: [String]?
    /// The effect for the hero number. Nil while running, when stopped early, or with no call to show.
    public let effect: Double?
    public let unit: String
    public let keptVersion: Int?
    public let canKeep: Bool

    public var isKept: Bool { keptVersion != nil }

    public static func make(_ item: ProtocolExperimentItem, policy: ExperimentPolicy = .standard) -> ProtocolExperimentPresentation {
        let experiment = item.experiment
        let report = item.report
        let start = experiment.start
        let progress = ExperimentCopy.progress(experiment: experiment, report: report)
        let chip: String
        if experiment.status == .running {
            chip = "Running"
        } else if experiment.stoppedEarly {
            chip = "Stopped"
        } else if let label = report.label {
            chip = label.title
        } else if report.state == .notCalled {
            // The range is wider than the spread: the nights cannot tell a change from noise (ICP R1-VET-11).
            chip = "No clear change"
        } else {
            chip = "No result"
        }
        var subtitle = experiment.stoppedEarly
            ? "Stopped · \(ProtocolExperimentText.nightCount(report.nightsCompleted))"
            : ExperimentCopy.listSubtitle(report: report)
        if item.keptVersion != nil { subtitle += " \u{00B7} kept" }
        var alsoMoved: [String]?
        switch report.state {
        case .result, .notCalled: alsoMoved = experiment.stoppedEarly ? nil : report.alsoMoved.map(ExperimentCopy.alsoMoved)
        default: alsoMoved = nil
        }
        var effect: Double?
        if experiment.status != .running, !experiment.stoppedEarly {
            switch report.state {
            case .result, .notCalled: effect = report.difference
            default: effect = nil
            }
        }
        let call = ProtocolExperimentCall.make(item, policy: policy)
        let headline = experiment.status == .running || experiment.stoppedEarly ? nil
            : ExperimentCopy.resultSentence(report: report, interventionName: start.interventionName)
        var resultCall = call
        if let headline, call.lead == nil, call.sentence.hasPrefix(headline) {
            let rest = call.sentence.dropFirst(headline.count).trimmingCharacters(in: .whitespaces)
            resultCall = ProtocolExperimentCall(lead: nil, sentence: rest, stillNeeded: call.stillNeeded)
        }
        let night = min(report.nightsCompleted + 1, report.plannedNights)
        let verdict = "\(call.lead ?? call.sentence) Night \(night) of \(report.plannedNights)."
        let design = [ExperimentCopy.designLine(start.design), ExperimentCopy.washoutLine(start.washout)]
            .compactMap { $0 }.joined(separator: ". ") + "."
        var how: [String] = []
        if experiment.status == .running {
            if call.lead != nil, !call.sentence.isEmpty { how.append(call.sentence) }
            if let needed = call.stillNeeded { how.append(needed) }
        }
        if let spread = report.spread { how.append(ExperimentCopy.spreadExplanation(spread: spread, unit: start.outcome.unit, policy: policy)) }
        if experiment.status != .running, report.range != nil { how.append(ExperimentCopy.rangeExplanation(policy: policy)) }
        how.append(ExperimentCopy.outcomeFixed(start.outcome))
        if experiment.status == .running { how.append(design) }
        let rangeLine = experiment.stoppedEarly || experiment.status == .running ? nil : ExperimentCopy.rangeLine(report: report)
        return ProtocolExperimentPresentation(
            id: item.id, identifierSuffix: item.identifierSuffix, title: start.title, progress: progress,
            resultHeader: ProtocolExperimentText.resultHeader(progress), chip: chip,
            claimsDifference: !experiment.stoppedEarly && report.label?.claimsDifference == true, rowSubtitle: subtitle,
            call: call, headline: resultCall.sentence == call.sentence ? nil : headline, resultCall: resultCall,
            testsRule: ExperimentCopy.testsRule(item.ruleTitle), verdict: verdict, measuresLine: ProtocolExperimentText.measures(start.outcome),
            startedLine: ProtocolExperimentText.started(start.startDay), rangeLine: rangeLine, howItWorks: how,
            designLine: ExperimentCopy.designLine(start.design),
            washoutLine: ExperimentCopy.washoutLine(start.washout), outcomeLine: ExperimentCopy.outcomeLine(start.outcome),
            exclusionsLine: ExperimentCopy.exclusionsLine(report), alsoMoved: alsoMoved, effect: effect,
            unit: start.outcome.unit, keptVersion: item.keptVersion, canKeep: item.canKeep)
    }
}
