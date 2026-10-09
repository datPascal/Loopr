import Foundation
import Combine
import Testing
import DomainKit
import DesignSystem
import BluetoothKit
@testable import HeartKit

struct HeartKitTests {
    @Test
    func stateMatrixCoversAllFourteenStatesAndAbsentIsNotZero() {
        #expect(HeartFixtures.allStates.count == 14)
        let absent = HeartFixtures.snapshot(for: .absent).metric(.restingHeartRate)
        let zero = HeartFixtures.snapshot(for: .measuredZero).metric(.restingHeartRate)
        #expect(absent?.value == nil)
        #expect(absent?.state == .absent)
        #expect(zero?.value == "0")
        #expect(zero?.state == .measuredZero)
        #expect(absent?.accessibilitySummary != zero?.accessibilitySummary)
    }

    @Test
    func canonicalMetricSourcesAndQualityExplanationsRemainVisible() {
        let snapshot = HeartFixtures.populated
        #expect(snapshot.source == "ANA-02.canonical")
        #expect(snapshot.metric(.rmssd)?.source == "ANA-02.hrv")
        #expect(snapshot.metric(.rmssd)?.qualityDetail == "PRV-derived")
        #expect(snapshot.metric(.respiration)?.source == "ANA-02.respiration")
        #expect(HeartTrendFilter.points(snapshot.trend, range: .week).count == 7)
    }

    @Test
    func trendModelDecodesWithoutFabricatingOlderRecords() throws {
        let snapshot = HeartFixtures.populated
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HeartDaySnapshot.self, from: data)
        #expect(decoded.trend == snapshot.trend)
        #expect(HeartTrendFilter.points(decoded.trend, range: .month).count == 7)
    }

    @Test
    func liveLeaseReleasesExactlyOnce() async throws {
        let client = InMemoryHeartLiveStreamClient()
        let session = HeartLiveSession(client: client)
        try await session.start()
        #expect(await session.isActive())
        await session.stop()
        await session.stop()
        #expect(await client.releaseCount() == 1)
        #expect(!(await session.isActive()))
        #expect(await client.acquisitionsMade().count == 1)
    }

    @Test
    func typedLiveEventMapperPreservesGenerationAndEveryRRInterval() {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = LiveStreamEvent(
            kind: .compactHeartRateRR,
            generation: 19,
            payload: strippedCompactPayload(
                timestamp: 1_780_840_486,
                heartRate: 65,
                rr: [800, 810, 820, 830]
            ),
            receivedAt: receivedAt
        )

        let decoded = HeartLiveEventMapper.decode(event)

        #expect(decoded?.generation == 19)
        #expect(decoded?.deviceTimestampSeconds == 1_780_840_486)
        #expect(decoded?.heartRateBPM == 65)
        #expect(decoded?.rrIntervalsMilliseconds == [800, 810, 820, 830])
        #expect(decoded?.legacySample.rrMilliseconds == 800)
        #expect(decoded?.receivedAt == receivedAt)
    }

    @Test
    func typedLiveEventMapperFailsClosedForOffWristAndWrongStream() {
        let offWrist = LiveStreamEvent(
            kind: .compactHeartRateRR,
            generation: 1,
            payload: strippedCompactPayload(timestamp: 100, heartRate: 65, rr: [900], wearing: 0),
            receivedAt: Date()
        )
        let wrongKind = LiveStreamEvent(
            kind: .realtimeRaw,
            generation: 1,
            payload: Data([0x01, 0x02]),
            receivedAt: Date()
        )

        #expect(HeartLiveEventMapper.decode(offWrist) == nil)
        #expect(HeartLiveEventMapper.decode(wrongKind) == nil)
    }

    @Test @MainActor
    func viewModelReadsCanonicalRepositoryAndUsesLiveLifecycle() async {
        let repository = InMemoryHeartRepository(values: [HeartFixtures.day: HeartFixtures.populated])
        let client = InMemoryHeartLiveStreamClient(values: [
            .compactHeartRateRR: [HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 56, rrMilliseconds: 1_070, receivedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        ])
        let spot = InMemoryHeartSpotCheckRepository(result: HeartFixtures.spotCheck)
        let viewModel = HeartViewModel(repository: repository, spotCheckRepository: spot, liveClient: client)

        await viewModel.load(day: HeartFixtures.day)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.snapshot?.source == "ANA-02.canonical")
        await viewModel.startLive()
        #expect(viewModel.loadState == .live)
        #expect(viewModel.liveSamples.count == 1)
        await viewModel.runSpotCheck()
        #expect(viewModel.spotCheck == HeartFixtures.spotCheck)
        await viewModel.stopLive()
        #expect(await client.releaseCount() == 1)
    }

    @Test @MainActor
    func liveSamplesDoNotRepublishTheSavedDayPresentation() async {
        let client = InMemoryHeartLiveStreamClient(values: [
            .compactHeartRateRR: [HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: 62,
                rrMilliseconds: 968, receivedAt: Date())]
        ])
        let model = HeartViewModel(repository: InMemoryHeartRepository(values: [HeartFixtures.day: HeartFixtures.populated]),
                                   liveClient: client)
        await model.load(day: HeartFixtures.day)
        let day = HeartDayPresentation(model: model)
        var dayPublishes = 0
        let subscription = day.objectWillChange.sink { dayPublishes += 1 }
        await model.refreshLiveSamples()
        #expect(model.liveSamples.count == 1)
        #expect(day.snapshot == HeartFixtures.populated)
        #expect(dayPublishes == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor
    func liveUnavailableAndSpotCheckUnavailableAreRecoverable() async {
        let repository = InMemoryHeartRepository(values: [HeartFixtures.day: HeartFixtures.populated])
        let viewModel = HeartViewModel(repository: repository)
        await viewModel.startLive()
        guard case .failed = viewModel.loadState else {
            Issue.record("Expected live unavailable failure")
            return
        }
        await viewModel.runSpotCheck()
        guard case .failed = viewModel.loadState else {
            Issue.record("Expected spot-check unavailable failure")
            return
        }
    }

    @Test @MainActor
    func screensConstructForAllFeatureRoutes() {
        let repository = InMemoryHeartRepository(values: [HeartFixtures.day: HeartFixtures.populated])
        let viewModel = HeartViewModel(repository: repository)
        _ = HeartScreen(viewModel: viewModel)
        _ = HeartSpotCheckScreen(viewModel: viewModel)
        _ = HeartLiveScreen(samples: [], state: .absent)
        _ = HeartDetailScreen(snapshot: HeartFixtures.populated)
        _ = HeartTrendsScreen(snapshot: HeartFixtures.populated)
        #expect(HeartRoute.allCases == [.live, .detail, .trends, .spotCheck, .stress])
    }

    private func strippedCompactPayload(
        timestamp: UInt32,
        heartRate: UInt8,
        rr: [UInt16],
        wearing: UInt8 = 1
    ) -> Data {
        var bytes = Data(repeating: 0, count: 20)
        bytes[0] = 0x28
        bytes[1] = 0x01
        bytes[2] = UInt8(truncatingIfNeeded: timestamp)
        bytes[3] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[4] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[5] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[8] = heartRate
        bytes[9] = UInt8(truncatingIfNeeded: rr.count)
        for (index, value) in rr.prefix(4).enumerated() {
            let offset = 10 + index * 2
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        bytes[18] = wearing
        return Data(bytes.dropFirst())
    }
}
