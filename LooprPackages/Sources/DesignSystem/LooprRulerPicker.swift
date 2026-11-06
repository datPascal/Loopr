import SwiftUI

/// A horizontal ruler for one number, such as a body weight. Dragging moves the scale under a fixed
/// needle; each step ticks under the finger and each whole unit ticks a little harder, at most 30
/// ticks a second (`LooprDetent`). VoiceOver swipes up and down to change it by one step.
public struct LooprRulerPicker: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let majorEvery: Int
    private let accent: LooprColorToken
    private let label: String
    private let unit: String
    private let labelFormat: LooprValueFormat?
    private let majorsFromZero: Bool
    @State private var position: Int?
    /// True while a finger or a fling moves the scale. Only then does the scale write the value,
    /// so a value typed elsewhere moves the scale without the scale rounding it back.
    @State private var scrolling = false

    private static let spacing: CGFloat = 9

    /// - Parameters:
    ///   - majorEvery: Steps between labelled ticks. With a 0.1 step, 10 labels every whole unit.
    ///   - labelFormat: How the labelled ticks and the spoken value are written, such as `.clock` for seconds
    ///     shown as "1:30". Nil shows whole numbers.
    ///   - majorsFromZero: Counts the labelled ticks from zero instead of from the start of the range, so a
    ///     range that starts at 5 still labels 30, 60 and 90 and not 5, 35 and 65.
    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0.1,
                majorEvery: Int = 10, unit: String, accent: LooprColorToken,
                labelFormat: LooprValueFormat? = nil, majorsFromZero: Bool = false) {
        self.label = label; _value = value; self.range = range; self.step = step
        self.majorEvery = max(majorEvery, 1); self.unit = unit; self.accent = accent
        self.labelFormat = labelFormat; self.majorsFromZero = majorsFromZero
        _position = State(initialValue: LooprDetent(range: range, step: step).index(for: value.wrappedValue))
    }

    /// The ruler's stops: one per tick.
    var detent: LooprDetent { LooprDetent(range: range, step: step) }

    private var count: Int { detent.count }

    /// Added to a tick's index before it is tested against `majorEvery`.
    private var majorOffset: Int {
        guard majorsFromZero, step > 0 else { return 0 }
        let first = Int((range.lowerBound / step).rounded())
        return ((first % majorEvery) + majorEvery) % majorEvery
    }

    private func value(at index: Int) -> Double { detent.value(at: index) }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        tick(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .onScrollPhaseChange { _, phase in
                if phase.isScrolling { scrolling = true; return }
                guard scrolling else { return }
                scrolling = false
                if let position { write(position) }
            }
            .contentMargins(.horizontal, max(0, geometry.size.width / 2 - Self.spacing / 2), for: .scrollContent)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .top) {
                Capsule().fill(Color.loopr(accent))
                    .frame(width: 3, height: 40)
                    .shadow(color: Color.loopr(accent).opacity(0.45), radius: 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 64)
        .looprDetentFeedback(position, isActive: scrolling) { [majorEvery, majorOffset] in ($0 + majorOffset) % majorEvery == 0 }
        .onChange(of: position) { _, index in
            guard let index, scrolling else { return }
            write(index)
        }
        .onChange(of: value) { _, typed in
            let index = detent.index(for: typed)
            if index != position { position = index }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(labelFormat?.spoken(value)
            ?? "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value(at: (position ?? 0) + 1))
            case .decrement: value = max(range.lowerBound, value(at: max(0, (position ?? 0) - 1)))
            @unknown default: break
            }
        }
    }

    private func write(_ index: Int) {
        let next = value(at: index)
        if abs(next - value) > step / 2 { value = next }
    }

    private func tick(_ index: Int) -> some View {
        let major = (index + majorOffset) % majorEvery == 0
        let half = !major && majorEvery % 2 == 0 && (index + majorOffset) % (majorEvery / 2) == 0
        return VStack(spacing: LooprSpacing.xxs) {
            Capsule()
                .fill(Color.loopr(major ? .ink : .inkTertiary).opacity(major ? 0.9 : half ? 0.7 : 0.45))
                .frame(width: major ? 2 : 1.5, height: major ? 30 : half ? 22 : 14)
            if major {
                Text(labelFormat?.text(value(at: index)) ?? value(at: index).formatted(.number.precision(.fractionLength(0))))
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize()
            }
        }
        .frame(width: Self.spacing, height: 64, alignment: .top)
        .id(index)
    }
}

#Preview {
    @Previewable @State var weight = 78.4
    VStack(spacing: LooprSpacing.lg) {
        Text(weight.formatted(.number.precision(.fractionLength(1)))).looprTypography(.display)
        LooprRulerPicker("Weight", value: $weight, in: 30...250, unit: "kg", accent: .energy)
    }.padding()
}
