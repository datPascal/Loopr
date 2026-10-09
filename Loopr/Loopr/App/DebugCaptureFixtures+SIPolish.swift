#if DEBUG
import AnalyticsKit
import BodyKit
import TodayKit
import DesignSystem
import DataKit
import DeviceCenterKit
import DomainKit
import Foundation
import HeartKit
import SharedSurfaceKit
import SwiftUI
import WidgetKit
import WorkoutKit

nonisolated extension DebugCaptureFixtures {
    static var siPolishState: String? {
        let prefix = "--loopr-si-polish-fixture="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
    static var siPolishGlances: Bool { ProcessInfo.processInfo.arguments.contains("--loopr-si-polish-glances") }
    static var siStoreFixture: Bool { ProcessInfo.processInfo.arguments.contains("--loopr-si-store-fixture") }
}

extension DebugCaptureFixtures {
    static func siPolishSurfaceSnapshot(_ base: HeartDaySnapshot, state: String?) -> HeartDaySnapshot {
        guard let state else { return base }
        let pairs: [(HeartMetricID, MetricKey)] = [(.heartRateDip, .heartRateDip),
            (.sleepingHeartRate, .sleepingHeartRate), (.maxHeartRate, .maxHeartRate)]
        let capturedIDs = Set(pairs.map(\.0))
        let metrics = base.metrics.filter { !capturedIDs.contains($0.id) } + pairs.map { id, key in
            let number = SISurfacesMetricHistoryProvider.latestValue(for: key, state: state)
            return HeartMetricValue(id: id, title: id.title, value: number.map { String(format: "%.0f", $0) },
                unit: id == .heartRateDip ? "%" : "bpm", state: number == nil ? .absent : .partial,
                source: "synthetic-si-polish", numericValue: number,
                numericUnit: id == .heartRateDip ? .percentagePoints : .beatsPerMinute)
        }
        return HeartDaySnapshot(day: base.day, state: base.state, metrics: metrics,
            liveState: base.liveState, source: base.source, algorithmVersion: base.algorithmVersion,
            trend: base.trend, vitals: base.vitals)
    }
}

/// One synthetic world for the populated smart-insights captures.
nonisolated enum SIPolishFixtureWorld {
    static var summary: TodaySummary { DebugCaptureFixtures.siMorningSummary(mode: "good")! }
    static var recovery: Double? { summary.metric(.readiness)?.numericValue }
    static var target: StrainTarget? { StrainTarget(recovery: recovery) }
    static var dayString: String {
        let day = summary.day
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }
    static var captureNow: Date {
        let day = summary.day
        return Calendar.current.date(from: DateComponents(year: day.year, month: day.month,
            day: day.day, hour: 9, minute: 41))!
    }
    static var device: DeviceIdentity {
        let base = DeviceCenterStateFixtures.sampleDevice
        return DeviceIdentity(id: base.id, peripheralIdentifier: base.peripheralIdentifier,
            generation: base.generation, modelName: "Gen 4 band", displayName: "Training band",
            modelConfidence: base.modelConfidence, firmwareVersion: base.firmwareVersion,
            serialNumber: "4B7C2D9A6F31", capabilities: base.capabilities)
    }
    static var deviceStatus: DeviceStatusSnapshot {
        let fresh = captureNow.addingTimeInterval(-120)
        return DeviceStatusSnapshot(connection: .connected, bluetooth: .poweredOn,
            batteryPercent: .measured(74), charging: false,
            batteryForecast: .measured(BatteryForecast(hoursRemaining: 42, confidence: .high)),
            wristState: .worn, freshness: .measured(fresh), lastPacketAt: fresh,
            historyCommitAt: fresh, completedSyncAt: fresh, storedAt: fresh)
    }
    static var dataRecord: DataRecord {
        DataRecord(id: "si-store-record", day: dayString, table: "metrics",
                   payload: ["value": "79"], provenance: .whoopCSV)
    }
    static var workouts: [WorkoutRecord] {
        [(ActivityType.run, 0, 8, 5, 1_800, 5_000.0, 142),
         (.cycle, -1, 18, 0, 2_700, 16_400.0, 128)].enumerated().map { index, entry in
            let (activity, offset, hour, minute, seconds, meters, bpm) = entry
            let day = Calendar.current.date(byAdding: .day, value: offset, to: captureNow)!
            let start = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            let end = start.addingTimeInterval(Double(seconds))
            return WorkoutRecord(id: index == 0 ? WorkoutFixtures.completedRun.id : WorkoutFixtures.interrupted.id,
                identity: WorkoutIdentity.make(activity: activity, sourceKey: "si-store", startedAt: start, endedAt: end),
                activity: activity, source: .manual, state: .completed, createdAt: start,
                startedAt: start, endedAt: end, samples: (0...seconds / 30).map { tick in
                    WorkoutSample(timestamp: start.addingTimeInterval(Double(tick * 30)),
                        heartRate: bpm + Int(14 * LooprFixtureMetrics.variation(seed: "si-store-workout-\(index)", offset: tick)),
                        distanceMeters: meters * Double(tick * 30) / Double(seconds))
                }, checkpointNumber: 2, finalizationStage: .activeStateCleared)
        }
    }
    static var headline: String? {
        let summary = summary
        let context = DebugCaptureFixtures.siMorningContext(day: summary.day, summary: summary, mode: "good")
        return TodayDashboard(summary: summary, context: context, pinned: [], isToday: true).hero.reading?.driver
    }
    static var beats: BeatToBeatSummary {
        BeatToBeatSummary(sd1Milliseconds: 38.7, sd2Milliseconds: 74.6,
            meanIntervalMilliseconds: 1_097, beatCount: 21_837, pairCount: 21_836,
            points: (0..<160).map { index in
                let along = 170 * LooprFixtureMetrics.variation(seed: "si-beat-along", offset: index)
                let across = 74 * LooprFixtureMetrics.variation(seed: "si-beat-across", offset: index)
                return .init(current: 1_097 + Int(along - across), next: 1_097 + Int(along + across))
            }, tachogram: (0..<210).map { index in
                .init(minute: Double(index * 2), meanIntervalMilliseconds: 1_097
                    + 55 * sin(Double(index) * 0.045)
                    + 45 * LooprFixtureMetrics.variation(seed: "si-tachogram", offset: index))
            })
    }
}

/// The shipped glance views, hosted in the app for native UI capture.
struct SIPolishGlanceGallery: View {
    let state: String
    private let now = Date()
    private var snapshot: SurfaceSnapshot? {
        DebugCaptureFixtures.siSurfacesSnapshot(state: state == "good" ? "ready" : state, now: now)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: LooprSpacing.md) {
                LooprSectionHeader("Today widgets")
                LooprTodayWidgetContent(snapshot: snapshot, now: now, family: .systemSmall)
                    .padding(16).frame(width: 170, height: 170)
                    .background(Color.loopr(.background), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("si-polish-widget-small")
                LooprTodayWidgetContent(snapshot: snapshot, now: now, family: .systemMedium)
                    .padding(16).frame(width: 350, height: 170)
                    .background(Color.loopr(.background), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("si-polish-widget-medium")
                LooprSectionHeader("Lock screen")
                HStack {
                    LooprTodayWidgetContent(snapshot: snapshot, now: now, family: .accessoryCircular)
                        .frame(width: 64, height: 64)
                    LooprTodayWidgetContent(snapshot: snapshot, now: now, family: .accessoryRectangular)
                        .frame(width: 220, height: 76)
                }
                .accessibilityIdentifier("si-polish-accessories")
                LooprSectionHeader("Watch")
                if let snapshot {
                    VStack(alignment: .leading, spacing: 10) { LooprWatchSummaryRows(snapshot: snapshot, now: now) }
                        .padding(12).frame(width: 240)
                        .looprCardBackground()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("si-polish-watch")
                } else {
                    LooprWatchEmptySummary().padding(12).frame(width: 240).looprCardBackground()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("si-polish-watch")
                }
                LooprWatchComplicationContent(family: .accessoryRectangular, snapshot: snapshot, now: now)
                    .frame(width: 220, height: 76)
                    .accessibilityIdentifier("si-polish-watch-complication")
            }
            .padding(LooprSpacing.screenGutter)
        }
        .background(Color.loopr(.surfaceSunk))
        .navigationTitle("Glance review")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("si-polish-glances")
    }
}
#endif
