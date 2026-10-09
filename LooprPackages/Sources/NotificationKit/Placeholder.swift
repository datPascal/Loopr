import Foundation

public enum NotificationFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case recoveryReadiness, validatedHealthChanges, goals, detectedWorkouts, journaling, briefings
    case windDown, hydration, battery, chargeGuidance, disconnect, staleData
    case workoutCompletion, breathingCompletion, cycleReminders
    case highHeartRate, lowHeartRate, overnightCheck, cardioFitness

    /// Families no producer publishes yet. They stay off and out of Settings
    /// until something sends them; a toggle that does nothing is a broken
    /// promise.
    public static let unwired: Set<NotificationFamily> = [
        .validatedHealthChanges, .goals, .briefings, .windDown, .hydration
    ]

    /// Families that need an explicit opt-in. Everything that can buzz about
    /// the person's body starts off, so a new build never wakes anyone.
    public static let optIn: Set<NotificationFamily> = unwired.union([
        .recoveryReadiness, .cycleReminders, .journaling, .highHeartRate, .lowHeartRate, .overnightCheck, .cardioFitness
    ])

    public var isEnabledByDefault: Bool { !Self.optIn.contains(self) }

    /// Reminders fire at a time the person picked, so quiet hours never
    /// swallow them.
    public var isUserScheduled: Bool { self == .journaling || self == .cycleReminders }

    /// The heart alerts screen owns these toggles, not the general list.
    public static let heartAlerts: Set<NotificationFamily> = [.highHeartRate, .lowHeartRate, .overnightCheck, .cardioFitness]
}

public enum NotificationAuthorizationState: Sendable { case notDetermined, authorized, denied }
public enum NotificationSensitivity: String, Codable, Equatable, Sendable {
    case ordinary, healthDerived
    /// An alert the person switched on and configured themselves. Its text is
    /// the point of the alert, so it shows on the lock screen. This also covers
    /// the optional morning recap the person requested.
    case userRequestedAlert
}
public struct NotificationIdentity: Hashable, Codable, Sendable {
    public let family: NotificationFamily
    public let objectID: String
    public let day: String
    public init(family: NotificationFamily, objectID: String, day: String) {
        self.family = family; self.objectID = objectID; self.day = day
    }
}
public enum NotificationDeepLink: Equatable, Codable, Sendable {
    case today(String), heart(String), goals(String), workout(String), journal(String)
    case coach(String), sleep(String), hydration(String), device(String), stress(String), cycle(String)
    /// One heart alert or overnight check entry, by id.
    case heartAlert(String)
}
public struct NotificationRequest: Equatable, Sendable, Codable {
    public let identity: NotificationIdentity
    public let fireDate: Date
    public let title: String
    public let detail: String
    public let lockScreenBody: String
    public let sensitivity: NotificationSensitivity
    public let deepLink: NotificationDeepLink
    /// What quiet hours do to this request.
    public let quietHoursBehavior: QuietHoursBehavior
    /// A request still waiting after this moment is dropped instead of sent.
    public let expiresAt: Date?
    public var categoryIdentifier: String { NotificationCategoryCatalog.category(for: identity.family) }

    public init(identity: NotificationIdentity, fireDate: Date, title: String, detail: String,
                sensitivity: NotificationSensitivity, deepLink: NotificationDeepLink,
                quietHoursBehavior: QuietHoursBehavior = .suppress, expiresAt: Date? = nil) {
        self.identity = identity; self.fireDate = fireDate; self.title = title; self.detail = detail
        self.sensitivity = sensitivity; self.deepLink = deepLink
        self.quietHoursBehavior = quietHoursBehavior
        self.expiresAt = expiresAt
        self.lockScreenBody = sensitivity == .healthDerived
            ? "Open Loopr to view your private update." : detail
    }

    /// The same request moved to a later moment.
    public func rescheduled(to date: Date) -> NotificationRequest {
        NotificationRequest(identity: identity, fireDate: date, title: title, detail: detail,
                            sensitivity: sensitivity, deepLink: deepLink,
                            quietHoursBehavior: quietHoursBehavior, expiresAt: expiresAt)
    }
}
public struct QuietHours: Equatable, Sendable, Codable {
    /// Minutes after local midnight, 0..<1440.
    public let startMinute: Int
    public let endMinute: Int
    public init(startHour: Int, endHour: Int) { self.init(startMinute: startHour * 60, endMinute: endHour * 60) }
    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = ((startMinute % 1440) + 1440) % 1440
        self.endMinute = ((endMinute % 1440) + 1440) % 1440
    }
    public var startHour: Int { startMinute / 60 }
    public var endHour: Int { endMinute / 60 }
    /// 22:00 to 07:00.
    public static let standard = QuietHours(startHour: 22, endHour: 7)

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard startMinute != endMinute else { return false }
        return startMinute < endMinute
            ? (startMinute..<endMinute).contains(minute)
            : minute >= startMinute || minute < endMinute
    }

    /// The first moment after `date` at which quiet hours end.
    public func end(after date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay),
                  let candidate = calendar.date(byAdding: .minute, value: endMinute, to: day) else { continue }
            if candidate > date { return candidate }
        }
        return date
    }
}
public protocol NotificationSchedulingClient: Sendable {
    func schedule(_ request: NotificationRequest) async throws
    func remove(identities: Set<NotificationIdentity>) async
}

public enum NotificationPersistenceError: Error, Equatable, Sendable, LocalizedError {
    case unreadableClaims

    public var errorDescription: String? {
        "Loopr couldn't read saved notification data."
    }
}

public actor NotificationClaimLedger {
    private var claims: Set<NotificationIdentity> = []
    private let persistenceURL: URL?
    private let restorationFailed: Bool
    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL,
              FileManager.default.fileExists(atPath: persistenceURL.path) else {
            restorationFailed = false
            return
        }
        do {
            let data = try Data(contentsOf: persistenceURL)
            claims = try JSONDecoder().decode(Set<NotificationIdentity>.self, from: data)
            restorationFailed = false
        } catch {
            restorationFailed = true
        }
    }
    public func claim(_ identity: NotificationIdentity) throws -> Bool {
        guard !restorationFailed else { throw NotificationPersistenceError.unreadableClaims }
        let inserted = claims.insert(identity).inserted
        guard inserted else { return false }
        do {
            try persist()
        } catch {
            claims.remove(identity)
            throw error
        }
        return inserted
    }
    public func release(_ identities: Set<NotificationIdentity>) throws {
        guard !restorationFailed else { throw NotificationPersistenceError.unreadableClaims }
        let previous = claims
        claims.subtract(identities)
        do {
            try persist()
        } catch {
            claims = previous
            throw error
        }
    }
    public func count() -> Int { claims.count }
    public func allClaims() throws -> Set<NotificationIdentity> {
        guard !restorationFailed else { throw NotificationPersistenceError.unreadableClaims }
        return claims
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(claims)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: [.atomic])
    }
}

public enum NotificationScheduleResult: Equatable, Sendable {
    case scheduled, duplicate, disabled, quietHours, denied, queued
    /// Scheduled for the end of quiet hours instead of now.
    case deferred
    /// Past its expiry before it could be delivered.
    case expired
}

/// The app's sole scheduling/removal owner. Platform adapters call UserNotifications; feature
/// packages depend only on this actor and never on the system notification center directly.
public actor NotificationPolicy {
    private let client: any NotificationSchedulingClient
    private let claims: NotificationClaimLedger
    private var authorization: NotificationAuthorizationState = .notDetermined
    private var queued: [NotificationRequest] = []
    private var scheduled: Set<NotificationIdentity> = []
    private var preferences: [NotificationFamily: Bool]
    private var quietHours: QuietHours?
    private var delivery: NotificationDeliverySettings
    private var calendar: Calendar
    private let preferenceURL: URL?
    private let deliveryURL: URL?
    private let pendingURL: URL?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - deliveryURL: where quiet hours are kept. With a URL, quiet hours
    ///     default to 22:00 to 07:00; without one they start off, which is what
    ///     the in-memory tests rely on.
    ///   - pendingURL: where requests waiting for permission are kept, so an
    ///     app exit does not lose them.
    public init(client: any NotificationSchedulingClient, claims: NotificationClaimLedger,
                calendar: Calendar = .current, preferenceURL: URL? = nil,
                deliveryURL: URL? = nil, pendingURL: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.claims = claims; self.calendar = calendar
        self.preferenceURL = preferenceURL
        self.deliveryURL = deliveryURL
        self.pendingURL = pendingURL
        self.now = now
        if let deliveryURL {
            // A missing or unreadable file means the safe default: quiet
            // hours on.
            let restored = (try? Data(contentsOf: deliveryURL))
                .flatMap { try? JSONDecoder().decode(NotificationDeliverySettings.self, from: $0) }
            let settings = restored ?? .standard
            self.delivery = settings
            self.quietHours = settings.quietHoursEnabled ? settings.quietHours : nil
        } else {
            self.delivery = NotificationDeliverySettings(quietHoursEnabled: false)
            self.quietHours = nil
        }
        if let pendingURL,
           let data = try? Data(contentsOf: pendingURL),
           let restored = try? JSONDecoder().decode([NotificationRequest].self, from: data) {
            self.queued = restored
        }
        let defaults = Dictionary(uniqueKeysWithValues: NotificationFamily.allCases.map {
            ($0, $0.isEnabledByDefault)
        })
        if let preferenceURL, FileManager.default.fileExists(atPath: preferenceURL.path) {
            do {
                let data = try Data(contentsOf: preferenceURL)
                let restored = try JSONDecoder().decode([NotificationFamily: Bool].self, from: data)
                self.preferences = defaults.merging(restored) { _, restored in restored }
            } catch {
                self.preferences = Dictionary(uniqueKeysWithValues: NotificationFamily.allCases.map { ($0, false) })
            }
        } else {
            self.preferences = defaults
        }
    }
    public func setAuthorization(_ state: NotificationAuthorizationState) async {
        authorization = state
        guard state != .notDetermined else { return }
        let pending = queued; queued.removeAll()
        if state == .authorized {
            for request in pending {
                do {
                    _ = try await schedule(request)
                } catch {
                    queued.append(request)
                }
            }
        }
        persistPending()
    }
    public func authorizationState() -> NotificationAuthorizationState { authorization }
    public func pendingRequests() -> [NotificationRequest] { queued }
    public func setQuietHours(_ value: QuietHours?) { quietHours = value }
    public func deliverySettings() -> NotificationDeliverySettings { delivery }
    public func setDeliverySettings(_ value: NotificationDeliverySettings) throws {
        if let deliveryURL {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: deliveryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: deliveryURL, options: [.atomic])
        }
        delivery = value
        quietHours = value.quietHoursEnabled ? value.quietHours : nil
    }
    public func setEnabled(_ enabled: Bool, for family: NotificationFamily) async throws {
        let previous = preferences[family]
        preferences[family] = enabled
        do {
            try persistPreferences()
        } catch {
            preferences[family] = previous
            throw error
        }
        if !enabled { try await remove(family: family) }
    }
    public func disableAll() async throws {
        let previous = preferences
        for family in NotificationFamily.allCases {
            preferences[family] = false
        }
        do {
            try persistPreferences()
        } catch {
            preferences = previous
            throw error
        }
        try await remove()
    }
    public func isEnabled(_ family: NotificationFamily) -> Bool { preferences[family] == true }
    public func schedule(_ request: NotificationRequest) async throws -> NotificationScheduleResult {
        guard preferences[request.identity.family] == true else { return .disabled }
        var request = request
        var deferred = false
        // Producers pass the moment they want the notification seen, which is
        // usually now; quiet hours are judged against that moment.
        if let quietHours, quietHours.contains(request.fireDate, calendar: calendar) {
            let behavior: QuietHoursBehavior = request.identity.family.isUserScheduled ? .deliver : request.quietHoursBehavior
            switch behavior {
            case .suppress: return .quietHours
            case .deliver: break
            case .deferUntilEnd:
                request = request.rescheduled(to: quietHours.end(after: request.fireDate, calendar: calendar))
                deferred = true
            }
        }
        if let expiresAt = request.expiresAt, expiresAt < max(request.fireDate, now()) { return .expired }
        switch authorization {
        case .denied: return .denied
        case .notDetermined:
            if !queued.contains(where: { $0.identity == request.identity }) { queued.append(request) }
            persistPending()
            return .queued
        case .authorized: break
        }
        guard try await claims.claim(request.identity) else { return .duplicate }
        do {
            try await client.schedule(request)
            scheduled.insert(request.identity)
            return deferred ? .deferred : .scheduled
        }
        catch {
            let schedulingError = error
            try await claims.release([request.identity])
            throw schedulingError
        }
    }
    public func remove(family: NotificationFamily? = nil, objectID: String? = nil, day: String? = nil) async throws {
        let matches: @Sendable (NotificationIdentity) -> Bool = {
            (family == nil || $0.family == family) && (objectID == nil || $0.objectID == objectID) && (day == nil || $0.day == day)
        }
        let queuedIDs = Set(queued.map(\.identity).filter(matches))
        let scheduledIDs = Set(scheduled.filter(matches))
        let persistedIDs = try await claims.allClaims().filter(matches)
        let removedIDs = queuedIDs.union(scheduledIDs).union(persistedIDs)
        await client.remove(identities: removedIDs)
        try await claims.release(removedIDs)
        queued.removeAll { removedIDs.contains($0.identity) }
        scheduled.subtract(removedIDs)
        persistPending()
    }
    public static func deepLink(for family: NotificationFamily, target: String) -> NotificationDeepLink {
        switch family {
        case .recoveryReadiness: .today(target)
        case .validatedHealthChanges: .heart(target)
        case .goals: .goals(target)
        case .detectedWorkouts, .workoutCompletion: .workout(target)
        case .journaling: .journal(target)
        case .briefings: .coach(target)
        case .windDown: .sleep(target)
        case .hydration: .hydration(target)
        case .battery, .chargeGuidance, .disconnect, .staleData: .device(target)
        case .breathingCompletion: .stress(target)
        case .cycleReminders: .cycle(target)
        case .highHeartRate, .lowHeartRate, .overnightCheck, .cardioFitness: .heartAlert(target)
        }
    }

    /// Best effort: a failed write only means a queued request may be lost at
    /// exit, which is what happened before this file existed.
    private func persistPending() {
        guard let pendingURL else { return }
        do {
            if queued.isEmpty {
                try? FileManager.default.removeItem(at: pendingURL)
                return
            }
            let data = try JSONEncoder().encode(queued)
            try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: pendingURL, options: [.atomic])
        } catch {}
    }

    private func persistPreferences() throws {
        guard let preferenceURL else { return }
        let data = try JSONEncoder().encode(preferences)
        try FileManager.default.createDirectory(
            at: preferenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: preferenceURL, options: [.atomic])
    }
}

public enum NotificationResponsePayload {
    public static let deepLinkKey = "loopr.deep-link.v1"

    public static let familyKey = "loopr.family.v1" // gitleaks:allow (userInfo key, not a credential)
    public static let objectKey = "loopr.object.v1"

    public static func userInfo(for deepLink: NotificationDeepLink) throws -> [String: String] {
        let data = try JSONEncoder().encode(deepLink)
        return [deepLinkKey: data.base64EncodedString()]
    }

    /// The deep link plus the family and object, so an action handler knows
    /// what it acts on without opening the app.
    public static func userInfo(for request: NotificationRequest) throws -> [String: String] {
        var info = try userInfo(for: request.deepLink)
        info[familyKey] = request.identity.family.rawValue
        info[objectKey] = request.identity.objectID
        return info
    }

    public static func family(from userInfo: [AnyHashable: Any]) -> NotificationFamily? {
        (userInfo[familyKey] as? String).flatMap(NotificationFamily.init(rawValue:))
    }

    public static func deepLink(from userInfo: [AnyHashable: Any]) throws -> NotificationDeepLink {
        guard let value = userInfo[deepLinkKey] as? String,
              let data = Data(base64Encoded: value) else {
            throw NotificationPayloadError.missingDeepLink
        }
        do { return try JSONDecoder().decode(NotificationDeepLink.self, from: data) }
        catch { throw NotificationPayloadError.invalidDeepLink }
    }
}

public enum NotificationPayloadError: Error, Equatable, Sendable {
    case missingDeepLink, invalidDeepLink
}

public struct NotificationFamilyContext: Equatable, Sendable {
    public let targetID: String
    public let day: String
    public let fireDate: Date
    public let title: String
    public let detail: String
    public let isValidated: Bool
    public let cycleTrackingEnabled: Bool

    public init(targetID: String, day: String, fireDate: Date, title: String, detail: String,
                isValidated: Bool = true, cycleTrackingEnabled: Bool = false) {
        self.targetID = targetID; self.day = day; self.fireDate = fireDate
        self.title = title; self.detail = detail; self.isValidated = isValidated
        self.cycleTrackingEnabled = cycleTrackingEnabled
    }
}

public enum NotificationFamilyFactory {
    public static func request(
        family: NotificationFamily,
        context: NotificationFamilyContext
    ) -> NotificationRequest? {
        if family == .cycleReminders && !context.cycleTrackingEnabled { return nil }
        let sensitivity: NotificationSensitivity = switch family {
        case .recoveryReadiness, .validatedHealthChanges, .goals, .detectedWorkouts,
             .briefings, .windDown, .workoutCompletion, .breathingCompletion, .cycleReminders:
            .healthDerived
        case .journaling, .hydration, .battery, .chargeGuidance, .disconnect, .staleData:
            .ordinary
        case .highHeartRate, .lowHeartRate, .overnightCheck, .cardioFitness:
            .userRequestedAlert
        }
        if sensitivity == .healthDerived && !context.isValidated { return nil }
        return NotificationRequest(
            identity: .init(family: family, objectID: context.targetID, day: context.day),
            fireDate: context.fireDate,
            title: context.title,
            detail: context.detail,
            sensitivity: sensitivity,
            deepLink: NotificationPolicy.deepLink(for: family, target: context.targetID)
        )
    }
}

public enum HabitReminderRequestFactory {
    public static func request(behaviorDay: String, fireDate: Date) -> NotificationRequest {
        NotificationRequest(
            identity: NotificationIdentity(
                family: .journaling,
                objectID: "habit-check-in",
                day: behaviorDay
            ),
            fireDate: fireDate,
            title: "Habit check-in",
            detail: "Ready for yesterday's habit check-in?",
            sensitivity: .ordinary,
            deepLink: .journal(behaviorDay)
        )
    }
}

/// Converts already-published product state into notification requests. This
/// actor never reads Bluetooth, battery, or health APIs; callers pass the
/// canonical state transition they already own.
public actor ProductNotificationEventSource {
    private let policy: NotificationPolicy

    public init(policy: NotificationPolicy) { self.policy = policy }

    @discardableResult
    public func publish(
        _ family: NotificationFamily,
        targetID: String,
        day: String,
        fireDate: Date = Date(),
        title: String,
        detail: String,
        isValidated: Bool = true,
        cycleTrackingEnabled: Bool = false
    ) async throws -> NotificationScheduleResult? {
        let context = NotificationFamilyContext(
            targetID: targetID,
            day: day,
            fireDate: fireDate,
            title: title,
            detail: detail,
            isValidated: isValidated,
            cycleTrackingEnabled: cycleTrackingEnabled
        )
        guard let request = NotificationFamilyFactory.request(family: family, context: context) else {
            return nil
        }
        return try await policy.schedule(request)
    }

    public func workoutCompleted(id: String, day: String, fireDate: Date = Date()) async throws {
        _ = try await publish(
            .workoutCompletion,
            targetID: id,
            day: day,
            fireDate: fireDate,
            title: "Workout saved",
            detail: "Your workout summary is ready."
        )
    }

    public func breathingCompleted(id: String, day: String, fireDate: Date = Date()) async throws {
        _ = try await publish(
            .breathingCompletion,
            targetID: id,
            day: day,
            fireDate: fireDate,
            title: "Breathing session saved",
            detail: "Your breathing session summary is ready."
        )
    }

    public func briefingReady(id: String, day: String, fireDate: Date = Date()) async throws {
        _ = try await publish(
            .briefings,
            targetID: id,
            day: day,
            fireDate: fireDate,
            title: "Briefing ready",
            detail: "Your Loopr briefing is ready."
        )
    }
}
