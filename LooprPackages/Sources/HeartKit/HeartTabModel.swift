import Foundation
import DomainKit
import DesignSystem

/// Loads what the Heart tab shows besides the day snapshot: on a day change,
/// when the snapshot changes, and when the app says stored data moved.
///
/// History and the day's per-second heart rate are read through the app's
/// `HeartTabServices` off the main actor; this model only publishes the
/// results. A reload for the same day with the same inputs publishes nothing,
/// and a slow read for a day the person already left is dropped.
@MainActor
public final class HeartTabModel: ObservableObject {
    public enum TimelineState: Equatable, Sendable {
        /// Nothing asked yet, or no timeline source (fixtures without one).
        case unavailable
        case loading
        /// The day's timeline; nil when the band recorded nothing that day.
        case loaded(HeartDayTimeline?)
    }

    /// Days of history read for the cards: the 30-day chart plus the 7 days
    /// its first average point looks back over, plus the day itself.
    public static let historyDays = HeartBaselineTrend.windowDays + HeartBaselineTrend.averageDays + 1

    @Published public private(set) var resting: HeartBaselineTrend?
    @Published public private(set) var hrv: HeartBaselineTrend?
    @Published public private(set) var timeline: TimelineState = .unavailable
    @Published public private(set) var lastReading: HeartLastReading?

    private var day: LooprDay?
    private var history: [HeartBaselineMetric: [LooprChartPoint]] = [:]
    private var historyDay: LooprDay?

    public init() {}

    /// Loads the cards' history and the day's timeline for `day`.
    public func load(day: LooprDay, snapshot: HeartDaySnapshot?, services: HeartTabServices?,
                     calendar: Calendar = .current) async {
        self.day = day
        guard let dayStart = day.start(in: calendar) else { return }

        // History is read on every load, not cached per day: nights arrive
        // after the tab opens (the launch backfill writes them seconds later),
        // and two indexed reads of 38 rows cost less than a stale card.
        if historyDay != day {
            history = [:]
            historyDay = nil
        }
        if let source = services?.history, let end = day.noon(in: calendar) {
            async let restingPoints = source(HeartBaselineMetric.restingHeartRate.linkID, Self.historyDays, end)
            async let hrvPoints = source(HeartBaselineMetric.hrv.linkID, Self.historyDays, end)
            let loaded = await (restingPoints, hrvPoints)
            guard self.day == day, !Task.isCancelled else { return }
            history = [.restingHeartRate: loaded.0, .hrv: loaded.1]
        }
        historyDay = day
        updateTrends(day: day, dayStart: dayStart, snapshot: snapshot, calendar: calendar)

        if let source = services?.timeline {
            if case .loaded(let current) = timeline, current?.dayStart == dayStart {
                // Same day: keep the chart on screen while it refreshes.
            } else {
                timeline = .loading
            }
            let loaded = await source(day)
            guard self.day == day, !Task.isCancelled else { return }
            let next = TimelineState.loaded(loaded)
            if timeline != next { timeline = next }
        } else if timeline != .unavailable {
            timeline = .unavailable
        }

        if let source = services?.lastReading {
            let reading = await source()
            guard !Task.isCancelled else { return }
            if lastReading != reading { lastReading = reading }
        }
    }

    /// Rebuilds the cards from the history already loaded, for a snapshot
    /// that changed under the same day. Cheap: at most 38 points per card.
    public func snapshotChanged(_ snapshot: HeartDaySnapshot?, calendar: Calendar = .current) {
        guard let day, historyDay == day, let dayStart = day.start(in: calendar) else { return }
        updateTrends(day: day, dayStart: dayStart, snapshot: snapshot, calendar: calendar)
    }

    private func updateTrends(day: LooprDay, dayStart: Date, snapshot: HeartDaySnapshot?, calendar: Calendar) {
        let matches = snapshot.map { Self.identity(day) == $0.day } ?? false
        func value(_ metric: HeartBaselineMetric) -> Double? {
            guard matches else { return nil }
            return snapshot?.metric(metric.heartMetricID)?.numericValue
        }
        let nextResting = HeartBaselineTrend.make(metric: .restingHeartRate, history: history[.restingHeartRate] ?? [],
                                                  day: dayStart, dayValue: value(.restingHeartRate), calendar: calendar)
        let nextHRV = HeartBaselineTrend.make(metric: .hrv, history: history[.hrv] ?? [],
                                              day: dayStart, dayValue: value(.hrv), calendar: calendar)
        if resting != nextResting { resting = nextResting }
        if hrv != nextHRV { hrv = nextHRV }
    }

    static func identity(_ day: LooprDay) -> DayIdentity {
        DayIdentity(year: day.year, month: day.month, day: day.day)
    }
}
