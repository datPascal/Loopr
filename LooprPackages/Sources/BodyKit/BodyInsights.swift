import Foundation
import DomainKit
import DesignSystem
import AnalyticsKit

// Pure presentation logic for the Body tab. Views only lay these out, so
// every rule and every string here has a test in `BodyInsightsTests`.

// MARK: Strain hero

/// What the strain hero shows for a day.
public struct BodyStrainHero: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// A strain value, with the suggested range when the day has a
        /// recovery score.
        case measured(strain: Double, text: String, target: StrainTarget?)
        /// Neither a birth year nor a manual maximum is available yet.
        case needsAge
        /// No strain for another reason, with the derivation's own words.
        case missing(reason: String?)
    }

    public let state: State

    public init(state: State) { self.state = state }

    /// Reads the day's strain row and the morning's recovery score.
    public static func make(metric: BodyMetricValue?, recovery: Double?, trainingLoad: TrainingLoad? = nil) -> BodyStrainHero {
        guard let metric else { return BodyStrainHero(state: .missing(reason: nil)) }
        if let value = BodyValueParser.number(metric.value), metric.state != .absent, metric.state != .noRecords {
            let text = metric.value ?? LooprUnitFormatter.number(value, digits: 1) ?? ""
            return BodyStrainHero(state: .measured(strain: value, text: text, target: StrainTarget(recovery: recovery, trainingLoad: trainingLoad)))
        }
        if BodyProfileGaps.captionAsksForAge(metric.confidence) {
            return BodyStrainHero(state: .needsAge)
        }
        let reason = metric.confidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BodyStrainHero(state: .missing(reason: reason?.isEmpty == false ? reason : nil))
    }

    public var strain: Double? {
        if case .measured(let strain, _, _) = state { return strain }
        return nil
    }

    public var target: StrainTarget? {
        if case .measured(_, _, let target) = state { return target }
        return nil
    }

    public var position: StrainTarget.Position? { target?.position(of: strain) }

    /// One or two words under the number.
    public var verdict: String? {
        switch position {
        case .below: "Below suggested range"
        case .within: "In suggested range"
        case .above: "Above suggested range"
        case nil: nil
        }
    }

    /// The key under the ring for the brighter track segment: "Suggested
    /// 14 to 18 · recovery 74".
    public var rangeLegend: String? {
        guard let target else { return nil }
        return "Suggested \(target.text) · recovery \(target.recovery)"
    }

    /// A short line under the verdict, only where it adds something: what
    /// the rest of today allows, or why there is no range. A finished day
    /// needs nothing beyond its verdict.
    public func sentence(isToday: Bool) -> String? {
        guard case .measured = state else { return nil }
        guard target != nil else {
            return isToday
                ? "There is no recovery score for today yet, so there is no suggested range."
                : "There was no recovery score that day, so there is no suggested range."
        }
        guard isToday else { return nil }
        switch position {
        case .below: return "There is room for more today."
        case .above: return "An easy evening helps tomorrow."
        case .within, nil: return nil
        }
    }

    /// Strain against the 30 days before the day, for a finished day only:
    /// a partial today is never compared with whole days. Strain has no good
    /// direction, so the caption stays grey either way.
    public func usualDelta(history: BodyHistory?, anchorIsToday: Bool) -> LooprDelta? {
        guard !anchorIsToday, let strain, let history else { return nil }
        let past = BodyHistory.window(endingOn: history.anchor.bodyAdding(days: -1), length: LooprBaselineBand.windowDays)
            .compactMap { history.day($0)?.strain }
        return LooprDelta.compare(strain, usual: LooprBaselineBand.compute(values: past), higherIsBetter: nil,
                                  format: .number(digits: 1))
    }

    public func accessibilityLabel(isToday: Bool) -> String {
        switch state {
        case .measured(_, let text, _):
            return ["Strain \(text) of 21", verdict, rangeLegend.map { $0.replacingOccurrences(of: " · ", with: ", from ") },
                    sentence(isToday: isToday), target?.reason]
                .compactMap { $0 }.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: ". ") + "."
        case .needsAge:
            return "Strain needs your age"
        case .missing(let reason):
            return ["No strain for this day", reason].compactMap { $0 }.joined(separator: ". ")
        }
    }
}

// MARK: Profile prompt

/// Profile fields the Body tab can ask for.
public enum BodyProfileField: String, CaseIterable, Sendable {
    case age
    case height
    case weight
}

/// The one prompt Body shows when strain is blocked on the profile.
public struct BodyProfilePrompt: Equatable, Sendable {
    public let missing: [BodyProfileField]
    public let title: String
    public let message: String
    public let actionTitle: String
}

public enum BodyProfileGaps {
    /// Strain waits on an age estimate or a manually set maximum heart rate.
    public static func captionAsksForAge(_ caption: String?) -> Bool {
        guard let caption = caption?.lowercased() else { return false }
        return caption.contains("your age")
            && (caption.contains("profile") || caption.contains("maximum heart rate"))
    }

    /// The prompt, or nil when strain is not waiting on the profile.
    public static func prompt(for snapshot: BodyDaySnapshot) -> BodyProfilePrompt? {
        guard case .needsAge = BodyStrainHero.make(metric: snapshot.metric(.strain), recovery: nil).state else { return nil }
        var missing: [BodyProfileField] = [.age]
        if snapshot.composition.height == nil { missing.append(.height) }
        if snapshot.composition.weight == nil { missing.append(.weight) }
        // Height and weight stay with the active energy row, which asks for
        // them itself; the prompt keeps to the one field strain needs.
        let message = "Your age sets an estimated maximum heart rate for zones, strain and training load. You can also set a maximum in Heart zone settings."
        return BodyProfilePrompt(missing: missing, title: "Strain needs a maximum heart rate", message: message, actionTitle: ProfileAgePrompt.action)
    }
}

// MARK: Strain and next-morning recovery

public enum BodyStrainWeek {
    public static let length = 14

    /// The last day the week and the load count. Today's strain is still
    /// building, so a week seen on today ends yesterday.
    public static func lastCompleteDay(anchor: DayIdentity, anchorIsToday: Bool) -> DayIdentity {
        anchorIsToday ? anchor.bodyAdding(days: -1) : anchor
    }

    /// Fourteen days, oldest first: each day's strain beside the recovery of the
    /// morning after it.
    public static func days(history: BodyHistory, anchorIsToday: Bool, calendar: Calendar = .current) -> [LooprPairedBarDay] {
        let end = lastCompleteDay(anchor: history.anchor, anchorIsToday: anchorIsToday)
        return BodyHistory.window(endingOn: end, length: length).compactMap { day in
            guard let date = day.bodyDate(calendar: calendar) else { return nil }
            return LooprPairedBarDay(date: date, first: history.day(day)?.strain,
                                     second: history.day(day.bodyAdding(days: 1))?.recovery)
        }
    }

    /// The chart earns its space once at least two days have a strain.
    public static func isWorthShowing(_ days: [LooprPairedBarDay]) -> Bool {
        days.filter { $0.first != nil }.count >= 2
    }
}

// MARK: Training load

/// Presentation of the shared 42-day / 7-day daily-strain model.
public struct BodyTrainingLoad: Equatable, Sendable {
    public static let acuteDays = 7
    public static let chronicDays = 42
    public static let minimumChronicDays = TrainingLoad.minimumDays
    public static let usualBand: ClosedRange<Double> = 0.9...1.1
    public enum State: Equatable, Sendable {
        case ready(BodyTrainingLoad)
        case learning(daysWithStrain: Int, needed: Int)
    }
    public let model: TrainingLoad
    public var acute: Double { model.fatigue }
    public var chronic: Double { model.fitness }
    public var form: Double { model.form }
    public var usualRange: ClosedRange<Double> { chronic * 0.9...chronic * 1.1 }
    public var summary: String {
        guard model.isEstablished else { return "Learning your usual. " + LooprLearningText.progress(have: model.days, need: 42, noun: "days") + ". Keep wearing your band each day." }
        if let ratio = model.ratio, ratio > 1.10 { return "Your load this week is above what you're used to." }
        if let form = model.relativeForm, form > 0.10 { return "Your load this week is below what you're used to." }
        return "Your load this week is close to what you're used to."
    }
    public static func compute(history: BodyHistory, endingOn end: DayIdentity) -> State {
        let daily = BodyHistory.window(endingOn: end, length: BodyHistory.lookbackDays).map { history.day($0)?.strain }
        guard let model = ActivityAnalytics.trainingLoad(dailyStrain: daily) else {
            return .learning(daysWithStrain: TrainingLoad.contiguousDays(daily).count, needed: 42)
        }
        return .ready(BodyTrainingLoad(model: model))
    }
    public static func trend(history: BodyHistory, endingOn end: DayIdentity, days: Int = 28,
                             calendar: Calendar = .current) -> [BodyLoadTrendPoint] {
        BodyHistory.window(endingOn: end, length: days).compactMap { day in
            guard let date = day.bodyDate(calendar: calendar) else { return nil }
            if case .ready(let load) = compute(history: history, endingOn: day) {
                return BodyLoadTrendPoint(date: date, acute: load.acute,
                    usualLow: load.model.isEstablished ? load.usualRange.lowerBound : nil,
                    usualHigh: load.model.isEstablished ? load.usualRange.upperBound : nil)
            }
            return BodyLoadTrendPoint(date: date, acute: nil, usualLow: nil, usualHigh: nil)
        }
    }
}
public struct BodyLoadTrendPoint: Equatable, Identifiable, Sendable {
    public let date: Date
    public let acute: Double?
    public let usualLow: Double?
    public let usualHigh: Double?
    public var id: Date { date }
}
extension BodyTrainingLoad.State {
    public var title: String {
        switch self {
        case .ready(let load): load.model.isEstablished ? "Your training load" : "Building your history · " + LooprLearningText.progress(have: load.model.days, need: 42, noun: "days")
        case .learning(let measured, _): "Building your history · " + LooprLearningText.progress(have: measured, need: 42, noun: "days")
        }
    }
    public var detail: String {
        switch self {
        case .ready(let load): load.summary
        case .learning: "Wear your band each day. Load starts after 14 recorded days in a row and settles after 42. A missing day restarts the count."
        }
    }
}

// MARK: Heart-rate zones

/// The day's time in zones as one proportional bar.
public struct BodyZoneBar: Equatable, Sendable {
    public struct Segment: Equatable, Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let minutes: Double
        /// Share of the day's zone minutes, 0...1.
        public let share: Double
    }

    public let segments: [Segment]
    public let totalMinutes: Double

    /// Nil when no zone has any minutes: there is nothing to draw.
    public static func make(_ zones: [BodyZoneMinutes]) -> BodyZoneBar? {
        let clean = zones.map { BodyZoneMinutes(id: $0.id, name: $0.name, minutes: $0.minutes.isFinite ? max(0, $0.minutes) : 0) }
            .sorted { $0.id < $1.id }
        let total = clean.reduce(0) { $0 + $1.minutes }
        guard total > 0 else { return nil }
        return BodyZoneBar(segments: clean.map { Segment(id: $0.id, name: $0.name, minutes: $0.minutes, share: $0.minutes / total) },
                           totalMinutes: total)
    }

    /// Segment widths that fill `width`: every zone with minutes gets at
    /// least `minimum` so a 2-minute zone stays visible, the rest share what
    /// is left in proportion, and zones with no minutes get nothing.
    public func widths(total width: Double, minimum: Double) -> [Double] {
        let width = max(width, 0)
        let visible = segments.filter { $0.share > 0 }
        guard !visible.isEmpty, width > 0 else { return segments.map { _ in 0 } }
        let floor = min(max(minimum, 0), width / Double(visible.count))
        // Zones whose proportional width falls under the floor are pinned to
        // it; the others scale down to make room.
        var pinned = Set<Int>()
        while true {
            let free = width - floor * Double(pinned.count)
            let freeShare = visible.filter { !pinned.contains($0.id) }.reduce(0) { $0 + $1.share }
            let newlyPinned = visible.filter { !pinned.contains($0.id) && freeShare > 0 && $0.share / freeShare * free < floor }
            if newlyPinned.isEmpty { break }
            newlyPinned.forEach { pinned.insert($0.id) }
        }
        let free = width - floor * Double(pinned.count)
        let freeShare = visible.filter { !pinned.contains($0.id) }.reduce(0) { $0 + $1.share }
        return segments.map { segment in
            guard segment.share > 0 else { return 0 }
            if pinned.contains(segment.id) { return floor }
            return freeShare > 0 ? segment.share / freeShare * free : 0
        }
    }

    /// The zone with the most minutes.
    public var busiest: Segment? { segments.max { $0.minutes < $1.minutes } }

    /// "42 min", "1 h 8 m".
    public static func minutesText(_ minutes: Double) -> String {
        LooprUnitFormatter.duration(minutes: minutes.rounded()) ?? "0 min"
    }

    /// Whole percent of the day's zone time.
    public static func percentText(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        return share > 0 && percent == 0 ? "<1%" : "\(percent)%"
    }

    public var accessibilitySummary: String {
        let parts = segments.map { "Zone \($0.id), \($0.name), \(LooprUnitFormatter.spokenDuration(minutes: $0.minutes.rounded()) ?? "0 minutes")" }
        return (["\(LooprUnitFormatter.spokenDuration(minutes: totalMinutes.rounded()) ?? "") in heart-rate zones"] + parts)
            .joined(separator: ". ")
    }
}

// MARK: Activity

/// One row of the Activity section: steps or active energy.
public struct BodyActivityRow: Equatable, Identifiable, Sendable {
    public let id: BodyMetricID
    public let title: String
    /// The shown value, nil when there is none.
    public let value: String?
    public let unit: String?
    /// The derivation's own line: how it was estimated, or why it is missing.
    public let caption: String?
    public let delta: LooprDelta?
    public let metricLinkID: String?

    /// Steps and active energy from the day, each compared with the 30 days
    /// before it once the day is complete. A partial today is never compared
    /// with whole days.
    public static func rows(snapshot: BodyDaySnapshot, history: BodyHistory?, anchorIsToday: Bool) -> [BodyActivityRow] {
        [BodyMetricID.steps, .energy].compactMap { id in
            guard let metric = snapshot.metric(id) else { return nil }
            let number = BodyValueParser.number(metric.value)
            let hasValue = number != nil && metric.state != .absent && metric.state != .noRecords
            var delta: LooprDelta?
            if hasValue, !anchorIsToday, let history {
                let past = BodyHistory.window(endingOn: history.anchor.bodyAdding(days: -1), length: LooprBaselineBand.windowDays)
                    .compactMap { day -> Double? in
                        let entry = history.day(day)
                        return id == .steps ? entry?.steps : entry?.activeEnergy
                    }
                delta = LooprDelta.compare(number, usual: LooprBaselineBand.compute(values: past), higherIsBetter: nil,
                                           unit: id == .steps ? "" : "kcal", format: .number(digits: 0))
            }
            return BodyActivityRow(
                id: id,
                title: id == .steps ? "Estimated steps" : "Active energy",
                value: hasValue ? number.flatMap { LooprUnitFormatter.number($0) } : nil,
                unit: hasValue ? (id == .steps ? nil : "kcal") : nil,
                caption: caption(for: metric, hasValue: hasValue),
                delta: delta,
                metricLinkID: id.metricLinkID
            )
        }
    }

    /// Steps and energy are always estimates; the caption says from what.
    static func caption(for metric: BodyMetricValue, hasValue: Bool) -> String? {
        let own = metric.confidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        guard hasValue else { return nil }
        return metric.id == .steps ? "Estimated from wrist motion" : "Estimated from your heart rate"
    }

    public var accessibilityLabel: String {
        var parts = [title]
        if let value {
            parts.append([value, unit.map(LooprUnitFormatter.spokenUnit)].compactMap { $0 }.joined(separator: " "))
        } else {
            parts.append("No reading")
        }
        if let caption { parts.append(caption) }
        if let delta { parts.append(delta.spokenText) }
        return parts.joined(separator: ", ")
    }
}

// MARK: Age cards

/// One thing an age estimate needs, and whether Loopr has it.
public struct BodyAgeRequirement: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let isMet: Bool
}

/// An age card: available with a value, or locked with what is missing.
public struct BodyAgeLock: Equatable, Sendable {
    public let title: String
    public let isAvailable: Bool
    /// The value when available ("34 years"), or "Locked".
    public let status: String
    /// One line under the title.
    public let summary: String
    public let requirements: [BodyAgeRequirement]

    public var accessibilityLabel: String {
        [title, status, summary].joined(separator: ", ")
    }

    /// Cardio Age: only from Apple Health or a lab test (DEC-02.10), never
    /// from Loopr's resting heart-rate estimate.
    public static func cardio(snapshot: BodyDaySnapshot, presentation: BodyAgePresentation) -> BodyAgeLock {
        if case .available(let label, let confidence, let source) = presentation {
            return BodyAgeLock(title: "Cardio Age", isAvailable: true, status: label, summary: "\(source) · \(confidence)", requirements: [])
        }
        let hero = BodyStrainHero.make(metric: snapshot.metric(.strain), recovery: nil)
        let hasAge: Bool? = {
            if let fitness = snapshot.cardioFitness { return fitness.age != nil }
            if case .needsAge = hero.state { return false }
            return hero.strain != nil ? true : nil
        }()
        let hasSex: Bool? = snapshot.cardioFitness.map { $0.referenceGroup != nil }
        var requirements: [BodyAgeRequirement] = []
        if let hasAge {
            requirements.append(BodyAgeRequirement(id: "age", title: "Your age", detail: "Set in your profile.", isMet: hasAge))
        }
        if let hasSex {
            requirements.append(BodyAgeRequirement(id: "sex", title: "Your sex", detail: "The reference values differ for men and women.", isMet: hasSex))
        }
        requirements.append(BodyAgeRequirement(
            id: "vo2max",
            title: "VO₂ max",
            detail: "3 workout VO₂ max readings from Apple Health on different days, at least 2 weeks apart, in the last 6 weeks. A lab test from the last 6 months also works.",
            isMet: false))
        let names: [String] = requirements.filter { !$0.isMet }.map { requirement in
            switch requirement.id {
            case "age": "your age"
            case "sex": "your sex"
            default: "VO₂ max readings"
            }
        }
        let summary: String
        if case .unavailable(let reason, _) = presentation, !reason.isEmpty, names.isEmpty {
            summary = reason
        } else {
            summary = "Needs " + BodyText.list(names)
        }
        return BodyAgeLock(title: "Cardio Age", isAvailable: false, status: "Locked", summary: summary, requirements: requirements)
    }

    /// Loopr Age stays locked for everyone until its model is validated
    /// (DEC-02.12). There is nothing the person can add to unlock it.
    public static func loopr(presentation _: BodyAgePresentation) -> BodyAgeLock {
        return BodyAgeLock(title: "Loopr Age", isAvailable: false, status: "Locked",
                           summary: "Not available yet. The model is still being validated.", requirements: [])
    }
}

// MARK: Body composition

public struct BodyCompositionRows: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let value: String
    }

    public let rows: [Row]
    /// "From your profile" or "From Apple Health", nil without rows.
    public let source: String?

    public static func make(_ composition: BodyCompositionContext) -> BodyCompositionRows {
        var rows: [Row] = []
        if let weight = composition.weight.flatMap(clean) { rows.append(Row(id: "weight", title: "Weight", value: weight)) }
        if let height = composition.height.flatMap(clean) { rows.append(Row(id: "height", title: "Height", value: height)) }
        if let fat = composition.bodyFat.flatMap(clean) { rows.append(Row(id: "bodyFat", title: "Body fat", value: fat)) }
        guard !rows.isEmpty else { return BodyCompositionRows(rows: [], source: nil) }
        let source = composition.source.localizedCaseInsensitiveContains("health") ? "From Apple Health" : "From your profile"
        return BodyCompositionRows(rows: rows, source: source)
    }

    /// "70.0 kg" reads as "70 kg"; "72.4 kg" stays.
    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: #"(\d+)\.0(?!\d)"#, with: "$1", options: .regularExpression)
    }
}

// MARK: Helpers

enum BodyValueParser {
    /// "8,240" → 8240, "8.6" → 8.6, nil for anything that is not a number.
    static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\u{202F}", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

enum BodyText {
    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
