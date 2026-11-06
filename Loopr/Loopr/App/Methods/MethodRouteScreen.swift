import DataKit
import DesignSystem
import SwiftUI

/// The method page Data's stack opens for `AppHealthRoute.method`.
///
/// For a metric page the "How it works" text and the short citations come from `MetricContentCatalog`, the same words
/// the metric's detail page uses, so they are written once. Other pages use the method catalog's own rule.
///
/// The hero value is passed in by the caller. A DEBUG launch with `--loopr-method-fixture` shows the fixture PhenoAge
/// and recovery values so the waterfall can be captured and tested.
struct MethodRouteScreen: View {
    let id: MethodID
    var value: MethodPageValue?

    init(id: MethodID, value: MethodPageValue? = nil) {
        self.id = id
        self.value = value
    }

    var body: some View {
        let entry = MethodCatalog.entry(id)
        let content = MethodMetricText.content(for: entry)
        MethodPageView(entry: entry, value: shownValue, howItWorks: content?.calculation,
                       furtherReading: content?.sources ?? [])
    }

    private var shownValue: MethodPageValue? {
        // A page opened from the list shows the ruler's own reading, the one its pin would pass.
        if let own = value ?? DataAgeRulerLatest.ruler?.methodValue(for: id) { return own }
        #if DEBUG
        if MethodLaunchArgument.usesFixtureValues(ProcessInfo.processInfo.arguments) {
            return MethodFixtures.value(for: id)
        }
        #endif
        return nil
    }
}

/// Links metric keys to method pages and back.
enum MethodMetricText {
    /// The page that explains a metric. Every `MetricKey` has one; `MethodRouteTests` holds that.
    static func methodID(for key: MetricKey) -> MethodID? {
        MethodCatalog.entry(forMetricKey: key.rawValue)?.id
    }

    /// The metric catalog's text for a page that explains metrics, from its first metric key.
    static func content(for entry: MethodEntry) -> MetricContent? {
        guard let raw = entry.metricKeys.first, let key = MetricKey(rawValue: raw) else { return nil }
        return MetricContentCatalog.content(for: key)
    }
}
