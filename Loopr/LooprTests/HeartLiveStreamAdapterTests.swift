import Foundation
import BluetoothKit
import DomainKit
import HeartKit
import Testing
@testable import Loopr

private actor HeartLiveRuntimeFixture: LooprHeartLiveRuntime {
    private let manager = LiveStreamManager(historySafetyPassed: true)
    var frames: [LiveStreamSample] = []
    let generation: UInt64 = 7

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        try await manager.acquire(kind: kind, consumer: consumer)
    }

    func acquireLiveEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamEventSubscription {
        try await manager.acquireEventStream(kind: kind, consumer: consumer, generation: generation)
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] {
        frames.filter { $0.kind == kind }
    }

    func append(_ frame: LiveStreamSample) { frames.append(frame) }

    func consumerCount() async -> Int {
        await manager.consumerCount(for: .compactHeartRateRR)
    }

    func ingest(_ payload: Data, generation: UInt64 = 7) async {
        await manager.ingest(
            kind: .compactHeartRateRR,
            payload: payload,
            receivedAt: Date(timeIntervalSince1970: 42),
            generation: generation
        )
    }
}

private actor RefreshingHeartLiveClient: HeartLiveStreamClient {
    private var values: [HeartLiveSample]

    init(_ values: [HeartLiveSample]) { self.values = values }

    func acquire(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveConsumerLease {
        HeartLiveConsumerLease { }
    }

    func samples(for kind: LiveStreamKind) async -> [HeartLiveSample] { values }
    func replace(_ samples: [HeartLiveSample]) { values = samples }
}

@MainActor
@Test
func sharedHeartLiveAdapterMapsOpaqueFramesAndReleasesOnce() async throws {
    let runtime = HeartLiveRuntimeFixture()
    await runtime.append(LiveStreamSample(kind: .compactHeartRateRR, payload: Data([0x28, 0x01]), receivedAt: Date(timeIntervalSince1970: 42)))
    let client = SyncKitHeartLiveStreamClient(runtime: runtime)

    let lease = try await client.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
    #expect(await runtime.consumerCount() == 1)
    let samples = await client.samples(for: .compactHeartRateRR)
    #expect(samples.count == 1)
    #expect(samples[0].heartRateBPM == nil)
    #expect(samples[0].rawPayload == Data([0x28, 0x01]))
    #expect(await lease.release())
    #expect(!(await lease.release()))
    #expect(await runtime.consumerCount() == 0)
}

@MainActor
@Test
func unavailableHeartLiveClientFailsClosed() async {
    let client = UnavailableHeartLiveStreamClient()
    do {
        _ = try await client.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
        Issue.record("unavailable live stream must not acquire")
    } catch HeartLiveStreamAdapterError.unavailable {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(await client.samples(for: .compactHeartRateRR).isEmpty)
}

@MainActor
@Test
func typedHeartEventsDecodeMalformedAndStaleFramesFailClosedAndCancelOnce() async throws {
    let runtime = HeartLiveRuntimeFixture()
    let client = SyncKitHeartLiveStreamClient(runtime: runtime)
    let subscription = try await client.acquireEventStream(
        kind: .compactHeartRateRR,
        consumer: .spotCheck
    )

    let nextSample = Task { @Sendable in
        var iterator = subscription.stream.makeAsyncIterator()
        return await iterator.next()
    }

    // Missing RR bytes are malformed and a different connection generation
    // is stale. Neither may reach the feature stream.
    await runtime.ingest(Data([0x01, 0x01, 0, 0, 0, 0, 0, 72, 1]))
    await runtime.ingest(compactHeartRatePayload(), generation: 8)
    await runtime.ingest(compactHeartRatePayload())

    let sample = try #require(await nextSample.value)
    #expect(sample.generation == 7)
    #expect(sample.heartRateBPM == 72.0)
    #expect(sample.rrIntervalsMilliseconds == [1_000.0, 1_012.0])
    #expect(sample.wearing)

    #expect(await subscription.cancel())
    #expect(!(await subscription.cancel()))
    #expect(await runtime.consumerCount() == 0)
}

private func compactHeartRatePayload() -> Data {
    Data([
        0x01,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x00,
        72,
        2,
        0xE8, 0x03,
        0xF4, 0x03
    ])
}

@MainActor
@Test
func liveHeartRateDoesNotRequireSavedHistoryAndKeepsTraceOnDisconnect() async {
    let repository = InMemoryHeartRepository(values: [:])
    let client = InMemoryHeartLiveStreamClient(values: [
        .compactHeartRateRR: [HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 72, rrMilliseconds: nil, receivedAt: Date())]
    ])
    let viewModel = HeartViewModel(repository: repository, liveClient: client)
    await viewModel.load(day: HeartFixtures.day)
    #expect(viewModel.snapshot == nil)
    await viewModel.startLive()
    #expect(viewModel.liveSamples.last?.heartRateBPM == 72)
    #expect(viewModel.loadState == .live)
    await viewModel.load(day: HeartFixtures.day)
    #expect(viewModel.loadState == .live)
    await viewModel.stopLive()
    #expect(viewModel.liveSamples.last?.heartRateBPM == 72)
    #expect(viewModel.liveStats.count == 1)
    #expect(await client.releaseCount() == 1)
    await viewModel.startLive()
    #expect(viewModel.liveSamples.last?.heartRateBPM == 72)
    await viewModel.stopLive()
    #expect(await client.releaseCount() == 2)
}

@MainActor
@Test
func liveHistorySurvivesRefreshAndASecondScreenModel() async {
    let now = Date()
    let samples = [HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 110,
                                   rrMilliseconds: nil, receivedAt: now.addingTimeInterval(-1)),
                   HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 112,
                                   rrMilliseconds: nil, receivedAt: now)]
    let client = InMemoryHeartLiveStreamClient(values: [.compactHeartRateRR: samples])
    let history = HeartLiveHistoryStore()
    let first = HeartViewModel(repository: InMemoryHeartRepository(), liveClient: client, liveHistory: history)
    await first.startLive()
    await first.refreshLiveSamples()
    #expect(first.liveSamples.count == 2)
    #expect(first.liveStats.count == 2)
    let zones = HeartRateZoneSettings().resolved(age: 40)!
    #expect(first.liveStats.seconds(in: 2, zones: zones) == 1)
    await first.stopLive()

    let detail = HeartViewModel(repository: InMemoryHeartRepository(), liveClient: client, liveHistory: history)
    #expect(detail.liveSamples.count == 2)
    #expect(detail.liveStats.count == 2)
    await detail.startLive()
    #expect(detail.liveSamples.count == 2)
    #expect(detail.liveStats.count == 2)
    #expect(detail.liveStats.seconds(in: 2, zones: zones) == 1)
    await detail.stopLive()
}

@MainActor
@Test
func emptyStreamRefreshDoesNotEraseRecordedLiveHistory() async {
    let sample = HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 93,
                                 rrMilliseconds: nil, receivedAt: Date())
    let client = RefreshingHeartLiveClient([sample])
    let model = HeartViewModel(repository: InMemoryHeartRepository(), liveClient: client)
    await model.startLive()
    await client.replace([])
    await model.refreshLiveSamples()
    #expect(model.liveSamples == [sample])
    #expect(model.liveStats.count == 1)
    await model.stopLive()
}

@MainActor
@Test
func liveConnectionFailureKeepsSavedHeartHistoryVisible() async {
    let viewModel = HeartViewModel(
        repository: InMemoryHeartRepository(values: [HeartFixtures.day: HeartFixtures.populated]),
        liveEventClient: UnavailableHeartLiveEventClient()
    )
    await viewModel.load(day: HeartFixtures.day)
    await viewModel.startLive()
    #expect(viewModel.snapshot != nil)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.liveError != nil)
}
