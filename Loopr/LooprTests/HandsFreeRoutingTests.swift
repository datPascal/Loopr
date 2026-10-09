import BluetoothKit
import SyncKit
import Foundation
import JournalKit
import ProtocolKit
import StressKit
import WorkoutKit
import UIKit
import XCTest
@testable import Loopr

final class HandsFreeRoutingTests: XCTestCase {
    func testBreathingURLCarriesStartAndBandPacing() {
        XCTAssertEqual(ShellDeepLink(url: URL(string: "loopr://breathing?start=true&band=true")!), .breathing(start: true, bandPacing: true))
        XCTAssertEqual(ShellDeepLink(url: URL(string: "loopr://breathing")!), .breathing(start: false, bandPacing: false))
        XCTAssertEqual(ShellDeepLink(url: URL(string: "loopr://intervals")!), .intervals)
        XCTAssertEqual(ShellDeepLink(url: URL(string: "loopr://today")!), .todayHome)
        XCTAssertNil(ShellDeepLink(url: URL(string: "https://breathing?start=true")!))
        XCTAssertNil(ShellDeepLink(url: URL(string: "loopr://unknown")!))
    }

    func testBoundedCuePatternsUseExistingWriterAndExactBytes() throws {
        let patterns = [BandCuePattern.breathing(.inhale), BandCuePattern.breathing(.exhale),
                        BandCuePattern.interval(.work)!, BandCuePattern.interval(.rest)!,
                        BandCuePattern.interval(.complete)!]
        XCTAssertEqual(patterns, [0, 2, 0, 2, 2])
        for effect in patterns {
            let bytes = try ProductionCommandWriter(capabilities: .confirmed(.haptic))
                .encode(.haptic(.run(sequence: 7, pattern: effect)))
            XCTAssertEqual(try FrameDecoder().decode(bytes).paddedInner, Data([0x23, 7, 0x4F, effect, 0, 0, 0, 0]))
        }
    }

    func testWorkoutPatternsUseOnlyBoundedExistingEffects() throws {
        XCTAssertEqual(WorkoutBandCuePattern.effects(for: .tooHigh), [2])
        XCTAssertEqual(WorkoutBandCuePattern.effects(for: .tooLow), [0, 0, 0])
        XCTAssertEqual(WorkoutBandCuePattern.effects(for: .returned), [0])
        for event in [WorkoutZoneAlertEvent.tooHigh, .tooLow, .returned] {
            for effect in WorkoutBandCuePattern.effects(for: event) {
                let bytes = try ProductionCommandWriter(capabilities: .confirmed(.haptic)).encode(.haptic(.run(sequence: 9, pattern: effect)))
                XCTAssertEqual(try FrameDecoder().decode(bytes).paddedInner, Data([0x23, 9, 0x4F, effect, 0, 0, 0, 0]))
            }
        }
    }

    func testPatternQueueDoesNotInterleaveCommandsAndWaitsAfterEach() async {
        let recorder = CueSequenceRecorder()
        let queue = BandCueCommandQueue(wait: { @Sendable in await recorder.wait() })
        async let first = queue.perform(pattern: [2, 0, 0]) { @Sendable effect in await recorder.send(effect) }
        async let second = queue.perform(pattern: [0]) { @Sendable effect in await recorder.send(effect) }
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        let events = await recorder.events
        XCTAssertTrue(events == ["2", "wait", "0", "wait", "0", "wait", "0", "wait"]
                      || events == ["0", "wait", "2", "wait", "0", "wait", "0", "wait"])
        let maximum = await recorder.maximumActive
        XCTAssertEqual(maximum, 1)
    }

    func testPatternStopsAtConnectionReplacement() async {
        let runtime = CueRuntimeFixture()
        let queue = BandCueCommandQueue(wait: { @Sendable in await runtime.replaceConnection() })
        let delivery = BandCueDelivery(runtime: runtime)
        let sent = await delivery.send(pattern: [0, 0, 0], sessionID: UUID(), queue: queue)
        XCTAssertFalse(sent)
        let effects = await runtime.effects
        XCTAssertEqual(effects, [0])
    }

    func testShortcutMomentUsesCanonicalJournalWithItsSource() async throws {
        let journal = JournalRepository()
        let date = Date(timeIntervalSince1970: 100)
        let sink = LooprJournalMomentSink(journal: journal, note: "Marked from Shortcuts")
        try await sink.mark(at: date)
        let entries = await journal.history()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.createdAt, date)
        XCTAssertEqual(entries.first?.note, "Marked from Shortcuts")
    }

    func testOldCueSessionCannotBuzzReplacementConnection() async {
        let runtime = CueRuntimeFixture()
        let delivery = BandCueDelivery(runtime: runtime)
        let sessionID = UUID()
        await delivery.send(effect: 0, sessionID: sessionID)
        await runtime.replaceConnection()
        await delivery.send(effect: 2, sessionID: sessionID)
        let sent = await runtime.effects
        XCTAssertEqual(sent, [0])
        await delivery.send(effect: 0, sessionID: UUID())
        let fresh = await runtime.effects
        XCTAssertEqual(fresh, [0, 0])
    }

    func testReplacedRuntimeWithSameGenerationCannotReceiveOldCues() async {
        let first = CueRuntimeFixture()
        let second = CueRuntimeFixture()
        let handle = LooprRuntimeHandle()
        handle.bind(first)
        let delivery = BandCueDelivery(runtime: handle)
        let sessionID = UUID()
        await delivery.send(effect: 0, sessionID: sessionID)
        handle.bind(second)
        await delivery.send(effect: 2, sessionID: sessionID)
        let effects = await second.effects
        XCTAssertTrue(effects.isEmpty)
    }

    @MainActor
    func testQuickActionsResolveOnceAndIgnoreUnknownTypes() {
        _ = LooprQuickActions.shared.take()
        let items = LooprQuickActions.items
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(LooprQuickActions.shared.receive(items[0]))
        XCTAssertEqual(LooprQuickActions.shared.take(), .syncBand)
        XCTAssertNil(LooprQuickActions.shared.take())
        XCTAssertTrue(LooprQuickActions.shared.receive(items[1]))
        XCTAssertEqual(LooprQuickActions.shared.take(), .breathing(start: true, bandPacing: true))
        XCTAssertFalse(LooprQuickActions.shared.receive(.init(type: "unknown", localizedTitle: "Unknown")))
        XCTAssertNil(LooprQuickActions.shared.take())
    }
    @MainActor
    func testColdLaunchURLWaitsForShellConsumption() {
        _ = LooprQuickActions.shared.take()
        XCTAssertTrue(LooprQuickActions.shared.receive(url: URL(string: "loopr://breathing?start=true&band=true")!))
        XCTAssertEqual(LooprQuickActions.shared.take(), .breathing(start: true, bandPacing: true))
        XCTAssertNil(LooprQuickActions.shared.take())
    }

}

actor CueRuntimeFixture: LooprDeviceCenterRuntime {
    private let model: BandModel
    init(model: BandModel = .whoop4) { self.model = model }
    private var generation: UInt64 = 7
    private(set) var effects: [UInt8] = []
    func replaceConnection() { generation += 1 }
    func buzzBand(effect: UInt8) { effects.append(effect) }
    func buzzBand(effect: UInt8, expectedGeneration: UInt64) throws {
        guard expectedGeneration == generation else { throw LooprDeviceRuntimeCommandError.unavailable }
        effects.append(effect)
    }
    func performManualSync(maxDuration: TimeInterval) -> Bool { true }
    func bufferedLiveSamples(for kind: LiveStreamKind) -> [LiveStreamSample] { [] }
    func acquireLiveStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) throws -> LiveStreamConsumerHandle {
        throw HeartLiveStreamAdapterError.unavailable
    }
    func runtimeState() -> BluetoothAdoptionRuntimeState {
        .init(running: true, generation: generation,
              connection: .listening(generation: generation, peripheral: UUID()),
              setupReady: true, setupComplete: true, radioState: .poweredOn,
              health: .init(healthy: true, stale: false, shouldBounce: false, ageOfLatestObservation: 1, corruptionRate: 0, reasons: []),
              pendingReconnect: nil, liveConsumerCount: 0, pendingHistoryReplayCount: 0,
              validFrameCount: 1, corruptFrameCount: 0, writeTimeoutCount: 0, lastError: nil, bandModel: model)
    }
}

private actor CueSequenceRecorder {
    private(set) var events: [String] = []
    private var active = 0
    private(set) var maximumActive = 0
    func send(_ effect: UInt8) async -> Bool {
        active += 1; maximumActive = max(maximumActive, active)
        events.append(String(effect))
        for _ in 0..<10 { await Task.yield() }
        active -= 1
        return true
    }
    func wait() async { events.append("wait"); for _ in 0..<10 { await Task.yield() } }
}
