import Foundation

public enum CycleEventKind: String, Codable, CaseIterable, Sendable {
    case periodStart
    case flow
    case symptom

    public var displayName: String {
        switch self {
        case .periodStart: "Period start"
        case .flow: "Flow"
        case .symptom: "Symptom"
        }
    }
}

public enum FlowLevel: String, Codable, CaseIterable, Sendable { case spotting, light, medium, heavy }

public struct CycleEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let day: String
    public let kind: CycleEventKind
    public let flow: FlowLevel?
    public let symptoms: Set<String>
    public let note: String?
    public let createdAt: Date
    public init(id: UUID = UUID(), day: String, kind: CycleEventKind, flow: FlowLevel? = nil, symptoms: Set<String> = [], note: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.day = day; self.kind = kind; self.flow = flow; self.symptoms = symptoms; self.note = note; self.createdAt = createdAt
    }
}

public enum CyclePhase: String, Codable, CaseIterable, Sendable { case unknown, menstrual, follicular, fertile, ovulatory, luteal }

public struct CycleEstimate: Codable, Equatable, Sendable {
    public let phase: CyclePhase
    public let nextPeriodDay: String?
    public let fertileWindow: ClosedRange<String>?
    public let ovulationDay: String?
    public let confidence: Double
    public let uncertainty: String
    public let sampleSize: Int

    public var isAvailable: Bool { phase != .unknown || nextPeriodDay != nil }
    public init(phase: CyclePhase, nextPeriodDay: String? = nil, fertileWindow: ClosedRange<String>? = nil, ovulationDay: String? = nil, confidence: Double, uncertainty: String, sampleSize: Int) {
        self.phase = phase; self.nextPeriodDay = nextPeriodDay; self.fertileWindow = fertileWindow; self.ovulationDay = ovulationDay; self.confidence = confidence; self.uncertainty = uncertainty; self.sampleSize = sampleSize
    }
}

public struct CycleSettings: Codable, Equatable, Sendable {
    public var remindersEnabled: Bool
    public var reminderHour: Int?
    public init(remindersEnabled: Bool = false, reminderHour: Int? = nil) { self.remindersEnabled = remindersEnabled; self.reminderHour = reminderHour }
}

public enum CycleState: String, Codable, CaseIterable, Sendable {
    case optedOut, optedIn, unavailable, loading, error, empty, populated, disabled
}

public enum CycleError: Error, Equatable, Sendable, LocalizedError {
    case optedOut
    case invalidDay
    case missingEntry
    case invalidReminderHour
    /// The user or system denied local notification delivery. The setting is
    /// not persisted when this error is returned.
    case reminderDenied
    case reminderUnavailable
    case reminderCleanupFailed
    case reminderRestoreFailed
    case storageUnavailable
    case exportUnavailable

    public var errorDescription: String? {
        switch self {
        case .optedOut:
            "Cycle tracking is not enabled."
        case .invalidDay:
            "Use a calendar day in YYYY-MM-DD format."
        case .missingEntry:
            "That cycle entry is no longer available."
        case .invalidReminderHour:
            "Choose a reminder hour from 0 through 23."
        case .reminderDenied:
            "Notifications are disabled for Loopr. Enable them in Settings to use reminders."
        case .reminderUnavailable:
            "Local reminders are unavailable on this device."
        case .reminderCleanupFailed:
            "Loopr couldn't remove the reminder. Check Loopr's notification settings."
        case .reminderRestoreFailed:
            "Loopr couldn't restore the reminder. Check your cycle reminder settings."
        case .storageUnavailable:
            "Loopr couldn't access your cycle data. Try again."
        case .exportUnavailable:
            "Loopr couldn't prepare the export. Try again."
        }
    }
}

public struct CycleExport: Codable, Equatable, Sendable {
    public let entries: [CycleEntry]
    public let settings: CycleSettings
    public init(entries: [CycleEntry], settings: CycleSettings) { self.entries = entries; self.settings = settings }
}

public protocol CycleReminderScheduler: Sendable {
    func schedule(settings: CycleSettings) async throws
    func cancel() async throws
}

/// Notification authorization and delivery remain app-owned. This adapter is
/// intentionally unavailable until NotificationKit supplies a verified
/// scheduler; enabling reminders therefore never pretends that a notification
/// was registered.
public struct UnavailableCycleReminderScheduler: CycleReminderScheduler {
    public init() {}
    public func schedule(settings: CycleSettings) async throws { throw CycleError.reminderUnavailable }
    public func cancel() async throws {}
}

public protocol CycleExportWriter: Sendable {
    func write(_ export: CycleExport) async throws -> URL
}

public struct LocalCycleExportWriter: CycleExportWriter {
    public let directory: URL
    public let fileName: @Sendable () -> String

    public init(
        directory: URL = FileManager.default.temporaryDirectory,
        fileName: @escaping @Sendable () -> String = { "loopr-cycle-\(UUID().uuidString).json" }
    ) {
        self.directory = directory
        self.fileName = fileName
    }

    public func write(_ export: CycleExport) async throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(export)
        let url = directory.appendingPathComponent(fileName())
        try data.write(to: url, options: .atomic)
        return url
    }
}

public protocol CycleStore: Sendable {
    func state() async throws -> CycleState
    func isOptedIn() async throws -> Bool
    func optIn() async throws
    func disable() async throws
    func enableAfterDisable() async throws
    func deleteAll() async throws
    func log(_ entry: CycleEntry) async throws -> CycleEntry
    func history() async throws -> [CycleEntry]
    func delete(id: UUID) async throws
    func updateSettings(_ newValue: CycleSettings) async throws
    func currentSettings() async throws -> CycleSettings
    func estimate(today: String?) async throws -> CycleEstimate
    func export() async throws -> CycleExport
}

public actor CycleRepository: CycleStore {
    private var enabled = false
    private var disabled = false
    private var entries: [UUID: CycleEntry] = [:]
    private var settings = CycleSettings()

    public init(enabled: Bool = false, entries: [CycleEntry] = []) {
        self.enabled = enabled
        for entry in entries { self.entries[entry.id] = entry }
    }
    public func state() -> CycleState { enabled ? (disabled ? .disabled : (entries.isEmpty ? .optedIn : .populated)) : .optedOut }
    public func isOptedIn() -> Bool { enabled && !disabled }
    public func optIn() { enabled = true; disabled = false }
    /// Disable removes the feature from navigation and stops future logging,
    /// while preserving history until the user explicitly deletes it.
    public func disable() { guard enabled else { return }; disabled = true }
    public func enableAfterDisable() throws { guard enabled else { throw CycleError.optedOut }; disabled = false }
    public func deleteAll() { entries.removeAll(); enabled = false; disabled = false; settings = CycleSettings() }

    @discardableResult
    public func log(_ entry: CycleEntry) throws -> CycleEntry {
        guard enabled && !disabled else { throw CycleError.optedOut }
        guard entry.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CycleError.invalidDay }
        entries[entry.id] = entry
        return entry
    }

    public func history() -> [CycleEntry] { entries.values.sorted { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) } }
    public func delete(id: UUID) throws { guard entries.removeValue(forKey: id) != nil else { throw CycleError.missingEntry } }
    public func updateSettings(_ newValue: CycleSettings) throws { guard enabled else { throw CycleError.optedOut }; settings = newValue }
    public func currentSettings() -> CycleSettings { settings }

    public func estimate(today: String? = nil) -> CycleEstimate {
        guard enabled, !disabled else { return CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Cycle tracking is not enabled.", sampleSize: 0) }
        let starts = history().filter { $0.kind == .periodStart }.map(\.day).compactMap(CycleDate.parse).sorted()
        guard let latest = starts.last else { return CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "Log a period start to begin; no phase is inferred.", sampleSize: 0) }
        let lengths = zip(starts, starts.dropFirst()).map { CycleDate.days(from: $0, to: $1) }.filter { $0 > 0 }
        let typical = lengths.isEmpty ? 28.0 : Double(lengths.sorted()[lengths.count / 2])
        let variation = lengths.isEmpty ? 0 : lengths.map { abs(Double($0) - typical) }.reduce(0, +) / Double(lengths.count)
        let irregular = variation > 5 || lengths.contains(where: { $0 < 15 || $0 > 60 })
        let uncertainty: String
        if lengths.isEmpty {
            uncertainty = "Only one period start is logged. Loopr is assuming a 28-day cycle, so this date is a placeholder."
        } else if irregular {
            uncertainty = "Irregular history; dates are broad estimates, not a medical prediction."
        } else {
            uncertainty = "Estimate from logged period starts; dates may vary."
        }
        let sampleSize = starts.count
        let baseConfidence = min(1, Double(sampleSize) / 3)
        let confidence = irregular ? baseConfidence * 0.45 : baseConfidence
        let reference = today.flatMap(CycleDate.parse) ?? latest
        let elapsed = max(0, CycleDate.days(from: latest, to: reference))
        let cycleDay = elapsed + 1
        let phase: CyclePhase
        switch cycleDay {
        case 1...5: phase = .menstrual
        case 6...13: phase = .follicular
        case 14...16: phase = .ovulatory
        case 17...21: phase = .luteal
        default: phase = .luteal
        }
        let next = CycleDate.adding(days: Int(typical.rounded()), to: latest)
        let ovulation = CycleDate.adding(days: max(1, Int(typical.rounded()) - 14), to: latest)
        let fertileStart = CycleDate.adding(days: max(1, Int(typical.rounded()) - 18), to: latest)
        let fertileEnd = CycleDate.adding(days: max(1, Int(typical.rounded()) - 12), to: latest)
        return CycleEstimate(phase: phase, nextPeriodDay: next, fertileWindow: fertileStart...fertileEnd, ovulationDay: ovulation, confidence: confidence, uncertainty: uncertainty, sampleSize: sampleSize)
    }

    public func export() -> CycleExport { CycleExport(entries: history(), settings: settings) }
}

public enum CycleDate {
    private static func calendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    public static func parse(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let date = calendar().date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
        guard let date, string(date) == value else { return nil }
        return date
    }

    public static func string(_ value: Date) -> String {
        let components = calendar().dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func days(from start: Date, to end: Date) -> Int {
        calendar().dateComponents([.day], from: start, to: end).day ?? 0
    }

    public static func adding(days: Int, to date: Date) -> String {
        string(calendar().date(byAdding: .day, value: days, to: date) ?? date)
    }
}

public struct CycleRelationshipCopy: Sendable {
    public let text: String
    public init(metric: String, phase: CyclePhase) {
        text = "Observed \(metric) alongside the logged \(phase.rawValue) phase. This association does not establish causation."
    }
}

public struct CycleScreenSnapshot: Equatable, Sendable {
    public let state: CycleState
    public let estimate: CycleEstimate
    public init(state: CycleState, estimate: CycleEstimate) { self.state = state; self.estimate = estimate }
}
