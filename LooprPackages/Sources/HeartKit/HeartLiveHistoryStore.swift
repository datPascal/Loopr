import Combine
import Foundation

/// One foreground-app history shared by the Heart tab and its live detail.
/// Acquisition may stop while this store keeps the recent recorded samples.
@MainActor
public final class HeartLiveHistoryStore: ObservableObject {
    public struct Snapshot: Equatable {
        public let recentSamples: [HeartLiveSample]
        public let stats: HeartLiveSessionStats
    }

    public nonisolated static let windowSeconds: TimeInterval = 60 * 60
    public static let sessionGapSeconds = HeartLiveSessionStats.sessionGapSeconds
    public nonisolated static let maximumSamples = 3_600

    @Published public private(set) var snapshot = Snapshot(recentSamples: [], stats: HeartLiveSessionStats())
    public private(set) var bufferedSamples: [HeartLiveSample] = []

    private var stats = HeartLiveSessionStats()
    private var seedSource: (@Sendable () async -> [HeartLiveSample])?
    private var seedTask: Task<[HeartLiveSample], Never>?
    private var seeded = false

    public init(seed: (@Sendable () async -> [HeartLiveSample])? = nil) {
        seedSource = seed
    }

    public func configureSeed(_ source: @escaping @Sendable () async -> [HeartLiveSample]) {
        guard !seeded else { return }
        seedSource = source
    }

    /// The database query runs in the supplied source, away from the main actor.
    /// A second screen waits for the same read instead of starting another one.
    public func seedIfNeeded() async {
        guard !seeded else { return }
        if seedTask == nil {
            let source = seedSource
            seedTask = Task { await source?() ?? [] }
        }
        guard let seedTask else { return }
        let saved = await seedTask.value
        guard !seeded else { return }
        seeded = true
        self.seedTask = nil
        let newestLive = bufferedSamples.last?.receivedAt
        let eligible = saved.filter { sample in
            guard HeartLiveReading.rate(of: sample) != nil else { return false }
            return newestLive.map { sample.receivedAt < $0 } ?? true
        }
        let ordered = eligible.sorted { $0.receivedAt < $1.receivedAt } + bufferedSamples
        bufferedSamples = []
        stats = HeartLiveSessionStats()
        for sample in ordered { insert(sample) }
        publish()
    }

    public func append(_ sample: HeartLiveSample) {
        if insert(sample) { publish() }
    }

    public func append(_ samples: [HeartLiveSample]) {
        var changed = false
        for sample in samples.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            changed = insert(sample) || changed
        }
        if changed { publish() }
    }

    /// Called by the visible live leaf so its line ages out without clearing
    /// the last reading or the session totals.
    public func refreshWindow(at now: Date) {
        if let last = bufferedSamples.last,
           now.timeIntervalSince(last.receivedAt) > Self.sessionGapSeconds,
           stats.count > 0 {
            stats = HeartLiveSessionStats()
        }
        let recent = recentSamples(at: now)
        guard recent != snapshot.recentSamples || stats != snapshot.stats else { return }
        snapshot = Snapshot(recentSamples: recent, stats: stats)
    }

    public func clear() {
        seedTask?.cancel()
        seedTask = nil
        seedSource = nil
        seeded = true
        bufferedSamples = []
        stats = HeartLiveSessionStats()
        snapshot = Snapshot(recentSamples: [], stats: stats)
    }

    @discardableResult
    private func insert(_ sample: HeartLiveSample) -> Bool {
        guard HeartLiveReading.rate(of: sample) != nil else { return false }
        if let last = bufferedSamples.last {
            guard sample.receivedAt > last.receivedAt else { return false }
        }
        bufferedSamples.append(sample)
        stats.append(sample)
        let cutoff = sample.receivedAt.addingTimeInterval(-Self.windowSeconds)
        if let firstKept = bufferedSamples.firstIndex(where: { $0.receivedAt >= cutoff }), firstKept > 0 {
            bufferedSamples.removeFirst(firstKept)
        }
        if bufferedSamples.count > Self.maximumSamples {
            bufferedSamples.removeFirst(bufferedSamples.count - Self.maximumSamples)
        }
        return true
    }

    private func publish() {
        snapshot = Snapshot(recentSamples: recentSamples(at: Date()), stats: stats)
    }

    private func recentSamples(at now: Date) -> [HeartLiveSample] {
        let cutoff = now.addingTimeInterval(-HeartLiveReading.lineSeconds)
        guard let first = bufferedSamples.firstIndex(where: { $0.receivedAt >= cutoff }) else {
            return bufferedSamples.suffix(1).map { $0 }
        }
        return Array(bufferedSamples[first...])
    }
}
