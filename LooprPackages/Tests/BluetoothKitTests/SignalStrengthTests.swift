import BluetoothKit
import Foundation
import TestSupport
import XCTest

/// A transport that can answer a signal read, wrapping the scripted one so it
/// still behaves like every other fake for connect and write.
private final class SignalReportingTransport: BLETransport, BLESignalStrengthReporting, @unchecked Sendable {
    private let base: ScriptedTransport
    private let lock = NSLock()
    private var answers: [Int?]
    private(set) var reads = 0

    init(events: [TransportEvent] = [], answers: [Int?]) {
        base = ScriptedTransport(events: events)
        self.answers = answers
    }

    func readSignalStrength() async -> Int? {
        lock.withLock {
            reads += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    func events() -> AsyncStream<TransportEvent> { base.events() }
    func connect(_ peripheral: PeripheralID) async { await base.connect(peripheral) }
    func discoverServices(_ ids: [ServiceID]) async { await base.discoverServices(ids) }
    func setNotify(_ char: CharacteristicID, enabled: Bool) async { await base.setNotify(char, enabled: enabled) }
    func write(_ data: Data, to char: CharacteristicID) async throws { try await base.write(data, to: char) }
    func disconnect() async { await base.disconnect() }
}

/// "Find my strap" needs to know whether the person is walking towards the
/// band. The reading is link level, it never scans, and it reports nothing
/// rather than failing when the link drops mid-hunt.
final class SignalStrengthTests: XCTestCase {
    private func makeSession(_ transport: any BLETransport) -> BluetoothConnectionSession {
        BluetoothConnectionSession(
            transport: transport,
            store: InMemoryAccessoryProvisioningStore(),
            clock: ManualBluetoothClock()
        )
    }

    private func connect(_ session: BluetoothConnectionSession) async -> TransportSessionIdentity? {
        guard case .scan(let generation, _) = await session.start() else {
            XCTFail("a fresh session must start with the service-filtered scan")
            return nil
        }
        let peripheral = UUID()
        _ = await session.handle(
            .discovered(peripheral, advertisedServices: [HarvardBluetoothProfile.service]),
            generation: generation
        )
        let identity = TransportSessionIdentity(peripheral: peripheral)
        _ = await session.handle(.connectedInSession(identity), generation: generation)
        return identity
    }

    func testAConnectedSessionReportsTheRadioReading() async throws {
        let transport = SignalReportingTransport(answers: [-58, -44])
        let session = makeSession(transport)
        _ = await connect(session)

        let first = await session.readSignalStrength()
        XCTAssertEqual(first, -58)
        let second = await session.readSignalStrength()
        XCTAssertEqual(second, -44, "Walking closer has to read as a different number")
    }

    func testNothingIsReadBeforeThereIsALink() async throws {
        let transport = SignalReportingTransport(answers: [-58])
        let session = makeSession(transport)

        let value = await session.readSignalStrength()
        XCTAssertNil(value)
        XCTAssertEqual(transport.reads, 0, "A hunt must never touch the radio without a connection")
    }

    func testATransportWithNothingToReportIsNotAnError() async throws {
        let transport = ScriptedTransport(events: [])
        let session = makeSession(transport)
        _ = await connect(session)

        let value = await session.readSignalStrength()
        XCTAssertNil(value, "No capability means no guidance, not a failure")
    }

    func testARadioThatDoesNotAnswerReadsAsNoGuidance() async throws {
        let transport = SignalReportingTransport(answers: [nil])
        let session = makeSession(transport)
        _ = await connect(session)

        let value = await session.readSignalStrength()
        XCTAssertNil(value)
        XCTAssertEqual(transport.reads, 1)
    }
}
