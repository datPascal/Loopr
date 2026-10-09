import XCTest
import ProtocolKit
@testable import BluetoothKit

final class DelegateQueueBudgetTests: XCTestCase {
    func testTenThousandDelegateBytesKeepParserAndLiveBuffersBounded() async throws {
        var reassembler = FrameReassembler()
        for byte in Data(repeating: 0xff, count: 10_000) {
            _ = reassembler.ingest(Data([byte]))
            XCTAssertLessThanOrEqual(reassembler.maximumObservedBufferedBytes, FrameReassembler.maximumBufferedBytes)
        }

        let manager = LiveStreamManager(bufferCapacity: 256, historySafetyPassed: true)
        let lease = try await manager.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
        let start = Date(timeIntervalSince1970: 1_787_472_000)
        var summaryCount = 0
        for packet in 0..<10_000 {
            let timestamp = start.addingTimeInterval(Double(packet) / 100)
            await manager.ingest(
                kind: .compactHeartRateRR,
                payload: Data([UInt8(truncatingIfNeeded: packet)]),
                receivedAt: timestamp
            )
            if await manager.summary(for: .compactHeartRateRR, at: timestamp) != nil {
                summaryCount += 1
            }
        }
        let bufferedCount = await manager.bufferedSamples(for: .compactHeartRateRR).count
        let released = await lease.release()
        XCTAssertLessThanOrEqual(bufferedCount, 256)
        XCTAssertLessThan(summaryCount, 500, "100 Hz input must not become per-packet UI observation")
        XCTAssertTrue(released)
    }
}

final class LiveHRUpdateBudgetTests: XCTestCase {
    func testSummaryThrottleIsAtMostFourUIUpdatesPerSecond() async throws {
        XCTAssertEqual(LiveStreamManager.defaultSummaryInterval, 0.25)
        let manager = LiveStreamManager(historySafetyPassed: true)
        let lease = try await manager.acquire(kind: .compactHeartRateRR, consumer: .spotCheck)
        let start = Date(timeIntervalSince1970: 1_787_472_000)
        var updates = 0
        for packet in 0..<1_000 {
            let timestamp = start.addingTimeInterval(Double(packet) / 100)
            await manager.ingest(kind: .compactHeartRateRR, payload: Data([1]), receivedAt: timestamp)
            if await manager.summary(for: .compactHeartRateRR, at: timestamp) != nil { updates += 1 }
        }
        XCTAssertLessThanOrEqual(updates, 40)
        XCTAssertLessThan(updates, 1_000)
        let released = await lease.release()
        XCTAssertTrue(released)
    }
}
