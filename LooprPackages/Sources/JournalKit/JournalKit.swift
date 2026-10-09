import Foundation

public struct JournalEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let day: String
    public var behaviors: Set<String>
    public var tags: Set<String>
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), day: String, behaviors: Set<String> = [], tags: Set<String> = [], note: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.day = day; self.behaviors = behaviors; self.tags = tags; self.note = note
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public struct JournalSearchQuery: Sendable, Equatable {
    public var text: String?
    public var tag: String?
    public var day: String?
    public init(text: String? = nil, tag: String? = nil, day: String? = nil) { self.text = text; self.tag = tag; self.day = day }
}

public struct JournalExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let entries: [JournalEntry]
    public let habitDefinitions: [HabitDefinition]
    public let habitDayRecords: [HabitDayRecord]
    public let includesJournalContent: Bool

    public init(
        schemaVersion: Int = 2,
        entries: [JournalEntry],
        habitDefinitions: [HabitDefinition] = [],
        habitDayRecords: [HabitDayRecord] = [],
        includesJournalContent: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.habitDefinitions = includesJournalContent ? habitDefinitions : []
        self.habitDayRecords = includesJournalContent ? habitDayRecords : []
        self.includesJournalContent = includesJournalContent
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, entries, habitDefinitions, habitDayRecords, includesJournalContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        entries = try container.decodeIfPresent([JournalEntry].self, forKey: .entries) ?? []
        habitDefinitions = try container.decodeIfPresent([HabitDefinition].self, forKey: .habitDefinitions) ?? []
        habitDayRecords = try container.decodeIfPresent([HabitDayRecord].self, forKey: .habitDayRecords) ?? []
        includesJournalContent = try container.decodeIfPresent(Bool.self, forKey: .includesJournalContent) ?? true
    }

    public func includingHabits(
        definitions: [HabitDefinition],
        dayRecords: [HabitDayRecord]
    ) -> JournalExport {
        JournalExport(
            schemaVersion: max(2, schemaVersion),
            entries: entries,
            habitDefinitions: definitions,
            habitDayRecords: dayRecords,
            includesJournalContent: includesJournalContent
        )
    }
}

public protocol JournalExportWriter: Sendable {
    func write(_ export: JournalExport) async throws -> URL
}

public struct JournalRestorePreview: Equatable, Sendable {
    public let entryCount: Int
    public let habitCount: Int
    public let dayCount: Int

    public init(entryCount: Int, habitCount: Int, dayCount: Int) {
        self.entryCount = entryCount
        self.habitCount = habitCount
        self.dayCount = dayCount
    }
}

public enum JournalRestoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema
    case contentMissing
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "This journal archive was created by a newer version of Loopr."
        case .contentMissing: "This archive does not include journal content."
        case .invalidArchive: "Loopr could not validate this journal archive."
        }
    }
}

public struct LocalJournalExportWriter: JournalExportWriter {
    public let directory: URL
    public let fileName: @Sendable () -> String

    public init(
        directory: URL = FileManager.default.temporaryDirectory,
        fileName: @escaping @Sendable () -> String = { "loopr-journal-\(UUID().uuidString).json" }
    ) {
        self.directory = directory
        self.fileName = fileName
    }

    public func write(_ export: JournalExport) async throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = directory.appendingPathComponent(fileName())
        try encoder.encode(export).write(to: url, options: .atomic)
        return url
    }
}

public struct JournalPrivacyPayload: Codable, Equatable, Sendable {
    public let entries: [JournalEntry]
    public let selectedEntryIDs: Set<UUID>
    public let habitDefinitions: [HabitDefinition]
    public let habitDayRecords: [HabitDayRecord]
    public let selectedHabitIDs: Set<HabitID>
    public let selectedDayRange: ClosedRange<String>?

    public init(
        entries: [JournalEntry] = [],
        selectedEntryIDs: Set<UUID> = [],
        habitDefinitions: [HabitDefinition] = [],
        habitDayRecords: [HabitDayRecord] = [],
        selectedHabitIDs: Set<HabitID> = [],
        selectedDayRange: ClosedRange<String>? = nil
    ) {
        self.entries = entries
        self.selectedEntryIDs = selectedEntryIDs
        self.habitDefinitions = habitDefinitions
        self.habitDayRecords = habitDayRecords
        self.selectedHabitIDs = selectedHabitIDs
        self.selectedDayRange = selectedDayRange
    }

    /// A crash/log/widget/watch snapshot never receives journal content.  AI
    /// context receives only entries explicitly selected by the user.
    public func forAIContext(
        selected: Set<UUID> = [],
        selectedHabits: Set<HabitID> = [],
        dayRange: ClosedRange<String>? = nil
    ) -> JournalPrivacyPayload {
        let selectedDefinitions = habitDefinitions.filter { selectedHabits.contains($0.id) }
        let selectedDays = habitDayRecords.compactMap { record -> HabitDayRecord? in
            guard dayRange?.contains(record.behaviorDay.habitKey) ?? true else { return nil }
            var selectedRecord = record
            selectedRecord.responses = record.responses.filter { selectedHabits.contains($0.habitID) }
            return selectedRecord.responses.isEmpty ? nil : selectedRecord
        }
        return JournalPrivacyPayload(
            entries: entries.filter { selected.contains($0.id) },
            selectedEntryIDs: selected,
            habitDefinitions: selectedDefinitions,
            habitDayRecords: selectedDays,
            selectedHabitIDs: selectedHabits,
            selectedDayRange: dayRange
        )
    }

    public func redactedForNonAI() -> JournalPrivacyPayload { JournalPrivacyPayload() }
}

public struct JournalProposal: Sendable, Equatable, Hashable {
    public let day: String
    public let tags: Set<String>
    public let note: String
    public init(day: String, tags: Set<String>, note: String) { self.day = day; self.tags = tags; self.note = note }
}

public enum JournalError: Error, Equatable, Sendable { case missingEntry, emptyDay, proposalNotReviewed }

/// Journal storage is injectable so production can use the local StorageKit
/// ledger while DEBUG previews can keep the in-memory implementation.
public protocol JournalStore: Sendable {
    func save(_ entry: JournalEntry) async throws -> JournalEntry
    func create(day: String, behaviors: Set<String>, tags: Set<String>, note: String?, id: UUID?, now: Date) async throws -> JournalEntry
    func edit(id: UUID, behaviors: Set<String>?, tags: Set<String>?, note: String??, now: Date) async throws -> JournalEntry
    func entry(id: UUID) async -> JournalEntry?
    func history(descending: Bool) async -> [JournalEntry]
    func search(_ query: JournalSearchQuery) async -> [JournalEntry]
    func delete(id: UUID) async throws
    func export(includeContent: Bool) async -> JournalExport
    func approve(_ proposal: JournalProposal) async
    func saveProposal(_ proposal: JournalProposal, accepted: Bool, now: Date) async throws -> JournalEntry?
    func redactedSnapshot() async -> JournalPrivacyPayload
    func deleteAll() async
}

public actor JournalRepository: JournalStore {
    private var rows: [UUID: JournalEntry] = [:]
    private var reviewedProposals: Set<JournalProposal> = []

    public init() {}

    @discardableResult
    public func save(_ entry: JournalEntry) throws -> JournalEntry {
        guard !entry.day.isEmpty else { throw JournalError.emptyDay }
        rows[entry.id] = entry
        return entry
    }

    @discardableResult
    public func create(day: String, behaviors: Set<String> = [], tags: Set<String> = [], note: String? = nil, id: UUID? = nil, now: Date = Date()) throws -> JournalEntry {
        let entry = JournalEntry(id: id ?? UUID(), day: day, behaviors: behaviors, tags: tags, note: note, createdAt: now)
        return try save(entry)
    }

    @discardableResult
    public func edit(id: UUID, behaviors: Set<String>? = nil, tags: Set<String>? = nil, note: String?? = nil, now: Date = Date()) throws -> JournalEntry {
        guard var entry = rows[id] else { throw JournalError.missingEntry }
        if let behaviors { entry.behaviors = behaviors }
        if let tags { entry.tags = tags }
        if let note { entry.note = note }
        entry.updatedAt = now
        rows[id] = entry
        return entry
    }

    public func entry(id: UUID) -> JournalEntry? { rows[id] }
    public func history(descending: Bool = true) -> [JournalEntry] {
        rows.values.sorted {
            let lhs = ($0.day, $0.updatedAt)
            let rhs = ($1.day, $1.updatedAt)
            return descending ? lhs > rhs : lhs < rhs
        }
    }

    public func search(_ query: JournalSearchQuery) -> [JournalEntry] {
        let needle = query.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history().filter { entry in
            if let day = query.day, entry.day != day { return false }
            if let tag = query.tag, !entry.tags.contains(tag) && !entry.behaviors.contains(tag) { return false }
            if let needle, !needle.isEmpty {
                let haystack = ([entry.day] + Array(entry.tags) + Array(entry.behaviors) + [entry.note ?? ""]).joined(separator: " ").lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }

    public func delete(id: UUID) throws {
        guard rows.removeValue(forKey: id) != nil else { throw JournalError.missingEntry }
    }

    public func export(includeContent: Bool) -> JournalExport {
        let entries = includeContent ? history(descending: false) : history(descending: false).map {
            JournalEntry(id: $0.id, day: $0.day, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        return JournalExport(entries: entries, includesJournalContent: includeContent)
    }

    public func approve(_ proposal: JournalProposal) { reviewedProposals.insert(proposal) }

    @discardableResult
    public func saveProposal(_ proposal: JournalProposal, accepted: Bool, now: Date = Date()) throws -> JournalEntry? {
        guard accepted, reviewedProposals.contains(proposal) else {
            if !accepted { return nil }
            throw JournalError.proposalNotReviewed
        }
        return try create(day: proposal.day, tags: proposal.tags, note: proposal.note, now: now)
    }

    public func redactedSnapshot() -> JournalPrivacyPayload { JournalPrivacyPayload().redactedForNonAI() }

    public func deleteAll() {
        rows.removeAll(keepingCapacity: true)
        reviewedProposals.removeAll(keepingCapacity: true)
    }
}

public struct JournalScreenSnapshot: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case loading, unavailable, error, empty, populated, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure }
    public let state: State
    public let entries: [JournalEntry]
    public init(state: State, entries: [JournalEntry] = []) { self.state = state; self.entries = entries }
}
