import BluetoothKit
import Foundation
import StorageKit
import SyncKit
import XCTest
@testable import ProtocolKit

private actor Gen5RuntimeOrder {
    private var values: [String] = []
    private let pair = AsyncStream<String>.makeStream()

    func events() -> AsyncStream<String> { pair.stream }
    func record(_ value: String) {
        values.append(value)
        pair.continuation.yield(value)
    }
    func recorded() -> [String] { values }
}

private actor Gen5RuntimeStore: HistoryBatchStore, HistoryBatchAcknowledger {
    private let order: Gen5RuntimeOrder
    private var stored: [StoredHistoricalRecord] = []
    private var archives: [ArchivedHistoricalRecord] = []

    init(order: Gen5RuntimeOrder) { self.order = order }

    func commit(
        records: [StoredHistoricalRecord],
        archived: [ArchivedHistoricalRecord],
        boundary: HistoryCommitBoundary,
        diagnostics: HistoryBatchDiagnostics
    ) async throws -> DurableHistoryCommit {
        stored.append(contentsOf: records)
        archives.append(contentsOf: archived)
        await order.record("commit")
        switch boundary {
        case .tokenized(let token):
            return .ackEligible(CommittedHistoryBatch(
                token: token, batchID: diagnostics.batchID,
                recordCount: records.count, archivedCount: archived.count
            ))
        case .completionTail:
            return .completionTail(CommittedHistoryTail(
                batchID: diagnostics.batchID,
                recordCount: records.count, archivedCount: archived.count
            ))
        }
    }

    func markAcknowledged(batchID: String, updatedAt: Int64) async throws {
        await order.record("marked")
    }

    func counts() -> (Int, Int) { (stored.count, archives.count) }
    func heartRates() -> [UInt8?] { stored.map(\.heartRate) }
}

private final class Gen5RuntimeTransport: BLEPeripheralRetriever, BLEGATTDiscoverer, @unchecked Sendable {
    private let peripheral: UUID
    private let order: Gen5RuntimeOrder
    private let pair = AsyncStream<TransportEvent>.makeStream()
    private let lock = NSLock()
    private var written: [Data] = []
    private var sharingValue: UInt8 = 0x30
    var sharingWriteFailed = false

    init(peripheral: UUID, order: Gen5RuntimeOrder) {
        self.peripheral = peripheral
        self.order = order
    }

    func events() -> AsyncStream<TransportEvent> { pair.stream }
    func emit(_ event: TransportEvent) { pair.continuation.yield(event) }
    func retrieve(_ peripherals: [PeripheralID]) async -> [PeripheralID] { [peripheral] }
    func connect(_ peripheral: PeripheralID) async { emit(.connected(peripheral)) }
    func discoverServices(_ ids: [ServiceID]) async { emit(.servicesDiscovered([GATTProfile.gen5.service])) }
    func discoverCharacteristics(_ ids: [CharacteristicID]) async {
        emit(.characteristicsDiscovered([
            CharacteristicDescriptor(id: GATTProfile.gen5.command, properties: [.write]),
            CharacteristicDescriptor(id: GATTProfile.gen5.response, properties: [.notify]),
            CharacteristicDescriptor(id: GATTProfile.gen5.events, properties: [.notify]),
            CharacteristicDescriptor(id: GATTProfile.gen5.data, properties: [.notify])
        ]))
    }
    func setNotify(_ char: CharacteristicID, enabled: Bool) async {
        await order.record("notify")
        emit(.notificationStateChanged(char, enabled: enabled))
    }
    func write(_ data: Data, to char: CharacteristicID) async throws {
        lock.withLock { written.append(data) }
        let inner = try Gen5FrameCodec().decode(data).paddedInner
        if inner.count >= 68, inner[2] == 119 {
            if sharingWriteFailed { throw TransportError.disconnected }
            sharingValue = inner[36]
        }
        if inner.count >= 3, inner[2] == 121 {
            let reply = Data([0x24, 99, 121, inner[1], 1, 1]) + HeartRateSharingCommand.keyField
                + Data([sharingValue]) + Data(repeating: 0, count: 31)
            emit(.value(GATTProfile.gen5.response, try Gen5FrameCodec().encode(reply,
                directionMarker: Gen5FrameEnvelope.observedInboundDirectionMarker)))
        }
        if inner.count >= 3, inner[2] == 0x91 { await order.record("hello") }
        if inner.count >= 3, inner[2] == 0x17 { await order.record("ack") }
    }
    func disconnect() async {}
    func writes() -> [Data] { lock.withLock { written } }
}

final class Gen5ExperimentalRuntimeTests: XCTestCase {
    func testHeartRateSharingReadsBandStateAndBatteryEventsRespectGen5Layout() async throws {
        let peripheral = UUID()
        let order = Gen5RuntimeOrder()
        let transport = Gen5RuntimeTransport(peripheral: peripheral, order: order)
        let runtime = Gen5ExperimentalRuntime(transport: transport, peripheral: peripheral,
            model: .whoop5, store: Gen5RuntimeStore(order: order))
        let ready = expectation(description: "ready")
        let states = await runtime.states()
        let task = Task {
            for await state in states where state.setupComplete { ready.fulfill(); break }
        }
        await runtime.start()
        transport.emit(.managerState(.poweredOn))
        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        let enabled = try await runtime.setHeartRateSharing(enabled: true)
        XCTAssertEqual(enabled, true)
        let disabled = try await runtime.setHeartRateSharing(enabled: false)
        XCTAssertEqual(disabled, false)
        transport.sharingWriteFailed = true
        do {
            _ = try await runtime.setHeartRateSharing(enabled: true)
            XCTFail("A failed write must not become a confirmed setting")
        } catch { XCTAssertEqual(error as? TransportError, .disconnected) }
        transport.sharingWriteFailed = false
        var event = Data(repeating: 0, count: 24)
        event[0] = 0x30; event[2] = 3; event[10] = 11
        event[13] = 0x2c; event[14] = 1; event[22] = 1
        let battery = expectation(description: "charging battery event")
        let observation = Task {
            for await state in states where state.charging == true {
                XCTAssertEqual(state.batteryPercentage, 30)
                battery.fulfill(); break
            }
        }
        transport.emit(.value(GATTProfile.gen5.events, try Gen5FrameCodec().encode(event,
            directionMarker: Gen5FrameEnvelope.observedInboundDirectionMarker)))
        await fulfillment(of: [battery], timeout: 5)
        observation.cancel()
        await runtime.stop()
        let stopped = await runtime.currentState()
        XCTAssertNil(stopped.charging)
        do {
            _ = try await runtime.setHeartRateSharing(enabled: false)
            XCTFail("A stopped runtime must not write")
        } catch { XCTAssertEqual(error as? BandCommandError, .notReady) }
    }

    func testHelloPrecedesSubscriptionsAndHistoryCommitsBeforeExactTokenAck() async throws {
        let peripheral = UUID()
        let order = Gen5RuntimeOrder()
        let store = Gen5RuntimeStore(order: order)
        let transport = Gen5RuntimeTransport(peripheral: peripheral, order: order)
        let runtime = Gen5ExperimentalRuntime(
            transport: transport, peripheral: peripheral, model: .whoop5, store: store
        )
        let ready = expectation(description: "fd4b notification setup completes")
        let states = await runtime.states()
        let stateTask = Task {
            for await state in states where state.setupComplete {
                ready.fulfill()
                break
            }
        }
        await runtime.start()
        transport.emit(.managerState(.poweredOn))
        await fulfillment(of: [ready], timeout: 5)
        stateTask.cancel()

        let writes = transport.writes()
        // OpenStrap protocol@c525e29e:test/gen5_test.dart:56-62.
        XCTAssertEqual(writes.first.map { $0.hex }, "aa0108000001e67123019101363e5c8d")

        let marked = expectation(description: "history commit and ACK finish")
        let orderEvents = await order.events()
        let orderTask = Task {
            for await value in orderEvents where value == "marked" {
                marked.fulfill()
                break
            }
        }
        // OpenStrap protocol@c525e29e:lib/src/control.dart:670-711:
        // metadata sub-type is inner[2], exact token bytes are inner[13..<21].
        let codec = Gen5FrameCodec()
        let start = try codec.encode(Data([0x31, 0, 1]), directionMarker: Gen5FrameEnvelope.observedInboundDirectionMarker)
        var end = Data(repeating: 0, count: 21)
        end[0] = 0x31
        end[2] = 2
        let token = Data([0x41, 0xB6, 0x01, 0, 0x10, 0, 0, 0])
        end.replaceSubrange(13..<21, with: token)
        let endFrame = try codec.encode(end, directionMarker: Gen5FrameEnvelope.observedInboundDirectionMarker)
        // OpenStrap protocol@c525e29e:test/gen5_historical_test.dart:26-40,
        // the same captured v18 frame used in Gen5RecordVersionDecoderTests.
        let v18 = try XCTUnwrap(Data(hex:
            "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b" +
            "0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7" +
            "000901f10b0007010c020c00000000000000000000000000000000000000000000000" +
            "100656f1e1e0000009d61a7c00000003e862817"))
        let unknown = try codec.encode(Data([0x2F, 99, 0, 0]), directionMarker: Gen5FrameEnvelope.observedInboundDirectionMarker)
        for frame in [start, v18, unknown, endFrame] {
            transport.emit(.value(GATTProfile.gen5.data, frame))
        }
        await fulfillment(of: [marked], timeout: 5)
        orderTask.cancel()

        let counts = await store.counts()
        let heartRates = await store.heartRates()
        let recordedOrder = await order.recorded()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(heartRates.compactMap { $0 }, [102])
        XCTAssertEqual(recordedOrder.first, "hello")
        XCTAssertEqual(recordedOrder.filter { $0 == "notify" }.count, 3)
        XCTAssertEqual(Array(recordedOrder.suffix(3)), ["commit", "ack", "marked"])
        let ack = try XCTUnwrap(transport.writes().last)
        let ackInner = try codec.decode(ack).paddedInner
        XCTAssertEqual(Data(ackInner[4..<12]), token)
        await runtime.stop()
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var value = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            value.append(byte)
            index = next
        }
        self = value
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
