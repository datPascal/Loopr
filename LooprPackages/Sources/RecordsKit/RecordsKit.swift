import Foundation

public struct MetricSnapshot: Codable, Equatable, Sendable {
    public let day: String
    public let metric: String
    public let value: Double
    public let algorithmVersion: Int
    public let provenance: String
    public init(day: String, metric: String, value: Double, algorithmVersion: Int, provenance: String = "Loopr-computed") {
        self.day = day; self.metric = metric; self.value = value; self.algorithmVersion = algorithmVersion; self.provenance = provenance
    }
}

public struct PersonalRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let metric: String
    public let value: Double
    public let day: String
    public let algorithmVersion: Int
    public init(metric: String, value: Double, day: String, algorithmVersion: Int) {
        self.id = "record:\(metric)"; self.metric = metric; self.value = value; self.day = day; self.algorithmVersion = algorithmVersion
    }
}

public struct Streak: Codable, Equatable, Sendable {
    public let metric: String
    public let qualifyingDays: Set<String>
    public let length: Int
    public let current: Bool
    public init(metric: String, qualifyingDays: Set<String>, length: Int, current: Bool) { self.metric = metric; self.qualifyingDays = qualifyingDays; self.length = length; self.current = current }
}

public enum TimelineEventKind: String, Codable, CaseIterable, Sendable {
    case sleep, workout, journal, notableChange, device

    public var displayName: String {
        switch self {
        case .sleep: "Sleep"
        case .workout: "Workout"
        case .journal: "Journal"
        case .notableChange: "Notable change"
        case .device: "Device"
        }
    }
}

public struct TimelineEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: TimelineEventKind
    public let day: String
    public let title: String
    public let sourceID: String
    public let correctionProvenance: String?
    public init(kind: TimelineEventKind, day: String, title: String, sourceID: String, correctionProvenance: String? = nil) {
        self.id = "\(kind.rawValue):\(sourceID)"; self.kind = kind; self.day = day; self.title = title; self.sourceID = sourceID; self.correctionProvenance = correctionProvenance
    }
}

public struct Recap: Codable, Equatable, Sendable {
    public enum Period: String, Codable, Sendable { case week, month }
    public let period: Period
    public let startDay: String
    public let endDay: String
    public let metrics: [MetricSnapshot]
    public let algorithmDiscontinuities: [Int]
    public let correctionDays: [String]
    public init(period: Period, startDay: String, endDay: String, metrics: [MetricSnapshot], algorithmDiscontinuities: [Int], correctionDays: [String]) {
        self.period = period; self.startDay = startDay; self.endDay = endDay; self.metrics = metrics; self.algorithmDiscontinuities = algorithmDiscontinuities; self.correctionDays = correctionDays
    }
}

public struct JourneySummary: Codable, Equatable, Sendable {
    public let startDay: String?
    public let endDay: String?
    public let activeDays: Int
    public let eventCount: Int

    public init(startDay: String?, endDay: String?, activeDays: Int, eventCount: Int) {
        self.startDay = startDay
        self.endDay = endDay
        self.activeDays = activeDays
        self.eventCount = eventCount
    }
}

public struct RecordsShareOptions: Sendable, Equatable {
    public var includeRoute: Bool
    public var includeJournal: Bool
    public var includeLocation: Bool
    public init(includeRoute: Bool = false, includeJournal: Bool = false, includeLocation: Bool = false) { self.includeRoute = includeRoute; self.includeJournal = includeJournal; self.includeLocation = includeLocation }
}

public struct RecordsShareCard: Codable, Equatable, Sendable {
    public let recap: Recap
    public let includesPrivateContent: Bool
    public let privateContent: [String]
    public init(recap: Recap, options: RecordsShareOptions = .init()) {
        self.recap = recap
        includesPrivateContent = options.includeRoute || options.includeJournal || options.includeLocation
        privateContent = [
            options.includeRoute ? "route" : nil,
            options.includeJournal ? "journal" : nil,
            options.includeLocation ? "location" : nil
        ].compactMap { $0 }
    }
}

public struct RecordsScreenSnapshot: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case loading, empty, error, populated, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure }
    public let state: State
    public let timeline: [TimelineEvent]
    public init(state: State, timeline: [TimelineEvent] = []) { self.state = state; self.timeline = timeline }
}

public enum LocalDayNavigator {
    public static func dayString(for date: Date, calendar: Calendar) -> String {
        var calendar = calendar; calendar.locale = Locale(identifier: "en_US_POSIX")
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func addingDays(_ count: Int, to date: Date, calendar: Calendar) -> Date { calendar.date(byAdding: .day, value: count, to: date) ?? date }
    public static func dayBoundary(containing date: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }
}

public protocol RecordsStore: Sendable {
    func save(_ metric: MetricSnapshot) async
    func save(_ event: TimelineEvent) async
    func metrics() async -> [MetricSnapshot]
    func timeline() async -> [TimelineEvent]
    func personalRecords() async -> [PersonalRecord]
    func streak(metric: String, qualifying: @escaping @Sendable (MetricSnapshot) -> Bool, calendar: Calendar, now: Date) async -> Streak
    func mergedTimeline(_ candidates: [TimelineEvent]) async -> [TimelineEvent]
    func recap(period: Recap.Period, startDay: String, endDay: String) async -> Recap
    func journey(startDay: String, endDay: String) async -> JourneySummary
    func shareCard(period: Recap.Period, startDay: String, endDay: String, options: RecordsShareOptions) async -> RecordsShareCard
    func deleteAll() async
}

public actor RecordsRepository: RecordsStore {
    private var snapshots: [String: MetricSnapshot] = [:]
    private var events: [String: TimelineEvent] = [:]

    public init() {}
    public func save(_ metric: MetricSnapshot) { snapshots["\(metric.day):\(metric.metric)"] = metric }
    public func save(_ event: TimelineEvent) { events[event.id] = event }
    public func metrics() -> [MetricSnapshot] { snapshots.values.sorted { ($0.day, $0.metric) < ($1.day, $1.metric) } }
    public func timeline() -> [TimelineEvent] { events.values.sorted { ($0.day, $0.id) < ($1.day, $1.id) } }

    /// Records only selects the maximum committed value; it never recomputes a
    /// metric owned by AnalyticsKit.
    public func personalRecords() -> [PersonalRecord] {
        Dictionary(grouping: snapshots.values, by: \.metric).compactMap { metric, rows in
            guard let best = rows.max(by: {
                if $0.value != $1.value { return $0.value < $1.value }
                if $0.day != $1.day { return $0.day < $1.day }
                return $0.algorithmVersion < $1.algorithmVersion
            }) else { return nil }
            return PersonalRecord(metric: metric, value: best.value, day: best.day, algorithmVersion: best.algorithmVersion)
        }.sorted { $0.metric < $1.metric }
    }

    public func streak(metric: String, qualifying: (MetricSnapshot) -> Bool, calendar: Calendar, now: Date) -> Streak {
        let qualifyingDays = Set(snapshots.values.filter { $0.metric == metric && qualifying($0) }.map(\.day))
        var cursor = calendar.startOfDay(for: now), count = 0
        while true {
            let day = LocalDayNavigator.dayString(for: cursor, calendar: calendar)
            guard qualifyingDays.contains(day) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Streak(metric: metric, qualifyingDays: qualifyingDays, length: count, current: count > 0)
    }

    public func mergedTimeline(_ candidates: [TimelineEvent]) -> [TimelineEvent] {
        for event in candidates { events[event.id] = event }
        return timeline()
    }

    public func recap(period: Recap.Period, startDay: String, endDay: String) -> Recap {
        let rows = snapshots.values.filter { $0.day >= startDay && $0.day <= endDay }.sorted { ($0.day, $0.metric) < ($1.day, $1.metric) }
        let versions = Set(rows.map(\.algorithmVersion)).sorted()
        let corrections = events.values.filter { $0.day >= startDay && $0.day <= endDay && $0.correctionProvenance != nil }.map(\.day).sorted()
        return Recap(period: period, startDay: startDay, endDay: endDay, metrics: rows, algorithmDiscontinuities: versions.count > 1 ? Array(versions.dropFirst()) : [], correctionDays: Array(Set(corrections)).sorted())
    }

    public func journey(startDay: String, endDay: String) -> JourneySummary {
        let events = events.values.filter { $0.day >= startDay && $0.day <= endDay }
        let days = Set(events.map(\.day)).sorted()
        return JourneySummary(startDay: days.first, endDay: days.last, activeDays: days.count, eventCount: events.count)
    }

    public func shareCard(period: Recap.Period, startDay: String, endDay: String, options: RecordsShareOptions = .init()) -> RecordsShareCard {
        RecordsShareCard(recap: recap(period: period, startDay: startDay, endDay: endDay), options: options)
    }

    public func deleteAll() {
        snapshots.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
    }
}
