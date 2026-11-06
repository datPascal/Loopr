import AIKit
import Foundation
import OSLog
import StorageKit

/// A saved list of what Loopr sent to AI providers. The bodies are the exact bytes of each request.
nonisolated protocol AgentRequestLogStore: AIRequestRecording {
    /// Newest first.
    func records() throws -> [AIRequestRecord]
    func record(id: UUID) throws -> AIRequestRecord?
    func clear() throws
    /// Deletes records older than `AgentRequestLogPolicy.retentionDays`.
    func prune(now: Date) throws
}

nonisolated enum AgentRequestLogPolicy {
    static let retentionDays = 30
    static func cutoff(from now: Date) -> Date { now.addingTimeInterval(-Double(retentionDays) * 86_400) }
}

/// Records in the `agent` namespace of the products database, keyed `log.<epoch milliseconds>.<id>`.
/// `willSend` writes before the request leaves the device, so the log cannot miss a send that went out.
nonisolated final class SQLiteAgentRequestLog: AgentRequestLogStore, @unchecked Sendable {
    static let namespace = "agent"
    static let prefix = "log."
    private static let logger = Logger(subsystem: "com.loopr.ios", category: "AgentRequestLog")
    private let store: StorageDocumentStore
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    init(database: StorageDatabase, now: @escaping @Sendable () -> Date = { Date() }) throws {
        store = try StorageDocumentStore(database: database, namespace: Self.namespace)
        self.now = now
    }

    static func key(for record: AIRequestRecord) -> String {
        String(format: "log.%013lld.%@", Int64((record.date.timeIntervalSince1970 * 1000).rounded()), record.id.uuidString)
    }
    private static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: ".")
        guard parts.count == 3, parts[0] == "log", let ms = Int64(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
    private func keys() throws -> [String] { try store.keys().filter { $0.hasPrefix(Self.prefix) } }

    func willSend(_ record: AIRequestRecord) {
        lock.withLock {
            do {
                try store.write(record, key: Self.key(for: record))
                try pruneLocked(now: now())
            } catch {
                // The request still goes out. Say so loudly, because the log is now missing one.
                Self.logger.error("Request log could not save a record: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) {
        lock.withLock {
            do {
                guard let key = try keys().first(where: { $0.hasSuffix("." + id.uuidString) }),
                      var record = try store.read(AIRequestRecord.self, key: key) else { return }
                record.status = status; record.httpStatus = httpStatus
                try store.write(record, key: key)
            } catch {
                Self.logger.error("Request log could not update a record: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func records() throws -> [AIRequestRecord] {
        try lock.withLock {
            try keys().sorted(by: >).compactMap { try? store.read(AIRequestRecord.self, key: $0) }
        }
    }
    func record(id: UUID) throws -> AIRequestRecord? {
        try lock.withLock {
            guard let key = try keys().first(where: { $0.hasSuffix("." + id.uuidString) }) else { return nil }
            return try store.read(AIRequestRecord.self, key: key)
        }
    }
    func clear() throws { try lock.withLock { try store.removeAll(whereKeyPrefix: Self.prefix) } }
    func prune(now: Date) throws { try lock.withLock { try pruneLocked(now: now) } }

    private func pruneLocked(now: Date) throws {
        let cutoff = AgentRequestLogPolicy.cutoff(from: now)
        for key in try keys() {
            // A key that does not parse is not ours to judge. Leave it.
            if let date = Self.date(fromKey: key), date < cutoff { try store.remove(key: key) }
        }
    }
}

/// The log for fixture and test compositions, so they never touch the real database.
nonisolated final class InMemoryAgentRequestLog: AgentRequestLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UUID: AIRequestRecord] = [:]
    private let now: @Sendable () -> Date
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }
    func willSend(_ record: AIRequestRecord) {
        lock.withLock { rows[record.id] = record }
        try? prune(now: now())
    }
    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) {
        lock.withLock { rows[id]?.status = status; rows[id]?.httpStatus = httpStatus }
    }
    func records() throws -> [AIRequestRecord] { lock.withLock { rows.values.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) } } }
    func record(id: UUID) throws -> AIRequestRecord? { lock.withLock { rows[id] } }
    func clear() throws { lock.withLock { rows = [:] } }
    func prune(now: Date) throws {
        let cutoff = AgentRequestLogPolicy.cutoff(from: now)
        lock.withLock { rows = rows.filter { $0.value.date >= cutoff } }
    }
}

/// Forwards to whichever log is attached. The default AI runtime is built before the database is open,
/// so it records through this hub. Until a log attaches, events wait in memory (the newest 100) and
/// flow in order when it does.
nonisolated final class AgentRequestLogHub: AIRequestRecording, @unchecked Sendable {
    static let shared = AgentRequestLogHub()
    private enum Event { case send(AIRequestRecord), finish(UUID, AIRequestStatus, Int?) }
    private let lock = NSLock()
    private var sink: (any AIRequestRecording)?
    private var waiting: [Event] = []

    func attach(_ log: any AIRequestRecording) {
        let pending: [Event] = lock.withLock { sink = log; defer { waiting = [] }; return waiting }
        for event in pending { forward(event, to: log) }
    }
    func detach() { lock.withLock { sink = nil } }

    func willSend(_ record: AIRequestRecord) { deliver(.send(record)) }
    func didFinish(id: UUID, status: AIRequestStatus, httpStatus: Int?) { deliver(.finish(id, status, httpStatus)) }

    private func deliver(_ event: Event) {
        let target: (any AIRequestRecording)? = lock.withLock {
            if let sink { return sink }
            waiting.append(event)
            if waiting.count > 100 { waiting.removeFirst(waiting.count - 100) }
            return nil
        }
        if let target { forward(event, to: target) }
    }
    private func forward(_ event: Event, to log: any AIRequestRecording) {
        switch event {
        case .send(let record): log.willSend(record)
        case .finish(let id, let status, let http): log.didFinish(id: id, status: status, httpStatus: http)
        }
    }
}
