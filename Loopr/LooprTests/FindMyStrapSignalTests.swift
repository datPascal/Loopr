import XCTest
import Foundation
import BluetoothKit
import DeviceCenterKit
import SyncKit
@testable import Loopr

private enum SignalStateFactory {
    static let peripheral = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    static let listening = make(connection: .listening(generation: 1, peripheral: peripheral), setupComplete: true)
    static let idle = make(connection: .idle, setupComplete: false)

    static func make(connection: BluetoothConnectionState, setupComplete: Bool) -> BluetoothAdoptionRuntimeState {
        BluetoothAdoptionRuntimeState(
            running: setupComplete,
            generation: setupComplete ? 1 : nil,
            connection: connection,
            setupReady: setupComplete,
            setupComplete: setupComplete,
            radioState: .poweredOn,
            health: ConnectionHealthReport(
                healthy: setupComplete, stale: !setupComplete, shouldBounce: false,
                ageOfLatestObservation: 1, corruptionRate: 0, reasons: []
            ),
            pendingReconnect: nil,
            liveConsumerCount: 0,
            pendingHistoryReplayCount: 0,
            validFrameCount: 0,
            corruptFrameCount: 0,
            writeTimeoutCount: 0,
            lastError: nil
        )
    }
}

/// Collects what the hunt screen would render.
private actor SampleCollector {
    private(set) var values: [Int?] = []
    func append(_ value: Int?) { values.append(value) }
}

/// A Device Center runtime that answers signal reads, and counts them so the
/// polling rule can be asserted.
private actor SignalTestRuntime: LooprDeviceCenterRuntime {
    private var readings: [Int?]
    private(set) var reads = 0

    init(readings: [Int?]) { self.readings = readings }

    func readSignalStrength() async -> Int? {
        reads += 1
        return readings.isEmpty ? nil : readings.removeFirst()
    }

    func runtimeState() async -> BluetoothAdoptionRuntimeState { SignalStateFactory.listening }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { true }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }
}

/// A runtime with no signal source at all, which is every fake in the suite
/// and every build where the band is not connected.
private actor SilentTestRuntime: LooprDeviceCenterRuntime {
    func runtimeState() async -> BluetoothAdoptionRuntimeState { SignalStateFactory.idle }

    func performManualSync(maxDuration: TimeInterval) async -> Bool { false }

    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> LiveStreamConsumerHandle {
        throw LooprDeviceRuntimeCommandError.unavailable
    }

    func bufferedLiveSamples(for kind: LiveStreamKind) async -> [LiveStreamSample] { [] }
}

/// The signal seam behind "Find my strap". The guidance maths already existed
/// and was tested; it just had no input.
final class FindMyStrapSignalTests: XCTestCase {
    func testARuntimeWithNoSignalSourceReportsNoGuidance() async throws {
        let runtime = SilentTestRuntime()
        let value = await runtime.readSignalStrength()
        XCTAssertNil(value)
        let feedback = FindMyStrapGuidanceCalculator.feedback(currentRSSI: value, previousRSSI: nil)
        XCTAssertEqual(feedback.guidance, .unavailable)
        XCTAssertEqual(feedback.haptic, .unavailable)
    }

    func testWalkingTowardsTheBandReadsAsWarmer() async throws {
        let runtime = SignalTestRuntime(readings: [-72, -55])
        let previous = await runtime.readSignalStrength()
        let current = await runtime.readSignalStrength()
        XCTAssertEqual(previous, -72)
        XCTAssertEqual(current, -55)

        let feedback = FindMyStrapGuidanceCalculator.feedback(currentRSSI: current, previousRSSI: previous)
        XCTAssertEqual(feedback.guidance, .warmer)
        XCTAssertEqual(feedback.haptic, .intensify)
    }

    func testWalkingAwayReadsAsColder() async throws {
        let runtime = SignalTestRuntime(readings: [-50, -68])
        let previous = await runtime.readSignalStrength()
        let current = await runtime.readSignalStrength()
        let feedback = FindMyStrapGuidanceCalculator.feedback(currentRSSI: current, previousRSSI: previous)
        XCTAssertEqual(feedback.guidance, .colder)
        XCTAssertEqual(feedback.haptic, .soften)
    }

    func testALinkThatDropsMidHuntStopsGuidingRatherThanFailing() async throws {
        let runtime = SignalTestRuntime(readings: [-60, nil])
        let previous = await runtime.readSignalStrength()
        let current = await runtime.readSignalStrength()
        XCTAssertNil(current)
        let feedback = FindMyStrapGuidanceCalculator.feedback(currentRSSI: current, previousRSSI: previous)
        XCTAssertEqual(feedback.guidance, .unavailable)
    }

    func testTheHuntPollsAboutOncePerSecondAndOnlyWhileTheScreenIsOpen() async throws {
        let runtime = SignalTestRuntime(readings: [-60, -59, -58, -57, -56])
        let poll = FindMyStrapSignalPoll(interval: 0.01)
        let collector = SampleCollector()

        let task = Task {
            await poll.run(reading: { await runtime.readSignalStrength() }, emit: { await collector.append($0) })
        }
        // Closing the screen cancels the loop. Nothing polls in the background.
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        await task.value

        let reads = await runtime.reads
        XCTAssertGreaterThan(reads, 0, "An open hunt screen has to read the radio")
        let samples = await collector.values
        XCTAssertEqual(samples.count, reads)

        try await Task.sleep(nanoseconds: 40_000_000)
        let later = await runtime.reads
        XCTAssertEqual(later, reads, "A closed screen must never touch the radio again")
    }
}
