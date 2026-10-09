import DesignSystem
import DomainKit
import Foundation
import Observation
import SwiftUI

/// The one day Today, Sleep, Heart and Body show.
///
/// Held by the tab shell and shared through the environment, so switching
/// tabs keeps the day, as in WHOOP. Until the person picks a day themselves
/// the selection follows the default day: today when today has data,
/// otherwise the latest complete day (see `LooprDayResolution`). When the
/// morning's night lands, a selection still following the default moves to
/// today by itself; a day the person picked is left alone.
@MainActor
@Observable
final class LooprDaySelection {
    /// The day the four tabs show.
    private(set) var day: DayIdentity
    /// The current civil day in the person's time zone.
    private(set) var today: DayIdentity
    /// What the default resolution last settled on.
    private(set) var defaultDay: DayIdentity?
    private(set) var knowledge: LooprDayKnowledge
    /// True while the first resolution after launch is still running and no
    /// earlier answer for today was kept. Screens show a skeleton meanwhile.
    private(set) var isResolving: Bool
    /// False once the person steps to a day themselves.
    private(set) var followsDefault = true
    /// Bumped whenever a resolution pass finishes, so a screen can re-read.
    private(set) var generation = 0

    let calendar: Calendar
    @ObservationIgnored private let dateProvider: any DateProviding
    @ObservationIgnored private let timeZoneProvider: any TimeZoneProviding
    @ObservationIgnored private var source: (any LooprDayDataSource)?
    @ObservationIgnored private let hints: LooprDayHintStore?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var backgroundedAt: Date?
    /// Fixture launches read a fixed clock; production reads the real one.
    @ObservationIgnored private let pinnedNow: Date?

    /// A resolution derives at most this many days before it settles on the
    /// best answer it has. Usually it is one: today, or yesterday.
    static let maximumDerivationsPerPass = 3
    /// Back on screen after this long, a picked day is let go and the
    /// selection follows the default again.
    static let releaseAfterBackgroundSeconds: TimeInterval = 30 * 60

    init(
        today: DayIdentity,
        dateProvider: any DateProviding,
        timeZoneProvider: any TimeZoneProviding,
        source: (any LooprDayDataSource)? = nil,
        knowledge: LooprDayKnowledge? = nil,
        hints: LooprDayHintStore? = nil
    ) {
        self.today = today
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
        self.calendar = LooprDays.calendar(timeZoneProvider.timeZone)
        self.source = source
        self.hints = hints
        self.pinnedNow = knowledge == nil ? nil : dateProvider.now()
        if let knowledge {
            // Everything is known up front (fixtures and tests): resolve now.
            self.knowledge = knowledge
            let resolved = Self.settle(today: today, knowledge: knowledge, calendar: calendar)
            self.day = resolved
            self.defaultDay = resolved
            self.isResolving = false
        } else if let hinted = hints?.day(forToday: today) {
            // The answer from earlier today. Opening on it means the launch
            // snapshot for that day paints the first frame.
            self.knowledge = LooprDayKnowledge()
            self.day = hinted
            self.defaultDay = hinted
            self.isResolving = false
        } else {
            self.knowledge = LooprDayKnowledge()
            self.day = today
            self.isResolving = source != nil || hints != nil
        }
    }

    // Task cancellation is thread safe. Teardown needs no actor hop, which
    // avoids the iOS 26.3 TaskLocal abort when a hosted view releases its
    // day-selection environment outside a Swift task.
    nonisolated deinit { refreshTask?.cancel() }

    /// The selection for an app composition. Production resolves against
    /// its analytics once storage opens; DEBUG fixtures know their days now.
    convenience init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        let today = environment.productDay(fixture: LooprDaySelection.fixtureDay)
        #if DEBUG
        if environment.composition != .production {
            let knowledge = FixtureDayHistory.knowledge(
                fixtureDay: today, composition: environment.composition,
                hasData: ProductFixture.metricState(for: environment.composition) != .noRecords)
            self.init(today: today, dateProvider: environment.dateProvider, timeZoneProvider: environment.timeZoneProvider,
                      source: FixtureDayDataSource(knowledgeValue: knowledge), knowledge: knowledge)
            return
        }
        #endif
        self.init(today: today, dateProvider: environment.dateProvider, timeZoneProvider: environment.timeZoneProvider,
                  hints: LooprDayHintStore(defaults: defaults))
    }

    /// Every tab fixture uses the same day.
    static let fixtureDay = DayIdentity(year: 2023, month: 11, day: 14)

    // MARK: Reading

    var isToday: Bool { day == today }

    var status: LooprDayDataStatus { knowledge.status(of: day) }

    /// The navigation value screens read from the environment.
    var navigation: LooprDayNavigation {
        LooprDayNavigation(
            day: LooprDays.looprDay(day),
            today: LooprDays.looprDay(today),
            earliest: knowledge.earliestDay.map(LooprDays.looprDay),
            calendar: calendar,
            status: isResolving ? .unknown : status,
            latestDayWithData: knowledge.latestDayWithData(onOrBefore: today).map(LooprDays.looprDay),
            isResolving: isResolving,
            lastSyncedAt: knowledge.lastRecordAt,
            now: pinnedNow,
            onSelect: { [weak self] target in self?.select(LooprDays.identity(target)) }
        )
    }

    /// Whether `day` can be read without deriving.
    func isCached(_ day: DayIdentity) async -> Bool {
        guard let source else { return true }
        return await source.isCached(day: day)
    }

    // MARK: Changing the day

    /// The person picked a day. It is clamped to the recorded range.
    func select(_ target: DayIdentity) {
        let lower = knowledge.earliestDay.map { LooprDays.isEarlier($0, today) ? $0 : today } ?? today
        var bounded = target
        if LooprDays.isEarlier(bounded, lower) { bounded = lower }
        if LooprDays.isEarlier(today, bounded) { bounded = today }
        followsDefault = false
        guard bounded != day else { return }
        day = bounded
    }

    func step(by offset: Int) {
        guard let target = LooprDays.adding(offset, to: day, calendar: calendar) else { return }
        select(target)
    }

    // MARK: Resolution

    /// Connects the production source once storage is open, and resolves.
    func attach(_ source: (any LooprDayDataSource)?) {
        self.source = source
        guard source != nil else { return }
        requestRefresh()
    }

    /// Re-reads the day index and the default day. Calls that arrive while a
    /// pass runs fold into one more pass after it, never a queue.
    func requestRefresh() {
        guard source != nil else { return }
        if refreshTask != nil {
            needsAnotherPass = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshPasses()
        }
    }

    /// Awaitable form, for tests and callers that need the answer.
    func refresh() async {
        guard source != nil else { return }
        if let refreshTask {
            needsAnotherPass = true
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshPasses()
        }
        refreshTask = task
        await task.value
    }

    private func runRefreshPasses() async {
        repeat {
            needsAnotherPass = false
            await resolveOnce()
        } while needsAnotherPass && !Task.isCancelled
        refreshTask = nil
    }

    private func resolveOnce() async {
        guard let source else { return }
        rollOverIfNeeded()
        let currentToday = today
        var fresh = await source.knowledge(today: currentToday)
        // Days derived empty in this process stay known: the stored index
        // only records days with values.
        fresh.derivedEmpty = knowledge.derivedEmpty.subtracting(fresh.withData)
        var derivations = 0
        var resolved = currentToday
        resolution: while true {
            switch LooprDayResolution.resolve(today: currentToday, knowledge: fresh, calendar: calendar) {
            case .show(let answer):
                resolved = answer
                break resolution
            case .derive(let candidate):
                guard derivations < Self.maximumDerivationsPerPass,
                      let hasData = await source.hasData(day: candidate) else {
                    // Could not settle it now. Show it: its screen reads the
                    // same generation and says what it finds.
                    resolved = candidate
                    break resolution
                }
                derivations += 1
                fresh.record(day: candidate, hasData: hasData)
            }
        }
        guard currentToday == today else { return }
        let changed = knowledge != fresh || defaultDay != resolved
            || (followsDefault && day != resolved) || isResolving
        if knowledge != fresh { knowledge = fresh }
        if defaultDay != resolved {
            defaultDay = resolved
            hints?.save(day: resolved, forToday: currentToday)
        }
        if followsDefault, day != resolved { day = resolved }
        if isResolving { isResolving = false }
        if changed { generation &+= 1 }
    }

    /// A screen finished reading `day`. The generation is saved now, so
    /// settling its status costs a cached read, and a day that turned out
    /// empty shows the empty state instead of a wall of blanks.
    func noteDisplayed(_ displayed: DayIdentity) {
        guard let source, knowledge.status(of: displayed) == .unknown else { return }
        Task { [weak self] in
            guard let hasData = await source.hasData(day: displayed) else { return }
            self?.knowledge.record(day: displayed, hasData: hasData)
        }
    }

    // MARK: Time

    /// Moves `today` forward after midnight or a time zone change. A new day
    /// lets go of a picked day.
    @discardableResult
    func rollOverIfNeeded() -> Bool {
        let now = LooprDays.day(containing: dateProvider.now(), calendar: LooprDays.calendar(timeZoneProvider.timeZone))
        guard now != today else { return false }
        today = now
        followsDefault = true
        if LooprDays.isEarlier(today, day) { day = today }
        return true
    }

    func sceneDidEnterBackground() {
        backgroundedAt = dateProvider.now()
    }

    func sceneDidBecomeActive() {
        if let backgroundedAt,
           dateProvider.now().timeIntervalSince(backgroundedAt) >= Self.releaseAfterBackgroundSeconds {
            followsDefault = true
            if let defaultDay, day != defaultDay { day = defaultDay }
        }
        backgroundedAt = nil
        requestRefresh()
    }

    private static func settle(today: DayIdentity, knowledge: LooprDayKnowledge, calendar: Calendar) -> DayIdentity {
        switch LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: calendar) {
        case .show(let day), .derive(let day): day
        }
    }
}

/// Remembers the default day Loopr settled on today, so the next cold launch
/// on the same day opens straight onto it. Listed in
/// `ProductRepositoryKeys.allOwnedDefaultsKeys`, so deleting all Loopr data
/// removes it.
nonisolated struct LooprDayHintStore {
    static let key = "loopr.days.default-day.v1"

    private struct Hint: Codable {
        let today: DayIdentity
        let day: DayIdentity
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved default, only when it was saved for `today`.
    func day(forToday today: DayIdentity) -> DayIdentity? {
        guard let data = defaults.data(forKey: Self.key),
              let hint = try? JSONDecoder().decode(Hint.self, from: data),
              hint.today == today else { return nil }
        return hint.day
    }

    func save(day: DayIdentity, forToday today: DayIdentity) {
        guard let data = try? JSONEncoder().encode(Hint(today: today, day: day)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

// MARK: Environment

extension EnvironmentValues {
    /// The shell's shared day. Nil outside the tab shell.
    @Entry var looprDaySelection: LooprDaySelection? = nil
}
