import DesignSystem
import SwiftUI

/// One push of a metric detail page. The id keeps two opens of the same
/// metric distinct so the second tap still navigates.
struct MetricDetailRoute: Hashable, Identifiable {
    let key: MetricKey
    /// The card the page grows out of, when one is on screen.
    var zoomSourceID: String?
    let id = UUID()
}

/// Lets the screen it is applied to open metric detail pages. It gives the
/// screen a `LooprMetricLink`, so a card in any feature package can open a
/// metric page and load its sparkline, and pushes the page with
/// `navigationDestination(item:)` declared on that same screen.
///
/// Apply it to every root and every pushed destination in a stack. Each
/// screen owns its own route: a single destination declared on the root
/// popped the whole stack when the user went back from a metric page opened
/// on a pushed screen, and pushed destinations do not inherit the root's
/// environment anyway. The typed route enums and `ProductFeatureRoots.swift`
/// stay untouched.
struct MetricDetailNavigation: ViewModifier {
    /// Whether pages zoom out of the card that opened them. Only tab roots
    /// zoom: going back from a zoomed page on a pushed screen popped the
    /// whole stack.
    var zooms = false
    @Environment(\.metricHistoryProvider) private var inheritedProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.looprTabScrollRequest) private var homeScrollRequest
    @State private var route: MetricDetailRoute?
    /// Cards on this screen that a page can zoom out of.
    @Namespace private var zoomNamespace
    @State private var zoomSources = LooprMetricZoomSources()

    func body(content: Content) -> some View {
        let provider = effectiveProvider
        content
            .navigationDestination(item: $route) { route in
                // The page gets its own link, so "What moves with this" can
                // push the next metric on top instead of replacing this one.
                MetricDetailScreen(key: route.key)
                    .modifier(MetricDetailNavigation())
                    .environment(\.metricHistoryProvider, provider)
                    .modifier(MetricDetailZoomTransition(sourceID: route.zoomSourceID, namespace: zoomNamespace))
            }
            .environment(\.looprMetricLink, Self.link(
                provider: provider,
                route: $route,
                zoomSources: zooms && !LooprMotion.reducesMotion(reduceMotion) ? zoomSources : nil
            ))
            .environment(\.looprMetricZoom, zooms ? LooprMetricZoom(namespace: zoomNamespace, sources: zoomSources) : nil)
            .environment(\.metricHistoryProvider, provider)
            .onChange(of: homeScrollRequest) { _, request in
                if request != nil { route = nil }
            }
            #if DEBUG
            .task {
                // Screenshot and UI-test hook: `--loopr-open-metric=<key>`.
                // These captures deep-link to a detail destination. Leave its
                // launch key there instead of consuming it at a zoomable tab root.
                guard DebugCaptureFixtures.siSurfacesState == nil || !zooms else { return }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let key = MetricDetailDebugLaunch.consumeOpenKey() else { return }
                route = MetricDetailRoute(key: key)
            }
            #endif
    }

    private var effectiveProvider: any MetricHistoryProviding {
        #if DEBUG
        if DebugCaptureFixtures.siHeartnavState != nil { return SIHeartnavMetricHistoryProvider() }
        if let state = DebugCaptureFixtures.siSurfacesState { return SISurfacesMetricHistoryProvider(state: state) }
        if FixtureMetricHistoryProvider.isRequested { return FixtureMetricHistoryProvider() }
        #endif
        return inheritedProvider
    }

    /// - Parameter zoomSources: The cards a page may zoom out of. Nil, as with
    ///   Reduce Motion, always uses the normal push.
    static func link(
        provider: any MetricHistoryProviding,
        route: Binding<MetricDetailRoute?>,
        zoomSources: LooprMetricZoomSources? = nil
    ) -> LooprMetricLink {
        LooprMetricLink(
            open: { id in
                guard let key = MetricKey(linkID: id) else { return }
                guard key != .oxygenSaturation else { return }
                let zooms = zoomSources?.contains(id) == true
                route.wrappedValue = MetricDetailRoute(key: key, zoomSourceID: zooms ? id : nil)
            },
            history: { @Sendable [provider] id, days in
                guard let key = MetricKey(linkID: id) else { return [] }
                let history = (try? await provider.series(for: key, days: days, endingOn: Date())) ?? []
                return MetricTrendNarrative.chartPoints(history)
            },
            supports: { id in
                guard let key = MetricKey(linkID: id) else { return false }
                return key != .oxygenSaturation
            },
            historyEndingOn: { @Sendable [provider] id, days, endingOn in
                guard let key = MetricKey(linkID: id) else { return [] }
                let history = (try? await provider.series(for: key, days: days, endingOn: endingOn)) ?? []
                return MetricTrendNarrative.chartPoints(history)
            }
        )
    }
}

/// The page grows out of the card that opened it, and shrinks back into it
/// when the person goes back. Without a source it is a normal push.
private struct MetricDetailZoomTransition: ViewModifier {
    let sourceID: String?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    /// Lets this screen open metric detail pages. Apply to each stack root
    /// and each pushed destination. `zooms` is for tab roots only.
    func metricDetailNavigation(zooms: Bool = false) -> some View {
        modifier(MetricDetailNavigation(zooms: zooms))
    }
}

/// Debug-only launch hooks for screenshots and UI tests:
/// `--loopr-open-metric=<MetricKey raw value>` opens that page once on the
/// first screen that can, `--loopr-metric-scroll=<section id>` scrolls it to
/// a section (`metric-detail-correlations`, ...), and
/// `--loopr-metric-range=<week|month|quarter|year>` picks the first range.
/// Release builds read nothing.
@MainActor
enum MetricDetailDebugLaunch {
    #if DEBUG
    private static var openConsumed = false
    private static var scrollConsumed = false

    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static func consumeOpenKey() -> MetricKey? {
        guard !openConsumed, let raw = argument("loopr-open-metric"), let key = MetricKey(rawValue: raw) else { return nil }
        guard key != .oxygenSaturation else { return nil }
        openConsumed = true
        return key
    }

    static func consumeScrollTarget() -> String? {
        guard !scrollConsumed, let target = argument("loopr-metric-scroll") else { return nil }
        scrollConsumed = true
        return target
    }

    static var initialRange: LooprChartRange? {
        argument("loopr-metric-range").flatMap(LooprChartRange.init(rawValue:))
    }
    #else
    static var initialRange: LooprChartRange? { nil }
    #endif
}
