import XCTest
import Foundation
import HealthKitBridge
import OnboardingKit
@testable import Loopr

private nonisolated struct FixedGate: AppleHealthSourceGating {
    let off: Set<AppleHealthSourceKind>
    func allowsSource(_ kind: AppleHealthSourceKind) async -> Bool { !off.contains(kind) }
}

private nonisolated final class RecordingReader: AppleHealthSourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [AppleHealthSourceKind: (Date, Date)] = [:]
    let results: [AppleHealthSourceKind: AppleHealthReadResult]
    init(results: [AppleHealthSourceKind: AppleHealthReadResult]) { self.results = results }
    func read(_ kind: AppleHealthSourceKind, from start: Date, to end: Date) async -> AppleHealthReadResult {
        lock.withLock { windows[kind] = (start, end) }
        return results[kind] ?? .absent(.noSamples)
    }
    func window(_ kind: AppleHealthSourceKind) -> (Date, Date)? { lock.withLock { windows[kind] } }
}

@MainActor
final class AppleHealthSourcesSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let watch = AppleHealthProvenance(sourceName: "Pascal's Apple Watch", sourceBundleIdentifier: "com.apple.health.7A2C",
                                              deviceName: "Apple Watch", wasUserEntered: false)

    private func vo2() -> AppleHealthSample {
        AppleHealthSample(kind: .vo2Max, value: 44.2, original: AppleHealthOriginalReading(value: 44.2, unit: .mlPerKgPerMin),
                          start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(-1_800), provenance: watch)
    }

    func testASwitchedOffKindIsNotReadAndShowsAsOff() async {
        let reader = RecordingReader(results: [.weight: .values([]), .vo2Max: .values([vo2()])])
        let sources = AppleHealthSources(gate: FixedGate(off: [.weight]), makeReader: { reader })
        let summary = await sources.sourceSummary(endingAt: now, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(summary.summary(for: .weight)?.isEnabled, false)
        XCTAssertEqual(summary.summary(for: .weight)?.absence, .switchedOff)
        XCTAssertNil(reader.window(.weight), "a switched-off kind never reaches Apple Health")
        XCTAssertEqual(summary.summary(for: .vo2Max)?.sourceLabel, "Apple Watch")
        XCTAssertEqual(summary.sources.map(\.label), ["Apple Watch"])
    }

    func testDailyKindsReadTheShortWindowAndTheRestReadAYear() async throws {
        let reader = RecordingReader(results: [:])
        let sources = AppleHealthSources(gate: FixedGate(off: []), makeReader: { reader })
        let calendar = Calendar(identifier: .gregorian)
        _ = await sources.sourceSummary(endingAt: now, calendar: calendar)
        let steps = try XCTUnwrap(reader.window(.steps))
        let weight = try XCTUnwrap(reader.window(.weight))
        XCTAssertEqual(steps.1, now)
        XCTAssertEqual(calendar.dateComponents([.day], from: steps.0, to: steps.1).day, 14)
        XCTAssertEqual(calendar.dateComponents([.day], from: weight.0, to: weight.1).day, 365)
    }

    func testTheWriteSetStillEqualsBuild21() throws {
        XCTAssertEqual(LooprHealthSyncRuntime.metrics, Set(ExportMetricKind.allCases))
        XCTAssertEqual(LooprHealthSyncRuntime.permissionRequest(for: HealthSyncPreferences()).writes, Set(ExportMetricKind.allCases))
        let update = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String)
        XCTAssertEqual(update, "Loopr saves heart rate, resting heart rate, heart rate variability (SDNN), respiratory rate, sleep stages, estimated steps and active energy, and completed workouts to Apple Health when you allow them.")
    }

    func testTurningASourceOffLeavesTheWriteRequestAlone() {
        var preferences = HealthSyncPreferences(disabledSources: Set(AppleHealthSourceKind.addedReads))
        XCTAssertEqual(LooprHealthSyncRuntime.permissionRequest(for: preferences).writes, Set(ExportMetricKind.allCases))
        preferences.disabledSources = []
        XCTAssertEqual(LooprHealthSyncRuntime.permissionRequest(for: preferences).writes, Set(ExportMetricKind.allCases))
        XCTAssertEqual(LooprHealthSyncRuntime.enabledSources(for: HealthSyncPreferences(disabledSources: [.weight])),
                       Set(AppleHealthSourceKind.allCases).subtracting([.weight]))
        XCTAssertEqual(LooprHealthSyncRuntime.enabledSources(for: HealthSyncPreferences(disabledRead: [.vo2Max, .steps])),
                       Set(AppleHealthSourceKind.addedReads))
    }
}
