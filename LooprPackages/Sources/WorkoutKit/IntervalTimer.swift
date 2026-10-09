import Combine
import Foundation

public struct IntervalConfiguration: Equatable, Sendable {
    public let workSeconds: Int
    public let restSeconds: Int
    public let rounds: Int
    public init(workSeconds: Int = 30, restSeconds: Int = 30, rounds: Int = 10) {
        self.workSeconds = workSeconds; self.restSeconds = restSeconds; self.rounds = rounds
    }
    public static let thirtyThirty = Self()
    public static let tabata = Self(workSeconds: 20, restSeconds: 10, rounds: 8)
    public var isValid: Bool { (1...3600).contains(workSeconds) && (0...3600).contains(restSeconds) && (1...100).contains(rounds) }
    /// Each round contains work and rest, including the last round.
    public var duration: TimeInterval { Double(rounds) * (Double(workSeconds) + Double(restSeconds)) }
}

public enum IntervalPhase: String, Equatable, Sendable { case work, rest, complete }

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
        guard configuration.isValid, date < endsAt else {
            return .init(phase: .complete, round: configuration.rounds, phaseIndex: configuration.rounds * 2,
                         phaseStartedAt: endsAt, phaseEndsAt: endsAt, remainingSeconds: 0)
        }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let cycle = Double(configuration.workSeconds + configuration.restSeconds)
        let roundIndex = min(configuration.rounds - 1, Int(elapsed / cycle))
        let cycleStart = startedAt.addingTimeInterval(Double(roundIndex) * cycle)
        let workEnd = cycleStart.addingTimeInterval(Double(configuration.workSeconds))
        let working = date < workEnd
        let end = working ? workEnd : cycleStart.addingTimeInterval(cycle)
        return .init(phase: working ? .work : .rest, round: roundIndex + 1,
                     phaseIndex: roundIndex * 2 + (working ? 0 : 1),
                     phaseStartedAt: working ? cycleStart : workEnd, phaseEndsAt: end,
                     remainingSeconds: max(0, Int(ceil(end.timeIntervalSince(date)))))
    }
    public var phaseStarts: [Date] {
        guard configuration.isValid else { return [] }
        return (0..<configuration.rounds).flatMap { round -> [Date] in
            let start = startedAt.addingTimeInterval(Double(round * (configuration.workSeconds + configuration.restSeconds)))
            return configuration.restSeconds > 0
                ? [start, start.addingTimeInterval(Double(configuration.workSeconds))] : [start]
        }
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
    private var id: UUID?
    private var ticker: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var lease: WorkoutLiveSampleLease?
    private var hooks = IntervalTimerHooks()
    public init() {}

    public func start(configuration: IntervalConfiguration, hooks: IntervalTimerHooks = .init(), liveSource: (any WorkoutLiveSampleSource)? = nil) async {
        guard !isRunning, configuration.isValid else { return }
        await stop()
        let id = UUID()
        let schedule = IntervalSchedule(configuration: configuration, startedAt: Date())
        self.id = id; self.schedule = schedule; self.hooks = hooks; isRunning = true; latestSample = nil
        await hooks.started(id, schedule)
        guard self.id == id else { return }
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
        if let liveSource, let lease = try? await liveSource.acquire(generation: id) {
            guard self.id == id, isRunning else { await lease.cancel(); return }
            self.lease = lease
            reader = Task { [weak self] in
                for await sample in lease.stream {
                    guard !Task.isCancelled, let self, self.id == id else { break }
                    self.latestSample = sample
                }
                await lease.cancel()
            }
        }
    }

    public func stop(keepResult: Bool = false) async {
        let endedID = id
        id = nil; isRunning = false
        ticker?.cancel(); ticker = nil
        reader?.cancel(); reader = nil
        let oldLease = lease; lease = nil
        await oldLease?.cancel()
        if let endedID { await hooks.ended(endedID) }
        if !keepResult { schedule = nil; progress = nil; latestSample = nil }
    }

    public func heartRate(at date: Date) -> Int? {
        guard isRunning, let sample = latestSample, let bpm = sample.heartRate, bpm > 0,
              (0...WorkoutLiveMetrics.heartRateFreshness).contains(date.timeIntervalSince(sample.timestamp)) else { return nil }
        return bpm
    }
}
