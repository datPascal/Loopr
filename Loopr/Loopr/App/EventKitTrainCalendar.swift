import EventKit
import Foundation
import TrainKit

/// Saves planned Train sessions to the person's Calendar through EventKit.
///
/// Loopr asks for write-only access (`requestWriteOnlyAccessToEvents`, iOS 17 and later) and only from
/// `requestAccess()`, which runs when the person turns Add to Calendar on. Events go to the default
/// calendar for new events and carry the session name, its time and a short note. Nothing leaves the iPhone
/// through Loopr. If that calendar belongs to an iCloud or other account, that account syncs it.
///
/// Loopr remembers the event identifier of every event it saved, by `TrainCalendarEvent.key`, in
/// `UserDefaults`. A second export updates those events and removes the ones no longer planned, so a
/// reschedule never duplicates a session. Write-only access may not let an app read its own events back. When
/// Calendar will not return an event, Loopr leaves it as it is, forgets it and reports it in `couldNotChange`.
/// Verifying this on a real device and account is an external check.
nonisolated final class EventKitTrainCalendar: TrainCalendarWriter, @unchecked Sendable {
    private let store: EKEventStore
    private let defaults: UserDefaults
    private let ledgerKey: String
    private let lock = NSLock()

    init(store: EKEventStore = EKEventStore(), defaults: UserDefaults = .standard,
         ledgerKey: String = "loopr.train.calendar.events") {
        self.store = store; self.defaults = defaults; self.ledgerKey = ledgerKey
    }

    func authorization() async -> TrainCalendarAuthorization { Self.map(EKEventStore.authorizationStatus(for: .event)) }

    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        @unknown default: return false
        }
    }

    func replaceEvents(keyPrefix: String, with events: [TrainCalendarEvent]) async throws -> TrainCalendarReplaceResult {
        guard Self.map(EKEventStore.authorizationStatus(for: .event)) == .granted else { return TrainCalendarReplaceResult() }
        lock.lock(); defer { lock.unlock() }
        var ledger = readLedger()
        let existing = ledger.filter { $0.key.hasPrefix(keyPrefix) }
        let diff = TrainCalendarDiff(existing: existing, desired: events.filter { $0.key.hasPrefix(keyPrefix) })
        if diff.create.isEmpty, diff.update.isEmpty, diff.remove.isEmpty { return TrainCalendarReplaceResult() }

        var result = TrainCalendarReplaceResult()
        let canReadBack = EKEventStore.authorizationStatus(for: .event) == .fullAccess

        for event in diff.create {
            guard let calendar = store.defaultCalendarForNewEvents else { throw EventKitTrainCalendarError.noCalendar }
            let item = EKEvent(eventStore: store)
            item.calendar = calendar
            Self.fill(item, from: event)
            try store.save(item, span: .thisEvent, commit: false)
            if let identifier = item.eventIdentifier { ledger[event.key] = identifier }
            result.created += 1
        }
        for change in diff.update {
            if let item = store.event(withIdentifier: change.identifier) {
                Self.fill(item, from: change.event)
                try store.save(item, span: .thisEvent, commit: false)
                result.updated += 1
            } else if canReadBack {
                // The person deleted it in Calendar. Put it back.
                guard let calendar = store.defaultCalendarForNewEvents else { throw EventKitTrainCalendarError.noCalendar }
                let item = EKEvent(eventStore: store)
                item.calendar = calendar
                Self.fill(item, from: change.event)
                try store.save(item, span: .thisEvent, commit: false)
                if let identifier = item.eventIdentifier { ledger[change.event.key] = identifier }
                result.created += 1
            } else {
                result.couldNotChange += 1
            }
        }
        for removal in diff.remove {
            if let item = store.event(withIdentifier: removal.identifier) {
                try store.remove(item, span: .thisEvent, commit: false)
                result.removed += 1
            } else if !canReadBack {
                result.couldNotChange += 1
            }
            ledger[removal.key] = nil
        }
        try store.commit()
        writeLedger(ledger)
        return result
    }

    // MARK: Ledger

    private func readLedger() -> [String: String] {
        guard let data = defaults.data(forKey: ledgerKey),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private func writeLedger(_ ledger: [String: String]) {
        if ledger.isEmpty { defaults.removeObject(forKey: ledgerKey); return }
        defaults.set(try? JSONEncoder().encode(ledger), forKey: ledgerKey)
    }

    // MARK: Mapping

    private static func fill(_ item: EKEvent, from event: TrainCalendarEvent) {
        item.title = event.title
        item.startDate = event.start
        item.endDate = event.end
        item.isAllDay = event.isAllDay
        item.notes = event.notes
    }

    static func map(_ status: EKAuthorizationStatus) -> TrainCalendarAuthorization {
        switch status {
        case .fullAccess, .writeOnly: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

nonisolated enum EventKitTrainCalendarError: Error, LocalizedError {
    case noCalendar

    var errorDescription: String? { "Calendar has no calendar to save sessions in." }
}

/// Picks the Calendar writer. DEBUG builds can swap in a fake with `--loopr-train-calendar=granted` or
/// `--loopr-train-calendar=denied`, so UI tests never meet the system permission sheet.
enum TrainCalendarWriters {
    static func make() -> any TrainCalendarWriter {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--loopr-train-calendar=") })?
            .dropFirst("--loopr-train-calendar=".count) {
            return FixtureTrainCalendar(grants: mode == "granted")
        }
        #endif
        return EventKitTrainCalendar()
    }
}

#if DEBUG
/// An in-memory writer for UI tests. It follows the `TrainCalendarWriter` contract: one event per key, updates in
/// place and removes what is no longer listed.
nonisolated final class FixtureTrainCalendar: TrainCalendarWriter, @unchecked Sendable {
    private let grants: Bool
    private let lock = NSLock()
    private var asked = false
    private var events: [String: TrainCalendarEvent] = [:]

    init(grants: Bool) { self.grants = grants }

    func authorization() async -> TrainCalendarAuthorization {
        lock.lock(); defer { lock.unlock() }
        return asked ? (grants ? .granted : .denied) : .notDetermined
    }

    func requestAccess() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        asked = true
        return grants
    }

    func replaceEvents(keyPrefix: String, with desired: [TrainCalendarEvent]) async throws -> TrainCalendarReplaceResult {
        lock.lock(); defer { lock.unlock() }
        guard asked, grants else { return TrainCalendarReplaceResult() }
        var result = TrainCalendarReplaceResult()
        let keys = Set(desired.map(\.key))
        for key in events.keys where key.hasPrefix(keyPrefix) && !keys.contains(key) { events[key] = nil; result.removed += 1 }
        for event in desired where event.key.hasPrefix(keyPrefix) {
            if events[event.key] == nil { result.created += 1 } else { result.updated += 1 }
            events[event.key] = event
        }
        return result
    }
}
#endif
