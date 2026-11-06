import DomainKit
import Foundation

public struct PatternSettings: Codable, Equatable, Sendable {
    /// "Look for new patterns". Off until the person turns it on.
    public var lookForNewPatterns: Bool
    public var defaultReminderMinuteOfDay: Int
    /// The last day discovery ran through, so a runtime can skip a second run in one day.
    public var lastDiscoveryDay: String?
    public var lastDiscoveryAt: Date?
    /// Set in the same save as a deletion that hid found patterns. The next foreground run looks again and
    /// clears it, so a quit before the recount does not leave the patterns hidden for a week.
    public var needsRecompute: Bool
    public let schemaVersion: Int

    public init(lookForNewPatterns: Bool = false,
                defaultReminderMinuteOfDay: Int = PatternPolicy.default.defaultReminderMinuteOfDay,
                lastDiscoveryDay: String? = nil, lastDiscoveryAt: Date? = nil, needsRecompute: Bool = false,
                schemaVersion: Int = 1) {
        self.lookForNewPatterns = lookForNewPatterns
        self.defaultReminderMinuteOfDay = defaultReminderMinuteOfDay
        self.lastDiscoveryDay = lastDiscoveryDay
        self.lastDiscoveryAt = lastDiscoveryAt
        self.needsRecompute = needsRecompute
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case lookForNewPatterns, defaultReminderMinuteOfDay, lastDiscoveryDay, lastDiscoveryAt, needsRecompute, schemaVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lookForNewPatterns: try c.decodeIfPresent(Bool.self, forKey: .lookForNewPatterns) ?? false,
            defaultReminderMinuteOfDay: try c.decodeIfPresent(Int.self, forKey: .defaultReminderMinuteOfDay)
                ?? PatternPolicy.default.defaultReminderMinuteOfDay,
            lastDiscoveryDay: try c.decodeIfPresent(String.self, forKey: .lastDiscoveryDay),
            lastDiscoveryAt: try c.decodeIfPresent(Date.self, forKey: .lastDiscoveryAt),
            needsRecompute: try c.decodeIfPresent(Bool.self, forKey: .needsRecompute) ?? false,
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
    }
}

/// A dismissed pattern with the evidence it had when it was dismissed, so
/// Restore can bring back exactly what the person saw.
public struct DismissedPattern: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let evidence: FoundPattern
    public let dismissedAt: Date
    /// A deletion removed data the evidence counted. The dismissal stays, the old numbers do not come back.
    public var evidenceIsStale: Bool
    public let schemaVersion: Int

    public init(evidence: FoundPattern, dismissedAt: Date, evidenceIsStale: Bool = false, schemaVersion: Int = 1) {
        self.key = evidence.key
        self.evidence = evidence
        self.dismissedAt = dismissedAt
        self.evidenceIsStale = evidenceIsStale
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey { case key, evidence, dismissedAt, evidenceIsStale, schemaVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let evidence = try c.decode(FoundPattern.self, forKey: .evidence)
        self.init(evidence: evidence, dismissedAt: try c.decodeIfPresent(Date.self, forKey: .dismissedAt) ?? .distantPast,
                  evidenceIsStale: try c.decodeIfPresent(Bool.self, forKey: .evidenceIsStale) ?? false,
                  schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
    }
}

/// Source data the person deleted, in the words Patterns needs to know which found patterns used it.
public enum PatternSourceChange: Equatable, Sendable {
    /// A whole day, or a workout or meal on it. Every pattern whose evidence window holds the day used it.
    case day(String)
    /// One answer to one habit question on one day.
    case answer(habit: HabitID, day: String)
    /// A habit question and every answer to it.
    case habit(HabitID)
    /// Something was deleted and the day is unknown, so every found pattern may have used it.
    case anything

    /// Discovery reads 90 days of habit answers and 120 days of food answers back from the window's last day. The
    /// longer one is used, so a pattern that might have counted the day is always hidden.
    public static let evidenceDays = 120

    public func affects(_ pattern: FoundPattern) -> Bool {
        switch self {
        case .anything: return true
        case .habit(let habit): return pattern.habitID == habit
        case .answer(let habit, let day): return pattern.habitID == habit && Self.window(of: pattern, holds: day)
        case .day(let day): return Self.window(of: pattern, holds: day)
        }
    }

    /// A day one after the window's last day counts too, because the night after an exposed day is the outcome.
    private static func window(of pattern: FoundPattern, holds day: String) -> Bool {
        guard !pattern.windowEnd.isEmpty, let distance = PatternDays.distance(from: day, to: pattern.windowEnd) else { return true }
        return distance >= -1 && distance <= evidenceDays
    }
}

public struct WeeklyReview: Codable, Equatable, Identifiable, Sendable {
    public var id: String { weekStartDay }
    public let weekStartDay: String
    public let weekEndDay: String
    public let text: String
    /// Keys of the patterns the text mentions.
    public let patternKeys: [String]
    public let testIDs: [UUID]
    public let generatedAt: Date
    public let schemaVersion: Int

    public init(weekStartDay: String, weekEndDay: String, text: String, patternKeys: [String],
                testIDs: [UUID] = [], generatedAt: Date, schemaVersion: Int = 1) {
        self.weekStartDay = weekStartDay; self.weekEndDay = weekEndDay; self.text = text
        self.patternKeys = patternKeys; self.testIDs = testIDs; self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case weekStartDay, weekEndDay, text, patternKeys, testIDs, generatedAt, schemaVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(String.self, forKey: .weekStartDay)
        self.init(
            weekStartDay: start,
            weekEndDay: try c.decodeIfPresent(String.self, forKey: .weekEndDay) ?? PatternDays.add(6, to: start) ?? start,
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            patternKeys: try c.decodeIfPresent([String].self, forKey: .patternKeys) ?? [],
            testIDs: try c.decodeIfPresent([UUID].self, forKey: .testIDs) ?? [],
            generatedAt: try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast,
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1)
    }
}

/// Persistence for tests, found patterns, dismissals, reviews and settings.
public protocol PatternStore: Sendable {
    func tests() async throws -> [PatternTest]
    func test(id: UUID) async throws -> PatternTest?
    func saveTest(_ test: PatternTest) async throws
    func deleteTest(id: UUID) async throws

    /// Everything discovery found last, including dismissed and early patterns.
    func foundPatterns() async throws -> [FoundPattern]
    /// Found patterns that are not dismissed, strongest first.
    func visibleFoundPatterns() async throws -> [FoundPattern]
    /// Replaces the whole found list in one step. Use it after discovery and
    /// again after any source deletion, so nothing derived from removed data survives.
    func replaceFoundPatterns(_ patterns: [FoundPattern]) async throws
    /// Hides every found pattern that used the deleted data, marks the dismissals that counted it out of date,
    /// drops the weekly reviews that mention them, and flags that a recount is due. The deletion itself writes
    /// the same changes in its own transaction (`SQLitePatternStore.hideFoundPatterns(affectedBy:in:)`); this is
    /// the same step for a caller that has no transaction.
    func hideFoundPatterns(affectedBy change: PatternSourceChange) async throws

    func dismissedPatterns() async throws -> [DismissedPattern]
    func dismiss(_ pattern: FoundPattern, at date: Date) async throws
    /// Removes the dismissal and puts its evidence back in the found list when
    /// discovery has not produced a newer result for that key.
    @discardableResult func restore(key: String) async throws -> FoundPattern?

    func reviews() async throws -> [WeeklyReview]
    func review(weekStartDay: String) async throws -> WeeklyReview?
    func saveReview(_ review: WeeklyReview) async throws

    func settings() async throws -> PatternSettings
    func saveSettings(_ settings: PatternSettings) async throws

    /// Deletes found patterns and reviews, which are derived from source data, and keeps tests, settings and the
    /// person's dismissals. A dismissal's stored numbers are marked out of date, so Restore cannot bring them back.
    func clearDerived() async throws
    /// Deletes everything in the `patterns` namespace.
    func deleteAll() async throws
}

public extension PatternStore {
    func visibleFoundPatterns() async throws -> [FoundPattern] {
        let dismissed = Set(try await dismissedPatterns().map(\.key))
        return try await foundPatterns().filter { !dismissed.contains($0.key) }
    }
}

public actor InMemoryPatternStore: PatternStore {
    private var testRows: [UUID: PatternTest] = [:]
    private var foundRows: [String: FoundPattern] = [:]
    private var dismissedRows: [String: DismissedPattern] = [:]
    private var reviewRows: [String: WeeklyReview] = [:]
    private var storedSettings = PatternSettings()

    public init() {}

    public func tests() -> [PatternTest] {
        testRows.values.sorted { ($0.startDay, $0.id.uuidString) < ($1.startDay, $1.id.uuidString) }
    }
    public func test(id: UUID) -> PatternTest? { testRows[id] }
    public func saveTest(_ test: PatternTest) { testRows[test.id] = test }
    public func deleteTest(id: UUID) { testRows[id] = nil }

    public func foundPatterns() -> [FoundPattern] { PatternDiscoveryEngine.ordered(Array(foundRows.values)) }
    public func visibleFoundPatterns() -> [FoundPattern] {
        PatternDiscoveryEngine.ordered(foundRows.values.filter { dismissedRows[$0.key] == nil })
    }
    public func replaceFoundPatterns(_ patterns: [FoundPattern]) {
        foundRows = Dictionary(patterns.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for (key, dismissed) in dismissedRows where dismissed.evidenceIsStale {
            if let fresh = foundRows[key] {
                dismissedRows[key] = DismissedPattern(evidence: fresh, dismissedAt: dismissed.dismissedAt)
            }
        }
    }
    public func hideFoundPatterns(affectedBy change: PatternSourceChange) {
        let hidden = Set(foundRows.values.filter(change.affects).map(\.key))
        for key in hidden { foundRows[key] = nil }
        for (key, dismissed) in dismissedRows where change.affects(dismissed.evidence) { dismissedRows[key]?.evidenceIsStale = true }
        let affectedKeys = hidden.union(dismissedRows.filter { change.affects($0.value.evidence) }.keys)
        reviewRows = reviewRows.filter { Set($0.value.patternKeys).isDisjoint(with: affectedKeys) }
        if storedSettings.lookForNewPatterns { storedSettings.needsRecompute = true }
    }

    public func dismissedPatterns() -> [DismissedPattern] {
        dismissedRows.values.sorted { ($0.dismissedAt, $0.key) > ($1.dismissedAt, $1.key) }
    }
    public func dismiss(_ pattern: FoundPattern, at date: Date) {
        dismissedRows[pattern.key] = DismissedPattern(evidence: pattern, dismissedAt: date)
    }
    @discardableResult public func restore(key: String) -> FoundPattern? {
        guard let dismissed = dismissedRows.removeValue(forKey: key) else { return nil }
        // Numbers a deletion made out of date do not come back. The next look finds the pattern again, if it holds.
        if foundRows[key] == nil, !dismissed.evidenceIsStale { foundRows[key] = dismissed.evidence }
        return foundRows[key]
    }

    public func reviews() -> [WeeklyReview] { reviewRows.values.sorted { $0.weekStartDay > $1.weekStartDay } }
    public func review(weekStartDay: String) -> WeeklyReview? { reviewRows[weekStartDay] }
    public func saveReview(_ review: WeeklyReview) { reviewRows[review.weekStartDay] = review }

    public func settings() -> PatternSettings { storedSettings }
    public func saveSettings(_ settings: PatternSettings) { storedSettings = settings }

    public func clearDerived() {
        foundRows = [:]; reviewRows = [:]
        for key in dismissedRows.keys { dismissedRows[key]?.evidenceIsStale = true }
    }
    public func deleteAll() {
        testRows = [:]; storedSettings = PatternSettings(); clearDerived()
    }
}
