import Foundation

/// What one exercise's history shows, chosen by its measure (R2-LIFT-01): the list row's best, the stats on the
/// detail screen and the one value the chart follows.
///
/// - Weight lifts follow the estimated one-rep max, or the most reps when no set carried a load.
/// - Bodyweight lifts follow the least assistance when the newest session was assisted (lower is better), the most
///   added load when it was weighted, and the most reps at body weight otherwise.
/// - Holds follow the longest hold in seconds, carries and sled pushes the longest distance in metres.
///
/// Warm-ups and skipped sets never count: `ExerciseHistory` leaves them out. A value that was never logged is nil
/// and the screen shows nothing for it, never a zero. Built from W1's measure-aware entry values
/// (`ExerciseHistory.Entry.longestHoldSeconds` and the rest), so the bests here match the session's bests.
public struct ExerciseProgress: Equatable, Sendable {
    /// The value the chart and the list row follow.
    public enum Metric: String, CaseIterable, Sendable {
        case estimatedOneRepMax, mostReps, mostAddedKg, leastAssistKg, longestHold, longestDistance

        /// The chart's title.
        public var title: String {
            switch self {
            case .estimatedOneRepMax: "Estimated 1RM"
            case .mostReps: "Most reps in a set"
            case .mostAddedKg: "Most added load"
            case .leastAssistKg: "Least assist"
            case .longestHold: "Longest hold"
            case .longestDistance: "Longest distance"
            }
        }

        /// Less assistance is a stronger pull-up.
        public var lowerIsBetter: Bool { self == .leastAssistKg }

        /// The smallest gap the chart leaves above and below the values, in the metric's unit.
        var minimumPadding: Double {
            switch self {
            case .estimatedOneRepMax, .mostAddedKg, .leastAssistKg: 2.5
            case .mostReps: 1
            case .longestHold: 5
            case .longestDistance: 5
            }
        }
    }

    /// One session on the chart.
    public struct Point: Equatable, Sendable, Identifiable {
        public let sessionID: UUID
        public let date: Date
        public let value: Double
        public var id: UUID { sessionID }
    }

    /// One cell of the Bests grid. `value` is nil when nothing was logged for it; the grid then shows a dash.
    public struct Stat: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let value: String?
        public let unit: String?
    }

    public let measure: TrainSetMeasure
    public let metric: Metric
    /// Oldest first. Only sessions that have a value for `metric` and the exercise's current measure.
    public let points: [Point]
    /// The list row's best: "est. 1RM 104 kg", "Longest hold 1:30", "Least assist 10 kg". Nil when there is none.
    public let headline: String?
    /// The headline for VoiceOver: "estimated one-rep max 104 kg", "Longest hold 1 minute 30 seconds".
    public var spokenHeadline: String? {
        guard let headline else { return nil }
        if metric == .longestHold, let best = points.map(\.value).max() { return "Longest hold \(spoken(best))" }
        return headline.replacingOccurrences(of: "est. 1RM", with: "estimated one-rep max")
    }
    public let stats: [Stat]
    /// A line under the Bests card, or nil.
    public let footnote: String?

    public init(_ exercise: ExerciseHistory.Exercise) {
        let measure = exercise.measure
        let entries = exercise.entries.filter { $0.measure == measure }
        let newest = entries.first
        let metric: Metric
        switch measure {
        case .weight:
            metric = entries.contains { $0.estimatedOneRepMax != nil } ? .estimatedOneRepMax : .mostReps
        case .bodyweight:
            if newest?.leastAssistKg != nil { metric = .leastAssistKg }
            else if newest?.mostAddedKg != nil { metric = .mostAddedKg }
            else { metric = .mostReps }
        case .time: metric = .longestHold
        case .distance: metric = .longestDistance
        }
        self.measure = measure
        self.metric = metric
        points = entries.reversed().compactMap { entry in
            Self.value(of: entry, metric: metric).map { Point(sessionID: entry.sessionID, date: entry.date, value: $0) }
        }

        let sets = entries.flatMap(\.sets)
        let setCount = Stat(id: "sets", title: "Sets logged", value: String(exercise.setCount), unit: nil)
        let reps = Self.mostReps(in: sets, measure: measure)
        switch measure {
        case .weight where metric == .estimatedOneRepMax:
            let e1rm = exercise.bestEstimatedOneRepMax
            headline = e1rm.map { "est. 1RM \(ExerciseProgressFormat.halfKilograms($0)) kg" }
            stats = [
                Stat(id: "e1rm", title: "Estimated 1RM", value: e1rm.map(ExerciseProgressFormat.halfKilograms), unit: "kg"),
                Stat(id: "heaviest", title: "Heaviest", value: exercise.heaviestLoad.map(TrainLiveFormat.kilograms), unit: "kg"),
                Stat(id: "volume", title: "Best set",
                     value: exercise.bestSet.map { "\(TrainLiveFormat.kilograms($0.loadKg ?? 0)) × \($0.reps)" }, unit: "kg"),
                setCount
            ]
            footnote = "Loopr works out the estimated 1RM from your best set with the Epley formula. It is an estimate, not a weight you lifted."
        case .weight, .bodyweight:
            let assist = entries.compactMap(\.leastAssistKg).min()
            let added = entries.compactMap(\.mostAddedKg).max()
            switch metric {
            case .leastAssistKg: headline = assist.map { "Least assist \(TrainLiveFormat.kilograms($0)) kg" }
            case .mostAddedKg: headline = added.map { "Most added \(TrainLiveFormat.kilograms($0)) kg" }
            default: headline = reps.map { "Most reps \($0)" }
            }
            var cells = [Stat(id: "reps", title: "Most reps", value: reps.map(String.init), unit: "reps")]
            if let added { cells.append(Stat(id: "added", title: "Most added", value: TrainLiveFormat.kilograms(added), unit: "kg")) }
            if let assist { cells.append(Stat(id: "assist", title: "Least assist", value: TrainLiveFormat.kilograms(assist), unit: "kg")) }
            cells.append(setCount)
            stats = cells
            footnote = assist == nil ? nil
                : "Least assist is the smallest band or machine help you used. Less help means a stronger pull."
        case .time:
            let hold = exercise.longestHoldSeconds
            headline = hold.map { "Longest hold \(TrainSetFormat.seconds($0))" }
            let load = sets.compactMap(\.loadKg).filter { $0 > 0 }.max()
            var cells = [Stat(id: "hold", title: "Longest hold", value: hold.map(TrainSetFormat.seconds), unit: nil)]
            if let load { cells.append(Stat(id: "hold-load", title: "Heaviest hold", value: TrainLiveFormat.kilograms(load), unit: "kg")) }
            cells.append(setCount)
            stats = cells
            footnote = nil
        case .distance:
            let best = Self.longestSet(in: sets)
            headline = best.map { "Longest \(Self.distanceText($0))" }
            let load = sets.compactMap(\.loadKg).filter { $0 > 0 }.max()
            var cells = [Stat(id: "distance", title: "Longest", value: best?.metres.map { TrainLiveFormat.kilograms($0) }, unit: "m")]
            if let load { cells.append(Stat(id: "carry-load", title: "Heaviest", value: TrainLiveFormat.kilograms(load), unit: "kg")) }
            cells.append(setCount)
            stats = cells
            footnote = nil
        }
    }

    /// The chart's value for one session, or nil when the session has none.
    static func value(of entry: ExerciseHistory.Entry, metric: Metric) -> Double? {
        switch metric {
        case .estimatedOneRepMax: entry.estimatedOneRepMax
        case .mostReps: mostReps(in: entry.sets, measure: entry.measure).map(Double.init)
        case .mostAddedKg: entry.mostAddedKg
        case .leastAssistKg: entry.leastAssistKg
        case .longestHold: entry.longestHoldSeconds.map(Double.init)
        case .longestDistance: entry.longestMetres
        }
    }

    /// Most reps in one set. For bodyweight work only sets at plain body weight count: an assisted or a weighted
    /// set is a different lift for reps.
    static func mostReps(in sets: [LoggedSet], measure: TrainSetMeasure) -> Int? {
        let counted = measure == .bodyweight ? sets.filter { ($0.assistKg ?? 0) <= 0 && ($0.loadKg ?? 0) <= 0 } : sets
        return counted.map(\.reps).filter { $0 > 0 }.max()
    }

    /// The farthest set, the heavier one on a tie.
    static func longestSet(in sets: [LoggedSet]) -> LoggedSet? {
        sets.filter { ($0.metres ?? 0) > 0 }.max { ($0.metres ?? 0, $0.loadKg ?? 0) < ($1.metres ?? 0, $1.loadKg ?? 0) }
    }

    /// "45 m at 32 kg" or "45 m".
    static func distanceText(_ set: LoggedSet) -> String {
        TrainSetFormat.set(TrainSetValues(loadKg: set.loadKg, metres: set.metres), measure: .distance)
    }

    // MARK: Chart text

    /// The unit after a value: "kg", "reps", "m", or nil for a time.
    public var unit: String? {
        switch metric {
        case .estimatedOneRepMax, .mostAddedKg, .leastAssistKg: "kg"
        case .mostReps: "reps"
        case .longestHold: nil
        case .longestDistance: "m"
        }
    }

    /// One chart value as text: "104", "1:30", "45".
    public func text(_ value: Double) -> String {
        switch metric {
        case .estimatedOneRepMax: ExerciseProgressFormat.halfKilograms(value)
        case .longestHold: TrainSetFormat.seconds(Int(value.rounded()))
        case .mostReps: String(Int(value.rounded()))
        case .mostAddedKg, .leastAssistKg, .longestDistance: TrainLiveFormat.kilograms(value)
        }
    }

    /// One chart value for VoiceOver: "104 kilograms", "1 minute 30 seconds", "12 reps", "45 metres".
    public func spoken(_ value: Double) -> String {
        switch metric {
        case .estimatedOneRepMax, .mostAddedKg, .leastAssistKg: "\(text(value)) kilograms"
        case .longestHold: LooprSpokenSeconds.text(Int(value.rounded()))
        case .mostReps: "\(text(value)) reps"
        case .longestDistance: "\(text(value)) metres"
        }
    }

    /// The value range the chart draws, padded so no dot sits on the top or bottom edge.
    public var valueDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.15, metric.minimumPadding)
        return max(0, low - pad)...(high + pad)
    }

    /// The date range the chart draws. One session sits in the middle of a week, two or more keep a gap at both
    /// ends so the first and last dots never touch the edges (R2-LIFT-09, R2-DES-14).
    public var dateDomain: ClosedRange<Date>? {
        guard let first = points.first?.date, let last = points.last?.date else { return nil }
        let day: TimeInterval = 86_400
        let pad = max((last.timeIntervalSince(first)) * 0.12, points.count == 1 ? 3 * day : day)
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }

    /// "One session so far." under one dot, "One more session to draw a trend." under two, nil once there is a line.
    public var chartCaption: String? {
        var lines: [String] = []
        if let trend = ExerciseTrend.caption(pointCount: points.count) { lines.append(trend) }
        if metric.lowerIsBetter { lines.append("Lower is better.") }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

enum ExerciseProgressFormat {
    /// An estimate rounded to half a kilo: anything finer suggests a precision it does not have.
    static func halfKilograms(_ value: Double) -> String { TrainLiveFormat.kilograms((value * 2).rounded() / 2) }
}
