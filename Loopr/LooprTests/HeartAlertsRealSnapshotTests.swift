import Foundation
import Testing
import AnalyticsKit
import StorageKit
@testable import Loopr

/// Replays a device snapshot through the production reader and the
/// detector, fifteen minutes at a time the way the band offloads, and checks
/// the alerts it would have raised. The snapshot is not in the repository;
/// the test skips itself without it. The original file is never opened: it is
/// copied first.
@Suite(.serialized)
struct HeartAlertsRealSnapshotTests {
    private static var snapshotPath: String? {
        [ProcessInfo.processInfo.environment["LOOPR_REAL_DB"], "/tmp/loopr-night/device-snapshot/loopr.sqlite"]
            .compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    private struct Replay {
        var alerts: [HeartRateAlertEpisode] = []
        var skips: [HeartRateAlertSkip: Int] = [:]
        var seconds = 0
        var slowestPassSeconds = 0.0
    }

    private func replay(_ database: StorageDatabase, settings: HeartRateAlertSettings,
                        parameters: HeartRateAlertParameters = .standard) throws -> Replay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ProcessInfo.processInfo.environment["LOOPR_REAL_DB_ZONE"].flatMap(TimeZone.init(identifier:)) ?? .current
        let bounds = try database.read { db in
            (try Int64.fetchOne(db, sql: "SELECT MIN(absolute_timestamp) FROM decoded_second") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT MAX(absolute_timestamp) FROM decoded_second") ?? 0)
        }
        var output = Replay()
        var state = HeartRateAlertState.initial
        var open: [String: HeartRateAlertEpisode] = [:]
        var cutoff = bounds.0 + 900
        while cutoff <= bounds.1 + 900 {
            let started = Date()
            let from = (state.watermark ?? bounds.0) - parameters.requiredLookbackSeconds
            let seconds = try HeartAlertHistoryReader.seconds(database, from: from, to: cutoff)
            output.seconds = max(output.seconds, seconds.count)
            let result = HeartRateAlertDetector.evaluate(
                seconds: seconds, settings: settings, state: state,
                context: HeartRateAlertContext(now: cutoff, calendar: calendar),
                openEpisodes: Array(open.values), parameters: parameters
            )
            state = result.nextState
            for alert in result.alerts { open[alert.id] = alert; output.alerts.append(alert) }
            for update in result.updatedEpisodes { open[update.id] = update }
            for candidate in result.candidates { if let skip = candidate.skip { output.skips[skip, default: 0] += 1 } }
            output.slowestPassSeconds = max(output.slowestPassSeconds, Date().timeIntervalSince(started))
            cutoff += 900
        }
        return output
    }

    @Test func defaultThresholdsStayQuietOnTheSnapshot() throws {
        guard let source = Self.snapshotPath else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heart-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("loopr.sqlite")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: source + suffix) {
            try? FileManager.default.copyItem(atPath: source + suffix, toPath: copy.path + suffix)
        }
        let database = try StorageDatabase(url: copy)

        let defaults = HeartRateAlertSettings(highEnabled: true, lowEnabled: true)
        let standard = try replay(database, settings: defaults)
        print("[heart-alerts snapshot] defaults: alerts=\(standard.alerts.count) skips=\(standard.skips) slowest pass=\(standard.slowestPassSeconds)s max rows=\(standard.seconds)")
        // 2.2 days of real wear: the only stretch past 120 bpm at rest is an
        // optical artifact (band 160-191 bpm while RR said about 75), which the
        // beat-to-beat check rejects.
        #expect(standard.alerts.isEmpty)
        #expect((standard.skips[.beatToBeatDisagrees] ?? 0) > 0)

        // The most sensitive choices still do not produce a stream of alerts.
        let sensitive = try replay(database, settings: HeartRateAlertSettings(
            highEnabled: true, highThresholdBPM: 100, lowEnabled: true, lowThresholdBPM: 50, lowIncludesSleep: true))
        print("[heart-alerts snapshot] 100/50 with sleep: alerts=\(sensitive.alerts.count) skips=\(sensitive.skips)")
        #expect(sensitive.alerts.count <= 2)

        // Without the beat-to-beat check the artifact would have alerted.
        var unchecked = HeartRateAlertParameters.standard
        unchecked.requiresBeatToBeatConfirmation = false
        unchecked.minimumConfirmationBeats = .max / 4
        let withoutCheck = try replay(database, settings: defaults, parameters: unchecked)
        print("[heart-alerts snapshot] defaults without beat-to-beat: alerts=\(withoutCheck.alerts.map { ($0.start, $0.medianBPM) })")
        #expect(withoutCheck.alerts.count == 1)
        // A pass over one offload stays cheap.
        #expect(standard.slowestPassSeconds < 2)
    }
}
