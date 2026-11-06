#if canImport(UIKit)
import Observation
import SwiftUI
import UIKit

/// The shape dots take on a registered target.
public enum LooprDotTargetShape: Equatable, Sendable {
    /// A ring inscribed in the target, from `from` to `to` of a turn. `inset` moves the landing line in
    /// from the edge, to the middle of the ring's stroke.
    case ring(from: Double = 0, to: Double = 1, inset: CGFloat = 0)
    /// A line across the target's middle, leading edge to trailing edge.
    case line
    /// The target's centre.
    case point
    /// The target as a grid cell that the dots fill.
    case slot

    /// The landing target inside `frame`.
    public func target(in frame: CGRect) -> LooprDotTarget {
        switch self {
        case let .ring(from, to, inset):
            .ring(center: CGPoint(x: frame.midX, y: frame.midY), radius: max(min(frame.width, frame.height) / 2 - inset, 0),
                  from: from, to: to)
        case .line:
            .line(from: CGPoint(x: frame.minX, y: frame.midY), to: CGPoint(x: frame.maxX, y: frame.midY))
        case .point:
            .point(CGPoint(x: frame.midX, y: frame.midY))
        case .slot:
            .slot(frame)
        }
    }
}

/// Lets a source in one view fly dots to a target in another view on the same screen. A screen
/// installs it with `looprDotFlightHost()`; views mark themselves with `looprDotFlightSource(_:)` and
/// `looprDotFlightTarget(_:)` and read it from `\.looprDotFlight`.
///
/// ```swift
/// @Environment(\.looprDotFlight) private var flight
/// ...
/// flight?.fly(from: "log-button", to: "day-ring", colors: colors, onLanding: { rank, _ in landed = rank + 1 })
/// ```
@MainActor @Observable
public final class LooprDotFlightCoordinator {
    /// One flight waiting for, or being played by, the overlay.
    struct Playback {
        let request: LooprDotFlightRequest
        let onLanding: LooprDotFlightView.Landing?
        let completion: (() -> Void)?
    }

    @ObservationIgnored public private(set) var sources: [String: CGRect] = [:]
    @ObservationIgnored public private(set) var targets: [String: CGRect] = [:]
    private(set) var playback: Playback?
    /// Reduce Motion, as the host last saw it.
    @ObservationIgnored var reduceMotion = false

    public init() {}

    public func registerSource(_ id: String, frame: CGRect) { sources[id] = frame }
    public func registerTarget(_ id: String, frame: CGRect) { targets[id] = frame }

    /// Replaces every frame with the ones the host resolved from the anchors on screen.
    func update(_ frames: [LooprDotFlightAnchorKey.ID: CGRect]) {
        var sources: [String: CGRect] = [:], targets: [String: CGRect] = [:]
        for (id, frame) in frames {
            switch id.role {
            case .source: sources[id.name] = frame
            case .target: targets[id.name] = frame
            }
        }
        self.sources = sources
        self.targets = targets
    }

    /// Flies one dot per colour from `source` to `target`. Each dot lands in `landingColor`, or keeps
    /// its own colour when that is nil. Returns false, and plays nothing, when either is not on screen.
    @discardableResult
    public func fly(from source: String, to target: String, shape: LooprDotTargetShape = .ring(),
                    colors: [UIColor], landingColor: UIColor? = nil, timing: LooprDotFlightTiming = .standard,
                    haptics: LooprDotFlightHaptics = .standard, onLanding: LooprDotFlightView.Landing? = nil,
                    completion: (() -> Void)? = nil) -> Bool {
        guard let from = sources[source], let to = targets[target], !colors.isEmpty else { return false }
        var random = SystemRandomNumberGenerator()
        let request = LooprDotFlight.request(from: from, to: shape.target(in: to), colors: colors, landingColor: landingColor,
                                             timing: timing, haptics: haptics, using: &random)
        play(request, onLanding: onLanding, completion: completion)
        return true
    }

    /// Plays a request the caller planned itself.
    public func play(_ request: LooprDotFlightRequest, onLanding: LooprDotFlightView.Landing? = nil,
                     completion: (() -> Void)? = nil) {
        playback = Playback(request: request, onLanding: onLanding, completion: completion)
    }

    func finished(_ id: UUID) {
        if playback?.request.id == id { playback = nil }
    }
}

public extension EnvironmentValues {
    /// The screen's dot flight, when it installed one with `looprDotFlightHost()`.
    @Entry var looprDotFlight: LooprDotFlightCoordinator? = nil
}

/// The source and target frames on screen, keyed by role and name.
public struct LooprDotFlightAnchorKey: PreferenceKey {
    public struct ID: Hashable, Sendable {
        public enum Role: Hashable, Sendable { case source, target }
        public let role: Role
        public let name: String
    }

    public static var defaultValue: [ID: Anchor<CGRect>] { [:] }

    public static func reduce(value: inout [ID: Anchor<CGRect>], nextValue: () -> [ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}

public extension View {
    /// Installs a dot flight over this view: the coordinator in the environment and the overlay the
    /// dots fly in. Apply it once per screen, outside every source and target.
    func looprDotFlightHost() -> some View {
        modifier(LooprDotFlightHostModifier())
    }

    /// Marks this view as a place dots fly from.
    func looprDotFlightSource(_ id: String) -> some View {
        transformAnchorPreference(key: LooprDotFlightAnchorKey.self, value: .bounds) { value, anchor in
            value[.init(role: .source, name: id)] = anchor
        }
    }

    /// Marks this view as a place dots land.
    func looprDotFlightTarget(_ id: String) -> some View {
        transformAnchorPreference(key: LooprDotFlightAnchorKey.self, value: .bounds) { value, anchor in
            value[.init(role: .target, name: id)] = anchor
        }
    }
}

struct LooprDotFlightHostModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coordinator = LooprDotFlightCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(\.looprDotFlight, coordinator)
            .overlayPreferenceValue(LooprDotFlightAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    LooprDotFlightOverlay(coordinator: coordinator, reduceMotion: LooprMotion.reducesMotion(reduceMotion))
                        .onChange(of: Self.frames(anchors, in: proxy), initial: true) { _, frames in
                            coordinator.update(frames)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    static func frames(_ anchors: [LooprDotFlightAnchorKey.ID: Anchor<CGRect>], in proxy: GeometryProxy)
        -> [LooprDotFlightAnchorKey.ID: CGRect] {
        anchors.mapValues { proxy[$0] }
    }
}

/// The view the coordinator's flights play in. Its coordinates are the host's.
struct LooprDotFlightOverlay: UIViewRepresentable {
    let coordinator: LooprDotFlightCoordinator
    let reduceMotion: Bool

    func makeUIView(context: Context) -> LooprDotFlightView { LooprDotFlightView() }

    func updateUIView(_ view: LooprDotFlightView, context: Context) {
        guard let playback = coordinator.playback, view.queuedID != playback.request.id else { return }
        let id = playback.request.id
        let coordinator = coordinator
        // Queued to the next turn of the run loop: landings and completion change state, which a view
        // update must not do.
        view.queue(playback.request, reduceMotion: reduceMotion, onLanding: playback.onLanding) {
            playback.completion?()
            coordinator.finished(id)
        }
    }
}
#endif
