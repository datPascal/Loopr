import AIKit
import Foundation
import StorageKit
import DomainKit
import DesignSystem
import JournalKit
import OSLog
import WorkoutKit
import TodayKit
import HeartKit
import SleepKit
import CycleKit
import ProfileKit

actor SQLiteCoachConversationRepository: CoachConversationRepository {
    private let store: StorageDocumentStore
    private var deletedIDs: Set<UUID> = []
    init(database: StorageDatabase) throws { store = try StorageDocumentStore(database: database, namespace: "coach") }
    private static let logger = Logger(subsystem: "com.loopr.ios", category: "Coach")
    /// One chat that no longer decodes is skipped and logged, so it cannot lock the person out of
    /// the rest. The stored document is left as it is. A storage failure still throws.
    func conversations() throws -> [CoachConversation] {
        try store.keys().filter { $0.hasPrefix("chat.") }
            .compactMap { key -> CoachConversation? in
                do { return try store.read(CoachConversation.self, key: key) }
                catch is DecodingError {
                    Self.logger.error("Skipped a saved coach chat that could not be decoded: \(key, privacy: .public)")
                    return nil
                }
            }
            .map { var value = $0; value.recoverInterruptedReply(); return value }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ conversation: CoachConversation) throws {
        guard !deletedIDs.contains(conversation.id) else { return }
        let key = "chat.\(conversation.id.uuidString)"
        if let existing = try? store.read(CoachConversation.self, key: key), existing.updatedAt > conversation.updatedAt { return }
        try store.write(conversation, key: key)
    }
    func delete(id: UUID) throws { try store.remove(key: "chat.\(id.uuidString)"); deletedIDs.insert(id) }
    func preferences() throws -> CoachPreferences { try store.read(CoachPreferences.self, key: "chat-preferences") ?? .init() }
    func savePreferences(_ preferences: CoachPreferences) throws { try store.write(preferences, key: "chat-preferences") }
}

/// The summary text sent to the provider, plus how many of the last 30 days had saved measurements.
/// `daysWithData` is nil when health metrics are not shared or the source cannot tell.
struct LooprCoachSummary: Sendable, Equatable {
    var text: String
    var daysWithData: Int?
}

nonisolated protocol LooprCoachContextSource: Sendable {
    func summary(sharing: CoachSharing, at date: Date) async throws -> String
    /// Same text as `summary`, with coverage the consent sheet can report. Sources that cannot count days keep the default.
    func summaryResult(sharing: CoachSharing, at date: Date) async throws -> LooprCoachSummary
    func saveAdvice(message: CoachChatMessage, at date: Date) async throws -> UUID
}

extension LooprCoachContextSource {
    func summaryResult(sharing: CoachSharing, at date: Date) async throws -> LooprCoachSummary {
        LooprCoachSummary(text: try await summary(sharing: sharing, at: date), daysWithData: nil)
    }
}

actor LooprCoachContextBuilder: LooprCoachContextSource {
    private let repositories: PersistentProductRepositories
    /// Where Your data keeps its switches. Every summary is cut down to what they allow, whatever the caller
    /// asked for. Nil skips the check, for tests that build a summary with no Your data.
    private nonisolated(unsafe) let accessDefaults: UserDefaults?
    init(repositories: PersistentProductRepositories, accessDefaults: UserDefaults? = .standard) {
        self.repositories = repositories; self.accessDefaults = accessDefaults
    }
    func summary(sharing: CoachSharing, at date: Date) async throws -> String {
        try await summaryResult(sharing: sharing, at: date).text
    }
    func summaryResult(sharing requested: CoachSharing, at date: Date) async throws -> LooprCoachSummary {
        let sharing = accessDefaults.map { AgentAccessGate.effective(requested, defaults: $0) } ?? requested
        var daysWithData: Int?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let firstDay = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: date))!
        let earliest = Self.dayString(firstDay)
        let latest = Self.dayString(date)
        var lines = ["Health summary saved at \(date.ISO8601Format()).", "Calendar time zone: \(calendar.timeZone.identifier).", "Missing data means unknown, not zero."]
        if sharing.metrics {
            var averages: [String: [Double]] = [:]
            daysWithData = 0
            lines.append("Daily measurements for the last 14 calendar days, newest first:")
            for offset in 0..<30 {
                try Task.checkCancellation()
                let dayDate = calendar.date(byAdding: .day, value: -offset, to: date)!
                let components = calendar.dateComponents([.year, .month, .day], from: dayDate)
                let day = DayIdentity(year: components.year!, month: components.month!, day: components.day!)
                guard let display = try await repositories.analytics.readDisplay(day: day, reason: "coach-context") else {
                    if offset < 14 { lines.append("\(Self.dayString(dayDate)): no saved measurements.") }
                    continue
                }
                daysWithData = (daysWithData ?? 0) + 1
                let projection = display.projection
                var values: [String] = ["Freshness: \(display.today.freshness.state.title)"]
                if let latestRecord = projection.latestRecord { values.append("Latest source record: \(latestRecord.ISO8601Format())") }
                for metric in display.today.metrics {
                    if let value = metric.numericValue, value.isFinite {
                        values.append("\(metric.title): \(Self.number(value)) \(metric.unit), \(metric.state.title)")
                        if Self.usable(metric.state) { averages[metric.title + " " + metric.unit, default: []].append(value) }
                    }
                }
                for metric in projection.heart.metrics where [.restingHeartRate, .rmssd, .respiration].contains(metric.id) {
                    if let value = metric.numericValue, value.isFinite {
                        values.append("\(metric.title): \(Self.number(value)) \(metric.unit), \(metric.state.title)")
                        if Self.usable(metric.state) { averages[metric.title + " " + metric.unit, default: []].append(value) }
                    }
                }
                if let sleep = projection.sleep.mainSleep {
                    values.append("Sleep: \(sleep.durationMinutes) minutes, confidence \(Int(min(1, max(0, sleep.confidence)) * 100))%, partial night \(sleep.isPartial ? "yes" : "no")")
                }
                if let debt = projection.sleep.debtHours, debt.isFinite { values.append("Sleep debt estimate: \(Self.number(debt)) hours") }
                if offset < 14 { lines.append("\(Self.dayString(dayDate)): " + (values.isEmpty ? "no usable measurements" : values.joined(separator: "; "))) }
            }
            lines.append("Averages over available measurements in the last 30 calendar days. Counts show coverage:")
            for key in averages.keys.sorted() {
                let values = averages[key]!
                lines.append("\(key): \(Self.number(values.reduce(0, +) / Double(values.count))), \(values.count) days with data.")
            }
        } else { lines.append("Health metrics were not shared.") }
        if sharing.training {
            let workouts = await repositories.workouts.all().filter {
                guard let start = $0.startedAt, let end = $0.endedAt else { return false }
                return start >= firstDay && end <= date && !$0.isActive
            }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }.prefix(6)
            lines.append("Recent completed workouts within that window:")
            for workout in workouts {
                lines.append("\(Self.dayString(workout.startedAt!)): \(workout.activity.rawValue), \(Int((workout.duration ?? 0) / 60)) minutes, source \(workout.source.rawValue).")
            }
        }
        if sharing.metrics {
            let goals = try await repositories.profile.readGoals()
            if !goals.isEmpty {
                lines.append("Current goals:")
                for goal in goals where goal.isEnabled && goal.target.isFinite {
                    lines.append("\(goal.type.rawValue): \(Self.number(goal.target)) \(goal.unit)")
                }
            }
        }
        if sharing.journalAnswers || sharing.journalNotes {
            let entries = await repositories.journal.history().filter { $0.day >= earliest && $0.day <= latest }.prefix(30)
            lines.append("Journal entries explicitly shared for the last 30 days, up to 30 entries:")
            for entry in entries {
                var parts: [String] = []
                if sharing.journalAnswers {
                    parts.append("behaviors \(entry.behaviors.sorted().joined(separator: ", ")); tags \(entry.tags.sorted().joined(separator: ", "))")
                }
                if sharing.journalNotes { parts.append("note: \(String((entry.note ?? "").prefix(1000)))") }
                lines.append("\(entry.day): " + parts.joined(separator: "; "))
            }
        }
        if sharing.cycle {
            let entries = try await repositories.cycle.history().filter { $0.day >= earliest && $0.day <= latest }.prefix(30)
            lines.append("Cycle records explicitly shared for the last 30 days, up to 30 entries:")
            for entry in entries {
                lines.append("\(entry.day): \(entry.kind.rawValue), flow \(entry.flow?.rawValue ?? "not recorded"), symptoms \(entry.symptoms.sorted().joined(separator: ", ")); note: \(String((entry.note ?? "").prefix(500)))")
            }
        }
        return LooprCoachSummary(text: lines.joined(separator: "\n"), daysWithData: daysWithData)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) async throws -> UUID {
        let id = message.journalEntryID ?? message.id
        _ = try await repositories.journal.create(day: Self.dayString(date), tags: ["coach"],
            note: message.text, id: id, now: date)
        return id
    }
    nonisolated static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    nonisolated private static func number(_ number: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), number) }
    nonisolated private static func usable(_ state: MetricState) -> Bool { [.measuredZero, .partial, .settling].contains(state) }
}

nonisolated struct LooprCoachDataDeletionDeleter: PersistentDataDeletionDeleter {
    let storeName = "coach.runtime"
    func deleteAll() async throws {
        await CoachBriefingRuntime.shared.cancel()
        await CoachChatViewModel.resetAllForDeletion()
        await LooprAISettingsRuntime.shared.cancelRequests()
        await LooprAgentRuntime.shared.resetAfterDeletion()
        await LooprPatternsRuntime.shared.resetAfterDeletion()
    }
}
