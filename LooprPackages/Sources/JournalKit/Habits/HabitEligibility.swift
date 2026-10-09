import Foundation
import DomainKit

public enum HabitEligibility {
    public static let responseGracePeriod: TimeInterval = 48 * 60 * 60

    public static func deadline(
        for day: DayIdentity,
        timeZoneID: String,
        calendar: any CalendarProviding = SystemCalendarProvider()
    ) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneID) else { return nil }
        var components = DateComponents()
        components.era = day.era
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let start = calendar.date(from: components, in: timeZone),
              let end = calendar.date(byAdding: .day, value: 1, to: start, in: timeZone)
        else { return nil }
        return end.addingTimeInterval(responseGracePeriod)
    }

    public static func exclusion(
        for response: HabitResponse,
        calendar: any CalendarProviding = SystemCalendarProvider()
    ) -> HabitExclusionReason? {
        if response.firstAnswerSource == .legacyPresence { return .legacyPresence }
        if response.answer == .skipped { return .skipped }
        guard let deadline = deadline(
            for: response.behaviorDay,
            timeZoneID: response.behaviorTimeZoneID,
            calendar: calendar
        ) else { return .unresolvedTimeZone }
        return response.firstAnsweredAt <= deadline ? nil : .lateFirstEntry
    }

    public static func isEligible(
        _ response: HabitResponse,
        calendar: any CalendarProviding = SystemCalendarProvider()
    ) -> Bool {
        exclusion(for: response, calendar: calendar) == nil
    }
}

public struct HabitMigrationSuggestion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayText: String
    public let matchingEntryIDs: [UUID]
    public let matchedCatalogID: String?

    public init(displayText: String, matchingEntryIDs: [UUID], matchedCatalogID: String?) {
        self.id = HabitCatalog.normalize(displayText)
        self.displayText = displayText
        self.matchingEntryIDs = matchingEntryIDs.sorted { $0.uuidString < $1.uuidString }
        self.matchedCatalogID = matchedCatalogID
    }
}

public enum HabitLegacyMigration {
    public static func suggestions(from entries: [JournalEntry]) -> [HabitMigrationSuggestion] {
        var grouped: [String: (display: String, ids: Set<UUID>)] = [:]
        for entry in entries {
            for value in entry.tags.union(entry.behaviors) {
                let normalized = HabitCatalog.normalize(value)
                guard !normalized.isEmpty else { continue }
                var row = grouped[normalized] ?? (value.trimmingCharacters(in: .whitespacesAndNewlines), [])
                row.ids.insert(entry.id)
                grouped[normalized] = row
            }
        }
        return grouped.values.map { row in
            let match = HabitCatalog.exactMatch(row.display)
            return HabitMigrationSuggestion(
                displayText: row.display,
                matchingEntryIDs: Array(row.ids),
                matchedCatalogID: match?.id
            )
        }.sorted { $0.displayText.localizedCaseInsensitiveCompare($1.displayText) == .orderedAscending }
    }

    public static func buildApprovedRecords(
        suggestions: [HabitMigrationSuggestion],
        approvedIDs: Set<String>,
        entries: [JournalEntry],
        existingDefinitions: [HabitDefinition],
        now: Date,
        uuid: @Sendable () -> UUID
    ) throws -> (definitions: [HabitDefinition], days: [HabitDayRecord]) {
        var definitions = existingDefinitions
        var days: [DayIdentity: HabitDayRecord] = [:]
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for suggestion in suggestions where approvedIDs.contains(suggestion.id) {
            let item = suggestion.matchedCatalogID.flatMap { HabitCatalog.byID[$0] }
            let definition = HabitDefinition(
                id: HabitID(rawValue: uuid()),
                source: item.map { .preset(catalogID: $0.id) } ?? .custom,
                name: item?.name ?? suggestion.displayText,
                question: item?.question ?? "Did \(suggestion.displayText.lowercased()) happen?",
                sortOrder: definitions.count,
                createdAt: now
            )
            definitions.append(definition)
            for entryID in suggestion.matchingEntryIDs {
                guard let entry = entriesByID[entryID], let day = DayIdentity(habitKey: entry.day) else { continue }
                let timeZoneID = TimeZone.current.identifier
                var record = days[day] ?? HabitDayRecord(
                    behaviorDay: day,
                    behaviorTimeZoneID: timeZoneID,
                    createdAt: entry.createdAt
                )
                record.responses.append(HabitResponse(
                    habitID: definition.id,
                    behaviorDay: day,
                    behaviorTimeZoneID: timeZoneID,
                    answer: .yes,
                    firstAnsweredAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    firstAnswerSource: .legacyPresence,
                    lastUpdateSource: .legacyPresence
                ))
                record.updatedAt = max(record.updatedAt, entry.updatedAt)
                days[day] = record
            }
        }
        try HabitStoreValidator.validateRestore(definitions: definitions, records: Array(days.values))
        return (definitions, Array(days.values))
    }
}

public struct HabitMigrationCoordinator: Sendable {
    private let journalStore: any JournalStore
    private let habitStore: any HabitStore
    private let dateProvider: any DateProviding
    private let uuidProvider: any UUIDProviding

    public init(
        journalStore: any JournalStore,
        habitStore: any HabitStore,
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        self.journalStore = journalStore
        self.habitStore = habitStore
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
    }

    public func pendingSuggestions() async throws -> [HabitMigrationSuggestion] {
        guard try await habitStore.migrationReceipt() == nil else { return [] }
        return HabitLegacyMigration.suggestions(from: await journalStore.history(descending: false))
    }

    public func complete(approvedSuggestionIDs: Set<String>) async throws {
        guard try await habitStore.migrationReceipt() == nil else { return }
        let entries = await journalStore.history(descending: false)
        let suggestions = HabitLegacyMigration.suggestions(from: entries)
        let approved = suggestions.filter { approvedSuggestionIDs.contains($0.id) }
        let now = dateProvider.now()
        var definitions = try await habitStore.definitions(includeArchived: true)
        var recordsByDay = Dictionary(uniqueKeysWithValues: try await habitStore.dayRecords().map { ($0.behaviorDay, $0) })
        var mappings: [String: HabitID] = [:]

        for suggestion in approved {
            guard definitions.filter({ !$0.isArchived }).count < HabitStoreValidator.activeLimit else {
                throw HabitStoreError.activeLimitReached
            }
            let id = HabitID(rawValue: await uuidProvider.nextUUID())
            mappings[suggestion.id] = id
            let item = suggestion.matchedCatalogID.flatMap { HabitCatalog.byID[$0] }
            let definition = HabitDefinition(
                id: id,
                source: item.map { .preset(catalogID: $0.id) } ?? .custom,
                name: item?.name ?? suggestion.displayText,
                question: item?.question ?? "Did \(suggestion.displayText.lowercased()) happen?",
                sortOrder: definitions.filter { !$0.isArchived }.count,
                createdAt: now
            )
            definitions.append(definition)
            let matchingIDs = Set(suggestion.matchingEntryIDs)
            for entry in entries where matchingIDs.contains(entry.id) {
                guard let day = DayIdentity(habitKey: entry.day) else { continue }
                let timeZoneID = TimeZone.current.identifier
                var record = recordsByDay[day] ?? HabitDayRecord(
                    behaviorDay: day,
                    behaviorTimeZoneID: timeZoneID,
                    createdAt: entry.createdAt
                )
                guard record.response(for: id) == nil else { continue }
                record.responses.append(HabitResponse(
                    habitID: id,
                    behaviorDay: day,
                    behaviorTimeZoneID: record.behaviorTimeZoneID,
                    answer: .yes,
                    firstAnsweredAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    firstAnswerSource: .legacyPresence,
                    lastUpdateSource: .legacyPresence
                ))
                recordsByDay[day] = record
            }
        }
        let receipt = HabitMigrationReceipt(completedAt: now, approvedMappings: mappings)
        try await habitStore.completeMigration(
            definitions: definitions,
            dayRecords: Array(recordsByDay.values),
            receipt: receipt
        )
    }
}
