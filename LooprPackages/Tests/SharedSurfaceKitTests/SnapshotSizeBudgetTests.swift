import XCTest
@testable import SharedSurfaceKit

final class SnapshotSizeBudgetTests: XCTestCase {
    func testOneSnapshotFileStaysBelowSixteenKilobytes() async throws {
        let snapshot = SurfaceSnapshot(
            generation: 42,
            createdAt: Date(timeIntervalSince1970: 1_787_472_000),
            sourceDay: "2026-08-23",
            syncDate: Date(timeIntervalSince1970: 1_787_471_900),
            metrics: SurfaceMetrics(recovery: 80, sleep: 92, strain: 10.3, heartRate: 62, hrv: 68, steps: 7000, sleepMinutes: 462),
            battery: SurfaceBatteryObservation(level: 0.75, observedAt: Date(timeIntervalSince1970: 1_787_471_800)),
            activeWorkout: SurfaceWorkoutSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
                activity: "run",
                startedAt: Date(timeIntervalSince1970: 1_787_471_700)
            ),
            staleReasons: [],
            insight: SurfaceDayInsight(headline: "Your overnight readings are close to usual.",
                recoveryStyle: .init(verdict: "Ready", lightRGB: 0x16A34A, darkRGB: 0x34D77B,
                    highContrastLightRGB: 0x0F7A36, highContrastDarkRGB: 0x86EFAC),
                recoveryUnavailableReason: "Wear your band overnight.", nightsRecorded: 14, nightsNeeded: 14,
                sleepNeedMinutes: 480, sleepUnavailableReason: "Wear your band overnight.",
                strainUnavailableReason: "Wear your band for an hour.")
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(data.count, 16 * 1_024)
        XCTAssertEqual(try SurfaceSnapshotCodec.decode(data), snapshot)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("surface.json")
        let store = AtomicSurfaceSnapshotStore(url: url)
        try await store.write(snapshot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["surface.json"])
        let storedSnapshot = try await store.read()
        XCTAssertEqual(storedSnapshot, snapshot)
    }
}
