#if DEBUG
import ActivityKit
import DomainKit
import Foundation
import RoutineKit
import UIKit

/// The UI test hook for the bedtime activity. With `LOOPR_BEDTIME_PROBE=19:49` the app runs the bedtime runtime on a
/// fixed time of day (tomorrow's) with fixture rules, and a small overlay reports `Activity<LooprBedtimeActivityAttributes>
/// .activities.count` so a UI test can see the activity start, update and end. Debug builds only, and only with the
/// variable set.
enum BedtimeActivityProbe {
    static let environmentKey = "LOOPR_BEDTIME_PROBE"
    static let countIdentifier = "bedtime-activity-count"
    static let tickIdentifier = "bedtime-activity-tick"

    static func startIfRequested(environment: [String: String]) async {
        guard let value = environment[environmentKey], let minute = clockMinute(value) else { return }
        let fixture = BedtimeFixtureInputs()
        // Tomorrow at the given time, so every date the activity carries is in the future whatever the real hour is.
        // ActivityKit would treat a stale date in the past as an activity that is already out of date.
        let clock: @Sendable () -> Date = {
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: tomorrow) ?? Date()
        }
        await BedtimeActivityRuntime.shared.useFixture(now: clock, calendar: { Calendar.current })
        await BedtimeActivityRuntime.shared.setOnReconciled { await BedtimeProbeOverlay.shared.refresh() }
        await MainActor.run {
            BedtimeProbeOverlay.shared.onTick = {
                Task {
                    await fixture.tickNext()
                    await BedtimeActivityRuntime.shared.reconcile()
                    await BedtimeProbeOverlay.shared.refresh()
                }
            }
        }
        await BedtimeActivityRuntime.shared.setProvider(fixture)
        await BedtimeProbeOverlay.shared.refresh()
    }

    /// "19:49" as minutes after midnight.
    static func clockMinute(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

/// The evening the test sees: an in-bed rule at 22:30 and three evening rules, the first already kept.
actor BedtimeFixtureInputs: BedtimeActivityInputProviding {
    static let rules: [ProtocolRule] = [
        ProtocolRule(key: "fixture-in-bed", title: "In bed by 22:30", group: .sleep,
                     target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350, unit: "min"),
                     source: .band),
        ProtocolRule(key: "fixture-kitchen-closed", title: "Kitchen closed", group: .food, timeOfDayMinutes: 1_100,
                     isEvening: true),
        ProtocolRule(key: "fixture-wind-down", title: "Wind-down", group: .sleep, timeOfDayMinutes: 1_305,
                     isEvening: true),
        ProtocolRule(key: "fixture-screens-off", title: "Screens off", group: .sleep, isEvening: true)
    ]
    private var ticked: Set<RuleKey> = ["fixture-kitchen-closed"]

    func tonight(now _: Date, timeZone _: TimeZone) -> BedtimeTonight { BedtimeTonight(rules: Self.rules) }

    func checks(day: DayIdentity, now: Date, timeZone _: TimeZone) -> [RuleCheck] {
        Self.rules.filter(\.isEvening).compactMap { rule in
            try? RuleCheck(ruleKey: rule.key, day: day, version: 1, state: ticked.contains(rule.key) ? .kept : .pending,
                           source: .manual, recordedAt: now)
        }
    }

    func sleepStart(since _: Date, now _: Date) -> Date? { nil }

    func tickNext() {
        guard let next = Self.rules.filter(\.isEvening).first(where: { !ticked.contains($0.key) }) else { return }
        ticked.insert(next.key)
    }
}

/// A tiny window that reports the activity count and offers one button that ticks the next fixture rule. It lets touches
/// through everywhere else.
@MainActor
final class BedtimeProbeOverlay {
    static let shared = BedtimeProbeOverlay()

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Walk up from whatever was hit: a button can answer with one of its inner views.
            var view = super.hitTest(point, with: event)
            while let current = view {
                if current is UIButton { return current }
                view = current.superview
            }
            return nil
        }
    }

    var onTick: (() -> Void)?
    private var window: UIWindow?
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var text = "activities=0"

    /// ActivityKit applies an update or an end in the system process, so `content` and `activities` can still show the old
    /// value right after the awaited call returns. Reading once would then keep the old text for good. A short repeating
    /// read follows the real state instead.
    private var poll: Timer?

    func refresh() async {
        read()
        attach(retries: 60)
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func read() {
        let activities = Activity<LooprBedtimeActivityAttributes>.activities
        let done = activities.first.map { String($0.content.state.doneCount) } ?? "none"
        text = "activities=\(activities.count) done=\(done)"
        label.text = text
    }

    private func attach(retries: Int) {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            guard retries > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                attach(retries: retries - 1)
            }
            return
        }
        let overlay = PassThroughWindow(windowScene: scene)
        overlay.frame = scene.screen.bounds
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        overlay.rootViewController = root

        let height: CGFloat = 14
        let top = overlay.bounds.height - height - 2
        label.frame = CGRect(x: 4, y: top, width: 150, height: height)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.text = text
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = BedtimeActivityProbe.countIdentifier
        root.view.addSubview(label)

        button.frame = CGRect(x: 160, y: top, width: 44, height: height)
        button.setTitle("tick", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 9, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.accessibilityIdentifier = BedtimeActivityProbe.tickIdentifier
        button.addAction(UIAction { [weak self] _ in self?.onTick?() }, for: .touchUpInside)
        root.view.addSubview(button)

        overlay.isHidden = false
        window = overlay
    }
}
#endif
