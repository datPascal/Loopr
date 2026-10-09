import Foundation
import DomainKit

public protocol HabitStore: Sendable {
    func definitions(includeArchived: Bool) async throws -> [HabitDefinition]
    func definition(id: HabitID) async throws -> HabitDefinition?
    func saveDefinition(_ definition: HabitDefinition) async throws
    func setArchived(_ archived: Bool, habitID: HabitID, at date: Date) async throws
    func deleteHabit(id: HabitID) async throws

    func dayRecord(for day: DayIdentity) async throws -> HabitDayRecord?
    func dayRecords() async throws -> [HabitDayRecord]
    func saveDayRecord(_ record: HabitDayRecord) async throws

    func outcome(for day: DayIdentity) async throws -> HabitOutcomeSnapshot?
    func outcomes() async throws -> [HabitOutcomeSnapshot]
    func saveOutcome(_ outcome: HabitOutcomeSnapshot) async throws
    func removeOutcome(for day: DayIdentity) async throws
    func outcomeExclusion(for day: DayIdentity) async throws -> HabitOutcomeExclusionRecord?
    func outcomeExclusions() async throws -> [HabitOutcomeExclusionRecord]
    func saveOutcomeExclusion(_ exclusion: HabitOutcomeExclusionRecord) async throws
    func removeOutcomeExclusion(for day: DayIdentity) async throws

    func estimate(for habitID: HabitID) async throws -> HabitImpactEstimate?
    func estimates() async throws -> [HabitImpactEstimate]
    func saveEstimate(_ estimate: HabitImpactEstimate) async throws

    func settings() async throws -> HabitSettings
    func saveSettings(_ settings: HabitSettings) async throws
    func todaySelection() async throws -> HabitTodaySelection?
    func saveTodaySelection(_ selection: HabitTodaySelection?) async throws
    func migrationReceipt() async throws -> HabitMigrationReceipt?
    func completeMigration(definitions: [HabitDefinition], dayRecords: [HabitDayRecord], receipt: HabitMigrationReceipt) async throws
    func replaceSourceRecords(definitions: [HabitDefinition], dayRecords: [HabitDayRecord]) async throws
    func deleteDerivedData() async throws
    func deleteAllHabitData() async throws
}

public actor InMemoryHabitStore: HabitStore {
    private var definitionRows: [HabitID: HabitDefinition]
    private var dayRows: [DayIdentity: HabitDayRecord]
    private var outcomeRows: [DayIdentity: HabitOutcomeSnapshot]
    private var outcomeExclusionRows: [DayIdentity: HabitOutcomeExclusionRecord]
    private var estimateRows: [HabitID: HabitImpactEstimate]
    private var storedSettings: HabitSettings
    private var storedTodaySelection: HabitTodaySelection?
    private var storedMigrationReceipt: HabitMigrationReceipt?

    public init(
        definitions: [HabitDefinition] = [],
        dayRecords: [HabitDayRecord] = [],
        outcomes: [HabitOutcomeSnapshot] = [],
        outcomeExclusions: [HabitOutcomeExclusionRecord] = [],
        estimates: [HabitImpactEstimate] = [],
        settings: HabitSettings = .init(),
        todaySelection: HabitTodaySelection? = nil,
        migrationReceipt: HabitMigrationReceipt? = nil
    ) {
        self.definitionRows = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        self.dayRows = Dictionary(uniqueKeysWithValues: dayRecords.map { ($0.behaviorDay, $0) })
        self.outcomeRows = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.behaviorDay, $0) })
        self.outcomeExclusionRows = Dictionary(uniqueKeysWithValues: outcomeExclusions.map { ($0.behaviorDay, $0) })
        self.estimateRows = Dictionary(uniqueKeysWithValues: estimates.map { ($0.habitID, $0) })
        self.storedSettings = settings
        self.storedTodaySelection = todaySelection
        self.storedMigrationReceipt = migrationReceipt
    }

    public func definitions(includeArchived: Bool = true) -> [HabitDefinition] {
        definitionRows.values
            .filter { includeArchived || !$0.isArchived }
            .sorted(by: Self.definitionOrder)
    }

    public func definition(id: HabitID) -> HabitDefinition? { definitionRows[id] }

    public func saveDefinition(_ definition: HabitDefinition) throws {
        try HabitStoreValidator.validate(definition: definition, existing: Array(definitionRows.values))
        definitionRows[definition.id] = definition
    }

    public func setArchived(_ archived: Bool, habitID: HabitID, at date: Date) throws {
        guard var definition = definitionRows[habitID] else { throw HabitStoreError.missingHabit }
        if !archived && definition.isArchived {
            let activeCount = definitionRows.values.filter { !$0.isArchived }.count
            guard activeCount < HabitStoreValidator.activeLimit else { throw HabitStoreError.activeLimitReached }
        }
        definition.archivedAt = archived ? date : nil
        definition.updatedAt = date
        definitionRows[habitID] = definition
    }

    public func deleteHabit(id: HabitID) throws {
        guard definitionRows.removeValue(forKey: id) != nil else { throw HabitStoreError.missingHabit }
        for (day, var record) in dayRows {
            record.responses.removeAll { $0.habitID == id }
            dayRows[day] = record
        }
        estimateRows[id] = nil
        if storedTodaySelection?.habitID == id { storedTodaySelection = nil }
    }

    public func dayRecord(for day: DayIdentity) -> HabitDayRecord? { dayRows[day] }

    public func dayRecords() -> [HabitDayRecord] {
        dayRows.values.sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    public func saveDayRecord(_ record: HabitDayRecord) throws {
        try HabitStoreValidator.validate(record: record, definitions: definitionRows)
        dayRows[record.behaviorDay] = record
    }

    public func outcome(for day: DayIdentity) -> HabitOutcomeSnapshot? { outcomeRows[day] }

    public func outcomes() -> [HabitOutcomeSnapshot] {
        outcomeRows.values.sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }

    public func saveOutcome(_ outcome: HabitOutcomeSnapshot) {
        outcomeRows[outcome.behaviorDay] = outcome
    }
    public func removeOutcome(for day: DayIdentity) { outcomeRows[day] = nil }
    public func outcomeExclusion(for day: DayIdentity) -> HabitOutcomeExclusionRecord? { outcomeExclusionRows[day] }
    public func outcomeExclusions() -> [HabitOutcomeExclusionRecord] {
        outcomeExclusionRows.values.sorted { $0.behaviorDay.habitKey < $1.behaviorDay.habitKey }
    }
    public func saveOutcomeExclusion(_ exclusion: HabitOutcomeExclusionRecord) {
        outcomeExclusionRows[exclusion.behaviorDay] = exclusion
    }
    public func removeOutcomeExclusion(for day: DayIdentity) { outcomeExclusionRows[day] = nil }

    public func estimate(for habitID: HabitID) -> HabitImpactEstimate? { estimateRows[habitID] }

    public func estimates() -> [HabitImpactEstimate] {
        estimateRows.values.sorted { $0.habitID < $1.habitID }
    }

    public func saveEstimate(_ estimate: HabitImpactEstimate) {
        estimateRows[estimate.habitID] = estimate
    }

    public func settings() -> HabitSettings { storedSettings }
    public func saveSettings(_ settings: HabitSettings) { storedSettings = settings }
    public func todaySelection() -> HabitTodaySelection? { storedTodaySelection }
    public func saveTodaySelection(_ selection: HabitTodaySelection?) { storedTodaySelection = selection }
    public func migrationReceipt() -> HabitMigrationReceipt? { storedMigrationReceipt }

    public func completeMigration(definitions: [HabitDefinition], dayRecords: [HabitDayRecord], receipt: HabitMigrationReceipt) throws {
        try HabitStoreValidator.validateRestore(definitions: definitions, records: dayRecords)
        definitionRows = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        dayRows = Dictionary(uniqueKeysWithValues: dayRecords.map { ($0.behaviorDay, $0) })
        storedMigrationReceipt = receipt
    }

    public func replaceSourceRecords(definitions: [HabitDefinition], dayRecords: [HabitDayRecord]) throws {
        try HabitStoreValidator.validateRestore(definitions: definitions, records: dayRecords)
        definitionRows = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        dayRows = Dictionary(uniqueKeysWithValues: dayRecords.map { ($0.behaviorDay, $0) })
        outcomeRows.removeAll()
        outcomeExclusionRows.removeAll()
        estimateRows.removeAll()
        storedTodaySelection = nil
    }

    public func deleteDerivedData() {
        outcomeRows.removeAll()
        outcomeExclusionRows.removeAll()
        estimateRows.removeAll()
        storedTodaySelection = nil
    }

    public func deleteAllHabitData() {
        definitionRows.removeAll()
        dayRows.removeAll()
        outcomeRows.removeAll()
        outcomeExclusionRows.removeAll()
        estimateRows.removeAll()
        storedSettings = HabitSettings()
        storedTodaySelection = nil
        storedMigrationReceipt = nil
    }

    private static func definitionOrder(_ lhs: HabitDefinition, _ rhs: HabitDefinition) -> Bool {
        if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id < rhs.id
    }
}

public enum HabitStoreValidator {
    public static let activeLimit = 10

    public static func validate(definition: HabitDefinition, existing: [HabitDefinition]) throws {
        guard definition.schemaVersion == 1,
              !definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !definition.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw HabitStoreError.invalidDefinition }
        guard definition.responseKind == .binary else { throw HabitStoreError.unsupportedResponseKind }

        let other = existing.filter { $0.id != definition.id }
        if case .preset(let catalogID) = definition.source,
           other.contains(where: {
               if case .preset(let existingID) = $0.source { return existingID == catalogID }
               return false
           }) {
            throw HabitStoreError.duplicatePreset
        }
        let activeCount = other.filter { !$0.isArchived }.count + (definition.isArchived ? 0 : 1)
        guard activeCount <= activeLimit else { throw HabitStoreError.activeLimitReached }
    }

    public static func validate(record: HabitDayRecord, definitions: [HabitID: HabitDefinition]) throws {
        guard record.schemaVersion == 1, isValid(day: record.behaviorDay) else { throw HabitStoreError.invalidDay }
        guard TimeZone(identifier: record.behaviorTimeZoneID) != nil else { throw HabitStoreError.timeZoneMismatch }
        let ids = record.responses.map(\.habitID)
        guard Set(ids).count == ids.count else { throw HabitStoreError.duplicateResponse }
        for response in record.responses {
            guard definitions[response.habitID] != nil else { throw HabitStoreError.missingHabit }
            guard response.behaviorDay == record.behaviorDay else { throw HabitStoreError.responseDayMismatch }
            guard response.behaviorTimeZoneID == record.behaviorTimeZoneID else { throw HabitStoreError.timeZoneMismatch }
        }
    }

    public static func validateRestore(definitions: [HabitDefinition], records: [HabitDayRecord]) throws {
        let ids = definitions.map(\.id)
        guard Set(ids).count == ids.count else { throw HabitStoreError.duplicateHabitID }
        guard definitions.filter({ !$0.isArchived }).count <= activeLimit else { throw HabitStoreError.activeLimitReached }
        var seenPresets = Set<String>()
        for definition in definitions {
            try validate(definition: definition, existing: definitions.filter { $0.id != definition.id })
            if case .preset(let catalogID) = definition.source {
                guard seenPresets.insert(catalogID).inserted else { throw HabitStoreError.duplicatePreset }
            }
        }
        let map = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let days = records.map(\.behaviorDay)
        guard Set(days).count == days.count else { throw HabitStoreError.invalidRestore }
        for record in records { try validate(record: record, definitions: map) }
    }

    private static func isValid(day: DayIdentity) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.era = day.era
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return resolved.era == day.era
            && resolved.year == day.year
            && resolved.month == day.month
            && resolved.day == day.day
    }
}

public struct HabitCheckInService: Sendable {
    private let store: any HabitStore
    private let dateProvider: any DateProviding

    public init(store: any HabitStore, dateProvider: any DateProviding = SystemDateProvider()) {
        self.store = store
        self.dateProvider = dateProvider
    }

    public func answer(
        habitID: HabitID,
        day: DayIdentity,
        timeZoneID: String,
        answer: HabitAnswer,
        source: HabitResponseSource
    ) async throws {
        guard try await store.definition(id: habitID) != nil else { throw HabitStoreError.missingHabit }
        let now = dateProvider.now()
        var record = try await store.dayRecord(for: day) ?? HabitDayRecord(
            behaviorDay: day,
            behaviorTimeZoneID: timeZoneID,
            createdAt: now
        )
        guard record.behaviorTimeZoneID == timeZoneID else { throw HabitStoreError.timeZoneMismatch }
        if let index = record.responses.firstIndex(where: { $0.habitID == habitID }) {
            record.responses[index].answer = answer
            record.responses[index].updatedAt = now
            record.responses[index].lastUpdateSource = source
        } else {
            record.responses.append(HabitResponse(
                habitID: habitID,
                behaviorDay: day,
                behaviorTimeZoneID: timeZoneID,
                answer: answer,
                firstAnsweredAt: now,
                firstAnswerSource: source
            ))
        }
        record.updatedAt = now
        try await store.saveDayRecord(record)
    }

    public func finish(day: DayIdentity) async throws {
        guard var record = try await store.dayRecord(for: day) else { return }
        let now = dateProvider.now()
        record.completedAt = now
        record.updatedAt = now
        try await store.saveDayRecord(record)
    }
}
