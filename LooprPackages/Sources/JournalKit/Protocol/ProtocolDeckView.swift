import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The check-in as a deck: one question per card, swipe right for yes and left for no, with buttons for the same
/// answers and a quieter "Skip today" under them (ICP R1-HAB-01). The card says who checks the rule, when, and why it is
/// on the list. It rests straight and tilts in 3D only while it is dragged, up to 6 degrees, and holds still under
/// Reduce Motion (ICP R1-DES-14). The swipe hint shows only to a person who has never answered a card (R3-HAB-01).
struct ProtocolDeckView: View {
    static let flightSource = "protocol-deck-card"
    /// How far a card travels before a release counts as an answer.
    static let commitDistance: CGFloat = 110
    static let maximumTilt: Double = 6
    /// The front card's smallest height. The cards behind peek out below it.
    static let cardHeight: CGFloat = 216

    let questions: [ProtocolDeckQuestion]
    /// The quiet line while nothing is due: "Nothing yet. Next: Magnesium at 21:30."
    let waitingText: String
    let lastAnswer: ProtocolDeckAnswer?
    let isSaving: Bool
    /// Shows "Swipe right for yes, left for no." on the card.
    var showsSwipeHint = true
    let onAnswer: (ProtocolDeckQuestion, ProtocolDeckChoice) -> Void
    let onUndo: () -> Void
    /// False leaves out the waiting line, so the view shows only Undo, as under the closing card.
    var showsEmpty = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var drag: CGFloat = 0
    @State private var leaving: CGFloat?

    /// The 3D tilt for a drag of `distance` points: 6 degrees at the commit distance, never more.
    static func tilt(for distance: CGFloat) -> Double {
        let value = Double(distance / commitDistance) * maximumTilt
        return min(max(value, -maximumTilt), maximumTilt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            if let top = questions.first {
                ZStack(alignment: .top) {
                    if questions.count > 2 { backCard(depth: 2) }
                    if questions.count > 1 { backCard(depth: 1) }
                    card(top)
                        .id(top.id)
                        .transition(reduces ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity), removal: .opacity))
                }
                .padding(.bottom, questions.count > 1 ? LooprSpacing.xl : 0)
                .animation(reduces ? .easeOut(duration: LooprMotion.fast) : .spring(response: 0.42, dampingFraction: 0.78),
                           value: top.id)
            } else if showsEmpty {
                empty
            }
            if let lastAnswer { undo(lastAnswer) }
        }
        // On the stack that always shows, so a card that comes back after the deck was empty, such as one brought up with
        // Answer now, starts in place and not where the last card flew off to (ICP R3-NEW-08).
        .onChange(of: questions.first?.id) { _, _ in reset() }
        .onChange(of: isSaving) { _, saving in if !saving { reset() } }
    }

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = 0; leaving = nil }
    }

    // MARK: Cards

    private func backCard(depth: Int) -> some View {
        RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous)
            .fill(Color.clear)
            .looprCardBackground(.standard)
            .frame(height: 120)
            .scaleEffect(depth == 1 ? 0.94 : 0.88, anchor: .top)
            .offset(y: CGFloat(depth) * 12 + 96)
            .opacity(depth == 1 ? 0.7 : 0.45)
            .accessibilityHidden(true)
    }

    private func card(_ question: ProtocolDeckQuestion) -> some View {
        let offset = leaving ?? drag
        let tilt = reduces ? 0 : Self.tilt(for: offset)
        return LooprSurface(emphasis: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(question.eyebrow, style: .caption, color: .protocolChip)
                        .accessibilityIdentifier("protocol-deck-eyebrow")
                    Text(question.question)
                        .looprTypography(.titleLarge)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    if let why = question.why {
                        // Shown whole: the line is already short and never ends mid-word (ICP R2-DES-02).
                        LooprText(why, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-deck-why")
                    }
                    if showsSwipeHint {
                        LooprText(ProtocolDeckQueue.swipeHint, style: .caption, color: .inkSecondary)
                            .accessibilityIdentifier("protocol-deck-hint")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Double tap Yes or No, or use the actions.")
                .accessibilityActions {
                    Button("Yes") { onAnswer(question, .yes) }
                    Button("No") { onAnswer(question, .no) }
                    Button(Self.skipTitle) { onAnswer(question, .skip) }
                    if lastAnswer != nil { Button("Undo") { onUndo() } }
                }
                Spacer(minLength: LooprSpacing.sm)
                buttons(question)
            }
            .frame(maxWidth: .infinity, minHeight: Self.cardHeight - 2 * LooprSpacing.cardVertical, alignment: .topLeading)
        }
        // The card fill is a few percent of light in dark mode, so it lifts off the colour field. Stacked on the cards
        // behind it that would let them show through, so the front card sits on a solid page-colour base: it looks the
        // same over the page and stays opaque over the deck.
        .background(Color.loopr(.background), in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
        .rotationEffect(.degrees(reduces ? 0 : tilt * 0.5))
        .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .offset(x: reduces ? 0 : offset)
        .opacity(leaving == nil ? 1 : 0.4)
        .modifier(ProtocolDeckSource())
        .modifier(ProtocolDeckSwipe(enabled: !isSaving, onChange: { drag = $0 }, onEnd: { distance in
            if abs(distance) >= Self.commitDistance {
                commit(question, choice: distance > 0 ? .yes : .no)
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = 0 }
            }
        }))
        .disabled(isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(question.accessibilityIdentifier)
    }

    static let skipTitle = "Skip today"

    private func buttons(_ question: ProtocolDeckQuestion) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LooprSpacing.xs)) : AnyLayout(HStackLayout(spacing: LooprSpacing.xs))
        return VStack(spacing: LooprSpacing.xxs) {
            layout { yesNo(question) }
            Button { commit(question, choice: .skip) } label: {
                LooprText(Self.skipTitle, style: .label, color: .inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("It counts neither for nor against your week.")
            .accessibilityIdentifier("protocol-deck-skip")
        }
    }

    @ViewBuilder
    private func yesNo(_ question: ProtocolDeckQuestion) -> some View {
        Button { commit(question, choice: .no) } label: {
            LooprText("No", style: .button)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                .background(Color.loopr(.divider), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("protocol-deck-no")
        Button { commit(question, choice: .yes) } label: {
            Text("Yes")
                .looprTypography(.button)
                .foregroundStyle(Color.loopr(.background))
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                .background(Color.loopr(.protocol), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("protocol-deck-yes")
    }

    private func commit(_ question: ProtocolDeckQuestion, choice: ProtocolDeckChoice) {
        guard !isSaving else { return }
        if !reduces {
            withAnimation(.easeOut(duration: 0.22)) {
                switch choice {
                case .yes: leaving = 420
                case .no: leaving = -420
                case .skip: leaving = 0
                }
            }
        }
        onAnswer(question, choice)
    }

    // MARK: Empty and undo

    /// One quiet line, not a white card that reads as an empty state (ICP R2-DES-05).
    private var empty: some View {
        ProtocolQuietLine(text: waitingText, symbol: "clock", identifier: "protocol-deck-empty", style: .prose)
            .frame(minHeight: 44, alignment: .leading)
    }

    private func undo(_ answer: ProtocolDeckAnswer) -> some View {
        Button(action: onUndo) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: "arrow.uturn.backward")
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.protocolChip))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText("Undo", style: .rowTitle, color: .protocolChip)
                    LooprText("\(answer.summary) \(answer.question.question)", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .disabled(isSaving)
        .accessibilityLabel("Undo. \(answer.summary) \(answer.question.question)")
        .accessibilityIdentifier("protocol-deck-undo")
    }
}

/// The deck's top card is where answer dots take off.
private struct ProtocolDeckSource: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.looprDotFlightSource(ProtocolDeckView.flightSource)
        #else
        content
        #endif
    }
}

/// The card's sideways swipe. Only a drag that starts sideways moves the card; a drag that starts up or down is the
/// page's, so the page scrolls even when the finger lands on the card (ICP R2-UPG-7). A SwiftUI drag gesture on a scroll
/// view's content claims every direction, so on iOS this is a UIKit pan that declines to begin on a vertical movement.
struct ProtocolDeckSwipe: ViewModifier {
    let enabled: Bool
    let onChange: @MainActor (CGFloat) -> Void
    let onEnd: @MainActor (CGFloat) -> Void

    /// True when a drag's first movement is sideways enough to be a card swipe.
    static func isSideways(_ movement: CGPoint) -> Bool {
        abs(movement.x) > abs(movement.y) * 1.2
    }

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.gesture(ProtocolDeckSwipeRecognizer(enabled: enabled, onChange: onChange, onEnd: onEnd))
        #else
        content.gesture(DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard Self.isSideways(CGPoint(x: value.translation.width, y: value.translation.height)) else { return }
                onChange(value.translation.width)
            }
            .onEnded { value in onEnd(value.translation.width) }, including: enabled ? .all : .none)
        #endif
    }
}

#if canImport(UIKit)
/// The UIKit pan behind `ProtocolDeckSwipe`: it starts only on a sideways movement, so a vertical drag reaches the page.
struct ProtocolDeckSwipeRecognizer: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onChange: @MainActor (CGFloat) -> Void
    let onEnd: @MainActor (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let distance = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChange(distance)
        case .ended: onEnd(distance)
        case .cancelled, .failed: onEnd(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return ProtocolDeckSwipe.isSideways(pan.velocity(in: pan.view))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
