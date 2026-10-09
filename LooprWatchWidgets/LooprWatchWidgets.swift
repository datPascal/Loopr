import SwiftUI
import SharedSurfaceKit
import WidgetKit

private struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: SurfaceSnapshot?
}

private struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        let current = entry()
        let entries = SurfaceTimelineSchedule.dates(now: current.date).map { WatchComplicationEntry(date: $0, snapshot: current.snapshot) }
        completion(Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(15 * 60))))
    }

    private func entry() -> WatchComplicationEntry {
        let context = UserDefaults(suiteName: SurfaceConfiguration.appGroupIdentifier)?
            .data(forKey: WatchSurfaceApplicationContext.payloadKey)
        return WatchComplicationEntry(
            date: .now,
            snapshot: context.flatMap { try? SurfaceSnapshotCodec.decode($0) }
        )
    }
}

private struct LooprComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchComplicationEntry

    var body: some View {
        LooprWatchComplicationContent(family: family, snapshot: entry.snapshot, now: entry.date)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct LooprWatchComplication: Widget {
    let kind = "LooprWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            LooprComplicationView(entry: entry)
        }
        .configurationDisplayName("Loopr")
        .description("See recovery, sleep and strain on your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

@main
struct LooprWatchWidgetsBundle: WidgetBundle {
    var body: some Widget { LooprWatchComplication() }
}
