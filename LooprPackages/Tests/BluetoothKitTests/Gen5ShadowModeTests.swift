import XCTest
import ProtocolKit
@testable import BluetoothKit

private actor RecordingGen5ShadowSink: Gen5ShadowLedgerSink {
    private(set) var records: [(Int, Data)] = []
    func append(_ frame: Gen5ShadowFrame, ordinal: Int) { records.append((ordinal, frame.rawFrame)) }
    func snapshot() -> [(Int, Data)] { records }
}

final class Gen5ShadowModeQueueTests: XCTestCase {
    func testFramesUseOneOrderedQueueAndExposeNoAckPath() async throws {
        let sink = RecordingGen5ShadowSink()
        let coordinator = Gen5ShadowModeCoordinator(sink: sink)
        let burst = UUID()
        for model in [BandModel.whoop5, .whoopMG] {
            for byte in UInt8(0)..<5 {
                try await coordinator.receive(.init(
                    model: model, connectionGeneration: 9, burstID: burst,
                    rawFrame: Data([byte]), marker: Data([1, 0]), token: nil,
                    decodeOutcome: "rawArchive"
                ))
            }
        }
        let snapshot = await sink.snapshot()
        XCTAssertEqual(snapshot.map(\.0), Array(0..<10))
        XCTAssertEqual(snapshot.map { $0.1.first! }, [0, 1, 2, 3, 4, 0, 1, 2, 3, 4])
        XCTAssertFalse(Gen5ShadowModePolicy.sendsAcknowledgement)
    }
}

final class Gen5ShadowModeDeepBufferDisabledTests: XCTestCase {
    func testDeepBufferSetupCannotBeRequestedInShadowMode() {
        XCTAssertFalse(Gen5ShadowModePolicy.requestsDeepBuffers)
        XCTAssertFalse(Gen5ShadowModePolicy.encodableHistoryCommands.contains("r22Setup"))
        XCTAssertFalse(Gen5ShadowModePolicy.encodableHistoryCommands.contains("v20"))
        XCTAssertFalse(Gen5ShadowModePolicy.encodableHistoryCommands.contains("v21"))
        XCTAssertFalse(Gen5ShadowModePolicy.encodableHistoryCommands.contains("v26"))
    }
}
