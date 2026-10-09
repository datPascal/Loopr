import Foundation

public nonisolated enum SurfaceConfiguration {
    public static let appGroupIdentifier = "group.com.loopr.shared"
    public static let supportedSchemaVersion = 1
}

/// The latest WatchConnectivity application context is durable on both
/// devices. A distinct revocation marker lets account deletion override an
/// older cached snapshot even when the Watch app was not running at the time.
public nonisolated enum WatchSurfaceApplicationContext {
    public static let payloadKey = "surfaceSnapshot"
    public static let revocationKey = "surfaceSnapshotRevoked"

    public static func publishing(_ data: Data) -> [String: Any] {
        [payloadKey: data]
    }

    public static var revoking: [String: Any] {
        [revocationKey: true]
    }

    public static func isRevoked(_ context: [String: Any]) -> Bool {
        context[revocationKey] as? Bool == true
    }

    public static func payload(in context: [String: Any]) -> Data? {
        guard !isRevoked(context) else { return nil }
        return context[payloadKey] as? Data
    }

    /// A delivered payload or revocation replaces the Watch's App Group
    /// cache. An empty context leaves the last successfully delivered payload
    /// available for offline complication rendering.
    public static func replacesCachedPayload(_ context: [String: Any]) -> Bool {
        isRevoked(context) || context[payloadKey] != nil
    }
}
public nonisolated enum SurfaceStaleReason: String, Codable, CaseIterable, Sendable {
    case noRecentSync, disconnected, permissionRevoked

    public var displayName: String {
        switch self {
        case .noRecentSync: "No recent sync"
        case .disconnected: "Strap disconnected"
        case .permissionRevoked: "Permission needed"
        }
    }
}
public nonisolated struct SurfaceBatteryObservation: Equatable, Codable, Sendable {
    public let level: Double?
    public let charging: Bool?
    public let observedAt: Date
    public init(level: Double?, observedAt: Date, charging: Bool? = nil) {
        self.level = level; self.observedAt = observedAt; self.charging = charging
    }
}
public nonisolated struct SurfaceWorkoutSummary: Equatable, Codable, Sendable {
    public let id: UUID
    public let activity: String
    public let startedAt: Date
    public init(id: UUID, activity: String, startedAt: Date) {
        self.id = id; self.activity = activity; self.startedAt = startedAt
    }
}
/// Every field is optional, so a snapshot written by an older build still
/// decodes: the synthesized decoder reads optional properties with
/// `decodeIfPresent`, and a missing key stays nil.
public nonisolated struct SurfaceMetrics: Equatable, Codable, Sendable {
    public let recovery: Double?
    /// Legacy sleep efficiency. Never interpret this field as a duration.
    public let sleep: Double?
    public let sleepMinutes: Double?
    public let strain: Double?
    /// Resting heart rate in beats per minute.
    public let heartRate: Double?
    public let hrv: Double?
    public let steps: Double?
    public init(recovery: Double? = nil, sleep: Double? = nil, strain: Double? = nil,
                heartRate: Double? = nil, hrv: Double? = nil, steps: Double? = nil, sleepMinutes: Double? = nil) {
        self.recovery = recovery; self.sleep = sleep; self.strain = strain
        self.heartRate = heartRate; self.hrv = hrv; self.steps = steps
        self.sleepMinutes = sleepMinutes
    }
}
/// Optional additions keep schema 1 snapshots written by earlier builds readable.
public nonisolated struct SurfaceRecoveryStyle: Equatable, Codable, Sendable {
    public let verdict: String
    public let lightRGB: UInt32
    public let darkRGB: UInt32
    public let highContrastLightRGB: UInt32?
    public let highContrastDarkRGB: UInt32?
    public init(verdict: String, lightRGB: UInt32, darkRGB: UInt32,
                highContrastLightRGB: UInt32? = nil, highContrastDarkRGB: UInt32? = nil) {
        self.verdict = verdict; self.lightRGB = lightRGB; self.darkRGB = darkRGB
        self.highContrastLightRGB = highContrastLightRGB; self.highContrastDarkRGB = highContrastDarkRGB
    }
}

public nonisolated struct SurfaceDayInsight: Equatable, Codable, Sendable {
    public let headline: String?
    public let recoveryStyle: SurfaceRecoveryStyle?
    public let recoveryUnavailableReason: String?
    public let nightsRecorded: Int?
    public let nightsNeeded: Int?
    public let sleepNeedMinutes: Double?
    public let sleepUnavailableReason: String?
    public let strainUnavailableReason: String?
    public init(headline: String? = nil, recoveryStyle: SurfaceRecoveryStyle? = nil, recoveryUnavailableReason: String? = nil,
                nightsRecorded: Int? = nil, nightsNeeded: Int? = nil, sleepNeedMinutes: Double? = nil,
                sleepUnavailableReason: String? = nil, strainUnavailableReason: String? = nil) {
        self.headline = headline; self.recoveryStyle = recoveryStyle
        self.recoveryUnavailableReason = recoveryUnavailableReason
        self.nightsRecorded = nightsRecorded; self.nightsNeeded = nightsNeeded
        self.sleepNeedMinutes = sleepNeedMinutes
        self.sleepUnavailableReason = sleepUnavailableReason; self.strainUnavailableReason = strainUnavailableReason
    }
}

public nonisolated struct SurfaceSnapshot: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let createdAt: Date
    public let sourceDay: String
    public let syncDate: Date?
    public let metrics: SurfaceMetrics
    public let battery: SurfaceBatteryObservation?
    public let activeWorkout: SurfaceWorkoutSummary?
    public let staleReasons: Set<SurfaceStaleReason>
    public let insight: SurfaceDayInsight?
    public init(schemaVersion: Int = SurfaceConfiguration.supportedSchemaVersion, generation: UInt64,
                createdAt: Date, sourceDay: String, syncDate: Date?, metrics: SurfaceMetrics,
                battery: SurfaceBatteryObservation?, activeWorkout: SurfaceWorkoutSummary?,
                staleReasons: Set<SurfaceStaleReason>, insight: SurfaceDayInsight? = nil) {
        self.schemaVersion = schemaVersion; self.generation = generation; self.createdAt = createdAt
        self.sourceDay = sourceDay; self.syncDate = syncDate; self.metrics = metrics
        self.battery = battery; self.activeWorkout = activeWorkout; self.staleReasons = staleReasons
        self.insight = insight
    }
}
public nonisolated enum SurfaceSnapshotError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), credentialShapedContent, unreadable
}
public nonisolated enum SurfaceSnapshotCodec {
    private struct VersionProbe: Decodable { let schemaVersion: Int }
    public static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> SurfaceSnapshot {
        let version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        guard version == SurfaceConfiguration.supportedSchemaVersion else {
            throw SurfaceSnapshotError.unsupportedVersion(version)
        }
        return try decoder.decode(SurfaceSnapshot.self, from: data)
    }
    public static func validateNoCredentials(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let forbidden = ["bearer ", "api_key", "apikey", "access_token", "secret_key"]
        if forbidden.contains(where: text.contains) { throw SurfaceSnapshotError.credentialShapedContent }
    }
}
public actor AtomicSurfaceSnapshotStore {
    private let url: URL
    private let encoder: JSONEncoder
    public init(url: URL) { self.url = url; self.encoder = JSONEncoder() }
    public func write(_ snapshot: SurfaceSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try SurfaceSnapshotCodec.validateNoCredentials(data)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    public func read() throws -> SurfaceSnapshot {
        try SurfaceSnapshotCodec.decode(Data(contentsOf: url))
    }
}

// MARK: - Snapshot-only widget projections

public nonisolated enum SurfaceWidgetFamily: String, CaseIterable, Codable, Sendable {
    case systemSmall, systemMedium, accessoryCircular, accessoryRectangular, accessoryInline
}

public nonisolated enum SurfacePrivacyMode: Equatable, Sendable { case normal, lockScreen }

public nonisolated struct SurfaceWidgetEntry: Equatable, Sendable {
    public let date: Date
    public let generation: UInt64?
    public let primaryText: String
    public let secondaryText: String
    public let isPlaceholder: Bool
    public let isStale: Bool

    public init(date: Date, generation: UInt64?, primaryText: String, secondaryText: String,
                isPlaceholder: Bool, isStale: Bool) {
        self.date = date; self.generation = generation; self.primaryText = primaryText
        self.secondaryText = secondaryText; self.isPlaceholder = isPlaceholder; self.isStale = isStale
    }
}

public nonisolated enum SurfaceWidgetProjection {
    public static func today(snapshot: SurfaceSnapshot?, now: Date,
                             privacy: SurfacePrivacyMode = .normal) -> SurfaceWidgetEntry {
        guard let snapshot else { return unavailable(now: now) }
        let reading = SurfaceTodayReading(snapshot: snapshot, now: now)
        let primary = privacy == .lockScreen ? "Open Loopr" : reading.recoveryLine
        return .init(date: now, generation: snapshot.generation, primaryText: primary,
                     secondaryText: privacy == .lockScreen ? staleText(snapshot.staleReasons) : reading.status,
                     isPlaceholder: false, isStale: reading.isStale)
    }

    public static func battery(snapshot: SurfaceSnapshot?, now: Date,
                               privacy: SurfacePrivacyMode = .normal) -> SurfaceWidgetEntry {
        guard let snapshot else { return unavailable(now: now) }
        let stale = !snapshot.staleReasons.isEmpty
        let primary: String
        if privacy == .lockScreen {
            primary = "Loopr battery"
        } else if let level = snapshot.battery?.level {
            primary = "\(Int((level * 100).rounded()))%"
        } else {
            primary = "Battery unavailable"
        }
        return .init(date: now, generation: snapshot.generation, primaryText: primary,
                     secondaryText: snapshot.battery?.charging == true && !stale ? "Charging" : staleText(snapshot.staleReasons), isPlaceholder: false, isStale: stale)
    }

    private static func unavailable(now: Date) -> SurfaceWidgetEntry {
        .init(date: now, generation: nil, primaryText: "Open Loopr to sync",
              secondaryText: "No snapshot", isPlaceholder: true, isStale: true)
    }

    private static func staleText(_ reasons: Set<SurfaceStaleReason>) -> String {
        guard !reasons.isEmpty else { return "Up to date" }
        return reasons.map(\.displayName).sorted().joined(separator: ", ")
    }
}

// MARK: - Live Activity lifecycle, independent of ActivityKit

public nonisolated enum SurfaceActivityKind: String, Codable, Sendable { case workout, breathing }
public nonisolated struct SurfaceActivityState: Equatable, Codable, Sendable {
    public let sessionID: UUID
    public let kind: SurfaceActivityKind
    public let startedAt: Date
    public let progress: Double
    public let status: String
    public init(sessionID: UUID, kind: SurfaceActivityKind, startedAt: Date,
                progress: Double, status: String) {
        self.sessionID = sessionID; self.kind = kind; self.startedAt = startedAt
        self.progress = progress; self.status = status
    }
}
public nonisolated protocol SurfaceActivityDriver: Sendable {
    func start(_ state: SurfaceActivityState) async throws
    func update(_ state: SurfaceActivityState) async throws
    func end(sessionID: UUID, finalState: SurfaceActivityState?) async throws
    func activeSessionIDs() async -> Set<UUID>
}
public actor SurfaceActivityCoordinator {
    private let driver: any SurfaceActivityDriver
    private var sessions: [UUID: SurfaceActivityState] = [:]
    public init(driver: any SurfaceActivityDriver) { self.driver = driver }

    public func start(_ state: SurfaceActivityState) async throws {
        guard sessions[state.sessionID] == nil else { return }
        try await driver.start(state); sessions[state.sessionID] = state
    }
    public func update(_ state: SurfaceActivityState) async throws {
        guard sessions[state.sessionID] != nil else { return }
        try await driver.update(state); sessions[state.sessionID] = state
    }
    public func end(sessionID: UUID, finalState: SurfaceActivityState?) async throws {
        guard sessions[sessionID] != nil else { return }
        try await driver.end(sessionID: sessionID, finalState: finalState)
        sessions[sessionID] = nil
    }
    public func recover(canonicalSessions: [SurfaceActivityState]) async throws {
        let canonical = Dictionary(uniqueKeysWithValues: canonicalSessions.map { ($0.sessionID, $0) })
        let platformIDs = await driver.activeSessionIDs()
        for orphan in platformIDs.subtracting(canonical.keys) {
            try await driver.end(sessionID: orphan, finalState: nil)
        }
        for state in canonicalSessions {
            if platformIDs.contains(state.sessionID) {
                try await driver.update(state)
            } else {
                try await driver.start(state)
            }
        }
        sessions = canonical
    }
}

// MARK: - Approved intent actions

public nonisolated enum SurfaceIntentRoute: Equatable, Hashable, Codable, Sendable {
    case today, heart, workout(UUID), breathing
}
public nonisolated enum SurfaceIntentError: Error, Equatable, Sendable { case authorizationDenied, unavailable }
public nonisolated enum SurfaceIntentAction: Equatable, Sendable {
    case readRecovery, readSleep, readStrain, navigate(SurfaceIntentRoute), openBreathing
    var requiresHealthAuthorization: Bool {
        switch self {
        case .readRecovery, .readSleep, .readStrain: true
        default: false
        }
    }
}
public nonisolated struct SurfaceIntentResult: Equatable, Sendable {
    public let route: SurfaceIntentRoute?
    public let spokenValue: String?
    public init(route: SurfaceIntentRoute? = nil, spokenValue: String? = nil) {
        self.route = route; self.spokenValue = spokenValue
    }
}
public actor SurfaceIntentExecutor {
    private var openedRoutes: Set<SurfaceIntentRoute> = []
    public init() {}
    public func perform(_ action: SurfaceIntentAction, snapshot: SurfaceSnapshot?,
                        healthAuthorized: Bool, now: Date = .now) throws -> SurfaceIntentResult {
        if action.requiresHealthAuthorization && !healthAuthorized {
            throw SurfaceIntentError.authorizationDenied
        }
        switch action {
        case .readRecovery:
            return .init(spokenValue: SurfaceTodayReading.dialog(.recovery, snapshot: snapshot, now: now))
        case .readSleep:
            return .init(spokenValue: SurfaceTodayReading.dialog(.sleep, snapshot: snapshot, now: now))
        case .readStrain:
            return .init(spokenValue: SurfaceTodayReading.dialog(.strain, snapshot: snapshot, now: now))
        case .navigate(let route):
            openedRoutes.insert(route); return .init(route: route)
        case .openBreathing:
            openedRoutes.insert(.breathing); return .init(route: .breathing)
        }
    }
    public func openedRouteCount() -> Int { openedRoutes.count }
}

// MARK: - Read-only Watch and complication projections

public nonisolated enum WatchComplicationFamily: String, CaseIterable, Sendable { case circular, rectangular }
public nonisolated struct WatchSurfaceProjection: Equatable, Sendable {
    public let recovery: String
    public let sleep: String
    public let strain: String
    public let steps: String
    public let battery: String
    public let staleText: String?

    public init(recovery: String, sleep: String, strain: String = "—", steps: String = "—",
                battery: String, staleText: String?) {
        self.recovery = recovery; self.sleep = sleep; self.strain = strain
        self.steps = steps; self.battery = battery; self.staleText = staleText
    }
}
public nonisolated enum WatchSurfaceProjector {
    public static func project(_ snapshot: SurfaceSnapshot, now: Date = .now) -> WatchSurfaceProjection {
        func whole(_ value: Double?) -> String {
            guard let value else { return "—" }
            guard value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
            return value.rounded().formatted(.number.precision(.fractionLength(0)))
        }
        let reading = SurfaceTodayReading(snapshot: snapshot, now: now)
        let strain = reading.strain
        let battery: String = snapshot.battery?.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let stale: String? = snapshot.staleReasons.isEmpty
            ? nil
            : snapshot.staleReasons.map(\.displayName).sorted().joined(separator: ", ")
        return WatchSurfaceProjection(
            recovery: reading.recovery.map { "\(Int($0.rounded()))" } ?? "—",
            sleep: reading.sleep,
            strain: strain,
            steps: whole(reading.isCurrentDay && !snapshot.staleReasons.contains(.permissionRevoked) ? snapshot.metrics.steps : nil),
            battery: battery,
            staleText: reading.isStale ? reading.status : stale
        )
    }
    public static func complication(_ family: WatchComplicationFamily,
                                    snapshot: SurfaceSnapshot) -> SurfaceWidgetEntry {
        switch family {
        case .circular:
            return SurfaceWidgetProjection.today(snapshot: snapshot, now: snapshot.createdAt)
        case .rectangular:
            return SurfaceWidgetProjection.today(snapshot: snapshot, now: snapshot.createdAt)
        }
    }
}
