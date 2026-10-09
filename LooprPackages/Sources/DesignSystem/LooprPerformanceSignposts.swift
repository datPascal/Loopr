import Foundation
import os

/// Launch and navigation timing.
///
/// Every interval is an `os_signpost` in the Points of Interest track, so it
/// shows in Instruments next to the main-thread trace. Each one also logs its
/// length at notice level under the `Performance` category, which lets a
/// headless run read the numbers with `log show` or `log stream`:
///
///     log stream --predicate 'subsystem == "com.loopr.ios" AND category == "Performance"'
///
/// The cost is one clock read and one signpost per call, so it stays on in
/// release builds.
public enum LooprPerformance {
    public static let subsystem = "com.loopr.ios"

    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    private static let logger = Logger(subsystem: subsystem, category: "Performance")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reachedMilestones: Set<String> = []
    nonisolated(unsafe) private static var pendingTabSwitch: Interval?

    /// When the kernel started this process. Launch milestones are measured
    /// from here, so they include dyld and everything before `main`.
    public static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// One open interval. End it exactly once with `end(_:_:)`.
    public struct Interval: @unchecked Sendable {
        fileprivate let name: StaticString
        fileprivate let detail: String
        fileprivate let state: OSSignpostIntervalState
        fileprivate let startedAt: UInt64
    }

    public static func begin(_ name: StaticString, _ detail: String = "") -> Interval {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id, "\(detail, privacy: .public)")
        return Interval(name: name, detail: detail, state: state, startedAt: DispatchTime.now().uptimeNanoseconds)
    }

    public static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - interval.startedAt) / 1_000_000
        logger.notice("interval \(String(describing: interval.name), privacy: .public) \(interval.detail, privacy: .public) \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }

    /// Times `work` as one interval.
    public static func measure<T>(_ name: StaticString, _ detail: String = "", _ work: () throws -> T) rethrows -> T {
        let interval = begin(name, detail)
        defer { end(interval) }
        return try work()
    }

    /// Marks a launch milestone once per process and logs how long after
    /// process start it was reached.
    public static func milestone(_ name: StaticString) {
        let key = String(describing: name)
        lock.lock()
        let isFirst = reachedMilestones.insert(key).inserted
        lock.unlock()
        guard isFirst else { return }
        signposter.emitEvent(name)
        let milliseconds = Date().timeIntervalSince(processStart) * 1_000
        logger.notice("milestone \(key, privacy: .public) \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms after process start")
    }

    /// Starts timing a tab switch. Called from the tab selection binding, so
    /// the interval covers the shell's re-render and the new tab's roots.
    public static func beginTabSwitch(to tab: String) {
        let interval = begin("TabSwitch", tab)
        lock.lock()
        let replaced = pendingTabSwitch
        pendingTabSwitch = interval
        lock.unlock()
        // A second tap before the first tab appeared: close the first one
        // so every begin has exactly one end.
        if let replaced { end(replaced) }
    }

    /// Ends a pending tab switch once the tab's root has appeared and the
    /// main queue has turned over, so the interval includes the update pass
    /// that built the tab.
    public static func tabRootDidAppear() {
        lock.lock()
        let pending = pendingTabSwitch
        pendingTabSwitch = nil
        lock.unlock()
        guard let pending else { return }
        DispatchQueue.main.async { end(pending) }
    }
}
