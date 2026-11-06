import Foundation

/// Where Calendar permission stands, reduced to what Loopr needs to know.
public enum TrainCalendarAuthorization: Equatable, Sendable {
    /// The person has not been asked. Loopr asks only when they turn Add to Calendar on.
    case notDetermined
    /// Denied or restricted. Only Settings can change it.
    case denied
    /// Loopr may save events. Write-only access counts.
    case granted
}

/// One planned session as a Calendar event.
public struct TrainCalendarEvent: Equatable, Sendable, Identifiable {
    /// Stable per session slot: `loopr.program.<program id>.w<week>.d<weekday>`. A moved session keeps its key,
    /// so exporting again updates the event instead of adding a second one.
    public let key: String
    public let title: String
    public let start: Date
    public let end: Date
    /// True when the slot has no planned time.
    public let isAllDay: Bool
    public let notes: String

    public var id: String { key }

    public init(key: String, title: String, start: Date, end: Date, isAllDay: Bool, notes: String) {
        self.key = key; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.notes = notes
    }
}

/// What one replace did.
public struct TrainCalendarReplaceResult: Equatable, Sendable {
    public var created: Int
    public var updated: Int
    public var removed: Int
    /// Events Loopr wanted to update or remove but Calendar would not hand back, for example under write-only access.
    /// They stay as they were and the person can delete them in Calendar.
    public var couldNotChange: Int

    public init(created: Int = 0, updated: Int = 0, removed: Int = 0, couldNotChange: Int = 0) {
        self.created = created; self.updated = updated; self.removed = removed; self.couldNotChange = couldNotChange
    }

    public var saved: Int { created + updated }
}

/// Writes planned sessions to the person's Calendar.
///
/// The app implements this with EventKit and asks for write-only access. Tests use a fake. Loopr calls
/// `requestAccess()` only from the moment the person turns Add to Calendar on, never at launch.
public protocol TrainCalendarWriter: Sendable {
    /// The current permission. Never shows a prompt.
    func authorization() async -> TrainCalendarAuthorization

    /// Shows the system prompt the first time. Returns true when events can be saved.
    func requestAccess() async -> Bool

    /// Makes the events whose key starts with `keyPrefix` equal `events`: creates new keys, updates keys that
    /// already have an event and removes events whose key is no longer listed. Never duplicates a key.
    func replaceEvents(keyPrefix: String, with events: [TrainCalendarEvent]) async throws -> TrainCalendarReplaceResult
}

public enum TrainCalendarKeys {
    /// The prefix shared by every event of one program.
    public static func prefix(programID: UUID) -> String { "loopr.program.\(programID.uuidString.lowercased())." }

    public static func key(programID: UUID, week: Int, weekday: TrainWeekday) -> String {
        "\(prefix(programID: programID))w\(week).d\(weekday.rawValue)"
    }
}

/// What to do to Calendar so it matches the plan, given the events Loopr saved before.
public struct TrainCalendarDiff: Equatable, Sendable {
    public struct Update: Equatable, Sendable {
        public let identifier: String
        public let event: TrainCalendarEvent
    }

    public struct Removal: Equatable, Sendable {
        public let key: String
        public let identifier: String
    }

    public let create: [TrainCalendarEvent]
    public let update: [Update]
    public let remove: [Removal]

    /// - Parameters:
    ///   - existing: Calendar event identifiers Loopr saved, by event key.
    ///   - desired: The events the plan needs now. A repeated key keeps its last event.
    public init(existing: [String: String], desired: [TrainCalendarEvent]) {
        var byKey: [String: TrainCalendarEvent] = [:]
        for event in desired { byKey[event.key] = event }
        let ordered = byKey.values.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
        create = ordered.filter { existing[$0.key] == nil }
        update = ordered.compactMap { event in existing[event.key].map { Update(identifier: $0, event: event) } }
        remove = existing.filter { byKey[$0.key] == nil }.sorted { $0.key < $1.key }.map { Removal(key: $0.key, identifier: $0.value) }
    }
}
