@testable import BluetoothKit
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
import Foundation
import ProtocolKit
import XCTest

private struct ImmediateBLETestClock: BLEClock {
    let value: Date
    init(value: Date = Date(timeIntervalSince1970: 1_750_000_000)) { self.value = value }
    func now() -> Date { value }
    func sleep(for _: TimeInterval) async throws {
        // Ordinary writer tests must not race an immediately-completing
        // timeout branch. The task group cancels this suspension as soon as
        // the transport write completes.
        try await Task.sleep(nanoseconds: UInt64.max)
    }
}

private struct TimeoutBLETestClock: BLEClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_750_000_000) }
    func sleep(for interval: TimeInterval) async throws {
        throw SerializedWriterError.timedOut(seconds: Int(interval))
    }
}

private struct ScaledBLETestClock: BLEClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_750_000_000) }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 10_000_000))
    }
}

private actor WriterTransportSpy: CommandWriteTransport {
    private(set) var writes: [Data] = []
    private(set) var disconnectCount = 0
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) { self.failuresRemaining = failuresRemaining }

    func writeCommand(_ data: Data) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestTransportError.failed
        }
        writes.append(Data(data))
    }

    func disconnect() async { disconnectCount += 1 }
    func recordedWrites() -> [Data] { writes }
}

private actor BlockingWriterTransport: CommandWriteTransport {
    private(set) var writes: [Data] = []
    private(set) var disconnectCount = 0

    func writeCommand(_ data: Data) async throws {
        writes.append(Data(data))
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func disconnect() async { disconnectCount += 1 }
    func recordedWrites() -> [Data] { writes }
}

private actor DelayedWriterTransport: CommandWriteTransport {
    private(set) var writes: [Data] = []

    func writeCommand(_ data: Data) async throws {
        try await Task.sleep(nanoseconds: 90_000_000)
        writes.append(Data(data))
    }

    func disconnect() async {}
    func recordedWrites() -> [Data] { writes }
}

private struct BondFailureWriterTransport: CommandWriteTransport {
    let error: TransportError

    func writeCommand(_: Data) async throws { throw error }
    func disconnect() async {}
}

private enum TestTransportError: Error {
    case failed
}

private func fixtureData(_ hex: String) -> Data {
    let characters = Array(hex)
    precondition(characters.count.isMultiple(of: 2))
    var result = Data(capacity: characters.count / 2)
    var index = 0
    while index < characters.count {
        result.append(UInt8(String(characters[index...index + 1]), radix: 16)!)
        index += 2
    }
    return result
}

final class SerializedWriterTests: XCTestCase {
#if canImport(CoreBluetooth)
    func testCoreBluetoothATTBondErrorsMapToTypedTransportFailures() {
        let authentication = NSError(
            domain: CBATTError.errorDomain,
            code: CBATTError.Code.insufficientAuthentication.rawValue
        )
        let encryption = NSError(
            domain: CBATTError.errorDomain,
            code: CBATTError.Code.insufficientEncryption.rawValue
        )

        XCTAssertEqual(CoreBluetoothTransport.transportError(authentication), .insufficientAuthentication)
        XCTAssertEqual(CoreBluetoothTransport.transportError(encryption), .insufficientEncryption)
    }

    func testPeerRemovedPairingMapsToATypedBondFailure() {
        let removed = NSError(
            domain: CBError.errorDomain,
            code: CBError.Code.peerRemovedPairingInformation.rawValue
        )

        XCTAssertEqual(CoreBluetoothTransport.transportError(removed), .peerRemovedPairing)
        XCTAssertTrue(TransportError.peerRemovedPairing.isBondFailure)
    }
#endif

    func testSlowFirstSetupWriteCanFinishAfterEightSecondsButBeforeThirty() async throws {
        let transport = DelayedWriterTransport()
        let writer = SerializedGenerationPinnedWriter(transport: transport, clock: ScaledBLETestClock())
        try await writer.begin(generation: 1)

        try await writer.write(
            .setClock(sequence: 0, unixSeconds: 1_750_000_000, subsecondTicks: 0),
            generation: 1,
            timeout: SerializedGenerationPinnedWriter.firstSetupWriteTimeout
        )

        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes.count, 1)
    }

    func testFirstSetupWriteUsesExtendedBondTimeoutWhileLaterWritesKeepEightSeconds() async throws {
        let transport = BlockingWriterTransport()
        let writer = SerializedGenerationPinnedWriter(transport: transport, clock: TimeoutBLETestClock())
        try await writer.begin(generation: 1)

        do {
            try await writer.write(
                .setClock(sequence: 0, unixSeconds: 1_750_000_000, subsecondTicks: 0),
                generation: 1,
                timeout: 30
            )
            XCTFail("expected scripted timeout")
        } catch let error as SerializedWriterError {
            XCTAssertEqual(error, .timedOut(seconds: 30))
        }

        do {
            try await writer.write(.hello(sequence: 1), generation: 1)
            XCTFail("expected scripted timeout")
        } catch let error as SerializedWriterError {
            XCTAssertEqual(error, .timedOut(seconds: 8))
        }
    }

    func testAuthenticationAndEncryptionFailuresStayTypedAtWriterBoundary() async throws {
        for transportError in [TransportError.insufficientAuthentication, .insufficientEncryption] {
            let writer = SerializedGenerationPinnedWriter(
                transport: BondFailureWriterTransport(error: transportError),
                clock: ImmediateBLETestClock()
            )
            try await writer.begin(generation: 1)

            do {
                try await writer.write(.hello(sequence: 0), generation: 1)
                XCTFail("Expected typed pairing failure")
            } catch let error as SerializedWriterError {
                XCTAssertEqual(error, .bondFailure(transportError))
            }
        }
    }
    func testConcurrentTypedWritesNeverOverlapAndPreserveOneWriterBoundary() async throws {
        let transport = WriterTransportSpy()
        let writer = SerializedGenerationPinnedWriter(
            transport: transport,
            clock: ImmediateBLETestClock(),
            queueLimit: 16
        )
        try await writer.begin(generation: 1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for sequence in 0..<8 {
                group.addTask {
                    try await writer.write(
                        .hello(sequence: UInt8(sequence)),
                        generation: 1
                    )
                }
            }
            try await group.waitForAll()
        }

        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes.count, 8)
        // A task group does not promise submission order. The writer must
        // serialize every accepted command exactly once, independent of the
        // order in which concurrent callers reach the actor.
        XCTAssertEqual(
            writes.compactMap { try? FrameDecoder().decode($0).paddedInner[1] }.sorted(),
            Array(0..<8).map(UInt8.init)
        )
    }

    func testTimeoutAtEightSecondsDoesNotRetryAndDisconnectCancelsPendingWrite() async throws {
        let timeoutTransport = BlockingWriterTransport()
        let writer = SerializedGenerationPinnedWriter(
            transport: timeoutTransport,
            clock: TimeoutBLETestClock()
        )
        try await writer.begin(generation: 1)

        do {
            try await writer.write(.hello(sequence: 0), generation: 1)
            XCTFail("write should time out")
        } catch let error as SerializedWriterError {
            XCTAssertEqual(error, .timedOut(seconds: 8))
        }
        let timedOutWrites = await timeoutTransport.recordedWrites()
        XCTAssertEqual(timedOutWrites.count, 1)

        let disconnectTransport = BlockingWriterTransport()
        let disconnectingWriter = SerializedGenerationPinnedWriter(
            transport: disconnectTransport,
            clock: ImmediateBLETestClock()
        )
        try await disconnectingWriter.begin(generation: 2)
        let pending = Task {
            try await disconnectingWriter.write(.hello(sequence: 1), generation: 2)
        }
        await Task.yield()
        await disconnectingWriter.disconnect()
        do {
            try await pending.value
            XCTFail("disconnect should cancel the pending write")
        } catch let error as SerializedWriterError {
            XCTAssertTrue([.cancelled, .disconnected].contains(error))
        }
        let disconnectCount = await disconnectTransport.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testReplacementGenerationRejectsOldQueuedCommand() async throws {
        let transport = WriterTransportSpy()
        let writer = SerializedGenerationPinnedWriter(
            transport: transport,
            clock: ImmediateBLETestClock()
        )
        try await writer.begin(generation: 1)
        try await writer.replaceGeneration(2)

        do {
            try await writer.write(.hello(sequence: 0), generation: 1)
            XCTFail("stale generation must not write")
        } catch let error as SerializedWriterError {
            guard case .staleGeneration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let writes = await transport.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testFinalWriterRejectsEveryDangerousTypedOpcode() async throws {
        let transport = WriterTransportSpy()
        let writer = SerializedGenerationPinnedWriter(
            transport: transport,
            clock: ImmediateBLETestClock()
        )
        try await writer.begin(generation: 1)
        let dangerous: [ProductionCommand] = [
            .forceTrim,
            .reboot,
            .powerCycle,
            .persistentRaw,
            .firmwareCommand24,
            .firmwareCommand25,
            .firmwareCommand26
        ]

        for command in dangerous {
            do {
                try await writer.write(command, generation: 1)
                XCTFail("dangerous command unexpectedly accepted: \(command)")
            } catch let error as CommandFirewallError {
                XCTAssertTrue(CommandFirewall.isDangerous(opcode: error.opcode))
            }
        }
        let writes = await transport.recordedWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testClockDisciplineRejectsFutureAndCapsCorrectionsThenClearsOnDisconnect() {
        var discipline = ClockDiscipline()
        let wall = Date(timeIntervalSince1970: 1_750_000_000)
        let future = wall.addingTimeInterval(86_400 + 1)
        XCTAssertEqual(discipline.evaluate(bandDate: future, wallDate: wall), .rejectedFuture)

        let old = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(discipline.evaluate(bandDate: old, wallDate: wall), .requiresCorrection(.init(bandDate: old, wallDate: wall)))
        _ = discipline.recordCorrection()
        _ = discipline.evaluate(bandDate: old, wallDate: wall)
        _ = discipline.recordCorrection()
        _ = discipline.evaluate(bandDate: old, wallDate: wall)
        _ = discipline.recordCorrection()
        XCTAssertEqual(discipline.correctionCount, 3)
        XCTAssertEqual(discipline.evaluate(bandDate: old, wallDate: wall), .correctionLimitReached)
        XCTAssertNotNil(discipline.correlation)

        discipline.disconnect()
        XCTAssertNil(discipline.correlation)
        XCTAssertEqual(discipline.correctionCount, 0)
    }

    func testClockExchangeReplaysExactSETAndGETFixtureBytes() async throws {
        let transport = WriterTransportSpy()
        let writer = SerializedGenerationPinnedWriter(
            transport: transport,
            clock: ImmediateBLETestClock()
        )
        try await writer.begin(generation: 1)

        let sequence = try await ClockExchange(writer: writer).send(
            wallDate: Date(timeIntervalSince1970: Double(0x1234_5678) + 0.5),
            generation: 1,
            setSequence: 9,
            getSequence: 5
        )

        let expectedSET = fixtureData("aa10005723090a7856341200400000004b800129")
        let expectedGET = fixtureData("aa0800a823050b00ecc4fc76")
        XCTAssertEqual(sequence.setClock, expectedSET)
        XCTAssertEqual(sequence.getClock, expectedGET)
        let writes = await transport.recordedWrites()
        XCTAssertEqual(writes, [expectedSET, expectedGET])
    }

    func testClockResponseParsesTheRealBandLayoutFromAHardwareCapture() throws {
        // Captured on a WHOOP 4.0 on 2026-09-21. GET_CLOCK was sent with
        // sequence 0x61; 0xD6 is the band's own rolling packet counter, and
        // 0x6AB152A9 is the correct wall-clock second.
        let response = try ClockResponse.parse(
            fixtureData("24d60b6101a952b16a00460000000000")
        )
        XCTAssertEqual(response.bandDate.timeIntervalSince1970, 1_790_005_929)
        XCTAssertEqual(response.sequence, 0x61)
        XCTAssertEqual(response.opcode, 0x0B)
        XCTAssertEqual(response.subsecondTicks, 0x4600)

        // The same exchange one packet earlier, sequence 0x60. Reading the
        // timestamp where the reference puts it, two bytes in, yields
        // 0x52A90161, which is why every hardware readback used to throw.
        let earlier = try ClockResponse.parse(
            fixtureData("24d30b6001a952b16aa01e0000000000")
        )
        XCTAssertEqual(earlier.sequence, 0x60)
        XCTAssertEqual(earlier.bandDate.timeIntervalSince1970, 1_790_005_929)
        XCTAssertEqual(earlier.subsecondTicks, 0x1EA0)
    }

    func testClockResponseStillParsesABarePayloadAndRejectsImplausibleTimes() throws {
        // A caller that hands over only the timestamp field keeps working and
        // claims no subsecond ticks it cannot justify.
        let bare = try ClockResponse.parse(fixtureData("a952b16a"))
        XCTAssertEqual(bare.bandDate.timeIntervalSince1970, 1_790_005_929)
        XCTAssertNil(bare.sequence)
        XCTAssertNil(bare.subsecondTicks)

        XCTAssertThrowsError(try ClockResponse.parse(fixtureData("24d60b610100000000")))
        XCTAssertThrowsError(try ClockResponse.parse(fixtureData("00112233")))
    }

    func testClockDisciplineRechecksAfterSixHoursOfHealthyCorrelation() {
        var discipline = ClockDiscipline()
        let wall = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(
            discipline.evaluate(bandDate: wall, wallDate: wall),
            .accepted(.init(bandDate: wall, wallDate: wall))
        )
        XCTAssertFalse(
            discipline.shouldRecheck(
                now: wall.addingTimeInterval(ClockDiscipline.recheckInterval - 0.001)
            )
        )
        XCTAssertTrue(
            discipline.shouldRecheck(
                now: wall.addingTimeInterval(ClockDiscipline.recheckInterval)
            )
        )
    }
}
