import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A 3D tilt: an angle about an axis in the view's plane.
public struct LooprTilt: Equatable, Sendable {
    public var degrees: Double
    public var axis: (x: CGFloat, y: CGFloat)

    public init(degrees: Double, axis: (x: CGFloat, y: CGFloat)) {
        self.degrees = degrees
        self.axis = axis
    }

    public static let flat = LooprTilt(degrees: 0, axis: (1, 0))

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.degrees == rhs.degrees && lhs.axis.x == rhs.axis.x && lhs.axis.y == rhs.axis.y
    }
}

/// The arithmetic behind the press tilt, kept apart from the view so it can be tested.
public enum LooprPressTiltMath {
    /// The tilt for a finger at `location` in a view of `size`: the pressed point sinks away from the
    /// viewer, by up to `maxDegrees` at the edges and nothing at the centre.
    public static func tilt(at location: CGPoint, in size: CGSize, maxDegrees: Double) -> LooprTilt {
        guard size.width > 0, size.height > 0, location.x.isFinite, location.y.isFinite else { return .flat }
        let dx = min(max((location.x - size.width / 2) / (size.width / 2), -1), 1)
        let dy = min(max((location.y - size.height / 2) / (size.height / 2), -1), 1)
        let reach = min(hypot(dx, dy), 1)
        guard reach > 0.001 else { return .flat }
        return LooprTilt(degrees: max(maxDegrees, 0) * Double(reach), axis: (x: -dy / reach, y: dx / reach))
    }
}

public extension View {
    /// Press and hold tilts the view towards the finger in 3D, up to `maxDegrees`, and it springs back
    /// on release (DESIGN_LANGUAGE premium check 5). `resting` is the tilt it holds when nobody
    /// touches it, as the food sticker leans 4°. Under Reduce Motion it stays flat. The press is a
    /// UIKit long press that recognises alongside other gestures, so it never blocks a tap, a button
    /// or a scroll view.
    func looprPressTilt(maxDegrees: Double = 4, resting: LooprTilt? = nil, isEnabled: Bool = true) -> some View {
        modifier(LooprPressTiltModifier(maxDegrees: maxDegrees, resting: resting, isEnabled: isEnabled))
    }
}

struct LooprPressTiltModifier: ViewModifier {
    /// How long a finger rests before the tilt starts: a tap ends before it.
    static let holdDuration: Double = 0.18

    let maxDegrees: Double
    let resting: LooprTilt?
    let isEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero
    @State private var pressed: LooprTilt?

    /// The tilt drawn now.
    static func tilt(pressed: LooprTilt?, resting: LooprTilt?, reducesMotion: Bool) -> LooprTilt {
        guard !reducesMotion else { return .flat }
        return pressed ?? resting ?? .flat
    }

    func body(content: Content) -> some View {
        let reduces = LooprMotion.reducesMotion(reduceMotion)
        let tilt = Self.tilt(pressed: isEnabled ? pressed : nil, resting: resting, reducesMotion: reduces)
        // The gesture stays attached when the tilt is off, so turning it on or off never rebuilds the view.
        content
            .rotation3DEffect(.degrees(tilt.degrees), axis: (x: tilt.axis.x, y: tilt.axis.y, z: 0))
            .animation(.spring(response: 0.35, dampingFraction: 0.62), value: pressed)
            #if canImport(UIKit)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(LooprPressTiltRecognizer(holdDuration: Self.holdDuration) { location in
                guard let location, isEnabled, !LooprMotion.reducesMotion(reduceMotion) else {
                    pressed = nil
                    return
                }
                pressed = LooprPressTiltMath.tilt(at: location, in: size, maxDegrees: maxDegrees)
            })
            #endif
    }
}

#if canImport(UIKit)
/// A long press that never takes the touch from anyone else: it recognises alongside every other
/// gesture and does not cancel touches, so taps, buttons and scrolling carry on.
private struct LooprPressTiltRecognizer: UIGestureRecognizerRepresentable {
    let holdDuration: Double
    let onChange: @MainActor (CGPoint?) -> Void

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = holdDuration
        recognizer.allowableMovement = LooprScrub.allowableMovement
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChange(context.converter.localLocation)
        case .ended, .cancelled, .failed:
            onChange(nil)
        default:
            break
        }
    }
}
#endif
