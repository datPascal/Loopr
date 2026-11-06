import Combine
import Foundation

/// Work and rest rounds, with an optional warm-up before them and cool-down after (R2-VET-05).
public struct IntervalConfiguration: Equatable, Sendable {
    public let workSeconds: Int
    public let restSeconds: Int
    public let rounds: Int
    /// Easy time before the first interval. Zero for none.
    public let warmUpSeconds: Int
    /// Easy time after the last interval. Zero for none.
    public let coolDownSeconds: Int
    public init(workSeconds: Int = 30, restSeconds: Int = 30, rounds: Int = 10, warmUpSeconds: Int = 0, coolDownSeconds: Int = 0) {
        self.workSeconds = workSeconds; self.restSeconds = restSeconds; self.rounds = rounds
        self.warmUpSeconds = warmUpSeconds; self.coolDownSeconds = coolDownSeconds
    }

    /// The warm-up and cool-down steppers' range and step: up to 30 minutes, a minute at a time.
    public static let easyMinutesRange = 0...30

    /// The same rounds with this warm-up and cool-down.
    public func with(warmUpSeconds: Int, coolDownSeconds: Int) -> Self {
        .init(workSeconds: workSeconds, restSeconds: restSeconds, rounds: rounds,
              warmUpSeconds: warmUpSeconds, coolDownSeconds: coolDownSeconds)
    }

    /// The work, rest and rounds alone, without warm-up and cool-down. Presets compare on this.
    public var intervals: Self { with(warmUpSeconds: 0, coolDownSeconds: 0) }
    public static let thirtyThirty = Self()
    public static let tabata = Self(workSeconds: 20, restSeconds: 10, rounds: 8)
    /// Four minutes hard, three easy, four times (R1-VET-08).
    public static let norwegianFourByFour = Self(workSeconds: 240, restSeconds: 180, rounds: 4)
    /// Every minute on the minute for ten minutes: the work fills the minute.
    public static let emomTen = Self(workSeconds: 60, restSeconds: 0, rounds: 10)

    /// The next work or rest value from a stepper: 5 s steps below a minute, 15 s from a minute up, snapped to
    /// the step and kept inside `range`. `direction` is 1 for plus and -1 for minus.
    public static func steppedSeconds(_ value: Int, direction: Int, range: ClosedRange<Int>) -> Int {
        let next: Int
        if direction > 0 {
            next = value < 60 ? (value / 5 + 1) * 5 : (value / 15 + 1) * 15
        } else {
            next = value <= 60 ? ((value - 1) / 5) * 5 : ((value - 1) / 15) * 15
        }
        return min(max(next, range.lowerBound), range.upperBound)
    }
    public var isValid: Bool {
        (1...3600).contains(workSeconds) && (0...3600).contains(restSeconds) && (1...100).contains(rounds)
            && (0...3600).contains(warmUpSeconds) && (0...3600).contains(coolDownSeconds)
    }

    /// The warm-up, every work interval, the rests between them and the cool-down. No rest follows the last
    /// interval: the session ends there, or goes into the cool-down.
    public var duration: TimeInterval { segments.last.map { $0.offset + $0.seconds } ?? 0 }

    /// One stretch of the timer: its phase, its round, when it starts after Start, and how long it lasts.
    public struct Segment: Equatable, Sendable {
        public let phase: IntervalPhase
        public let round: Int
        public let offset: TimeInterval
        public let seconds: TimeInterval
    }

    /// Every stretch in order: warm-up, work and rest for each round but the last rest, cool-down.
    public var segments: [Segment] {
        guard isValid else { return [] }
        var result: [Segment] = []
        var offset: TimeInterval = 0
        func add(_ phase: IntervalPhase, _ round: Int, _ seconds: Int) {
            guard seconds > 0 else { return }
            result.append(.init(phase: phase, round: round, offset: offset, seconds: Double(seconds)))
            offset += Double(seconds)
        }
        add(.warmUp, 1, warmUpSeconds)
        for round in 1...rounds {
            add(.work, round, workSeconds)
            if round < rounds { add(.rest, round, restSeconds) }
        }
        add(.coolDown, rounds, coolDownSeconds)
        return result
    }
}

/// A named interval session the timer offers.
public struct IntervalPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let configuration: IntervalConfiguration

    public static let all: [IntervalPreset] = [
        .init(id: "4x4", name: "Norwegian 4x4", configuration: .norwegianFourByFour),
        .init(id: "emom-10", name: "EMOM 10 min", configuration: .emomTen),
        .init(id: "tabata", name: "Tabata", configuration: .tabata),
        .init(id: "30-30", name: "30/30", configuration: .thirtyThirty)
    ]

    /// The preset with this configuration, if any.
    public static func matching(_ configuration: IntervalConfiguration) -> IntervalPreset? {
        all.first { $0.configuration == configuration.intervals }
    }

    /// The saved workout's name: the preset's, or "Intervals 40/20 x 8".
    public static func workoutTitle(for configuration: IntervalConfiguration) -> String {
        if let preset = matching(configuration) { return preset.name }
        func part(_ seconds: Int) -> String {
            seconds % 60 == 0 && seconds >= 60 ? "\(seconds / 60) min" : seconds >= 60
                ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) s"
        }
        let rest = configuration.restSeconds > 0 ? " on, \(part(configuration.restSeconds)) off" : ""
        return "Intervals \(part(configuration.workSeconds))\(rest), \(configuration.rounds) rounds"
    }
}

public enum IntervalPhase: String, Equatable, Sendable {
    case warmUp, work, rest, coolDown, complete

    /// "Warm-up", "Work", "Rest", "Cool-down", "Complete".
    public var title: String {
        switch self {
        case .warmUp: "Warm-up"
        case .work: "Work"
        case .rest: "Rest"
        case .coolDown: "Cool-down"
        case .complete: "Complete"
        }
    }
}

public struct IntervalProgress: Equatable, Sendable {
    public let phase: IntervalPhase
    public let round: Int
    public let phaseIndex: Int
    public let phaseStartedAt: Date
    public let phaseEndsAt: Date
    public let remainingSeconds: Int
}

public struct IntervalSchedule: Equatable, Sendable {
    public let configuration: IntervalConfiguration
    public let startedAt: Date
    public init(configuration: IntervalConfiguration, startedAt: Date) { self.configuration = configuration; self.startedAt = startedAt }
    public var endsAt: Date { startedAt.addingTimeInterval(configuration.duration) }
    /// Compute from the original clock anchor so suspension cannot stretch the
    /// workout or replay every missed cue on wake.
    public func progress(at date: Date) -> IntervalProgress {
        let segments = configuration.segments
        guard !segments.isEmpty, date < endsAt else {
            return .init(phase: .complete, round: configuration.rounds, phaseIndex: segments.count,
                         phaseStartedAt: endsAt, phaseEndsAt: endsAt, remainingSeconds: 0)
        }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let index = segments.lastIndex { $0.offset <= elapsed } ?? 0
        let segment = segments[index]
        let start = startedAt.addingTimeInterval(segment.offset)
        let end = start.addingTimeInterval(segment.seconds)
        return .init(phase: segment.phase, round: segment.round, phaseIndex: index, phaseStartedAt: start, phaseEndsAt: end,
                     remainingSeconds: max(0, Int(ceil(end.timeIntervalSince(date)))))
    }
    public var phaseStarts: [Date] { configuration.segments.map { startedAt.addingTimeInterval($0.offset) } }
}

/// A finished interval session, ready to save with its work phases and heart rate.
public struct IntervalSessionResult: Sendable {
    public let schedule: IntervalSchedule
    public let endedAt: Date
    public let samples: [WorkoutSample]

    public init(schedule: IntervalSchedule, endedAt: Date, samples: [WorkoutSample]) {
        self.schedule = schedule; self.endedAt = endedAt; self.samples = samples
    }

    /// The work phases that ran, cut at the moment the timer stopped.
    public var effortWindows: [WorkoutEffortWindow] {
        schedule.configuration.segments.filter { $0.phase == .work }.compactMap { segment in
            let start = schedule.startedAt.addingTimeInterval(segment.offset)
            let end = start.addingTimeInterval(segment.seconds)
            return end <= endedAt ? WorkoutEffortWindow(round: segment.round, start: start, end: end) : nil
        }
    }

    /// The record to save, or nil when not one work phase finished.
    public func record(title: String, id: UUID = UUID()) -> WorkoutRecord? {
        let windows = effortWindows
        guard !windows.isEmpty else { return nil }
        let identity = WorkoutIdentity.make(activity: .hiit, sourceKey: "interval-\(Int(schedule.startedAt.timeIntervalSince1970))",
                                            startedAt: schedule.startedAt, endedAt: endedAt)
        return WorkoutRecord(id: id, identity: identity, activity: .hiit, source: .live, state: .completed,
                             createdAt: schedule.startedAt, startedAt: schedule.startedAt, endedAt: endedAt, samples: samples,
                             finalizationStage: .activeStateCleared, title: WorkoutLogEntry.cleaned(title), effortWindows: windows)
    }
}

public struct IntervalTimerHooks: Sendable {
    public let started: @Sendable (UUID, IntervalSchedule) async -> Void
    public let changed: @Sendable (UUID, IntervalProgress) async -> Void
    public let ended: @Sendable (UUID) async -> Void
    public init(started: @escaping @Sendable (UUID, IntervalSchedule) async -> Void = { _, _ in },
                changed: @escaping @Sendable (UUID, IntervalProgress) async -> Void = { _, _ in },
                ended: @escaping @Sendable (UUID) async -> Void = { _ in }) {
        self.started = started; self.changed = changed; self.ended = ended
    }
}

@MainActor
public final class IntervalTimerModel: ObservableObject {
    @Published public private(set) var schedule: IntervalSchedule?
    @Published public private(set) var progress: IntervalProgress?
    @Published public private(set) var latestSample: WorkoutSample?
    @Published public private(set) var isRunning = false
    /// The record a finished session was saved as. Nil until it is saved, and after Discard.
    @Published public var savedWorkoutID: UUID?
    /// True once the finished session was saved or discarded, so coming back to the screen does not save it again.
    @Published public var completionHandled = false
    /// The name the finished session saves under ("Norwegian 4x4"), chosen before Start (R2-VET-05).
    @Published public private(set) var title: String?
    private var id: UUID?
    private var ticker: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var lease: WorkoutLiveSampleLease?
    private var hooks = IntervalTimerHooks()
    /// This session's heart rate, kept until the next start so a finished session can be saved with it.
    private var samples: [WorkoutSample] = []
    public init() {}

    /// The session that just ran to its end, or nil while none has.
    public var finishedSession: IntervalSessionResult? {
        guard progress?.phase == .complete, let schedule else { return nil }
        return IntervalSessionResult(schedule: schedule, endedAt: schedule.endsAt, samples: samples)
    }

    public func start(configuration: IntervalConfiguration, title: String? = nil, hooks: IntervalTimerHooks = .init(),
                      liveSource: (any WorkoutLiveSampleSource)? = nil) async {
        guard !isRunning, configuration.isValid, !Task.isCancelled else { return }
        let id = UUID()
        let schedule = IntervalSchedule(configuration: configuration, startedAt: Date())
        self.id = id; self.schedule = schedule; self.hooks = hooks; isRunning = true; latestSample = nil; progress = nil
        samples = []
        self.title = WorkoutLogEntry.cleaned(title)
        savedWorkoutID = nil; completionHandled = false
        await hooks.started(id, schedule)
        guard self.id == id else { return }
        guard !Task.isCancelled else { await stop(); return }
        ticker = Task { [weak self] in
            var previousIndex: Int?
            while !Task.isCancelled {
                guard let self, self.id == id else { return }
                let next = schedule.progress(at: Date())
                if self.progress != next { self.progress = next }
                if next.phaseIndex != previousIndex {
                    previousIndex = next.phaseIndex
                    await hooks.changed(id, next)
                }
                guard self.id == id else { return }
                if next.phase == .complete {
                    await self.stop(keepResult: true)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        if let liveSource {
            let lease: WorkoutLiveSampleLease
            do { lease = try await liveSource.acquire(generation: id) }
            catch {
                if self.id == id, Task.isCancelled || error is CancellationError { await stop() }
                return
            }
            guard self.id == id, isRunning, !Task.isCancelled else {
                await lease.cancel()
                if self.id == id { await stop() }
                return
            }
            self.lease = lease
            reader = Task { [weak self] in
                for await sample in lease.stream {
                    guard !Task.isCancelled, let self, self.id == id else { break }
                    self.latestSample = sample
                    self.samples.append(sample)
                }
                await lease.cancel()
            }
        }
    }

    public func stop(keepResult: Bool = false) async {
        let endedID = id
        let ended = hooks.ended
        id = nil; isRunning = false
        ticker?.cancel(); ticker = nil
        reader?.cancel(); reader = nil
        let oldLease = lease; lease = nil
        // Detach all old state before suspending. A new start may run while
        // the old lease or Live Activity is finishing.
        if !keepResult { schedule = nil; progress = nil; latestSample = nil }
        await oldLease?.cancel()
        if let endedID { await ended(endedID) }
    }

    public func heartRate(at date: Date) -> Int? {
        guard isRunning, let sample = latestSample, let bpm = sample.heartRate, bpm > 0,
              (0...WorkoutLiveMetrics.heartRateFreshness).contains(date.timeIntervalSince(sample.timestamp)) else { return nil }
        return bpm
    }
}
