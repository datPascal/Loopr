import Foundation

/// A fixture-only workload for the scroll tests. It uses the same notifications
/// as a finished history batch and changes the fixture battery every ten ticks.
enum DebugLivePerformance {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("--loopr-performance-live")
    static let batteryChanged = Notification.Name("loopr.debug.performance.battery")

    @MainActor static func run() async {
        guard enabled else { return }
        var tick = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            tick += 1
            if tick.isMultiple(of: 10) { NotificationCenter.default.post(name: batteryChanged, object: tick) }
            if tick.isMultiple(of: 12) { NotificationCenter.default.post(name: looprHealthHistoryCommitted, object: nil) }
            if tick.isMultiple(of: 15) { NotificationCenter.default.post(name: looprDerivedGenerationUpdated, object: nil) }
        }
    }
    #else
    static let enabled = false
    #endif
}
