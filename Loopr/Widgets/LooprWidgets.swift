import ActivityKit
import SharedSurfaceKit
import DesignSystem
import SwiftUI
import WidgetKit

private enum WidgetSnapshotReader {
    static func read() -> SurfaceSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SurfaceConfiguration.appGroupIdentifier
        ) else { return nil }
        return try? SurfaceSnapshotCodec.decode(
            Data(contentsOf: container.appendingPathComponent("surface.json"))
        )
    }
}

private struct LooprWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SurfaceSnapshot?
}

private struct LooprTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> LooprWidgetEntry {
        LooprWidgetEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (LooprWidgetEntry) -> Void) {
        completion(LooprWidgetEntry(date: .now, snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<LooprWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotReader.read()
        let entries = SurfaceTimelineSchedule.dates(now: now).map { LooprWidgetEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private struct TodayWidget: Widget {
    let kind = "LooprTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LooprTimelineProvider()) { entry in
            TodayWidgetBody(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("See your latest Loopr summary.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct TodayWidgetBody: View {
    @Environment(\.widgetFamily) private var family
    let entry: LooprWidgetEntry

    var body: some View {
        LooprTodayWidgetContent(snapshot: entry.snapshot, now: entry.date, family: family)
        .containerBackground(Color.loopr(.background), for: .widget)
    }
}

private struct BatteryWidget: Widget {
    let kind = "LooprBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LooprTimelineProvider()) { entry in
            BatteryWidgetBody(entry: entry)
        }
        .configurationDisplayName("Band Battery")
        .description("Check your band battery and sync status.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct BatteryWidgetBody: View {
    @Environment(\.widgetFamily) private var family
    let entry: LooprWidgetEntry

    var body: some View {
        LooprWidgetContent(
            title: entry.snapshot?.battery?.charging == true ? "Charging" : "Band",
            projection: SurfaceWidgetProjection.battery(
                snapshot: entry.snapshot,
                now: entry.date,
                privacy: family == .systemSmall ? .normal : .lockScreen
            ),
            family: family
        )
        .overlay(alignment: .topTrailing) {
            if entry.snapshot?.battery?.charging == true {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Charging")
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LooprWorkoutActivityAttributes.self) { context in
            LooprWorkoutLiveActivityBanner(visual: visual(context))
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let visual = visual(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visual.name).font(.caption)
                        Text("\(visual.heartRate) bpm")
                            .font(.title2.bold()).monospacedDigit()
                            .foregroundStyle(visual.zoneColor)
                            .accessibilityLabel(visual.heartRateAccessibility)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(visual.targetLine ?? visual.zoneName).foregroundStyle(visual.zoneColor)
                        LooprWorkoutElapsedView(state: visual.state).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let distance = visual.distance { Text(distance) }
                        if let pace = visual.pace { Text(pace) }
                        Spacer()
                        if visual.isStale { Text(visual.status) }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(visual.zoneColor)
                    .accessibilityLabel(visual.zoneName)
            } compactTrailing: {
                Text(visual.heartRate).monospacedDigit()
                    .accessibilityLabel(visual.heartRateAccessibility)
            } minimal: {
                Text(visual.heartRate)
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .foregroundStyle(visual.zoneColor)
                    .accessibilityLabel("\(visual.heartRateAccessibility), \(visual.zoneName)")
            }
        }
    }

    private func visual(
        _ context: ActivityViewContext<LooprWorkoutActivityAttributes>
    ) -> LooprWorkoutLiveActivityVisual {
        .init(name: context.attributes.activityName,
              state: context.state, isStale: context.isStale)
    }
}

private struct BreathingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LooprBreathingActivityAttributes.self) { context in
            LooprBreathingLiveActivityBanner(state: context.state, isStale: context.isStale)
            .activityBackgroundTint(.blue.opacity(0.75))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let visual = visual(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LooprLiveActivityLeadingContent(visual: visual)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LooprLiveActivityTrailingContent(visual: visual)
                }
                DynamicIslandExpandedRegion(.bottom) { Text(visual.status) }
            } compactLeading: {
                LooprLiveActivityCompactLeadingContent(visual: visual)
            } compactTrailing: {
                LooprLiveActivityCompactTrailingContent(visual: visual)
            } minimal: {
                LooprLiveActivityMinimalContent(visual: visual)
            }
        }
    }

    private func visual(
        _ context: ActivityViewContext<LooprBreathingActivityAttributes>
    ) -> LooprLiveActivityVisual {
        .breathing(
            completedCycles: context.state.completedCycles,
            status: context.isStale ? "Stopped updating" : context.state.status
        )
    }
}

private struct IntervalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LooprIntervalActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(context.isStale ? "Interval timer" : context.state.phase).font(.headline)
                    Spacer()
                    Text("Round \(context.state.round) of \(context.attributes.rounds)").font(.caption)
                }
                if context.isStale {
                    Text("Open Loopr for the current phase").font(.caption)
                } else {
                    Text(timerInterval: context.state.phaseStartedAt...context.state.phaseEndsAt, countsDown: true)
                        .font(.largeTitle.bold()).monospacedDigit()
                }
                HStack {
                    Text("Session remaining").font(.caption)
                    Text(timerInterval: context.state.phaseStartedAt...context.attributes.endsAt, countsDown: true)
                        .font(.caption).monospacedDigit()
                }
            }
            .padding()
            .widgetURL(URL(string: "loopr://intervals"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.isStale ? "Intervals" : context.state.phase) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.phaseStartedAt...context.attributes.endsAt, countsDown: true).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) { Text("Round \(context.state.round) of \(context.attributes.rounds)") }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text(timerInterval: context.state.phaseStartedAt...context.attributes.endsAt, countsDown: true).monospacedDigit()
            } minimal: {
                Image(systemName: "timer")
            }
            .widgetURL(URL(string: "loopr://intervals"))
        }
    }
}

@main
struct LooprWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        BatteryWidget()
        WorkoutLiveActivity()
        BreathingLiveActivity()
        IntervalLiveActivity()
    }
}
