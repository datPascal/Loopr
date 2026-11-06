import Foundation

public enum NotificationFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case recoveryReadiness, validatedHealthChanges, goals, detectedWorkouts, journaling, briefings
    case windDown, hydration, battery, chargeGuidance, disconnect, staleData
    case workoutCompletion, breathingCompletion, cycleReminders
    case highHeartRate, lowHeartRate, overnightCheck, cardioFitness
    /// Reminders the person confirmed in Ask or started with a Patterns test.
    case userReminders

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
    public var isUserScheduled: Bool { self == .journaling || self == .cycleReminders || self == .userReminders }

    /// Most requests that may wait at once. iOS keeps 64 pending notifications
    /// per app and every other Loopr family shares that room.
    public var pendingLimit: Int? { self == .userReminders ? Self.userReminderLimit : nil }
    public static let userReminderLimit = 10

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
    /// Ask, with the reminder's id.
    case ask(String)
    /// Patterns, with the test's id.
    case patterns(String)
    /// The weekly review sheet, with the reminder's id.
    case weeklyReview(String)
}

/// A request that comes back by itself. `weekly` comes back on the weekday of its first fire date.
public enum NotificationRepeat: String, Codable, Equatable, Sendable { case daily, weekly }

/// Where a reminder the person set came from.
public enum UserReminderSource: String, Codable, Equatable, Sendable { case ask, patternsTest }

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
    /// `.daily` fires at the time of day of `fireDate` every day until removed.
    public let repeats: NotificationRepeat?
    /// Set on requests of the `userReminders` family.
    public let reminderSource: UserReminderSource?
    /// The category the request asks for, such as a plain reminder for a protocol rule a source checks. Nil takes the
    /// catalog's choice. Requests saved before it existed decode with nil.
    public let category: String?
    public var categoryIdentifier: String { category ?? NotificationCategoryCatalog.category(for: self) }

    public init(identity: NotificationIdentity, fireDate: Date, title: String, detail: String,
                sensitivity: NotificationSensitivity, deepLink: NotificationDeepLink,
                quietHoursBehavior: QuietHoursBehavior = .suppress, expiresAt: Date? = nil,
                repeats: NotificationRepeat? = nil, reminderSource: UserReminderSource? = nil, category: String? = nil) {
        self.identity = identity; self.fireDate = fireDate; self.title = title; self.detail = detail
        self.sensitivity = sensitivity; self.deepLink = deepLink
        self.quietHoursBehavior = quietHoursBehavior
        self.expiresAt = expiresAt
        self.repeats = repeats; self.reminderSource = reminderSource
        self.category = category
        self.lockScreenBody = sensitivity == .healthDerived
            ? "Open Loopr to view your private update." : detail
    }

    /// The same request moved to a later moment.
    public func rescheduled(to date: Date) -> NotificationRequest {
        NotificationRequest(identity: identity, fireDate: date, title: title, detail: detail,
                            sensitivity: sensitivity, deepLink: deepLink,
                            quietHoursBehavior: quietHoursBehavior, expiresAt: expiresAt,
                            repeats: repeats, reminderSource: reminderSource, category: category)
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

    /// Whether a minute of the day falls inside quiet hours.
    public func contains(minuteOfDay minute: Int) -> Bool {
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
    /// The identities among `identities` the system still holds as pending, or
    /// nil when the client cannot tell.
    func pending(among identities: Set<NotificationIdentity>) async -> Set<NotificationIdentity>?
}

public extension NotificationSchedulingClient {
    func pending(among identities: Set<NotificationIdentity>) async -> Set<NotificationIdentity>? { nil }
}

/// One scheduling result for a reminder the person set, kept on the phone.
public struct ReminderHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case set, alreadySet, familyOff, notAllowed, full, waitingForPermission, failed
    }
    public let id: UUID
    public let date: Date
    public let source: UserReminderSource?
    public let title: String
    public let minuteOfDay: Int
    public let repeatsDaily: Bool
    public let outcome: Outcome

    public init(id: UUID = UUID(), date: Date, source: UserReminderSource?, title: String, minuteOfDay: Int,
                repeatsDaily: Bool, outcome: Outcome) {
        self.id = id; self.date = date; self.source = source; self.title = title
        self.minuteOfDay = minuteOfDay; self.repeatsDaily = repeatsDaily; self.outcome = outcome
    }
}

public extension NotificationRequest {
    /// The minute of the day this request fires, in `calendar`.
    func minuteOfDay(calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: fireDate)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The next moment this request fires after `date`. A daily request comes back every day at the same time, a
    /// weekly one on the same weekday at the same time.
    func nextFireDate(after date: Date, calendar: Calendar) -> Date? {
        switch repeats {
        case nil:
            return fireDate > date ? fireDate : nil
        case .daily?:
            let parts = calendar.dateComponents([.hour, .minute], from: fireDate)
            return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
        case .weekly?:
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: fireDate)
            return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
        }
    }
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
    /// The family already has its most pending requests, so nothing was added.
    case limitReached
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
    private let reminderURL: URL?
    private let historyURL: URL?
    private let standingURL: URL?
    private var reminderRecords: [NotificationRequest] = []
    /// Reminders the person keeps on, by object id, with their minute of the day. Most have a request waiting; one on a
    /// stretch with nothing to send, such as a rule whose week is done, has none until Loopr plans it again.
    private var standing: [String: Int] = [:]
    private var history: [ReminderHistoryEntry] = []
    private static let historyLimit = 30
    private let now: @Sendable () -> Date
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireMutation() async throws {
        try Task.checkCancellation()
        if mutationActive { await withCheckedContinuation { mutationWaiters.append($0) } }
        else { mutationActive = true }
        do { try Task.checkCancellation() }
        catch { releaseMutation(); throw error }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationActive = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    /// - Parameters:
    ///   - deliveryURL: where quiet hours are kept. With a URL, quiet hours
    ///     default to 22:00 to 07:00; without one they start off, which is what
    ///     the in-memory tests rely on.
    ///   - pendingURL: where requests waiting for permission are kept, so an
    ///     app exit does not lose them.
    ///   - reminderURL: where the reminders the person set are kept, so
    ///     Settings can list them with their time, repeat and source.
    ///   - historyURL: where the scheduling results for those reminders are kept.
    ///   - standingURL: where the reminders the person keeps on are kept, including one with nothing waiting this week.
    public init(client: any NotificationSchedulingClient, claims: NotificationClaimLedger,
                calendar: Calendar = .current, preferenceURL: URL? = nil,
                deliveryURL: URL? = nil, pendingURL: URL? = nil,
                reminderURL: URL? = nil, historyURL: URL? = nil, standingURL: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.claims = claims; self.calendar = calendar
        self.preferenceURL = preferenceURL
        self.deliveryURL = deliveryURL
        self.pendingURL = pendingURL
        self.reminderURL = reminderURL
        self.historyURL = historyURL
        self.standingURL = standingURL
        self.now = now
        if let standingURL, let data = try? Data(contentsOf: standingURL),
           let restored = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.standing = restored
        }
        if let reminderURL, let data = try? Data(contentsOf: reminderURL),
           let restored = try? JSONDecoder().decode([NotificationRequest].self, from: data) {
            self.reminderRecords = restored
        }
        if let historyURL, let data = try? Data(contentsOf: historyURL),
           let restored = try? JSONDecoder().decode([ReminderHistoryEntry].self, from: data) {
            self.history = restored
        }
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
    /// - Parameter recordsHistory: false for a reminder Loopr plans again by itself, such as a rule reminder that moves to
    ///   next week, so the history lists only what the person set.
    public func schedule(_ request: NotificationRequest, recordsHistory: Bool = true) async throws -> NotificationScheduleResult {
        try await acquireMutation()
        defer { releaseMutation() }
        do {
            let result = try await performSchedule(request)
            if recordsHistory { record(result, for: request) }
            return result
        } catch {
            if recordsHistory, !(error is CancellationError) { recordHistory(for: request, outcome: .failed) }
            throw error
        }
    }

    private func performSchedule(_ request: NotificationRequest) async throws -> NotificationScheduleResult {
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
        if let limit = request.identity.family.pendingLimit {
            await pruneFinishedReminders()
            // A reminder is counted once by its object, so a rule reminder on three weekdays (three weekly requests)
            // is one of the ten (ICP R2-HAB-06). One the person keeps on with nothing waiting this week counts too.
            var waiting = Set(Set(reminderRecords.map(\.identity)).union(queued.map(\.identity))
                .filter { $0.family == request.identity.family }.map(\.objectID))
            if request.identity.family == .userReminders { waiting.formUnion(standing.keys) }
            if !waiting.contains(request.identity.objectID), waiting.count >= limit { return .limitReached }
        }
        guard try await claims.claim(request.identity) else { return .duplicate }
        do {
            try await client.schedule(request)
            try Task.checkCancellation()
            scheduled.insert(request.identity)
            if request.identity.family == .userReminders {
                reminderRecords.removeAll { $0.identity == request.identity }
                reminderRecords.append(request)
                persistReminders()
            }
            return deferred ? .deferred : .scheduled
        }
        catch {
            let schedulingError = error
            await client.remove(identities: [request.identity])
            try await claims.release([request.identity])
            throw schedulingError
        }
    }
    public func remove(family: NotificationFamily? = nil, objectID: String? = nil, day: String? = nil) async throws {
        try await acquireMutation()
        defer { releaseMutation() }
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
        if reminderRecords.contains(where: { removedIDs.contains($0.identity) }) {
            reminderRecords.removeAll { removedIDs.contains($0.identity) }
            persistReminders()
        }
        persistPending()
    }

    // MARK: Reminders the person set

    /// The reminders waiting to fire, soonest first. A one-shot that has fired, a
    /// reminder past its expiry and one the system no longer holds drop out
    /// first.
    public func pendingReminders() async throws -> [NotificationRequest] {
        try await acquireMutation()
        defer { releaseMutation() }
        await pruneFinishedReminders()
        let current = now()
        let waiting = reminderRecords + queued.filter { $0.identity.family == .userReminders }
        return waiting.sorted {
            let lhs = $0.nextFireDate(after: current, calendar: calendar) ?? .distantFuture
            let rhs = $1.nextFireDate(after: current, calendar: calendar) ?? .distantFuture
            return (lhs, $0.identity.objectID) < (rhs, $1.identity.objectID)
        }
    }

    /// The reminders the person keeps on, by object id, with their minute of the day.
    public func standingReminders() -> [String: Int] { standing }

    /// Keeps a reminder on at `minuteOfDay`, or takes it off with nil. It does not schedule or remove a request.
    public func setStanding(_ objectID: String, minuteOfDay: Int?) {
        guard standing[objectID] != minuteOfDay else { return }
        standing[objectID] = minuteOfDay
        persistStanding()
    }

    /// Whether `minuteOfDay` falls inside the quiet hours that are on now.
    public func quietHoursContain(minuteOfDay: Int) -> Bool {
        quietHours?.contains(minuteOfDay: minuteOfDay) ?? false
    }

    /// The scheduling results for reminders the person set, newest first.
    public func reminderHistory() -> [ReminderHistoryEntry] { history.reversed() }

    /// Writes a result the policy never saw, such as a permission refusal that stopped the request before it got here.
    public func recordReminderOutcome(_ outcome: ReminderHistoryEntry.Outcome, source: UserReminderSource?,
                                      title: String, minuteOfDay: Int, repeatsDaily: Bool) {
        appendHistory(ReminderHistoryEntry(date: now(), source: source, title: title, minuteOfDay: minuteOfDay,
                                           repeatsDaily: repeatsDaily, outcome: outcome))
    }

    /// Delete all data. Forgets the reminders the person set and their history, in memory and on disk, so neither
    /// Settings nor the next save brings them back. The caller removes the pending requests from iOS.
    public func forgetUserReminders() async throws {
        try await acquireMutation()
        defer { releaseMutation() }
        var ids = Set<NotificationIdentity>(reminderRecords.map(\.identity))
        ids.formUnion(queued.map(\.identity))
        ids.formUnion(scheduled)
        ids = ids.filter { $0.family == .userReminders }
        try? await claims.release(ids)
        scheduled.subtract(ids)
        queued.removeAll { $0.identity.family == .userReminders }
        reminderRecords = []
        history = []
        standing = [:]
        persistReminders()
        persistStanding()
        if let historyURL { try? FileManager.default.removeItem(at: historyURL) }
        persistPending()
    }

    private func pruneFinishedReminders() async {
        guard !reminderRecords.isEmpty else { return }
        let current = now()
        var fired: [NotificationRequest] = []
        var expired: [NotificationRequest] = []
        var alive: [NotificationRequest] = []
        for record in reminderRecords {
            if let expiresAt = record.expiresAt, expiresAt <= current { expired.append(record) }
            else if record.repeats == nil, record.fireDate <= current { fired.append(record) }
            else { alive.append(record) }
        }
        if let present = await client.pending(among: Set(alive.map(\.identity))) {
            fired += alive.filter { !present.contains($0.identity) }
            alive = alive.filter { present.contains($0.identity) }
        }
        guard !fired.isEmpty || !expired.isEmpty else { return }
        // An expired repeating reminder is still pending in the system, so it is cancelled. A reminder that has
        // fired stays in Notification Center, so only its record goes.
        let cancelled = Set(expired.map(\.identity))
        if !cancelled.isEmpty { await client.remove(identities: cancelled) }
        let all = cancelled.union(fired.map(\.identity))
        try? await claims.release(all)
        scheduled.subtract(all)
        reminderRecords = alive
        persistReminders()
    }

    private func record(_ result: NotificationScheduleResult, for request: NotificationRequest) {
        let outcome: ReminderHistoryEntry.Outcome
        switch result {
        case .scheduled, .deferred: outcome = .set
        case .duplicate: outcome = .alreadySet
        case .disabled: outcome = .familyOff
        case .denied: outcome = .notAllowed
        case .limitReached: outcome = .full
        case .queued: outcome = .waitingForPermission
        case .quietHours, .expired: outcome = .failed
        }
        recordHistory(for: request, outcome: outcome)
    }

    private func recordHistory(for request: NotificationRequest, outcome: ReminderHistoryEntry.Outcome) {
        guard request.identity.family == .userReminders else { return }
        appendHistory(ReminderHistoryEntry(
            date: now(), source: request.reminderSource, title: request.title,
            minuteOfDay: request.minuteOfDay(calendar: calendar), repeatsDaily: request.repeats == .daily, outcome: outcome))
    }

    private func appendHistory(_ entry: ReminderHistoryEntry) {
        history.append(entry)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        guard let historyURL else { return }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: [.atomic])
        } catch {}
    }

    /// Best effort, like the pending file: the list is rebuilt from the system's pending requests when it is lost.
    private func persistReminders() {
        guard let reminderURL else { return }
        do {
            if reminderRecords.isEmpty {
                try? FileManager.default.removeItem(at: reminderURL)
                return
            }
            try FileManager.default.createDirectory(at: reminderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(reminderRecords).write(to: reminderURL, options: [.atomic])
        } catch {}
    }
    private func persistStanding() {
        guard let standingURL else { return }
        do {
            if standing.isEmpty {
                try? FileManager.default.removeItem(at: standingURL)
                return
            }
            try FileManager.default.createDirectory(at: standingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(standing).write(to: standingURL, options: [.atomic])
        } catch {}
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
        case .userReminders: .ask(target)
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
        case .highHeartRate, .lowHeartRate, .overnightCheck, .cardioFitness, .userReminders:
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

/// A reminder the person confirmed in Ask or started with a Patterns test. The lock screen shows the text they
/// confirmed, and a tap opens the place that set it.
public enum UserReminderRequestFactory {
    /// The day key of a reminder that repeats, fixed like the cycle reminder's.
    public static let recurringDay = "recurring"

    /// - Parameters:
    ///   - objectID: `ask.<proposal id>` or `patterns.<test id>`. One id is one reminder.
    ///   - day: `recurringDay` for a daily reminder, or the day a one-time reminder fires.
    public static func request(source: UserReminderSource, objectID: String, day: String, fireDate: Date,
                               title: String, detail: String, repeats: NotificationRepeat? = nil,
                               expiresAt: Date? = nil) -> NotificationRequest {
        NotificationRequest(
            identity: .init(family: .userReminders, objectID: objectID, day: day),
            fireDate: fireDate, title: title, detail: detail, sensitivity: .userRequestedAlert,
            deepLink: source == .ask ? .ask(objectID) : .patterns(objectID),
            quietHoursBehavior: .deliver, expiresAt: expiresAt, repeats: repeats, reminderSource: source)
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
            title: "Protocol check-in",
            detail: "Ready for yesterday's check-in?",
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
