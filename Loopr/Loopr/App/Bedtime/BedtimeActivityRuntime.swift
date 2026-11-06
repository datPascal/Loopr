import ActivityKit
import DesignSystem
import DomainKit
import Foundation
import OSLog
import RoutineKit
import SettingsKit
import UIKit

// The bedtime Live Activity runtime (DEC-12.17). `BedtimeActivityPlan.swift` makes the decisions. This file reads the
// inputs, asks ActivityKit through a small protocol so tests never touch it, and applies the decision.

/// What the runtime needs from the rest of the app. The composition builds one over the routine store; tests and
/// the DEBUG fixture build their own.
nonisolated protocol BedtimeActivityInputProviding: Sendable {
    /// The active protocol's rules and tonight's planned bedtime (Sleep's plan, used when no in-bed rule exists).
    func tonight(now: Date, timeZone: TimeZone) async -> BedtimeTonight
    /// The evening day's checks, evaluated against the sources.
    func checks(day: DayIdentity, now: Date, timeZone: TimeZone) async -> [RuleCheck]
    /// When the band saw the person fall asleep on or after `since`. Nil when it has not.
    func sleepStart(since: Date, now: Date) async -> Date?
}

nonisolated struct BedtimeTonight: Equatable, Sendable {
    var rules: [ProtocolRule]
    /// Minutes after midnight.
    var plannedBedtimeMinute: Int?

    init(rules: [ProtocolRule] = [], plannedBedtimeMinute: Int? = nil) {
        self.rules = rules
        self.plannedBedtimeMinute = plannedBedtimeMinute
    }
}

nonisolated struct BedtimeActivityHandle: Equatable, Sendable {
    let id: String
    let windowStart: Date
    let bedtime: Date
    /// Scheduled for 18:00 and not started yet.
    let isScheduled: Bool
    let state: LooprBedtimeActivityAttributes.ContentState
}

nonisolated struct BedtimeActivityRequest: Sendable {
    let attributes: LooprBedtimeActivityAttributes
    let state: LooprBedtimeActivityAttributes.ContentState
    let staleDate: Date
    /// Nil starts the activity now.
    let scheduledStart: Date?
}

/// ActivityKit behind a seam. Unit tests use a recording fake.
nonisolated protocol BedtimeActivityStarting: Sendable {
    func isAuthorized() async -> Bool
    /// True when the system can start an activity at a future time with the app closed.
    var canSchedule: Bool { get }
    func current() async -> [BedtimeActivityHandle]
    func start(_ request: BedtimeActivityRequest) async throws -> String
    func update(id: String, state: LooprBedtimeActivityAttributes.ContentState, staleDate: Date) async
    func end(id: String) async
}

/// The production starter. The deployment floor is iOS 26, which has the scheduled start in ActivityKit
/// (`Activity.request(attributes:content:pushType:style:alertConfiguration:start:)`), so no availability guard is needed.
nonisolated struct ActivityKitBedtimeStarter: BedtimeActivityStarting {
    func isAuthorized() async -> Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var canSchedule: Bool { true }

    func current() async -> [BedtimeActivityHandle] {
        Activity<LooprBedtimeActivityAttributes>.activities.compactMap { activity in
            switch activity.activityState {
            case .pending, .active, .stale: break
            case .ended, .dismissed: return nil
            @unknown default: return nil
            }
            return BedtimeActivityHandle(id: activity.id, windowStart: activity.attributes.windowStart,
                                         bedtime: activity.attributes.bedtime, isScheduled: activity.activityState == .pending,
                                         state: activity.content.state)
        }
    }

    func start(_ request: BedtimeActivityRequest) async throws -> String {
        let content = ActivityContent(state: request.state, staleDate: request.staleDate)
        if let startDate = request.scheduledStart {
            let time = LooprClockFormat.text(minuteOfDay: request.attributes.bedtimeMinuteOfDay)
            let alert = AlertConfiguration(title: "Bedtime", body: LocalizedStringResource("Bedtime is at \(time)"),
                                           sound: .default)
            return try Activity.request(attributes: request.attributes, content: content, pushType: nil,
                                        style: .standard, alertConfiguration: alert, start: startDate).id
        }
        return try Activity.request(attributes: request.attributes, content: content, pushType: nil).id
    }

    func update(id: String, state: LooprBedtimeActivityAttributes.ContentState, staleDate: Date) async {
        guard let activity = Activity<LooprBedtimeActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(id: String) async {
        guard let activity = Activity<LooprBedtimeActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
    }
}

/// Where the on or off choice lives. Settings stores it with the other surface switches.
nonisolated protocol BedtimePreferenceStoring: Sendable {
    func setBedtimeActivityEnabled(_ enabled: Bool) async throws
}

extension LooprSettingsSurfacePrivacyReader: BedtimePreferenceStoring {
    func setBedtimeActivityEnabled(_ enabled: Bool) async throws {
        var snapshot = await repository.snapshot()
        snapshot.surfacePrivacy.bedtimeLiveActivity = enabled
        try await repository.update(snapshot)
    }
}

/// The switch for the bedtime activity. Off by default. The Settings toggle writes the same value.
nonisolated enum BedtimeActivityPreference {
    /// For the Today first-evening card: turns the activity on and starts it if tonight's window is open.
    static func enable() { Task { await BedtimeActivityRuntime.shared.setPreference(true) } }

    /// Turns it off and ends a running activity.
    static func disable() { Task { await BedtimeActivityRuntime.shared.setPreference(false) } }

    static func set(_ enabled: Bool) async { await BedtimeActivityRuntime.shared.setPreference(enabled) }

    static func isEnabled() async -> Bool { await BedtimeActivityRuntime.shared.isEnabled() }
}

actor BedtimeActivityRuntime {
    static let shared = BedtimeActivityRuntime()

    private let logger = Logger(subsystem: "com.loopr.ios", category: "BedtimeActivity")
    private var starter: any BedtimeActivityStarting
    private var nowProvider: @Sendable () -> Date
    private var calendarProvider: @Sendable () -> Calendar
    private let scheduleWakeups: Bool
    private let observeSystemEvents: Bool

    private var privacy: (any LooprSurfacePrivacyReading)?
    private var store: (any BedtimePreferenceStoring)?
    /// The switch when no settings repository is attached, as in a fixture composition. A fresh install is off.
    private var fallbackEnabled = false
    private var provider: (any BedtimeActivityInputProviding)?

    private var observers: [any NSObjectProtocol] = []
    private var pendingReconcile: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    /// Called after every pass. The DEBUG probe uses it to publish the activity count.
    private var onReconciled: (@Sendable () async -> Void)?

    init(starter: any BedtimeActivityStarting = ActivityKitBedtimeStarter(),
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: @escaping @Sendable () -> Calendar = { Calendar.current },
         scheduleWakeups: Bool = true,
         observeSystemEvents: Bool = true) {
        self.starter = starter
        nowProvider = now
        calendarProvider = calendar
        self.scheduleWakeups = scheduleWakeups
        self.observeSystemEvents = observeSystemEvents
    }

    // MARK: Wiring

    /// Called by the composition with the surface privacy reader, the same one the workout activity uses. A reader that
    /// can also store the bedtime switch (`BedtimePreferenceStoring`) makes the switch durable.
    func attachSettings(_ reader: any LooprSurfacePrivacyReading) async {
        privacy = reader
        store = reader as? any BedtimePreferenceStoring
        startObserving()
        await reconcile()
    }

    /// Called by the composition with the routine store behind it, and by the DEBUG fixture.
    func setProvider(_ provider: any BedtimeActivityInputProviding) async {
        self.provider = provider
        startObserving()
        await reconcile()
    }

    func setOnReconciled(_ callback: (@Sendable () async -> Void)?) { onReconciled = callback }

    #if DEBUG
    /// The fixture composition: a fixed clock and calendar, and nothing else changes.
    func useFixture(now: @escaping @Sendable () -> Date, calendar: @escaping @Sendable () -> Calendar) {
        nowProvider = now
        calendarProvider = calendar
    }
    #endif

    // MARK: The switch

    func isEnabled() async -> Bool {
        guard let privacy else { return fallbackEnabled }
        let settings = await privacy.currentSurfacePrivacy()
        return settings.liveActivity && settings.bedtimeLiveActivity
    }

    func setPreference(_ enabled: Bool) async {
        fallbackEnabled = enabled
        if let store {
            do { try await store.setBedtimeActivityEnabled(enabled) }
            catch { logger.error("Could not save the bedtime switch: \(String(describing: error), privacy: .public)") }
        }
        await reconcile()
    }

    private func startObserving() {
        guard observeSystemEvents, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.reconcile() }
        })
        // Settings posts this after Save, with the saved switch. A composition with no settings repository has no other
        // way to learn it.
        observers.append(center.addObserver(forName: .looprSurfacePrivacyDidChange, object: nil, queue: nil) { [weak self] note in
            let bedtime = note.userInfo?[SurfacePrivacyChange.bedtimeKey] as? Bool
            Task { await self?.settingsSaved(bedtime: bedtime) }
        })
    }

    private func settingsSaved(bedtime: Bool?) async {
        if let bedtime { fallbackEnabled = bedtime }
        await reconcile()
    }

    // MARK: Reconcile

    /// Brings the activity in line with the switch, the clock and the rules: starts it in the window, updates the
    /// steps, ends it at bedtime plus the grace, when the person is in bed, or when the switch goes off. Call it when
    /// the app becomes active and when a rule is checked.
    func reconcile() async {
        let predecessor = pendingReconcile
        let operation = Task {
            await predecessor?.value
            await performReconcile()
        }
        pendingReconcile = operation
        await operation.value
    }

    private func performReconcile() async {
        wakeTask?.cancel()
        let now = nowProvider()
        let calendar = calendarProvider()
        let enabled = await isEnabled()
        let existing = await starter.current()
        let published = onReconciled
        defer { if let published { Task { await published() } } }

        var phase = BedtimeActivityWindow.Phase.noBedtime
        var tonight = BedtimeTonight()
        if enabled, let provider {
            tonight = await provider.tonight(now: now, timeZone: calendar.timeZone)
            let minute = BedtimeActivityBedtime.minuteOfDay(rules: tonight.rules, plannedMinute: tonight.plannedBedtimeMinute)
            phase = BedtimeActivityWindow.phase(now: now, bedtimeMinute: minute, calendar: calendar)
        }
        let evening = Self.evening(of: phase)
        var asleep = false
        if let evening, let provider, let sleep = await provider.sleepStart(since: evening.start, now: now) {
            asleep = sleep >= evening.start && sleep <= now
        }

        let plan = BedtimeActivityDecision.decide(
            enabled: enabled, authorized: await starter.isAuthorized(), asleep: asleep, phase: phase,
            existing: existing.map { .init(id: $0.id, windowStart: $0.windowStart, bedtime: $0.bedtime, isScheduled: $0.isScheduled) },
            canSchedule: starter.canSchedule)

        for id in plan.ends { await starter.end(id: id) }
        guard let evening, plan.updateID != nil || plan.start != nil, let provider else { return scheduleWake(phase: phase, now: now) }

        let checks = await provider.checks(day: evening.day, now: now, timeZone: calendar.timeZone)
        let steps = BedtimeActivitySteps.steps(rules: tonight.rules, checks: checks, evening: evening, calendar: calendar)
        let state = BedtimeActivitySteps.contentState(steps: steps, evening: evening, now: now)
        if let id = plan.updateID {
            if existing.first(where: { $0.id == id })?.state.differsVisibly(from: state) != false {
                await starter.update(id: id, state: state, staleDate: evening.endsAt)
            }
        } else if let start = plan.start {
            let request = BedtimeActivityRequest(
                attributes: LooprBedtimeActivityAttributes(bedtime: evening.bedtime, windowStart: evening.start,
                                                           bedtimeMinuteOfDay: evening.bedtimeMinuteOfDay),
                state: state, staleDate: evening.endsAt,
                scheduledStart: start.scheduledDate)
            do { _ = try await starter.start(request) }
            // iOS lets an app start an activity only while it is in front. A refusal here means the next time the app
            // becomes active will try again.
            catch { logger.notice("Bedtime Live Activity did not start: \(String(describing: error), privacy: .public)") }
        }
        scheduleWake(phase: phase, now: now)
    }

    private static func evening(of phase: BedtimeActivityWindow.Phase) -> BedtimeEvening? {
        switch phase {
        case .before(let evening), .running(let evening), .grace(let evening): evening
        case .noBedtime, .over: nil
        }
    }

    /// While the app stays in front, start at 18:00 and end after bedtime without waiting for the next activation.
    private func scheduleWake(phase: BedtimeActivityWindow.Phase, now: Date) {
        guard scheduleWakeups else { return }
        let target: Date
        switch phase {
        case .before(let evening): target = evening.start
        case .running(let evening): target = evening.bedtime
        case .grace(let evening): target = evening.endsAt
        case .noBedtime, .over: return
        }
        let delay = max(target.timeIntervalSince(now), 1)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }
}
