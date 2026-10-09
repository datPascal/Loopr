import AppIntents
import SharedSurfaceKit
import SwiftUI
import WatchConnectivity
import WidgetKit

private nonisolated enum WatchSnapshotCache {
    static let payloadKey = WatchSurfaceApplicationContext.payloadKey

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SurfaceConfiguration.appGroupIdentifier)
    }

    static func decode(_ context: [String: Any]) -> SurfaceSnapshot? {
        guard let data = WatchSurfaceApplicationContext.payload(in: context) else { return nil }
        return try? SurfaceSnapshotCodec.decode(data)
    }

    static func cached() -> SurfaceSnapshot? {
        defaults?.data(forKey: payloadKey).flatMap { try? SurfaceSnapshotCodec.decode($0) }
    }

    static func resolved(_ context: [String: Any]) -> SurfaceSnapshot? {
        if WatchSurfaceApplicationContext.isRevoked(context) { return nil }
        guard WatchSurfaceApplicationContext.payload(in: context) == nil else { return decode(context) }
        return cached()
    }

    static func store(_ snapshot: SurfaceSnapshot?) {
        guard let snapshot else {
            defaults?.removeObject(forKey: payloadKey)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: payloadKey)
    }
}

private nonisolated enum LooprWatchSurfaceProbe {
    static var mode: String? {
        ProcessInfo.processInfo.environment["LOOPR_WATCH_SURFACE_PROBE"]
    }

    static func snapshot(now: Date = Date()) -> SurfaceSnapshot {
        SurfaceSnapshot(
            generation: 805,
            createdAt: now,
            sourceDay: SurfaceDayLabel.format(now),
            syncDate: now,
            metrics: .init(recovery: 82, strain: 8.6, heartRate: 54, sleepMinutes: 462),
            battery: .init(level: 0.74, observedAt: now),
            activeWorkout: nil,
            staleReasons: []
        )
    }
}

@MainActor
private final class WatchSnapshotModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: SurfaceSnapshot?

    override init() {
        let session = WCSession.default
        // `receivedApplicationContext` is what the iPhone last sent. The
        // similarly named `applicationContext` is what this watch last sent,
        // and the watch never sends one, so reading that returns an empty
        // dictionary forever and the dashboard sticks on "No recent sync".
        let applicationContext = session.receivedApplicationContext
        let deliveredSnapshot = WatchSnapshotCache.resolved(applicationContext)
        snapshot = deliveredSnapshot
        #if DEBUG
        if LooprWatchSurfaceProbe.mode == "populated" {
            snapshot = LooprWatchSurfaceProbe.snapshot()
        }
        #endif
        super.init()
        if WatchSurfaceApplicationContext.replacesCachedPayload(applicationContext) {
            WatchSnapshotCache.store(deliveredSnapshot)
        } else if let snapshot {
            WatchSnapshotCache.store(snapshot)
        }
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    /// The received context is only guaranteed to be readable once the session
    /// is active, so the value read in `init` can still be empty. Reading it
    /// again here is what picks up a snapshot the iPhone sent while this app
    /// was not running.
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard error == nil, state == .activated else { return }
        let context = session.receivedApplicationContext
        guard WatchSurfaceApplicationContext.replacesCachedPayload(context) else { return }
        apply(context)
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext context: [String: Any]) {
        apply(context)
    }

    /// An empty context is a delivery with nothing in it, not an instruction
    /// to forget. Only a payload or an explicit revocation replaces the cache.
    private nonisolated func apply(_ context: [String: Any]) {
        guard WatchSurfaceApplicationContext.replacesCachedPayload(context) else { return }
        let decoded = WatchSnapshotCache.decode(context)
        WatchSnapshotCache.store(decoded)
        Task { @MainActor in
            self.snapshot = decoded
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

#if DEBUG
private struct WatchComplicationCandidate: View {
    let family: WidgetFamily

    var body: some View {
        LooprWatchComplicationContent(
            family: family,
            snapshot: LooprWatchSurfaceProbe.snapshot(now: Date(timeIntervalSince1970: 1_788_000_000))
        )
        .frame(maxWidth: family == .accessoryCircular ? 58 : .infinity)
        .frame(height: family == .accessoryCircular ? 58 : 64)
        .padding(family == .accessoryCircular ? 4 : 8)
        .background(.fill.tertiary)
        .clipShape(family == .accessoryCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14)))
        .padding(.horizontal, 8)
    }
}
#endif

private struct WatchDashboard: View {
    @StateObject private var model = WatchSnapshotModel()
    var body: some View {
        if let snapshot = model.snapshot {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List { LooprWatchSummaryRows(snapshot: snapshot, now: context.date) }
            }
        } else {
            LooprWatchEmptySummary()
        }
    }
}

@main
struct LooprWatchApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if LooprWatchSurfaceProbe.mode == "circular" {
                WatchComplicationCandidate(family: .accessoryCircular)
            } else if LooprWatchSurfaceProbe.mode == "rectangular" {
                WatchComplicationCandidate(family: .accessoryRectangular)
            } else {
                WatchDashboard()
            }
            #else
            WatchDashboard()
            #endif
        }
    }
}
