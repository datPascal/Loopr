import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Steps the four day tabs through days.
///
/// Two layouts share one behaviour:
/// - `.compact` sits in a `StickyHeader`'s trailing accessory. The header's
///   own title or meta names the day, so this is only the previous and next
///   buttons plus a "Today" pill when another day is showing.
/// - `.bar` is a full-width row that names the day itself, for a screen that
///   wants the navigator under its header instead.
///
/// Both are bounded by the earliest recorded day and today, play a selection
/// haptic on every change, and read to VoiceOver as one adjustable element:
/// swipe up for the next day, down for the previous one.
public struct LooprDayNavigator: View {
    public enum Style: Equatable {
        case compact
        /// `title` and `subtitle` default to the navigation's own title and
        /// date, so the Sleep tab can pass its night instead.
        case bar(title: String? = nil, subtitle: String? = nil)
    }

    @Environment(\.colorScheme) private var colorScheme
    private let navigation: LooprDayNavigation
    private let style: Style
    private let accent: LooprColorToken

    public init(_ navigation: LooprDayNavigation, style: Style = .compact, accent: LooprColorToken = .brand) {
        self.navigation = navigation
        self.style = style
        self.accent = accent
    }

    public var body: some View {
        Group {
            switch style {
            case .compact:
                compact
            case .bar(let title, let subtitle):
                bar(title: title ?? navigation.title, subtitle: subtitle ?? barSubtitle)
            }
        }
        .sensoryFeedback(.selection, trigger: navigation.day)
    }

    // MARK: Layouts

    private var compact: some View {
        HStack(spacing: 6) {
            if !navigation.isToday {
                todayPill
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            HStack(spacing: 0) {
                stepButton(.back)
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)
                stepButton(.forward)
            }
            .background(controlFill, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .modifier(AdjustableDay(navigation: navigation))
        }
        .animation(.easeOut(duration: LooprMotion.fast), value: navigation.isToday)
    }

    private func bar(title: String, subtitle: String?) -> some View {
        HStack(spacing: LooprSpacing.xs) {
            stepButton(.back)
            VStack(spacing: 2) {
                Text(title)
                    .looprTypography(.cardTitle)
                    .foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let subtitle {
                    Text(subtitle.uppercased())
                        .looprTypography(.headerMeta)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(AdjustableDay(navigation: navigation))
            stepButton(.forward)
            if !navigation.isToday {
                todayPill
            }
        }
        .animation(.easeOut(duration: LooprMotion.fast), value: navigation.isToday)
    }

    private var barSubtitle: String? {
        navigation.isToday || navigation.title != navigation.dateText ? navigation.dateText : nil
    }

    // MARK: Parts

    private enum Direction { case back, forward }

    private func stepButton(_ direction: Direction) -> some View {
        let enabled = direction == .back ? navigation.canGoBack : navigation.canGoForward
        return Button {
            direction == .back ? navigation.goBack() : navigation.goForward()
        } label: {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.loopr(enabled ? .ink : .inkMuted))
                .frame(width: 34, height: 32)
                // The visible control is compact; the touch target is not.
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(direction == .back ? "Previous day" : "Next day")
        .accessibilityIdentifier(direction == .back ? "day-navigator-previous" : "day-navigator-next")
    }

    private var todayPill: some View {
        Button {
            navigation.goToToday()
        } label: {
            Text("Today")
                .looprTypography(.label)
                .foregroundStyle(Color.loopr(accent))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.loopr(accent).opacity(isDark ? 0.16 : 0.12), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.loopr(accent).opacity(isDark ? 0.34 : 0.28), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule().inset(by: -5))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Go to today")
        .accessibilityIdentifier("day-navigator-today")
    }

    private var controlFill: Color {
        Color.loopr(isDark ? .surfaceElevated : .sheetFill)
    }

    private var isDark: Bool {
        switch DesignSystemRuntime.state().appearance {
        case .system: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
}

/// One adjustable element for VoiceOver: the value is the day, swiping up
/// moves to the next day and down to the previous one.
private struct AdjustableDay: ViewModifier {
    let navigation: LooprDayNavigation

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Day")
            .accessibilityValue(navigation.spokenTitle)
            .accessibilityHint(hint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: navigation.goForward()
                case .decrement: navigation.goBack()
                @unknown default: break
                }
            }
            .accessibilityIdentifier("day-navigator")
    }

    private var hint: String {
        switch (navigation.canGoBack, navigation.canGoForward) {
        case (true, true): "Swipe up or down to change the day."
        case (true, false): "Swipe down for the previous day."
        case (false, true): "Swipe up for the next day."
        case (false, false): "No other days recorded yet."
        }
    }
}

// MARK: Swipe between days

/// A horizontal flick on a tab's content changes the day: right for the
/// previous day, left for the next.
///
/// It never fights the page, a row or a chart:
/// - it only starts when the finger's first movement is clearly sideways,
///   so a vertical scroll never becomes a day change;
/// - it recognises beside the scroll view rather than in place of it;
/// - while it runs the content is disabled, so a sideways flick that starts
///   on a row does not also open that row;
/// - it never starts after a hold, because that is how a chart scrub begins.
public struct LooprDaySwipe: ViewModifier {
    /// A flick has to travel this far sideways, or be thrown this far.
    public static let minimumDistance: CGFloat = 64
    public static let minimumThrow: CGFloat = 150
    /// Sideways travel must beat vertical travel by this factor.
    public static let horizontalDominance: CGFloat = 1.8
    /// Longer than this is a scrub or a slow drag, not a flick.
    public static let maximumDuration: TimeInterval = 0.6
    /// A finger that rests this long before moving is starting a scrub.
    public static let holdThreshold: TimeInterval = 0.25

    private let navigation: LooprDayNavigation?
    /// True from the moment a flick is recognised until just after the
    /// finger lifts. The content is disabled meanwhile, so the row or button
    /// the flick started on does not open as well.
    @State private var isSwiping = false

    public init(_ navigation: LooprDayNavigation?) {
        self.navigation = navigation
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let navigation {
            #if canImport(UIKit)
            content
                // Disabled, not just untouchable: a row's button that already
                // saw the finger go down checks this when the finger lifts.
                .disabled(isSwiping)
                .gesture(LooprDaySwipeRecognizer(
                    onSwiping: { swiping in
                        if swiping {
                            isSwiping = true
                        } else {
                            // Re-enable after the lift has been handled.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(150))
                                isSwiping = false
                            }
                        }
                    },
                    onStep: { step in
                        withAnimation(.easeOut(duration: LooprMotion.fast)) { navigation.step(by: step) }
                    }
                ))
            #else
            content
            #endif
        } else {
            content
        }
    }

    /// The day step a finished drag asks for, or nil. -1 is the previous day.
    public static func step(translation: CGSize, predictedEnd: CGSize, duration: TimeInterval) -> Int? {
        guard duration <= maximumDuration else { return nil }
        let horizontal = abs(translation.width)
        guard horizontal >= abs(translation.height) * horizontalDominance else { return nil }
        guard horizontal >= minimumDistance || abs(predictedEnd.width) >= minimumThrow else { return nil }
        return translation.width > 0 ? -1 : 1
    }

    /// Whether a drag may start at all: its first movement is sideways and it
    /// did not begin with a hold.
    public static func mayBegin(velocity: CGPoint, heldFor: TimeInterval) -> Bool {
        heldFor < holdThreshold && abs(velocity.x) > abs(velocity.y) * horizontalDominance
    }
}

#if canImport(UIKit)
/// The UIKit pan behind `LooprDaySwipe`. A SwiftUI drag gesture on a scroll
/// view's content blocks its scrolling; this pan declines to start on a
/// vertical movement, so the page never notices it.
struct LooprDaySwipeRecognizer: UIGestureRecognizerRepresentable {
    let onSwiping: @MainActor (Bool) -> Void
    let onStep: @MainActor (Int) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: onSwiping(true)
        case .ended, .cancelled, .failed: onSwiping(false)
        default: break
        }
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        let duration = ProcessInfo.processInfo.systemUptime - context.coordinator.touchDownAt
        // Where the flick would come to rest, a fifth of a second on.
        let predicted = CGSize(width: translation.x + velocity.x * 0.2, height: translation.y + velocity.y * 0.2)
        guard let step = LooprDaySwipe.step(translation: CGSize(width: translation.x, height: translation.y),
                                            predictedEnd: predicted, duration: duration) else { return }
        onStep(step)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var touchDownAt: TimeInterval = 0

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A zoomed chart owns its horizontal drags. Starting the day
            // gesture would disable that chart before its pan completes.
            guard !Self.startsInHorizontalScrollView(touch.view) else { return false }
            touchDownAt = touch.timestamp
            return true
        }

        static func startsInHorizontalScrollView(_ view: UIView?) -> Bool {
            var ancestor = view
            while let current = ancestor {
                if let scroll = current as? UIScrollView,
                   scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 {
                    return true
                }
                ancestor = current.superview
            }
            return false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return LooprDaySwipe.mayBegin(velocity: pan.velocity(in: pan.view),
                                          heldFor: ProcessInfo.processInfo.systemUptime - touchDownAt)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

public extension View {
    /// Lets a horizontal flick on this content change the shared day.
    func looprDaySwipe(_ navigation: LooprDayNavigation?) -> some View {
        modifier(LooprDaySwipe(navigation))
    }
}

// MARK: Empty day

/// What a day tab shows when the selected day has nothing to show.
///
/// It says which day, why it is empty, and what to do next, in one quiet
/// card instead of a list of blank rows.
public struct LooprDayEmptyState: View {
    private let navigation: LooprDayNavigation
    private let accent: LooprColorToken
    private let now: Date

    public init(_ navigation: LooprDayNavigation, accent: LooprColorToken = .brand, now: Date? = nil) {
        self.navigation = navigation
        self.accent = accent
        self.now = now ?? navigation.now ?? Date()
    }

    public var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                Image(systemName: navigation.isToday ? "clock.arrow.circlepath" : "calendar")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.loopr(accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(Self.title(for: navigation), style: .rowTitle)
                    LooprText(Self.detail(for: navigation, now: now), style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if let latest = Self.suggestedDay(for: navigation) {
                    Button {
                        withAnimation(.easeOut(duration: LooprMotion.fast)) { navigation.select(latest) }
                    } label: {
                        Text("Show \(LooprDayLabel.title(for: latest, today: navigation.today, calendar: navigation.calendar).lowercasedFirstWordIfRelative)")
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                    .accessibilityIdentifier("day-empty-show-latest")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("day-empty-state")
    }

    /// "Nothing for today yet" or "Nothing recorded on Mon 21 Sep".
    public static func title(for navigation: LooprDayNavigation) -> String {
        if navigation.isToday { return "Nothing for today yet" }
        return "Nothing recorded \(navigation.title == "Yesterday" ? "yesterday" : "on \(navigation.dateText)")"
    }

    public static func detail(for navigation: LooprDayNavigation, now: Date) -> String {
        guard navigation.isToday else {
            return "Loopr has no band data for this day."
        }
        guard navigation.lastSyncedAt != nil else {
            return "Wear your band and keep it near your iPhone. Today's numbers appear after it syncs."
        }
        let sync = LooprSyncAge.label(lastSync: navigation.lastSyncedAt, now: now) ?? ""
        return "Today's numbers appear after your band syncs. \(sync)."
    }

    /// On an empty today, the newest day with data. A past day offers
    /// nothing: the chevrons and the Today pill already go both ways.
    public static func suggestedDay(for navigation: LooprDayNavigation) -> LooprDay? {
        guard navigation.isToday, let latest = navigation.latestDayWithData, latest != navigation.day else { return nil }
        return latest
    }
}

private extension String {
    /// "Show yesterday", "Show today", but "Show Tue 22 Sep".
    var lowercasedFirstWordIfRelative: String {
        self == "Today" || self == "Yesterday" ? lowercased() : self
    }
}
