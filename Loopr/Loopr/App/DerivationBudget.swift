import Foundation
import DomainKit
import ProfileKit
#if canImport(UIKit)
import UIKit
#endif

/// Whether Loopr is on screen.
///
/// Everything that derives a day reads this first. iOS kills an app that
/// averages more than 80% CPU over sixty seconds while it is not on screen,
/// and it killed Loopr six times in one day for exactly that.
nonisolated protocol LooprForegroundStateReading: Sendable {
    var isForeground: Bool { get }
}

/// A fixed answer, for tests and previews.
nonisolated struct LooprFixedForegroundState: LooprForegroundStateReading {
    let isForeground: Bool
    init(_ isForeground: Bool) { self.isForeground = isForeground }
}

/// The live application state. The app delegate starts it closed at launch,
/// then scene activation opens it. Notifications also close the budget when
/// an active scene resigns or enters the background.
nonisolated final class LooprForegroundState: LooprForegroundStateReading, @unchecked Sendable {
    static let shared = LooprForegroundState()

    private let lock = NSLock()
    private var value: Bool
    private var tokens: [any NSObjectProtocol] = []

    /// On screen by default for isolated unit tests. The app delegate closes
    /// the live instance in didFinishLaunching until a scene activates.
    init(initial: Bool = true) {
        value = initial
        #if canImport(UIKit)
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ foreground: Bool) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.set(foreground: foreground)
            })
        }
        observe(UIApplication.didBecomeActiveNotification, true)
        // Resigning active covers Control Centre and the app switcher as well
        // as a real background transition. Being conservative there only ever
        // tightens the budget.
        observe(UIApplication.willResignActiveNotification, false)
        observe(UIApplication.didEnterBackgroundNotification, false)
        #endif
    }

    var isForeground: Bool { lock.withLock { value } }

    func set(foreground: Bool) { lock.withLock { value = foreground } }
}

/// The one place that decides whether derived-data work may run right now.
///
/// A data revision used to fan out into four unbounded consumers: the visible
/// screen's catch-up pass, the widget and Watch snapshot, the Apple Health
/// export, and detected-workout publishing. The band tops history up around
/// the clock, so in the background that fan-out ran forever and iOS killed the
/// process for CPU overuse.
///
/// The rule this enforces off screen is a conjunction, not a choice: a
/// consumer may run only when new history has landed since its last pass *and*
/// at least `backgroundInterval` has gone by. On screen the only bound is the
/// interval, so opening a tab is never blocked.
actor LooprDerivationBudget {
    /// The consumers that hang off a data revision. Each keeps its own clock,
    /// so a Health export does not spend the widget's allowance.
    enum Consumer: String, Sendable, CaseIterable {
        /// A background catch-up pass for a day a screen is showing.
        case dayDisplay = "day-display"
        /// The widget, Watch and complication snapshot.
        case surfaceSnapshot = "surface-snapshot"
        /// The Apple Health export walk.
        case healthExport = "health-export"
    }

    /// Why a claim was granted. Carried into the DEBUG derivation trace.
    enum Grant: String, Sendable {
        /// Loopr is on screen and the interval has gone by.
        case foreground
        /// New history landed and the off-screen interval has gone by.
        case topUp = "top-up"
        /// iOS handed Loopr a background processing window, which is the
        /// cheapest CPU it will ever get.
        case processingWindow = "processing-window"
    }

    /// Off screen, a consumer repeats at most this often. Thirty minutes is
    /// two band top-ups, so nothing waits long for numbers it can show.
    static let backgroundIntervalSeconds: TimeInterval = 30 * 60
    /// On screen, the visible day is recomputed at most this often. Live
    /// seconds arrive once a second and must never each buy a derivation.
    static let foregroundIntervalSeconds: TimeInterval = 60

    /// The hard ceiling. iOS kills a background app that averages 80% CPU over
    /// sixty seconds, so off screen Loopr may spend at most this many seconds
    /// deriving in any rolling minute. On the phone one worn day costs about
    /// fifteen seconds in a Debug build, so this is one day per minute and
    /// nothing else.
    static let backgroundRollingBudgetSeconds: TimeInterval = 15
    /// Inside a processing window iOS picked the moment, so the ceiling is
    /// higher. It is still a ceiling.
    static let processingRollingBudgetSeconds: TimeInterval = 25
    static let rollingWindowSeconds: TimeInterval = 60
    /// A background launch derives nothing at all for this long. iOS relaunches
    /// Loopr for its restored Bluetooth central around the clock, and the first
    /// minute of a cold launch is exactly where the kills happened.
    static let coldStartQuietSeconds: TimeInterval = 5 * 60
    /// The longest a screen read waits behind another derivation.
    static let laneWaitLimitSeconds: TimeInterval = 30
    /// How long after the last acknowledged batch history still counts as
    /// arriving. A backlog offload commits about once a second; the next
    /// scheduled top-up is a quarter of an hour away.
    static let historyLandingWindowSeconds: TimeInterval = 10

    /// The process-wide budget. Consumers take it as a defaulted dependency so
    /// tests can hand them an isolated one with a fake clock.
    static let shared = LooprDerivationBudget()

    private let dates: any DateProviding
    private nonisolated let foreground: any LooprForegroundStateReading
    private let backgroundInterval: TimeInterval
    private let foregroundInterval: TimeInterval

    private let rollingWindow: TimeInterval
    private let coldStartQuiet: TimeInterval
    /// When this process started. Everything off screen is measured from here.
    private let processStart: Date

    private var lastRunAt: [Consumer: Date] = [:]
    /// Consumers that have seen no new history since their last pass. Off
    /// screen they stay parked.
    private var spentHistory: Set<Consumer> = []
    /// When the last history batch was acknowledged. Nil until the band hands
    /// over anything at all, which is what keeps tests and a fresh install out
    /// of the offload rules.
    private var lastHistoryCommitAt: Date?
    private var processingWindows = 0
    /// What every derivation in the last rolling window cost. This is the
    /// number iOS is really measuring.
    private var spend: [(at: Date, seconds: TimeInterval)] = []
    /// What the next derivation is expected to cost, taken from the last one.
    /// The first guess off screen is the whole ceiling, so a cold launch can
    /// never start a second day before it has learned what one costs.
    private var estimatedDerivationSeconds = LooprDerivationBudget.backgroundRollingBudgetSeconds

    // One derivation at a time for the whole process. Two days deriving on two
    // cores is how Loopr reached a 98% CPU average and got killed; the health
    // export owns a second analytics actor, so per-actor de-duplication cannot
    // see it.
    private var laneBusy = false

    init(
        dates: any DateProviding = SystemDateProvider(),
        foreground: any LooprForegroundStateReading = LooprForegroundState.shared,
        backgroundInterval: TimeInterval = LooprDerivationBudget.backgroundIntervalSeconds,
        foregroundInterval: TimeInterval = LooprDerivationBudget.foregroundIntervalSeconds,
        rollingWindow: TimeInterval = LooprDerivationBudget.rollingWindowSeconds,
        coldStartQuiet: TimeInterval = LooprDerivationBudget.coldStartQuietSeconds
    ) {
        self.dates = dates
        self.foreground = foreground
        self.backgroundInterval = backgroundInterval
        self.foregroundInterval = foregroundInterval
        self.rollingWindow = rollingWindow
        self.coldStartQuiet = coldStartQuiet
        self.processStart = dates.now()
        self.spentHistory = Set(Consumer.allCases)
    }

    /// Readable without awaiting, so a scheduler can pick a task priority.
    nonisolated var isForegroundNow: Bool { foreground.isForeground }

    /// One acknowledged history batch. A top-up arrives as a burst of these;
    /// the budget only cares that something new landed.
    func noteHistoryCommit() {
        spentHistory.removeAll()
        lastHistoryCommitAt = dates.now()
    }

    /// Whether the band is still handing over history right now.
    ///
    /// An overnight backlog acknowledges a batch roughly every second for
    /// minutes on end, and each one moves the day's revision. On screen that is
    /// the signal to coalesce: a derivation started now is obsolete before it
    /// finishes. The window is longer than the gap between batches and much
    /// shorter than the gap between top-ups, so an idle band reads as idle.
    func isHistoryLanding(within window: TimeInterval = LooprDerivationBudget.historyLandingWindowSeconds) -> Bool {
        guard let lastHistoryCommitAt else { return false }
        return dates.now().timeIntervalSince(lastHistoryCommitAt) < window
    }

    /// iOS granted a `BGProcessingTask` window. Heavy work belongs here.
    func beginProcessingWindow() { processingWindows += 1 }

    func endProcessingWindow() { processingWindows = max(0, processingWindows - 1) }

    /// Whether `consumer` may run now. Granting records the run, so two
    /// callers racing the same revision produce one pass.
    func claim(_ consumer: Consumer) -> Grant? {
        guard let grant = decision(consumer) else { return nil }
        lastRunAt[consumer] = dates.now()
        spentHistory.insert(consumer)
        return grant
    }

    /// The same question without spending the allowance. Used by tests and by
    /// callers that want to log a skip.
    func wouldAllow(_ consumer: Consumer) -> Grant? { decision(consumer) }

    private func decision(_ consumer: Consumer) -> Grant? {
        let elapsed = lastRunAt[consumer].map { dates.now().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if foreground.isForeground {
            return elapsed >= foregroundInterval ? .foreground : nil
        }
        // Off screen there has to be something new to derive.
        guard !spentHistory.contains(consumer) else { return nil }
        if processingWindows > 0 { return .processingWindow }
        // A cold background launch does nothing at all for the first minutes.
        guard dates.now().timeIntervalSince(processStart) >= coldStartQuiet else { return nil }
        return elapsed >= backgroundInterval ? .topUp : nil
    }

    // MARK: The CPU ceiling

    /// Seconds spent deriving inside the current rolling window.
    func recentDerivationSeconds() -> TimeInterval {
        trimSpend()
        return spend.reduce(0) { $0 + $1.seconds }
    }

    /// Whether heavy work may start, without taking the lane. `priorDays` asks
    /// this before walking another night.
    func canDerive() -> Bool {
        if foreground.isForeground { return true }
        let inProcessingWindow = processingWindows > 0
        if !inProcessingWindow, dates.now().timeIntervalSince(processStart) < coldStartQuiet { return false }
        let ceiling = inProcessingWindow
            ? Self.processingRollingBudgetSeconds
            : Self.backgroundRollingBudgetSeconds
        // Measured against what the next one is expected to cost, not only
        // against what has been spent. Checking only the spend lets a window
        // that is one second short of the ceiling admit a whole further day.
        return recentDerivationSeconds() + estimatedDerivationSeconds <= ceiling
    }

    /// True when Loopr should keep the last good widget and Watch snapshot
    /// rather than publishing an empty one it was not allowed to derive.
    func shouldHoldBackSnapshot() -> Bool { !foreground.isForeground && !canDerive() }

    /// Takes the derivation lane and the CPU allowance together.
    ///
    /// Every path that derives a day goes through here, including the
    /// prior-day walk and a processing window, so no caller can spend more
    /// than the ceiling. False means: do not derive, use whatever is cached.
    /// A caller that gets true must call `endDerivation(seconds:)`.
    func beginDerivation() async -> Bool {
        guard canDerive() else { return false }
        if foreground.isForeground {
            guard await waitForLane() else { return false }
        } else {
            // Off screen nothing queues. A second pass that arrives while one
            // is running is dropped, never stacked behind it.
            guard !laneBusy else { return false }
            laneBusy = true
        }
        // Time passed while waiting, and another derivation spent from the
        // same window. Check once more before doing anything expensive.
        guard canDerive() else { releaseLane(); return false }
        return true
    }

    func endDerivation(seconds: TimeInterval) {
        let cost = max(0, seconds)
        spend.append((at: dates.now(), seconds: cost))
        // A day that has just been derived is the best available estimate of
        // what the next one costs. The phone is roughly six times slower than
        // the simulator, and this is how the ceiling learns that.
        estimatedDerivationSeconds = cost
        trimSpend()
        releaseLane()
    }

    private func trimSpend() {
        let cutoff = dates.now().addingTimeInterval(-rollingWindow)
        spend.removeAll { $0.at < cutoff }
    }

    // MARK: Derivation lane

    /// One derivation at a time for the whole process.
    ///
    /// This polls rather than parking a continuation on purpose: a cancelled
    /// derivation used to leave its waiter suspended forever and the lane was
    /// then held for the life of the process.
    private func waitForLane() async -> Bool {
        let pollNanoseconds: UInt64 = 20_000_000
        // The deadline is the real rule. The poll count is the same limit
        // counted a second way, because an injected clock that does not move
        // makes the deadline unreachable and the wait becomes a hang rather
        // than a refusal.
        let pollLimit = Int((Self.laneWaitLimitSeconds * 1_000_000_000) / Double(pollNanoseconds))
        let deadline = dates.now().addingTimeInterval(Self.laneWaitLimitSeconds)
        var polls = 0
        while laneBusy {
            if Task.isCancelled { return false }
            if dates.now() >= deadline { return false }
            if polls >= pollLimit { return false }
            polls += 1
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        // A waiter cancelled during its last sleep found the lane free and
        // took it, and nothing would ever release it.
        if Task.isCancelled { return false }
        laneBusy = true
        return true
    }

    func releaseLane() { laneBusy = false }

    /// Whether a derivation is running. Tests read this to prove nothing ever
    /// runs in parallel.
    var laneIsBusy: Bool { laneBusy }
}

/// One derived day per data revision for the whole process.
///
/// Loopr runs two analytics actors: the screens read one, and the Apple Health
/// export owns a second for its own civil day boundaries. They persist to
/// different document namespaces, so every worn day used to be derived twice,
/// once for each, on every launch. On the phone that is thirty seconds of CPU
/// for one day's numbers.
///
/// The cache is keyed by everything a generation depends on, so a day that has
/// gained a second is a miss, exactly as the document caches treat it.
actor LooprSharedGenerationCache {
    static let shared = LooprSharedGenerationCache()

    /// A day, a revision and the settings it was derived under. Two engines
    /// only share a generation when all of it matches.
    struct Key: Hashable, Sendable {
        /// Which history the day was derived from. Both production engines are
        /// handed the same database, so they share; two test fixtures each
        /// open their own, so a day derived in one case can never be handed to
        /// another that happens to have picked the same date.
        let history: ObjectIdentifier
        let day: DayIdentity
        let revision: Int64
        let baselineRevision: Int64
        let timeZoneIdentifier: String
        let algorithmVersion: String
    }

    /// Twenty-nine days is a full trailing window plus today. Past that the
    /// oldest entry goes, so a long export walk cannot grow without bound.
    static let capacity = 40

    private var entries: [Key: (profile: Profile?, projection: CanonicalDailyProjection)] = [:]
    private var order: [Key] = []

    func projection(for key: Key, profile: Profile?) -> CanonicalDailyProjection? {
        guard let entry = entries[key], entry.profile == profile else { return nil }
        return entry.projection
    }

    func store(_ projection: CanonicalDailyProjection, for key: Key, profile: Profile?) {
        if entries[key] == nil { order.append(key) }
        entries[key] = (profile, projection)
        while order.count > Self.capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}
