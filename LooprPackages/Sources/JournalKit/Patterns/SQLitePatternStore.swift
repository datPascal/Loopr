import DomainKit
import Foundation
import StorageKit

/// `PatternStore` on a `StorageDocumentStore` in the `patterns` namespace.
///
/// Keys: `test.<id>`, `found.<candidate>.<metric>`, `dismissed.<key>`,
/// `review.<weekStartDay>`, `settings`. Every method that changes more than one
/// document does it in one SQLite transaction.
public actor SQLitePatternStore: PatternStore {
    public static let namespace = "patterns"
    private let store: StorageDocumentStore

    public init(database: StorageDatabase) throws {
        store = try StorageDocumentStore(database: database, namespace: Self.namespace)
    }

    private enum Prefix {
        static let test = "test."
        static let found = "found."
        static let dismissed = "dismissed."
        static let review = "review."
        static let settings = "settings"
    }

    private func read<T: Decodable>(_ type: T.Type, prefix: String) throws -> [T] {
        try store.keys().filter { $0.hasPrefix(prefix) }.compactMap { try store.read(type, key: $0) }
    }

    /// Derived documents are rebuilt by discovery, so one unreadable row is skipped, not fatal.
    private func readSkippingUnreadable<T: Decodable>(_ type: T.Type, prefix: String) throws -> [T] {
        try store.keys().filter { $0.hasPrefix(prefix) }.compactMap { try? store.read(type, key: $0) }
    }

    public func tests() throws -> [PatternTest] {
        try read(PatternTest.self, prefix: Prefix.test)
            .sorted { ($0.startDay, $0.id.uuidString) < ($1.startDay, $1.id.uuidString) }
    }
    public func test(id: UUID) throws -> PatternTest? { try store.read(PatternTest.self, key: Prefix.test + id.uuidString) }
    public func saveTest(_ test: PatternTest) throws { try store.write(test, key: Prefix.test + test.id.uuidString) }
    public func deleteTest(id: UUID) throws { try store.remove(key: Prefix.test + id.uuidString) }

    public func foundPatterns() throws -> [FoundPattern] {
        PatternDiscoveryEngine.ordered(try readSkippingUnreadable(FoundPattern.self, prefix: Prefix.found))
    }
    public func replaceFoundPatterns(_ patterns: [FoundPattern]) throws {
        let fresh = Dictionary(patterns.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var mutations: [StorageDocumentMutation] = try store.keys().filter { $0.hasPrefix(Prefix.found) }
            .map { StorageDocumentMutation.remove(key: $0) }
        for (key, pattern) in fresh.sorted(by: { $0.key < $1.key }) {
            mutations.append(try .write(pattern, key: Prefix.found + key))
        }
        // A dismissal whose numbers a deletion made out of date takes the new numbers when the pattern still holds.
        for dismissed in try readSkippingUnreadable(DismissedPattern.self, prefix: Prefix.dismissed) where dismissed.evidenceIsStale {
            if let current = fresh[dismissed.key] {
                mutations.append(try .write(DismissedPattern(evidence: current, dismissedAt: dismissed.dismissedAt), key: Prefix.dismissed + dismissed.key))
            }
        }
        try store.mutate(mutations)
    }

    public func hideFoundPatterns(affectedBy change: PatternSourceChange) throws {
        try store.mutate([], additionalChanges: { db in try Self.hideFoundPatterns(affectedBy: change, in: db) })
    }

    /// Does the hiding inside the caller's transaction, so a deletion and the patterns that counted it change in
    /// one save. Reads only the `patterns` namespace, so it costs nothing for a person who never used Patterns.
    public static func hideFoundPatterns(affectedBy change: PatternSourceChange, in db: Database) throws {
        let table = StorageDocumentStore.documentTable
        // A store that never held a document has no table yet, and so no pattern to hide.
        guard try db.tableExists(table) else { return }
        let rows = try Row.fetchAll(db, sql: "SELECT document_key, payload FROM \(table) WHERE namespace = ?", arguments: [namespace])
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hidden = Set<String>()
        var staleDismissals: [(key: String, value: DismissedPattern)] = []
        var settings: (key: String, value: PatternSettings)?
        var reviews: [(key: String, value: WeeklyReview)] = []
        for row in rows {
            let key: String = row["document_key"], payload: Data = row["payload"]
            if key.hasPrefix(Prefix.found) {
                guard let pattern = try? decoder.decode(FoundPattern.self, from: payload) else { continue }
                if change.affects(pattern) { hidden.insert(pattern.key); try db.execute(sql: "DELETE FROM \(table) WHERE namespace = ? AND document_key = ?", arguments: [namespace, key]) }
            } else if key.hasPrefix(Prefix.dismissed) {
                guard var dismissed = try? decoder.decode(DismissedPattern.self, from: payload), change.affects(dismissed.evidence) else { continue }
                dismissed.evidenceIsStale = true
                staleDismissals.append((key, dismissed))
            } else if key.hasPrefix(Prefix.review) {
                if let review = try? decoder.decode(WeeklyReview.self, from: payload) { reviews.append((key, review)) }
            } else if key == Prefix.settings {
                if let value = try? decoder.decode(PatternSettings.self, from: payload) { settings = (key, value) }
            }
        }
        let timestamp = Date().timeIntervalSince1970
        func write(_ value: some Encodable, key: String) throws {
            try db.execute(sql: """
                INSERT INTO \(table)(namespace, document_key, payload, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, document_key) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
                """, arguments: [namespace, key, try encoder.encode(value), timestamp])
        }
        for item in staleDismissals { try write(item.value, key: item.key) }
        let affectedKeys = hidden.union(staleDismissals.map(\.value.key))
        for item in reviews where !Set(item.value.patternKeys).isDisjoint(with: affectedKeys) {
            try db.execute(sql: "DELETE FROM \(table) WHERE namespace = ? AND document_key = ?", arguments: [namespace, item.key])
        }
        if var value = settings?.value, value.lookForNewPatterns, !value.needsRecompute {
            value.needsRecompute = true
            try write(value, key: Prefix.settings)
        }
    }

    public func dismissedPatterns() throws -> [DismissedPattern] {
        try readSkippingUnreadable(DismissedPattern.self, prefix: Prefix.dismissed)
            .sorted { ($0.dismissedAt, $0.key) > ($1.dismissedAt, $1.key) }
    }
    public func dismiss(_ pattern: FoundPattern, at date: Date) throws {
        try store.write(DismissedPattern(evidence: pattern, dismissedAt: date), key: Prefix.dismissed + pattern.key)
    }
    @discardableResult public func restore(key: String) throws -> FoundPattern? {
        guard let dismissed = try store.read(DismissedPattern.self, key: Prefix.dismissed + key) else { return nil }
        let current = try? store.read(FoundPattern.self, key: Prefix.found + key)
        var mutations: [StorageDocumentMutation] = [.remove(key: Prefix.dismissed + key)]
        // Numbers a deletion made out of date do not come back. The next look finds the pattern again, if it holds.
        if current == nil, !dismissed.evidenceIsStale { mutations.append(try .write(dismissed.evidence, key: Prefix.found + key)) }
        try store.mutate(mutations)
        return current ?? (dismissed.evidenceIsStale ? nil : dismissed.evidence)
    }

    public func reviews() throws -> [WeeklyReview] {
        try readSkippingUnreadable(WeeklyReview.self, prefix: Prefix.review).sorted { $0.weekStartDay > $1.weekStartDay }
    }
    public func review(weekStartDay: String) throws -> WeeklyReview? {
        try store.read(WeeklyReview.self, key: Prefix.review + weekStartDay)
    }
    public func saveReview(_ review: WeeklyReview) throws { try store.write(review, key: Prefix.review + review.weekStartDay) }

    public func settings() throws -> PatternSettings {
        try store.read(PatternSettings.self, key: Prefix.settings) ?? PatternSettings()
    }
    public func saveSettings(_ settings: PatternSettings) throws { try store.write(settings, key: Prefix.settings) }

    public func clearDerived() throws {
        let derived = [Prefix.found, Prefix.review]
        var mutations = try store.keys().filter { key in derived.contains { key.hasPrefix($0) } }
            .map { StorageDocumentMutation.remove(key: $0) }
        // Dismissals are the person's choice, so they stay. Their numbers came from the deleted data.
        for var dismissed in try readSkippingUnreadable(DismissedPattern.self, prefix: Prefix.dismissed) {
            dismissed.evidenceIsStale = true
            mutations.append(try .write(dismissed, key: Prefix.dismissed + dismissed.key))
        }
        try store.mutate(mutations)
    }
    public func deleteAll() throws { try store.removeAll() }
}
