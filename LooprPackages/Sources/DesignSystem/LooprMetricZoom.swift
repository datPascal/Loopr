import SwiftUI

/// Lets a metric card grow into its detail page.
///
/// The app owns the namespace and the navigation; a card in any feature
/// package only marks itself with `looprMetricZoomSource(_:)`. A page opened
/// from a card that is marked and on screen zooms out of it. A page opened
/// any other way uses the normal push, so a missing source never leaves the
/// page animating out of nothing.
@MainActor
public final class LooprMetricZoomSources {
    private var counts: [String: Int] = [:]

    public init() {}

    /// Whether a marked card for `id` is on screen.
    public func contains(_ id: String) -> Bool {
        (counts[id] ?? 0) > 0
    }

    func appeared(_ id: String) {
        counts[id, default: 0] += 1
    }

    func disappeared(_ id: String) {
        let next = (counts[id] ?? 0) - 1
        counts[id] = next > 0 ? next : nil
    }
}

/// The namespace and the on-screen sources of one navigation stack level.
/// Equal while both stay the same, so handing it down again on every render
/// of the screen does not invalidate the tree below it.
public struct LooprMetricZoom: Equatable {
    public let namespace: Namespace.ID
    public let sources: LooprMetricZoomSources

    public init(namespace: Namespace.ID, sources: LooprMetricZoomSources) {
        self.namespace = namespace
        self.sources = sources
    }

    public static func == (lhs: LooprMetricZoom, rhs: LooprMetricZoom) -> Bool {
        lhs.namespace == rhs.namespace && lhs.sources === rhs.sources
    }
}

public extension EnvironmentValues {
    @Entry var looprMetricZoom: LooprMetricZoom? = nil
}

public extension View {
    /// Marks this view as the card the metric page `id` zooms out of. The
    /// corner radius shapes the card while it grows; nil uses the card radius
    /// of the current appearance. Without a zoom in the environment this does
    /// nothing.
    func looprMetricZoomSource(_ id: String, cornerRadius: CGFloat? = nil) -> some View {
        modifier(LooprMetricZoomSource(id: id, cornerRadius: cornerRadius))
    }
}

private struct LooprMetricZoomSource: ViewModifier {
    @Environment(\.looprMetricZoom) private var zoom
    @Environment(\.colorScheme) private var colorScheme
    let id: String
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        if let zoom {
            content
                .matchedTransitionSource(id: id, in: zoom.namespace) { source in
                    source.clipShape(RoundedRectangle(
                        cornerRadius: cornerRadius ?? LooprRadius.surface(isDark: LooprAppearance.isDark(colorScheme)),
                        style: .continuous
                    ))
                }
                .onAppear { zoom.sources.appeared(id) }
                .onDisappear { zoom.sources.disappeared(id) }
        } else {
            content
        }
    }
}
