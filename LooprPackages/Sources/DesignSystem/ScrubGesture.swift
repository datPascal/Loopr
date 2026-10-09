import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Timing and tolerances shared by every scrubbable chart.
public enum LooprScrub {
    /// How long a finger rests before scrubbing starts (tabs spec, principle 7).
    /// Shorter and a page scroll that starts on a chart would scrub instead.
    public static let holdDuration: Double = 0.25
    /// How far the finger may drift during the hold, in points. Moving further
    /// first means the person is scrolling, so the chart lets go.
    public static let allowableMovement: CGFloat = 10
}

/// The pure arithmetic behind scrubbing, kept apart from the views so it can
/// be tested. Every function clamps, so a finger dragged past either edge
/// reads the first or last item rather than nothing.
public enum LooprScrubMath {
    /// Position of `x` across `width`, from 0 at the leading edge to 1 at the
    /// trailing edge.
    public static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// The slot under `x` when `count` equal slots share `width`, as bars do.
    /// Nil when there are no slots.
    public static func index(x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        let slot = Int((fraction(x: x, width: width) * Double(count)).rounded(.down))
        return min(max(slot, 0), count - 1)
    }

    /// The centre of slot `index` when `count` equal slots share `width`.
    public static func center(of index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return width / 2 }
        let slot = width / CGFloat(count)
        return slot * (CGFloat(min(max(index, 0), count - 1)) + 0.5)
    }

    /// The moment under `x` on a time axis running from `start` to `end`.
    public static func date(x: CGFloat, width: CGFloat, start: Date, end: Date) -> Date {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return start }
        return start.addingTimeInterval(span * fraction(x: x, width: width))
    }

    /// Where `date` falls on a time axis `width` wide, clamped to the axis.
    public static func x(for date: Date, width: CGFloat, start: Date, end: Date) -> CGFloat {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        let share = min(max(date.timeIntervalSince(start) / span, 0), 1)
        return width * CGFloat(share)
    }

    /// The centre for a readout label `labelWidth` wide that follows `x` but
    /// never leaves a container `containerWidth` wide.
    public static func readoutCenter(x: CGFloat, labelWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let half = labelWidth / 2
        guard containerWidth > labelWidth else { return containerWidth / 2 }
        return min(max(x, half), containerWidth - half)
    }
}

public extension View {
    /// Hold-then-drag scrubbing for a chart.
    ///
    /// Scrubbing starts after the finger rests for `LooprScrub.holdDuration`
    /// (0.25 s) without moving more than 10 pt, so a vertical page scroll that
    /// starts on the chart still scrolls. Once it starts, the page stays put
    /// while the finger moves. One selection haptic plays when it engages.
    ///
    /// `onChange` receives the finger's x position in this view's own
    /// coordinates on every move, and nil when the finger lifts or the
    /// gesture is cancelled. Convert x to a data index with `LooprScrubMath`.
    ///
    /// ```swift
    /// Canvas { ... }
    ///     .looprScrub { x in
    ///         selected = x.flatMap { LooprScrubMath.index(x: $0, width: width, count: bars.count) }
    ///     }
    /// ```
    func looprScrub(
        holdDuration: Double = LooprScrub.holdDuration,
        onChange: @escaping @MainActor (CGFloat?) -> Void
    ) -> some View {
        modifier(LooprScrubGesture(holdDuration: holdDuration, onChange: onChange))
    }

    /// The same gesture writing into a binding: the x position while
    /// scrubbing, nil otherwise.
    func looprScrub(_ x: Binding<CGFloat?>, holdDuration: Double = LooprScrub.holdDuration) -> some View {
        looprScrub(holdDuration: holdDuration) { x.wrappedValue = $0 }
    }
}

/// The hold-then-drag scrub as a view modifier. Most callers use
/// `.looprScrub { x in ... }`, which applies this.
public struct LooprScrubGesture: ViewModifier {
    let holdDuration: Double
    let onChange: @MainActor (CGFloat?) -> Void
    @State private var engagements = 0
    @State private var isScrubbing = false

    public init(holdDuration: Double = LooprScrub.holdDuration, onChange: @escaping @MainActor (CGFloat?) -> Void) {
        self.holdDuration = holdDuration
        self.onChange = onChange
    }

    public func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .gesture(LooprScrubRecognizer(holdDuration: holdDuration) { x in
                if let x {
                    if !isScrubbing {
                        isScrubbing = true
                        engagements += 1
                    }
                    onChange(x)
                } else {
                    isScrubbing = false
                    onChange(nil)
                }
            })
            .sensoryFeedback(.selection, trigger: engagements)
        #else
        content
        #endif
    }
}

#if canImport(UIKit)
/// A UIKit long press, because it hands over to `UIScrollView` correctly: it
/// fails as soon as the finger travels during the hold (so the page
/// scrolls), and once recognised it blocks the scroll view's pan (so the page
/// holds still while the finger scrubs). A SwiftUI long press sequenced before
/// a drag does not reliably do either inside a `ScrollView`.
private struct LooprScrubRecognizer: UIGestureRecognizerRepresentable {
    let holdDuration: Double
    let onChange: @MainActor (CGFloat?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = holdDuration
        recognizer.allowableMovement = LooprScrub.allowableMovement
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = holdDuration
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChange(context.converter.localLocation.x)
        case .ended, .cancelled, .failed:
            onChange(nil)
        default:
            break
        }
    }
}
#endif

/// The vertical rule and value label a scrubbed chart shows under the finger.
///
/// Lay it over the chart (it fills its container) and give it the x position
/// from `looprScrub`. The label sits inside the top edge, follows the finger
/// and never leaves the container; the rule runs from under the label to the
/// bottom. Leave about 34 pt of headroom above the data so the label does
/// not cover it.
///
/// ```swift
/// chart
///     .looprScrub($scrubX)
///     .overlay {
///         if let scrubX {
///             LooprScrubReadout(x: scrubX, title: "Tue 22 Sep", value: "−42 min", accent: .sleep)
///         }
///     }
/// ```
///
/// The readout is hidden from VoiceOver: charts give VoiceOver the same
/// values through their own accessibility label or chart descriptor.
public struct LooprScrubReadout: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var labelSize: CGSize = .zero
    private let x: CGFloat
    private let title: String
    private let value: String?
    private let accent: LooprColorToken
    private let showsRule: Bool

    /// - Parameters:
    ///   - x: The finger's x position in the container's coordinates.
    ///   - title: The small uppercase line, usually the date or time range.
    ///   - value: The reading, or nil for "No reading" over a gap.
    ///   - showsRule: Draw the vertical rule. Turn it off when the chart
    ///     already highlights the selection itself.
    public init(x: CGFloat, title: String, value: String?, accent: LooprColorToken, showsRule: Bool = true) {
        self.x = x
        self.title = title
        self.value = value
        self.accent = accent
        self.showsRule = showsRule
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clampedX = min(max(x, 0), width)
            ZStack(alignment: .topLeading) {
                if showsRule {
                    let top = labelSize.height
                    let ruleHeight = max(proxy.size.height - top, 0)
                    Rectangle()
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.55 : 0.45))
                        .frame(width: 1, height: ruleHeight)
                        .position(x: clampedX, y: top + ruleHeight / 2)
                }
                label
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { labelSize = $0 }
                    .position(
                        x: LooprScrubMath.readoutCenter(x: clampedX, labelWidth: labelSize.width, containerWidth: width),
                        y: labelSize.height / 2
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        VStack(alignment: .center, spacing: 1) {
            Text(title.uppercased())
                .looprTypography(.confidence)
                .foregroundStyle(Color.loopr(.inkSecondary))
            Text(value ?? "No reading")
                .looprTypography(value == nil ? .caption : .metricUnit)
                .fontWeight(value == nil ? .regular : .semibold)
                .foregroundStyle(Color.loopr(value == nil ? .inkSecondary : .ink))
                .monospacedDigit()
        }
        .padding(.horizontal, LooprSpacing.xs)
        .padding(.vertical, LooprSpacing.xxs)
        .background(
            Color.loopr(isDark ? .surfaceElevated : .sheetFill),
            in: RoundedRectangle(cornerRadius: LooprSpacing.xs, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LooprSpacing.xs, style: .continuous)
                .strokeBorder(Color.loopr(accent).opacity(isDark ? 0.35 : 0.25), lineWidth: 1)
        }
        .shadow(color: Color.loopr(.ink).opacity(isDark ? 0 : 0.08), radius: 4, y: 2)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
