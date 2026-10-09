import Combine
import Foundation
import DomainKit
import DesignSystem

public enum TodayLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
public final class TodayViewModel: ObservableObject {
    @Published public private(set) var loadState: TodayLoadState = .idle
    @Published public private(set) var summary: TodaySummary? { didSet { dashboardRevision &+= 1 } }
    @Published public private(set) var goals: [TodayGoalProgress] = []
    @Published public private(set) var coachPlan: TodayCoachPlanSlot = .placeholder
    /// History, the recovery split and tonight's inputs for the loaded day.
    /// Nil until loaded, or when the app supplies no context repository.
    @Published public private(set) var context: TodayDayContext? { didSet { dashboardRevision &+= 1 } }
    /// Pinned numbers and the dismissed heads-up day.
    @Published public private(set) var preferences: TodayPreferences { didSet { dashboardRevision &+= 1 } }

    private let repository: any TodayRepository
    private let goalsRepository: (any TodayGoalsRepository)?
    private let coachPlanRepository: (any TodayCoachPlanRepository)?
    private let contextRepository: (any TodayContextRepository)?
    private let preferencesStore: TodayPreferencesStore?
    /// The day the newest `load(day:)` asked for.
    private var requestedDay: DayIdentity?
    /// The summary the current context was loaded for. A refresh that reads
    /// the same summary keeps the context instead of reading history again.
    private var contextBasis: TodaySummary?
    private var dashboardMemo: (key: DashboardKey, value: TodayDashboard)?
    /// Bumped by every assignment to `summary`, `context` or `preferences`.
    /// The load path assigns only when a value changed, so equal reloads
    /// keep the memo.
    private var dashboardRevision: UInt64 = 0

    /// `lastKnownSummary` and `day` remain for existing callers. A saved
    /// same-day summary can change when later band data arrives, so it is not
    /// published before the fresh read completes.
    public init(
        repository: any TodayRepository,
        goalsRepository: (any TodayGoalsRepository)? = nil,
        coachPlanRepository: (any TodayCoachPlanRepository)? = nil,
        lastKnownSummary: TodaySummary? = nil,
        day: DayIdentity? = nil,
        contextRepository: (any TodayContextRepository)? = nil,
        preferencesStore: TodayPreferencesStore? = nil
    ) {
        self.repository = repository
        self.goalsRepository = goalsRepository
        self.coachPlanRepository = coachPlanRepository
        self.contextRepository = contextRepository
        self.preferencesStore = preferencesStore
        self.preferences = preferencesStore?.load() ?? TodayPreferences()
    }

    public func load(day: DayIdentity) async {
        requestedDay = day
        if let shown = summary, shown.day != day {
            // Another day's numbers must never sit under this day's label.
            summary = nil
            goals = []
            coachPlan = .placeholder
        }
        if let shown = context, shown.day != day {
            context = nil
            contextBasis = nil
        }
        if summary == nil { loadState = .loading }
        do {
            let read = try await repository.readSummary(for: day)
            // A slower read for a day the person already left must not land
            // on top of the day they moved to.
            guard requestedDay == day else { return }
            guard var value = read else {
                summary = nil
                goals = []
                coachPlan = .placeholder
                context = nil
                contextBasis = nil
                loadState = .loaded
                Self.noteFirstContent()
                return
            }
            // History is read once per day and again only when the day's
            // numbers change, before the summary is published, so the
            // comparisons arrive in the same frame as the numbers.
            if let contextRepository, context?.day != day || contextBasis != value {
                let loaded = try? await contextRepository.context(for: day, summary: value)
                guard requestedDay == day else { return }
                if context != loaded { context = loaded }
                contextBasis = value
            }
            if let goalsRepository {
                let loaded = try await goalsRepository.readGoals(for: day)
                guard requestedDay == day else { return }
                if goals != loaded { goals = loaded }
                value = TodaySummary(
                    day: value.day,
                    overallState: value.overallState,
                    freshness: value.freshness,
                    device: value.device,
                    metrics: value.metrics,
                    goals: loaded,
                    coachPlan: value.coachPlan,
                    notableChanges: value.notableChanges,
                    sleepNeedMinutes: TodaySleepNeed.minutes(from: loaded),
                    headline: value.headline
                )
            } else if goals != value.goals {
                goals = value.goals
            }
            let plan = try await coachPlanRepository?.readPlan(for: day)
            guard requestedDay == day else { return }
            if let plan {
                if coachPlan != .plan(plan) { coachPlan = .plan(plan) }
                value = TodaySummary(
                    day: value.day,
                    overallState: value.overallState,
                    freshness: value.freshness,
                    device: value.device,
                    metrics: value.metrics,
                    goals: value.goals,
                    coachPlan: .plan(plan),
                    notableChanges: value.notableChanges,
                    sleepNeedMinutes: value.sleepNeedMinutes, headline: value.headline
                )
            } else if coachPlan != value.coachPlan {
                coachPlan = value.coachPlan
            }
            // A reload that produces the same day must not republish it. While
            // the band offloads history, Today reloads every few seconds, and
            // an identical assignment still invalidates every card on screen.
            if summary != value { summary = value }
            if loadState != .loaded { loadState = .loaded }
            Self.noteFirstContent()
        } catch is CancellationError {
            guard requestedDay == day else { return }
            loadState = .idle
        } catch {
            guard requestedDay == day else { return }
            summary = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Marks the launch milestone once the first day's numbers are on
    /// screen: the main queue turns over after the publish, so the frame that
    /// carries them has been built.
    private static func noteFirstContent() {
        DispatchQueue.main.async { LooprPerformance.milestone("TodayFirstContent") }
    }

    /// Refreshes only the goal projection after APP-02A publishes a change.
    /// The canonical metric summary is retained byte-for-byte.
    public func refreshGoals(for day: DayIdentity) async {
        guard let goalsRepository else { return }
        do {
            let loaded = try await goalsRepository.readGoals(for: day)
            if goals != loaded { goals = loaded }
            guard let summary, summary.goals != loaded else { return }
            self.summary = TodaySummary(
                day: summary.day,
                overallState: summary.overallState,
                freshness: summary.freshness,
                device: summary.device,
                metrics: summary.metrics,
                goals: loaded,
                coachPlan: summary.coachPlan,
                notableChanges: summary.notableChanges,
                sleepNeedMinutes: TodaySleepNeed.minutes(from: loaded), headline: summary.headline
            )
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Refreshes only the allowlisted APP-14 plan card. Today never evaluates
    /// or rewrites a recommendation itself.
    public func refreshCoachPlan(for day: DayIdentity) async {
        guard let coachPlanRepository else { return }
        do {
            guard let plan = try await coachPlanRepository.readPlan(for: day) else {
                if coachPlan != .placeholder { coachPlan = .placeholder }
                guard let summary, summary.coachPlan != .placeholder else { return }
                self.summary = TodaySummary(
                    day: summary.day,
                    overallState: summary.overallState,
                    freshness: summary.freshness,
                    device: summary.device,
                    metrics: summary.metrics,
                    goals: summary.goals,
                    coachPlan: .placeholder,
                    notableChanges: summary.notableChanges,
                    sleepNeedMinutes: summary.sleepNeedMinutes, headline: summary.headline
                )
                return
            }
            if coachPlan != .plan(plan) { coachPlan = .plan(plan) }
            guard let summary, summary.coachPlan != .plan(plan) else { return }
            self.summary = TodaySummary(
                day: summary.day,
                overallState: summary.overallState,
                freshness: summary.freshness,
                device: summary.device,
                metrics: summary.metrics,
                goals: summary.goals,
                coachPlan: .plan(plan),
                notableChanges: summary.notableChanges,
                sleepNeedMinutes: summary.sleepNeedMinutes, headline: summary.headline
            )
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Re-reads only the projections owned by APP-02A and APP-14. This is the
    /// refresh boundary used when a goal or coach edit returns to Today; the
    /// canonical metric summary is not recomputed here.
    public func refreshProjections(for day: DayIdentity) async {
        guard summary != nil else {
            await load(day: day)
            return
        }
        await refreshGoals(for: day)
        await refreshCoachPlan(for: day)
    }

    public func clearPersistedProjection() {
        summary = nil
        goals = []
        coachPlan = .placeholder
        context = nil
        contextBasis = nil
        loadState = .idle
    }

    // MARK: Dashboard and preferences

    private struct DashboardKey: Equatable {
        let revision: UInt64
        let isToday: Bool
    }

    /// The screen's presentation for the loaded day. Built once per change of
    /// summary, context or preferences, not per render. The memo compares a
    /// revision counter rather than the summary and context themselves, which
    /// carry per-metric history arrays and were compared on every body pass.
    public func dashboard(isToday: Bool) -> TodayDashboard? {
        guard let summary else { return nil }
        let key = DashboardKey(revision: dashboardRevision, isToday: isToday)
        if let memo = dashboardMemo, memo.key == key { return memo.value }
        let value = TodayDashboard(
            summary: summary,
            context: context,
            pinned: preferences.pinned,
            isToday: isToday,
            headsUpDismissed: preferences.isHeadsUpDismissed(on: summary.day)
        )
        dashboardMemo = (key, value)
        return value
    }

    public func setPinned(_ metrics: [TodayTrackedMetric]) {
        var next = preferences
        next.setPinned(metrics)
        guard next != preferences else { return }
        preferences = next
        preferencesStore?.save(next)
    }

    public func dismissHeadsUp(for day: DayIdentity) {
        var next = preferences
        next.dismissHeadsUp(for: day)
        guard next != preferences else { return }
        preferences = next
        preferencesStore?.save(next)
    }
}
