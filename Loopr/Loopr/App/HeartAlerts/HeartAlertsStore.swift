import Foundation
import AnalyticsKit

/// What the person chose on the Heart alerts screen. Every alert starts off.
nonisolated struct HeartAlertsPreferences: Codable, Equatable, Sendable {
    var rates: HeartRateAlertSettings
    var overnightCheckEnabled: Bool
    /// Stays off until an estimate exists; the vitals work turns it on.
    var cardioFitnessEnabled: Bool
    /// Heart rate alerts are held until quiet hours end unless this is on.
    var allowDuringQuietHours: Bool
    /// "Pause for today" from a notification: kind raw value to the moment
    /// the pause ends.
    var pausedUntil: [String: Date]

    init(rates: HeartRateAlertSettings = .off, overnightCheckEnabled: Bool = false,
         cardioFitnessEnabled: Bool = false, allowDuringQuietHours: Bool = false,
         pausedUntil: [String: Date] = [:]) {
        self.rates = rates
        self.overnightCheckEnabled = overnightCheckEnabled
        self.cardioFitnessEnabled = cardioFitnessEnabled
        self.allowDuringQuietHours = allowDuringQuietHours
        self.pausedUntil = pausedUntil
    }

    static let off = HeartAlertsPreferences()

    var anyEnabled: Bool {
        rates.highEnabled || rates.lowEnabled || overnightCheckEnabled || cardioFitnessEnabled
    }

    func isPaused(_ kind: HeartRateAlertKind, at date: Date) -> Bool {
        guard let until = pausedUntil[kind.rawValue] else { return false }
        return date < until
    }
}

/// A workout span the detector must leave alone. Open while `end` is nil.
nonisolated struct HeartAlertsWorkoutSpan: Codable, Equatable, Sendable {
    let id: String
    let start: Date
    var end: Date?
}

/// Everything the runtime carries between evaluations.
nonisolated struct HeartAlertsRuntimeState: Codable, Equatable, Sendable {
    var rates: HeartRateAlertState
    var overnight: OvernightVitalsCheckState
    var cardioFitnessLastNotifiedAt: Date?
    var workouts: [HeartAlertsWorkoutSpan]

    init(rates: HeartRateAlertState = .initial, overnight: OvernightVitalsCheckState = .initial,
         cardioFitnessLastNotifiedAt: Date? = nil, workouts: [HeartAlertsWorkoutSpan] = []) {
        self.rates = rates
        self.overnight = overnight
        self.cardioFitnessLastNotifiedAt = cardioFitnessLastNotifiedAt
        self.workouts = workouts
    }
}

nonisolated enum HeartAlertRecordKind: String, Codable, Sendable, CaseIterable {
    case highHeartRate, lowHeartRate, overnightCheck, cardioFitness
}

/// One overnight metric outside its range, kept for the history row.
nonisolated struct HeartAlertOvernightMetric: Codable, Equatable, Sendable, Hashable {
    let metric: OvernightVitalMetric
    let value: Double
    let low: Double
    let high: Double
    let direction: OvernightVitalDirection
}

/// How a raised alert left the app.
nonisolated enum HeartAlertDelivery: String, Codable, Sendable {
    case sent
    case heldForQuietHours
    case waitingForPermission
    case paused
    case notificationsOff
    case notSent
}

/// One row of the alert history.
nonisolated struct HeartAlertRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: HeartAlertRecordKind
    let date: Date
    var episode: HeartRateAlertEpisode?
    var overnightNight: String?
    var overnightMetrics: [HeartAlertOvernightMetric]
    var delivery: HeartAlertDelivery

    init(id: String, kind: HeartAlertRecordKind, date: Date, episode: HeartRateAlertEpisode? = nil,
         overnightNight: String? = nil, overnightMetrics: [HeartAlertOvernightMetric] = [],
         delivery: HeartAlertDelivery) {
        self.id = id
        self.kind = kind
        self.date = date
        self.episode = episode
        self.overnightNight = overnightNight
        self.overnightMetrics = overnightMetrics
        self.delivery = delivery
    }
}

/// Small JSON files under Application Support. The history is a few hundred
/// rows at most, and the headless Bluetooth relaunch must be able to read and
/// write it without the product database.
actor HeartAlertsStore {
    static let historyLimit = 200

    private let root: URL
    private var cachedPreferences: HeartAlertsPreferences?
    private var cachedState: HeartAlertsRuntimeState?
    private var cachedHistory: [HeartAlertRecord]?

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartAlerts", isDirectory: true)
    }

    private var preferencesURL: URL { root.appendingPathComponent("preferences.json") }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var historyURL: URL { root.appendingPathComponent("history.json") }

    func preferences() -> HeartAlertsPreferences {
        if let cachedPreferences { return cachedPreferences }
        // Unreadable preferences fail closed: every alert off.
        let value = read(HeartAlertsPreferences.self, from: preferencesURL) ?? .off
        cachedPreferences = value
        return value
    }

    func savePreferences(_ value: HeartAlertsPreferences) throws {
        try write(value, to: preferencesURL)
        cachedPreferences = value
    }

    func state() -> HeartAlertsRuntimeState {
        if let cachedState { return cachedState }
        let value = read(HeartAlertsRuntimeState.self, from: stateURL) ?? HeartAlertsRuntimeState()
        cachedState = value
        return value
    }

    func saveState(_ value: HeartAlertsRuntimeState) throws {
        try write(value, to: stateURL)
        cachedState = value
    }

    /// Newest first.
    func history() -> [HeartAlertRecord] {
        if let cachedHistory { return cachedHistory }
        let value = read([HeartAlertRecord].self, from: historyURL) ?? []
        cachedHistory = value
        return value
    }

    func record(_ record: HeartAlertRecord) throws {
        var rows = history().filter { $0.id != record.id }
        rows.insert(record, at: 0)
        rows.sort { $0.date > $1.date }
        if rows.count > Self.historyLimit { rows = Array(rows.prefix(Self.historyLimit)) }
        try write(rows, to: historyURL)
        cachedHistory = rows
    }

    func updateEpisode(_ episode: HeartRateAlertEpisode) throws {
        var rows = history()
        guard let index = rows.firstIndex(where: { $0.id == episode.id }) else { return }
        rows[index].episode = episode
        try write(rows, to: historyURL)
        cachedHistory = rows
    }

    func episodes(ids: [String]) -> [HeartRateAlertEpisode] {
        let wanted = Set(ids)
        return history().compactMap { wanted.contains($0.id) ? $0.episode : nil }
    }

    func deleteAll() throws {
        cachedPreferences = nil
        cachedState = nil
        cachedHistory = nil
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        // The Bluetooth relaunch runs while the phone is locked, so the files
        // must stay writable then, like the history database.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
