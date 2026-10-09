import Combine
import Foundation
import DomainKit
import DesignSystem
import BluetoothKit

public enum HeartLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case live
    case failed(String)
}

public enum HeartLiveSessionError: Error, Equatable, Sendable {
    case unavailable
}

/// What the Heart tab says when the live stream or a spot check cannot run.
///
/// Errors from the Bluetooth layer are written for engineers ("Live streams
/// remain disabled until history commit safety has passed."). Right after a
/// reconnect the band offloads its history and refuses live data for a while,
/// which is normal and not worth an error. This is the one place those errors
/// become short, calm copy.
public enum HeartLiveErrorCopy {
    public static let syncing = "Your band is syncing. Live heart rate starts when it's done."
    public static let reconnecting = "Connecting to your band."
    public static let waiting = "Live heart rate starts when your band is ready."

    public static func live(_ error: Error) -> String {
        switch error as? LiveStreamError {
        case .historySafetyRequired: syncing
        case .generationUnavailable: reconnecting
        default: waiting
        }
    }

    public static func spotCheck(_ error: Error) -> String {
        switch error as? LiveStreamError {
        case .historySafetyRequired:
            "Your band is syncing. Try the spot check again when it's done."
        case .generationUnavailable:
            "Your band reconnected during the reading. Try again."
        default:
            "The reading didn't finish. Keep the strap snug and try again."
        }
    }
}

public actor HeartLiveSession {
    private let client: (any HeartLiveStreamClient)?
    private let eventClient: (any HeartLiveEventStreamClient)?
    private var lease: HeartLiveConsumerLease?
    private var eventSubscription: HeartLiveEventSubscription?
    private var eventTask: Task<Void, Never>?
    private var sampleContinuation: AsyncStream<HeartLiveSample>.Continuation?
    private var decodedSamples: [HeartLiveSample] = []
    private var activeGeneration: UInt64?

    public init(client: (any HeartLiveStreamClient)? = nil, eventClient: (any HeartLiveEventStreamClient)? = nil) {
        self.client = client
        self.eventClient = eventClient
    }

    public func start() async throws {
        guard lease == nil, eventSubscription == nil else { return }
        if let eventClient {
            let subscription = try await eventClient.acquireEventStream(kind: .compactHeartRateRR, consumer: .spotCheck)
            if Task.isCancelled {
                _ = await subscription.cancel()
                return
            }
            decodedSamples.removeAll(keepingCapacity: true)
            activeGeneration = subscription.generation
            eventSubscription = subscription
            let generation = subscription.generation
            eventTask = Task { [weak self, subscription] in
                for await sample in subscription.stream {
                    guard !Task.isCancelled else { break }
                    await self?.accept(sample, generation: generation)
                }
                await self?.eventStreamEnded(generation: generation)
            }
            return
        }
        guard let client else { throw HeartLiveSessionError.unavailable }
        let acquired = try await client.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
        if Task.isCancelled {
            _ = await acquired.release()
            return
        }
        lease = acquired
    }

    public func samples() async -> [HeartLiveSample] {
        if eventClient != nil { return decodedSamples }
        guard let client else { return [] }
        return await client.samples(for: .compactHeartRateRR)
    }

    public func samplesStream() -> AsyncStream<HeartLiveSample> {
        let pair = AsyncStream<HeartLiveSample>.makeStream(bufferingPolicy: .bufferingNewest(256))
        sampleContinuation?.finish()
        sampleContinuation = pair.continuation
        return pair.stream
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if let eventSubscription {
            self.eventSubscription = nil
            activeGeneration = nil
            _ = await eventSubscription.cancel()
        }
        if let lease {
            self.lease = nil
            _ = await lease.release()
        }
        sampleContinuation?.finish()
        sampleContinuation = nil
    }

    public func isActive() -> Bool { lease != nil || eventSubscription != nil }

    private func accept(_ sample: HeartLiveDecodedSample, generation: UInt64) {
        guard activeGeneration == generation, sample.generation == generation else { return }
        let legacy = sample.legacySample
        decodedSamples.append(legacy)
        if decodedSamples.count > 256 { decodedSamples.removeFirst(decodedSamples.count - 256) }
        _ = sampleContinuation?.yield(legacy)
    }

    private func eventStreamEnded(generation: UInt64) async {
        guard activeGeneration == generation else { return }
        eventTask = nil
        if let eventSubscription {
            self.eventSubscription = nil
            activeGeneration = nil
            _ = await eventSubscription.cancel()
        }
        sampleContinuation?.finish()
        sampleContinuation = nil
    }
}

@MainActor
public final class HeartViewModel: ObservableObject {
    @Published public private(set) var loadState: HeartLoadState = .idle
    @Published public private(set) var snapshot: HeartDaySnapshot?
    /// The day the newest `load(day:)` asked for.
    private var requestedDay: DayIdentity?
    /// Set once a load for the requested day has finished. A stopped live
    /// stream then returns to `.loaded`, never to `.idle`, which the screen
    /// reads as a first load and answers with a skeleton.
    private var hasCompletedLoad = false
    public var liveSamples: [HeartLiveSample] { liveHistory.snapshot.recentSamples }
    public var liveStats: HeartLiveSessionStats { liveHistory.snapshot.stats }
    @Published public private(set) var liveError: String?
    @Published public private(set) var spotCheck: HeartSpotCheckResult?

    private let repository: any HeartRepository
    private let spotCheckRepository: (any HeartSpotCheckRepository)?
    private let spotCheckRunner: (any HeartSpotCheckRunner)?
    private let liveSession: HeartLiveSession?
    private let liveHistory: HeartLiveHistoryStore
    private var historyCancellable: AnyCancellable?
    private var liveTask: Task<Void, Never>?
    private var liveRunID: UUID?

    public init(
        repository: any HeartRepository,
        spotCheckRepository: (any HeartSpotCheckRepository)? = nil,
        spotCheckRunner: (any HeartSpotCheckRunner)? = nil,
        liveClient: (any HeartLiveStreamClient)? = nil,
        liveEventClient: (any HeartLiveEventStreamClient)? = nil,
        liveHistory: HeartLiveHistoryStore? = nil
    ) {
        self.repository = repository
        self.spotCheckRepository = spotCheckRepository
        self.spotCheckRunner = spotCheckRunner
        self.liveHistory = liveHistory ?? HeartLiveHistoryStore()
        if liveClient != nil || liveEventClient != nil {
            self.liveSession = HeartLiveSession(client: liveClient, eventClient: liveEventClient)
        } else {
            self.liveSession = nil
        }
        historyCancellable = self.liveHistory.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func load(day: DayIdentity) async {
        if requestedDay != day { hasCompletedLoad = false }
        requestedDay = day
        if let shown = snapshot, shown.day != day {
            // Another day's numbers must never sit under this day's label.
            snapshot = nil
        }
        if snapshot == nil { loadState = .loading }
        do {
            // An identical reload must not republish the day. While history
            // offloads, this screen reloads every few seconds.
            let loaded = try await repository.readHeartDay(for: day)
            // A slower read for a day the person already left must not land
            // on top of the day they moved to.
            guard requestedDay == day else { return }
            hasCompletedLoad = true
            if snapshot != loaded { snapshot = loaded }
            let state: HeartLoadState = await liveSession?.isActive() == true ? .live : .loaded
            if loadState != state { loadState = state }
        } catch is CancellationError {
            guard requestedDay == day else { return }
            loadState = .idle
        } catch {
            guard requestedDay == day else { return }
            snapshot = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    public func startLive() async {
        await liveHistory.seedIfNeeded()
        guard let liveSession else {
            loadState = .failed("Live heart data is unavailable.")
            return
        }
        do {
            liveTask?.cancel()
            let stream = await liveSession.samplesStream()
            try await liveSession.start()
            liveHistory.append(await liveSession.samples())
            liveTask = Task { @MainActor [weak self] in
                for await sample in stream {
                    guard !Task.isCancelled else { return }
                    self?.liveHistory.append(sample)
                }
            }
            // Cleared only once the stream is up, so a retry loop does not
            // blink the message off and on every two seconds.
            if liveError != nil { liveError = nil }
            loadState = .live
        } catch {
            let message = HeartLiveErrorCopy.live(error)
            if liveError != message { liveError = message }
            if snapshot == nil, loadState != .loaded { loadState = .loaded }
        }
    }

    /// Keeps acquisition tied to the visible, foreground screen and retries
    /// when a connection is ready before the stream's setup has completed.
    public func runLive() async {
        guard liveSession != nil else { return }
        let runID = UUID()
        liveRunID = runID
        while !Task.isCancelled, liveRunID == runID {
            if await liveSession?.isActive() != true { await startLive() }
            liveHistory.refreshWindow(at: Date())
            do { try await Task.sleep(for: .seconds(2)) }
            catch { break }
        }
        if liveRunID == runID {
            await stopLive()
        }
    }

    public func refreshLiveSamples() async {
        guard let liveSession else { return }
        liveHistory.append(await liveSession.samples())
    }

    public func loadLiveHistory() async {
        await liveHistory.seedIfNeeded()
        liveHistory.refreshWindow(at: Date())
    }

    public func stopLive() async {
        liveTask?.cancel()
        liveTask = nil
        // `runLive` calls this after its own task has been cancelled, which is
        // exactly what happens when the screen goes away. Awaiting the stop
        // directly made every stream-off write and every inter-command pause
        // throw straight back out of a cancelled task, so the band was left
        // streaming. Detaching the teardown from that cancellation lets the
        // disable sequence actually reach the wire.
        let session = liveSession
        await Task { await session?.stop() }.value
        if liveError != nil { liveError = nil }
        if loadState == .live { loadState = snapshot != nil || hasCompletedLoad ? .loaded : .idle }
    }

    public func runSpotCheck() async {
        guard spotCheckRunner != nil || spotCheckRepository != nil else {
            loadState = .failed("Spot check is unavailable.")
            return
        }
        do {
            if let spotCheckRunner {
                spotCheck = try await spotCheckRunner.runSpotCheck()
            } else if let spotCheckRepository {
                spotCheck = try await spotCheckRepository.runSpotCheck()
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            loadState = .failed(HeartLiveErrorCopy.spotCheck(error))
        }
    }

    public func deleteAllData() async {
        await liveSession?.stop()
        snapshot = nil
        liveHistory.clear()
        spotCheck = nil
        loadState = .idle
    }
}
