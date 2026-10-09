import BluetoothKit
import Foundation
import TestSupport
import XCTest

final class TransportFakesTests: XCTestCase {
    func testScriptedTransportWaitsForAWriteBeforeEachSubsequentEvent() async throws {
        let response = HarvardBluetoothProfile.response
        let transport = ScriptedTransport(
            events: [
                .value(response, Data([0x01])),
                .value(response, Data([0x02]))
            ],
            awaitWrites: true
        )
        var iterator = transport.events().makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first, .value(response, Data([0x01])))
        XCTAssertEqual(transport.emittedEventCount(), 1)

        try await transport.write(Data([0xAA]), to: HarvardBluetoothProfile.command)
        let second = await iterator.next()
        XCTAssertEqual(second, .value(response, Data([0x02])))
        XCTAssertEqual(transport.recordedWrites().count, 1)
    }

    func testReplayTransportPreservesChunksAndVerifiesExpectedWrites() async throws {
        let response = HarvardBluetoothProfile.response
        let command = HarvardBluetoothProfile.command
        let replay = try ReplayTransport(
            values: [
                ReplayValue(characteristic: response, bytes: "0102"),
                ReplayValue(characteristic: response, bytes: "03")
            ],
            expectedWrites: [ReplayWrite(characteristic: command, bytes: "aabb")]
        )
        var iterator = replay.events().makeAsyncIterator()

        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .value(response, Data([0x01, 0x02])))
        XCTAssertEqual(second, .value(response, Data([0x03])))
        let end = await iterator.next()
        XCTAssertNil(end)

        try await replay.write(Data([0xAA, 0xBB]), to: command)
        XCTAssertNoThrow(try replay.assertWritesComplete())
        XCTAssertTrue(replay.writesVerified)
    }

    func testReplayTransportRejectsMismatchedAndUnexpectedWrites() async throws {
        let command = HarvardBluetoothProfile.command
        let replay = try ReplayTransport(
            values: [ReplayValue(characteristic: HarvardBluetoothProfile.response, bytes: "00")],
            expectedWrites: [ReplayWrite(characteristic: command, bytes: "aabb")]
        )

        do {
            try await replay.write(Data([0xAA, 0xBC]), to: command)
            XCTFail("a byte mismatch must fail the replay")
        } catch let error as ReplayTransportError {
            guard case .writeMismatch(index: 0, _, _) = error else {
                return XCTFail("unexpected replay error: \(error)")
            }
        }

        do {
            try await replay.write(Data([0xAA, 0xBB]), to: command)
            XCTFail("a write after the expected sequence must fail")
        } catch let error as ReplayTransportError {
            guard case .unexpectedWrite(index: 1, _) = error else {
                return XCTFail("unexpected replay error: \(error)")
            }
        }
    }

    func testReplayTransportReportsMissingEmptyAndIncompleteCapturesWithTypedErrors() throws {
        let missingPath = "/private/tmp/loopr-missing-capture-\(UUID().uuidString)"
        do {
            _ = try ReplayTransport(fileAt: missingPath)
            XCTFail("a missing capture must fail")
        } catch let error as ReplayTransportError {
            guard case .missingFile(missingPath) = error else {
                return XCTFail("unexpected missing capture error: \(error)")
            }
        }

        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-empty-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        try Data().write(to: emptyURL)
        do {
            _ = try ReplayTransport(fileAt: emptyURL.path)
            XCTFail("an empty capture must fail")
        } catch let error as ReplayTransportError {
            guard case .emptyFile(emptyURL.path) = error else {
                return XCTFail("unexpected empty capture error: \(error)")
            }
        }

        let replay = try ReplayTransport(
            values: [ReplayValue(characteristic: HarvardBluetoothProfile.response, bytes: "00")],
            expectedWrites: [ReplayWrite(characteristic: HarvardBluetoothProfile.command, bytes: "00")]
        )
        do {
            try replay.assertWritesComplete()
            XCTFail("a replay with an unsent expected write must fail completion")
        } catch let error as ReplayTransportError {
            guard case .incompleteWrites(expected: 1, actual: 0) = error else {
                return XCTFail("unexpected incomplete replay error: \(error)")
            }
        }
    }

    func testChaosTransportSplitsDuplicatesCorruptsAndDisconnectsSelectedPeripheral() async {
        let peripheral = UUID()
        let response = HarvardBluetoothProfile.response
        let base = ScriptedTransport(events: [
            .connected(peripheral),
            .value(response, Data([0x01, 0x02]))
        ])
        let chaos = ChaosTransport(
            base: base,
            schedule: ChaosSchedule(seed: 9, faults: [
                .duplicatePacket(1),
                .disconnectAfterPacket(1)
            ])
        )
        let events = await collect(chaos.events())
        XCTAssertEqual(events, [
            .connected(peripheral),
            .value(response, Data([0x01, 0x02])),
            .value(response, Data([0x01, 0x02])),
            .disconnected(peripheral, error: .disconnected)
        ])

        let corruptBase = ScriptedTransport(events: [
            .value(response, Data([0x01, 0x02]))
        ])
        let corruptChaos = ChaosTransport(
            base: corruptBase,
            schedule: ChaosSchedule(seed: 10, faults: [.corruptByte(packet: 1, offset: 1)])
        )
        let corruptedEvents = await collect(corruptChaos.events())
        XCTAssertEqual(corruptedEvents, [.value(response, Data([0x01, 0xFD]))])
    }

    func testChaosTransportDropsWriteCompletionAndSchedulesAreSeededAndEnumerable() async {
        let command = HarvardBluetoothProfile.command
        let base = ScriptedTransport(events: [
            .writeCompleted(command, error: nil)
        ])
        let chaos = ChaosTransport(
            base: base,
            schedule: ChaosSchedule(seed: 1, faults: [.dropWriteCompletion])
        )
        let droppedEvents = await collect(chaos.events())
        XCTAssertTrue(droppedEvents.isEmpty)

        let first = ChaosSchedule.enumerate(seed: 42, packetCount: 3)
        XCTAssertEqual(first, ChaosSchedule.enumerate(seed: 42, packetCount: 3))
        XCTAssertEqual(first.count, 13)
        XCTAssertNotEqual(first, ChaosSchedule.enumerate(seed: 43, packetCount: 3))
    }

    func testChaosTransportStallUsesInjectedDeterministicClock() async {
        let clock = ManualBluetoothClock()
        let base = ScriptedTransport(events: [
            .value(HarvardBluetoothProfile.response, Data([0x01]))
        ])
        let chaos = ChaosTransport(
            base: base,
            schedule: ChaosSchedule(seed: 11, faults: [.stallForNanoseconds(75)]),
            clock: clock
        )
        let events = await collect(chaos.events())
        XCTAssertEqual(events, [.value(HarvardBluetoothProfile.response, Data([0x01]))])
        XCTAssertEqual(clock.nowNanoseconds(), 75)
    }

    private func collect(_ stream: AsyncStream<TransportEvent>) async -> [TransportEvent] {
        var iterator = stream.makeAsyncIterator()
        var events: [TransportEvent] = []
        while let event = await iterator.next() {
            events.append(event)
        }
        return events
    }
}
