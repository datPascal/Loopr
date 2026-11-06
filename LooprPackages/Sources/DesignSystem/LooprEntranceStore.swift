import Foundation
import SwiftUI

/// Remembers whether a tab's entrance animation played today (DESIGN_LANGUAGE premium check 6): the
/// first visit to a tab on a local day plays it, every later visit shows the final state at once.
/// The day is the calendar's local day, so it turns over at local midnight, and daylight saving
/// changes neither repeat nor skip a day. Records live in `UserDefaults`, so they survive relaunch.
///
/// The launch arguments `--loopr-entrance-final-state` and `--loopr-visual-capture` make every
/// entrance show its final state, for UI tests and captures. In DEBUG builds, `--loopr-entrance-reset`
/// forgets every recorded entrance at launch, so a performance suite can replay each tab's entrance
/// on every relaunch.
public final class LooprEntranceStore: @unchecked Sendable {
    /// Forces the final state of every entrance.
    public static let finalStateLaunchArgument = "--loopr-entrance-final-state"
    /// DEBUG only: clears every recorded entrance when the store is created.
    public static let resetLaunchArgument = "--loopr-entrance-reset"
    /// The visual capture runs also want final states.
    public static let visualCaptureLaunchArgument = "--loopr-visual-capture"
    /// The app's store, in the standard defaults.
    public static let shared = LooprEntranceStore()

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// True when a launch argument forces the final state.
    public let forcesFinalState: Bool

    /// - Parameters:
    ///   - defaults: where records live. Tests pass their own suite.
    ///   - calendar: the calendar and time zone that decide the local day.
    ///   - now: the clock.
    ///   - arguments: the launch arguments to read the final-state override from.
    public init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent,
                now: @escaping @Sendable () -> Date = { Date() },
                arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        forcesFinalState = arguments.contains(Self.finalStateLaunchArgument)
            || arguments.contains(Self.visualCaptureLaunchArgument)
        #if DEBUG
        if arguments.contains(Self.resetLaunchArgument) { forgetAll() }
        #endif
    }

    /// Forgets every recorded entrance in this store's defaults, whatever its key.
    func forgetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The local day `date` falls on, as "yyyy-MM-dd" in the calendar's time zone.
    public func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether `tab`'s entrance already played today.
    public func hasPlayedToday(_ tab: String) -> Bool {
        defaults.string(forKey: Self.key(tab)) == dayKey(for: now())
    }

    /// Whether `tab` should play its entrance now: not yet today, motion allowed, no override.
    public func shouldAnimate(_ tab: String, reduceMotion: Bool) -> Bool {
        !forcesFinalState && !reduceMotion && !hasPlayedToday(tab)
    }

    /// Records that `tab`'s entrance finished today.
    public func recordPlayed(_ tab: String) {
        defaults.set(dayKey(for: now()), forKey: Self.key(tab))
    }

    /// Forgets every tab, as "Reset" in the gallery does.
    public func reset(_ tabs: [String]) {
        tabs.forEach { defaults.removeObject(forKey: Self.key($0)) }
    }

    static let keyPrefix = "loopr.entrance."
    static func key(_ tab: String) -> String { keyPrefix + tab }
}

public extension EnvironmentValues {
    /// The store `looprEntrance(tab:animates:)` reads. Tests and previews put their own here.
    @Entry var looprEntranceStore: LooprEntranceStore = .shared
}

public extension View {
    /// Decides once, as the view appears, whether `tab` plays its entrance: `animates` turns true on
    /// the first visit of the local day and false otherwise, and always false under Reduce Motion or
    /// the final-state override. The visit is recorded when the entrance has run for `duration`, so
    /// leaving halfway through plays it again next time.
    ///
    /// ```swift
    /// @State private var entrance = false
    /// ...
    /// dial.looprEntrance(tab: "today", animates: $entrance)
    /// ```
    func looprEntrance(tab: String, animates: Binding<Bool>, duration: Double = LooprMotion.reveal) -> some View {
        modifier(LooprEntranceModifier(tab: tab, animates: animates, duration: duration))
    }
}

struct LooprEntranceModifier: ViewModifier {
    let tab: String
    @Binding var animates: Bool
    let duration: Double
    @Environment(\.looprEntranceStore) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear {
                animates = store.shouldAnimate(tab, reduceMotion: LooprMotion.reducesMotion(reduceMotion))
            }
            .task(id: animates) {
                guard animates else { return }
                // One animation interval from the first frame to the settled state, for the
                // entrance performance suite. It closes on every exit, a cancelled sleep included.
                let interval = LooprPerformanceSignposts.beginEntrance(tab: tab)
                defer { if let interval { LooprPerformanceSignposts.endInterval(interval) } }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                store.recordPlayed(tab)
            }
    }
}
