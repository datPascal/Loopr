import BluetoothKit
import HeartKit
import XCTest

@MainActor
final class HeartLiveHistoryStoreTests: XCTestCase {
    func testGapOverThirtyMinutesStartsNewSessionWithoutInventingZoneTime() {
        let store = HeartLiveHistoryStore()
        let start = Date()
        store.append([sample(100, at: start.addingTimeInterval(-1_900)),
                      sample(110, at: start.addingTimeInterval(-1_899))])
        XCTAssertEqual(store.snapshot.stats.count, 2)
        store.append(sample(120, at: start))
        XCTAssertEqual(store.snapshot.stats.count, 1)
        XCTAssertEqual(store.snapshot.stats.maximumBPM, 120)
        XCTAssertEqual(store.snapshot.stats.startedAt, start)
    }

    func testSeededHistorySurvivesFirstRefreshAndRelaunch() async {
        let now = Date()
        let saved = [sample(81, at: now.addingTimeInterval(-3)),
                     sample(82, at: now.addingTimeInterval(-2))]
        let store = HeartLiveHistoryStore(seed: { saved })
        await store.seedIfNeeded()
        XCTAssertEqual(store.snapshot.recentSamples.count, 2)
        XCTAssertEqual(store.snapshot.stats.count, 2)
        store.append(sample(83, at: now.addingTimeInterval(-1)))
        await store.seedIfNeeded()
        XCTAssertEqual(store.snapshot.stats.count, 3)

        let relaunched = HeartLiveHistoryStore(seed: { saved })
        await relaunched.seedIfNeeded()
        XCTAssertEqual(relaunched.snapshot.recentSamples.map(\.heartRateBPM), [81, 82])
        XCTAssertEqual(relaunched.snapshot.stats.count, 2)
    }

    func testQuietGapExpiresSessionTotalsButKeepsLastReading() {
        let store = HeartLiveHistoryStore()
        let now = Date()
        store.append(sample(90, at: now.addingTimeInterval(-1_801)))
        store.refreshWindow(at: now)
        XCTAssertEqual(store.snapshot.stats.count, 0)
        XCTAssertEqual(store.snapshot.recentSamples.last?.heartRateBPM, 90)
        store.append(sample(95, at: now))
        XCTAssertEqual(store.snapshot.stats.count, 1)
    }

    func testOneHourBufferAndSampleCountStayBounded() {
        let store = HeartLiveHistoryStore()
        let end = Date()
        let samples = (0..<4_200).map { second in
            sample(80, at: end.addingTimeInterval(TimeInterval(second - 4_199)))
        }
        store.append(samples)
        XCTAssertEqual(store.bufferedSamples.count, HeartLiveHistoryStore.maximumSamples)
        XCTAssertGreaterThanOrEqual(store.snapshot.recentSamples.count, 179)
        XCTAssertLessThanOrEqual(store.snapshot.recentSamples.count, 181)
        XCTAssertEqual(store.snapshot.stats.count, 4_200)
    }

    private func sample(_ bpm: Double, at date: Date) -> HeartLiveSample {
        HeartLiveSample(kind: .compactHeartRateRR, heartRateBPM: bpm,
                        rrMilliseconds: nil, receivedAt: date)
    }
}
