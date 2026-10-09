import Combine
import Foundation
import DomainKit

@MainActor
public final class HabitViewModel: ObservableObject {
    @Published public private(set) var definitions: [HabitDefinition] = []
    @Published public private(set) var records: [HabitDayRecord] = []
    @Published public private(set) var estimates: [HabitImpactEstimate] = []
    @Published public private(set) var settings = HabitSettings()
    @Published public private(set) var migrationSuggestions: [HabitMigrationSuggestion] = []
    @Published public private(set) var isLoading = true
    @Published public private(set) var errorMessage: String?

    public let store: any HabitStore
    private let dateProvider: any DateProviding
    private let calendarProvider: any CalendarProviding
    private let timeZoneProvider: any TimeZoneProviding
    private let uuidProvider: any UUIDProviding
    private let journalStore: (any JournalStore)?
    private let reminderScheduler: any HabitReminderScheduling
    private let featureStageOverride: HabitFeatureStage?

    public init(
        store: any HabitStore,
        dateProvider: any DateProviding = SystemDateProvider(),
        calendarProvider: any CalendarProviding = SystemCalendarProvider(),
        timeZoneProvider: any TimeZoneProviding = SystemTimeZoneProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider(),
        journalStore: (any JournalStore)? = nil,
        reminderScheduler: any HabitReminderScheduling = NoOpHabitReminderScheduler(),
        featureStageOverride: HabitFeatureStage? = nil
    ) {
        self.store = store
        self.dateProvider = dateProvider
        self.calendarProvider = calendarProvider
        self.timeZoneProvider = timeZoneProvider
        self.uuidProvider = uuidProvider
        self.journalStore = journalStore
        self.reminderScheduler = reminderScheduler
        self.featureStageOverride = featureStageOverride
    }

    public var activeDefinitions: [HabitDefinition] { definitions.filter { !$0.isArchived } }

    public var currentDay: DayIdentity {
        DayBoundaryCalculator.boundary(
            containing: dateProvider.now(),
            calendar: calendarProvider,
            timeZone: timeZoneProvider.timeZone
        )?.identity ?? DayIdentity(year: 1970, month: 1, day: 1)
    }

    public var previousDay: DayIdentity {
        shift(currentDay, by: -1) ?? currentDay
    }

    public func load() async {
        isLoading = true
        do {
            async let loadedDefinitions = store.definitions(includeArchived: true)
            async let loadedRecords = store.dayRecords()
            async let loadedEstimates = store.estimates()
            async let loadedSettings = store.settings()
            definitions = try await loadedDefinitions
            records = try await loadedRecords
            estimates = HabitInsightOrdering.sorted(
                estimates: try await loadedEstimates,
                definitions: definitions
            )
            settings = try await loadedSettings
            if let featureStageOverride { settings.featureStage = featureStageOverride }
            if let journalStore {
                migrationSuggestions = try await HabitMigrationCoordinator(
                    journalStore: journalStore,
                    habitStore: store,
                    dateProvider: dateProvider,
                    uuidProvider: uuidProvider
                ).pendingSuggestions()
            } else {
                migrationSuggestions = []
            }
            errorMessage = nil
            if settings.featureStage.exposesEntryPoints,
               settings.reminderEnabled, !activeDefinitions.isEmpty,
               record(for: previousDay)?.completedAt == nil {
                try await reminderScheduler.update(
                    settings: settings,
                    activeHabitCount: activeDefinitions.count,
                    behaviorDay: previousDay
                )
            } else {
                try await reminderScheduler.cancel()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func addPreset(_ item: HabitCatalogItem) async {
        guard !definitions.contains(where: {
            if case .preset(let catalogID) = $0.source { return catalogID == item.id }
            return false
        }) else { return }
        await saveNewDefinition(name: item.name, question: item.question, source: .preset(catalogID: item.id))
    }

    public func createCustom(name: String, question: String) async {
        await saveNewDefinition(name: name, question: question, source: .custom)
    }

    public func rename(_ definition: HabitDefinition, name: String, question: String) async {
        var output = definition
        output.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        output.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        output.updatedAt = dateProvider.now()
        do {
            try await store.saveDefinition(output)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func setArchived(_ archived: Bool, definition: HabitDefinition) async {
        do {
            try await store.setArchived(archived, habitID: definition.id, at: dateProvider.now())
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func delete(_ definition: HabitDefinition) async {
        do {
            try await store.deleteHabit(id: definition.id)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func answer(_ answer: HabitAnswer, habitID: HabitID, day: DayIdentity, source: HabitResponseSource) async {
        do {
            try await HabitCheckInService(store: store, dateProvider: dateProvider).answer(
                habitID: habitID,
                day: day,
                timeZoneID: timeZoneProvider.timeZone.identifier,
                answer: answer,
                source: source
            )
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func finish(day: DayIdentity) async {
        do {
            try await HabitCheckInService(store: store, dateProvider: dateProvider).finish(day: day)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    public func record(for day: DayIdentity) -> HabitDayRecord? {
        records.first { $0.behaviorDay == day }
    }

    public func estimate(for habitID: HabitID) -> HabitImpactEstimate? {
        estimates.first { $0.habitID == habitID }
    }

    public func definition(for habitID: HabitID) -> HabitDefinition? {
        definitions.first { $0.id == habitID }
    }

    public func completion(for day: DayIdentity) -> (answered: Int, total: Int) {
        let answered = record(for: day)?.responses.filter { response in
            activeDefinitions.contains { $0.id == response.habitID }
        }.count ?? 0
        return (answered, activeDefinitions.count)
    }

    public func clearError() { errorMessage = nil }

    public func updateReminder(enabled: Bool, hour: Int, minute: Int) async {
        var output = settings
        output.reminderEnabled = enabled
        output.reminderHour = min(23, max(0, hour))
        output.reminderMinute = min(59, max(0, minute))
        do {
            try await store.saveSettings(output)
            if output.featureStage.exposesEntryPoints, enabled && !activeDefinitions.isEmpty {
                try await reminderScheduler.update(
                    settings: output,
                    activeHabitCount: activeDefinitions.count,
                    behaviorDay: previousDay
                )
            } else {
                try await reminderScheduler.cancel()
            }
            settings = output
        } catch { errorMessage = error.localizedDescription }
    }

    public func completeMigration(approvedSuggestionIDs: Set<String>) async {
        guard let journalStore else { return }
        do {
            try await HabitMigrationCoordinator(
                journalStore: journalStore,
                habitStore: store,
                dateProvider: dateProvider,
                uuidProvider: uuidProvider
            ).complete(approvedSuggestionIDs: approvedSuggestionIDs)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveNewDefinition(name: String, question: String, source: HabitDefinitionSource) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = dateProvider.now()
        let definition = HabitDefinition(
            id: HabitID(rawValue: await uuidProvider.nextUUID()),
            source: source,
            name: trimmedName,
            question: trimmedQuestion,
            sortOrder: activeDefinitions.count,
            createdAt: now
        )
        do {
            try await store.saveDefinition(definition)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func shift(_ day: DayIdentity, by value: Int) -> DayIdentity? {
        let timeZone = timeZoneProvider.timeZone
        var components = DateComponents()
        components.era = day.era
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let date = calendarProvider.date(from: components, in: timeZone),
              let shifted = calendarProvider.date(byAdding: .day, value: value, to: date, in: timeZone) else { return nil }
        let output = calendarProvider.components(in: timeZone, from: shifted)
        guard let year = output.year, let month = output.month, let day = output.day else { return nil }
        return DayIdentity(era: output.era ?? 1, year: year, month: month, day: day)
    }
}

public enum HabitFixtures {
    public static let now = Date(timeIntervalSince1970: 1_785_680_000)
    public static let day = DayIdentity(year: 2026, month: 8, day: 29)
    public static let definition = HabitDefinition(
        id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000a01")!),
        source: .preset(catalogID: "short_video_before_bed"),
        name: "Short videos before bed",
        question: "Scrolled short videos in the final hour before sleep?",
        sortOrder: 0,
        createdAt: now
    )

    public static let overlappingDefinition = HabitDefinition(
        id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000a02")!),
        source: .preset(catalogID: "screen_before_bed"),
        name: "Screen before bed",
        question: "Used a screen in the final hour before sleep?",
        sortOrder: 1,
        createdAt: now
    )

    public static func estimate(status: HabitInsightStatus) -> HabitImpactEstimate {
        let clear = status == .clearAssociation
        let recovery = HabitMetricEstimate(
            metricID: .recoveryScore,
            yesMean: status == .collecting ? nil : 68,
            noMean: status == .collecting ? nil : 76,
            rawDifference: status == .collecting ? nil : -8,
            adjustedDifference: clear || status == .stale ? -7.2 : status == .noClearAssociation ? -1.1 : nil,
            intervalLower: clear || status == .stale ? -11 : status == .noClearAssociation ? -5 : nil,
            intervalUpper: clear || status == .stale ? -3.5 : status == .noClearAssociation ? 2.8 : nil,
            adjustedRowCount: clear || status == .noClearAssociation ? 32 : 0,
            isClear: clear
        )
        let sleepDuration = HabitMetricEstimate(
            metricID: .sleepDuration,
            yesMean: status == .collecting ? nil : 401,
            noMean: status == .collecting ? nil : 432,
            rawDifference: status == .collecting ? nil : -31,
            adjustedDifference: status == .noClearAssociation || clear ? -29.4 : nil,
            intervalLower: status == .noClearAssociation || clear ? -45 : nil,
            intervalUpper: status == .noClearAssociation || clear ? -16 : nil,
            adjustedRowCount: status == .noClearAssociation || clear ? 32 : 0,
            isClear: status == .noClearAssociation || clear
        )
        let exclusions: [HabitExclusion] = status == .unavailable
            ? [.init(day: DayIdentity(year: 2026, month: 8, day: 28), reason: .missingMainSleep)]
            : [
                .init(day: DayIdentity(year: 2026, month: 8, day: 24), reason: .skipped),
                .init(day: DayIdentity(year: 2026, month: 8, day: 25), reason: .lateFirstEntry)
            ]
        return HabitImpactEstimate(
            habitID: definition.id,
            status: status,
            yesCount: status == .collecting ? 3 : status == .earlySignal ? 6 : 16,
            noCount: status == .collecting ? 2 : status == .earlySignal ? 7 : 18,
            eligibleDayCount: status == .collecting ? 5 : status == .earlySignal ? 13 : 34,
            excludedDayCount: exclusions.count,
            metrics: [recovery, sleepDuration],
            exclusions: exclusions,
            overlappingHabitID: status == .cannotSeparate ? overlappingDefinition.id : nil,
            windowStart: DayIdentity(year: 2026, month: 6, day: 1),
            windowEnd: day,
            calculatedAt: now,
            lastValidEstimate: status == .stale
                ? HabitLastValidEstimate(
                    validThrough: DayIdentity(year: 2026, month: 8, day: 22),
                    recovery: recovery
                )
                : nil
        )
    }

    public static let allInsightStates = HabitInsightStatus.allCases.map(estimate(status:))

    public static let dayRecords: [HabitDayRecord] = [
        record(day: 18, answer: .yes, completed: true),
        record(day: 19, answer: .no, completed: true),
        record(day: 20, answer: .yes, completed: true),
        record(day: 21, answer: .no, completed: true),
        record(day: 22, answer: .yes, completed: true),
        record(day: 23, answer: .no, completed: true),
        record(day: 24, answer: .skipped, completed: true),
        record(day: 25, answer: .yes, completed: false),
        record(day: 26, answer: .no, completed: true),
        record(day: 27, answer: .yes, completed: true),
        record(day: 28, answer: .no, completed: true),
        record(day: 29, answer: .yes, completed: false)
    ]

    public static func store(status: HabitInsightStatus = .collecting) -> InMemoryHabitStore {
        InMemoryHabitStore(
            definitions: [definition, overlappingDefinition],
            dayRecords: dayRecords,
            estimates: [estimate(status: status)]
        )
    }

    private static func record(day: Int, answer: HabitAnswer, completed: Bool) -> HabitDayRecord {
        let identity = DayIdentity(year: 2026, month: 8, day: day)
        let response = HabitResponse(
            habitID: definition.id,
            behaviorDay: identity,
            behaviorTimeZoneID: "Asia/Bangkok",
            answer: answer,
            firstAnsweredAt: now,
            firstAnswerSource: .morningCheckIn
        )
        return HabitDayRecord(
            behaviorDay: identity,
            behaviorTimeZoneID: "Asia/Bangkok",
            responses: [response],
            completedAt: completed ? now : nil,
            createdAt: now
        )
    }
}
