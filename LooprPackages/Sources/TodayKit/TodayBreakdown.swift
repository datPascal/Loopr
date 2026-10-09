import Foundation
import DomainKit
import DesignSystem

/// One day's bar in a 30-day trend.
public struct TodayTrendBar: Equatable, Sendable, Identifiable {
    public let date: Date
    public let value: Double?
    public var id: Date { date }
}

/// "What shaped it" for the recovery breakdown screen, built from the day's
/// summary and the formula's own split. Tested without a view.
public struct TodayRecoveryExplanation: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The split reproduces the score on screen: exact points per signal.
        case exact
        /// A split exists but does not reproduce the score, so only direction
        /// and relative size are shown.
        case directionOnly
        /// Too few earlier nights.
        case learning
        /// Nothing to split.
        case none
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let signal: TodayRecoveryBreakdown.Signal
        public let title: String
        public let value: String?
        public let unit: String?
        public let delta: LooprDelta?
        /// Share of the day's biggest push, -1 to 1. Nil hides the bar.
        public let share: Double?
        /// "+6 pts", only in exact mode.
        public let pointsLabel: String?
        public let status: String?
        public var id: String { signal.rawValue }
    }

    public let mode: Mode
    public let rows: [Row]
    /// The sentence under the rows that says how to read them.
    public let note: String
    /// Sleep's place, stated plainly: it is not part of the score.
    public let sleepNote: String?
    public let trend: [TodayTrendBar]

    public init(summary: TodaySummary, context: TodayDayContext?, calendar: Calendar = .current) {
        let values = TodayValues(summary: summary, context: context, calendar: calendar)
        let displayed = values.value(.recovery)
        let breakdown = context?.recovery
        let learning = TodayHeroRules.learningState(summary: summary, breakdown: breakdown)
        let mode: Mode
        if let breakdown, breakdown.explains(displayed) {
            mode = .exact
        } else if learning != nil, displayed == nil {
            mode = .learning
        } else if let breakdown, breakdown.inputs.contains(where: { $0.contribution != nil }) {
            mode = .directionOnly
        } else {
            mode = .none
        }
        self.mode = mode

        let scaled = LooprContributorImpact.scaled(TodayRecoveryBreakdown.Signal.allCases.map { signal in
            mode == .exact ? breakdown?.input(signal)?.points : breakdown?.input(signal)?.contribution
        })
        rows = TodayRecoveryBreakdown.Signal.allCases.enumerated().map { index, signal in
            let metric = signal.metric
            let input = breakdown?.input(signal)
            let value = values.value(metric) ?? input?.value
            let formatted = value.map(metric.formatted)
            let delta: LooprDelta?
            switch mode {
            case .exact, .directionOnly:
                // The same "vs usual" the Today rows print, so one number
                // never reads two ways; the formula's own median only fills
                // in while the 30-day range is still building.
                if let band = values.delta(metric, withinRange: .signed), band.reference == "usual",
                   case .learning = band.kind {
                    if let value, let usual = input?.usual {
                        delta = LooprDelta(kind: .change(value - usual), higherIsBetter: metric.higherIsBetter,
                                           unit: metric.unit ?? "", format: metric.deltaFormat)
                    } else {
                        delta = band
                    }
                } else {
                    delta = values.delta(metric, withinRange: .signed)
                }
            case .learning:
                let need = learning?.need ?? breakdown?.nightsNeeded ?? 3
                let have = min(input.map { $0.baselineNights + 1 } ?? learning?.have ?? 0, need)
                delta = value == nil ? nil : .learning(have, of: need, noun: "nights")
            case .none:
                delta = values.delta(metric, withinRange: .signed)
            }
            let share = (mode == .exact || mode == .directionOnly) && input?.status == .used ? scaled[index] : nil
            let pointsLabel: String? = mode == .exact ? input?.points.map(Self.pointsText) : nil
            return Row(signal: signal, title: metric.title, value: formatted?.value, unit: formatted?.unit,
                       delta: delta, share: share, pointsLabel: pointsLabel,
                       status: input?.status == .flatBaseline ? "Not scored. Your \(metric == .hrv ? metric.title : metric.title.lowercased()) has barely changed over your usual nights." : nil)
        }

        switch mode {
        case .exact:
            note = "A night that matches your usual on all three scores 50. Each bar is that signal's share of the move from 50 to your score."
        case .directionOnly:
            note = "The bars show which way each signal leaned and how strongly. Exact points aren't shown because the nights behind this score have changed since it was calculated."
        case .learning:
            let need = learning?.need ?? 3
            note = "Recovery needs at least two heart readings with \(need) earlier nights each. The estimate settles after 14 nights."
        case .none:
            note = "Recovery needs at least two usable overnight heart readings with three earlier nights each."
        }

        if let sleep = values.value(.sleep), let text = LooprUnitFormatter.duration(minutes: sleep) {
            let need = summary.sleepNeedMinutes.flatMap { LooprUnitFormatter.duration(minutes: $0) }
            sleepNote = "Sleep isn't part of this score. Last night: \(text)" + (need.map { " against a \($0) need." } ?? ".")
        } else {
            sleepNote = nil
        }
        trend = Self.trend(context?.history[.recovery] ?? [], dayStart: context?.dayStart, calendar: calendar)
    }

    static func pointsText(_ points: Double) -> String {
        let rounded = Int(points.rounded())
        if rounded == 0 { return "0 pts" }
        let sign = rounded > 0 ? "+" : "\u{2212}"
        return "\(sign)\(abs(rounded)) \(abs(rounded) == 1 ? "pt" : "pts")"
    }

    /// The 30 days ending on the day, one bar per day, nil for a gap.
    static func trend(_ points: [LooprChartPoint], dayStart: Date?, days: Int = 30, calendar: Calendar) -> [TodayTrendBar] {
        guard let dayStart else { return [] }
        let byDay = Dictionary(points.map { (calendar.startOfDay(for: $0.date), $0.value) }, uniquingKeysWith: { _, last in last })
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: dayStart).map { date in
                TodayTrendBar(date: date, value: byDay[calendar.startOfDay(for: date)])
            }
        }
    }
}

/// The strain breakdown: the day's strain, how it compares, time per zone
/// and the last 30 days.
public struct TodayStrainExplanation: Equatable, Sendable {
    public struct Zone: Equatable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let minutes: Double
        /// Share of the longest zone, 0 to 1.
        public let share: Double
    }

    public let value: Double?
    public let text: String
    public let delta: LooprDelta?
    public let rangeText: String?
    public let zones: [Zone]
    public let totalZoneMinutes: Double
    public let trend: [TodayTrendBar]

    public init(summary: TodaySummary, context: TodayDayContext?, calendar: Calendar = .current) {
        let values = TodayValues(summary: summary, context: context, calendar: calendar)
        value = values.value(.strain)
        text = value.map { String(format: "%.1f", $0) } ?? "—"
        delta = values.delta(.strain, withinRange: .word)
        if let range = context?.suggestedStrainRange {
            rangeText = "Suggested today: \(String(format: "%.0f", range.lowerBound)) to \(String(format: "%.0f", range.upperBound))"
        } else {
            rangeText = nil
        }
        let zones = context?.zoneMinutes ?? []
        let longest = zones.map(\.minutes).max() ?? 0
        self.zones = zones.map { Zone(id: $0.id, name: $0.name, minutes: $0.minutes, share: longest > 0 ? $0.minutes / longest : 0) }
        totalZoneMinutes = zones.reduce(0) { $0 + $1.minutes }
        trend = TodayRecoveryExplanation.trend(context?.history[.strain] ?? [], dayStart: context?.dayStart, calendar: calendar)
    }
}
