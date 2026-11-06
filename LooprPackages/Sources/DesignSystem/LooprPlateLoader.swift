import SwiftUI

/// Plate arithmetic for a loaded barbell. Plates are counted per side, heaviest first, the way they
/// go on the sleeve.
public enum LooprPlateMath {
    /// The plates a gym usually has, in kilograms.
    public static let plates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    /// The plates offered as one-tap buttons. 1.25 kg stays out: the minus and plus buttons cover it.
    public static let buttons: [Double] = [25, 20, 15, 10, 5, 2.5]

    /// Plates on one side for `total` on a `bar`, heaviest first, and what the plates cannot make up.
    public static func perSide(total: Double, bar: Double = 20) -> (plates: [Double], remainder: Double) {
        var left = max(0, (total - bar) / 2)
        var result: [Double] = []
        for plate in plates {
            while left + 0.0001 >= plate, result.count < 12 {
                result.append(plate)
                left -= plate
            }
        }
        return (result, (left * 100).rounded() / 100)
    }

    /// "25 + 15 each side", "Just the bar", or nil below the bar.
    public static func caption(total: Double, bar: Double = 20) -> String? {
        guard total >= bar else { return nil }
        let side = perSide(total: total, bar: bar)
        guard !side.plates.isEmpty else { return "Just the bar" }
        let text = side.plates.map(format).joined(separator: " + ") + " each side"
        return side.remainder > 0 ? text + ", about" : text
    }

    static func format(_ kilograms: Double) -> String {
        kilograms.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// How this weight compares with the last session: "Same weight as last time", "+10 kg on last
/// time", or "10 kg under last time".
public enum LooprLoadComparison {
    public static func text(load: Double, lastTime: Double?) -> String? {
        guard let lastTime, lastTime > 0 else { return nil }
        let difference = ((load - lastTime) * 100).rounded() / 100
        if difference == 0 { return "Same weight as last time" }
        let amount = LooprPlateMath.format(abs(difference))
        return difference > 0 ? "+\(amount) kg on last time" : "\(amount) kg under last time"
    }
}

/// The weight for the next set: a large number with minus and plus, how it compares with last time,
/// and for a barbell lift the bar itself, loaded with the plates that make the number. Tapping a plate
/// below adds a pair; tapping the loaded bar takes the outer pair off. Every change ticks under the
/// finger, heavier plates a little harder.
///
/// Pass `platesExpanded` to fold the bar and the plate buttons behind a one-line "Plates" row that says
/// what goes on each side, so the set table can sit right under the weight.
public struct LooprLoadPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var value: Double
    private let lastTime: Double?
    private let showsBarbell: Bool
    private let bar: Double
    private let step: Double
    private let range: ClosedRange<Double>
    private let accent: LooprColorToken
    private let identifier: String
    private let label: String
    private let platesExpanded: Binding<Bool>?

    /// - Parameters:
    ///   - label: What the number is, for VoiceOver: "Weight", or "Added weight" on a bodyweight lift.
    ///   - platesExpanded: Nil shows the bar and plates whenever `showsBarbell` is true. A binding folds them
    ///     behind a "Plates" row and opens them while it is true.
    public init(value: Binding<Double>, lastTime: Double?, showsBarbell: Bool, bar: Double = 20, step: Double = 2.5,
                range: ClosedRange<Double> = 0...1_000, accent: LooprColorToken, identifier: String,
                label: String = "Weight", platesExpanded: Binding<Bool>? = nil) {
        _value = value; self.lastTime = lastTime; self.showsBarbell = showsBarbell; self.bar = bar
        self.step = step; self.range = range; self.accent = accent; self.identifier = identifier
        self.label = label; self.platesExpanded = platesExpanded
    }

    /// The folded Plates row: "Bar 20 kg · 25 + 5 each side".
    public static func platesSummary(total: Double, bar: Double = 20) -> String {
        let plates = LooprPlateMath.caption(total: total, bar: bar) ?? "Under the bar"
        return "Bar \(LooprPlateMath.format(bar)) kg · \(plates)"
    }

    private var spring: Animation? { LooprMotion.reducesMotion(reduceMotion) ? nil : .spring(response: 0.38, dampingFraction: 0.72) }
    private var plates: [Double] { value >= bar ? LooprPlateMath.perSide(total: value, bar: bar).plates : [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                        Text(LooprPlateMath.format(value))
                            .looprTypography(.display)
                            .foregroundStyle(Color.loopr(.ink))
                            .contentTransition(.numericText(value: value))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        LooprText("kg", style: .metricUnit, color: .inkSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(LooprPlateMath.format(value)) kilograms")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: change(by: step)
                        case .decrement: change(by: -step)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier(identifier)
                    if let comparison = LooprLoadComparison.text(load: value, lastTime: lastTime) {
                        LooprText(comparison, style: .caption, color: .inkSecondary)
                            .padding(.horizontal, LooprSpacing.sm)
                            .padding(.vertical, 6)
                            .background(Color.loopr(.surface), in: Capsule(style: .continuous))
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("\(identifier)-comparison")
                    }
                }
                Spacer(minLength: 0)
                stepButton("minus", label: "Less weight", identifier: "\(identifier)-minus") { change(by: -step) }
                stepButton("plus", label: "More weight", identifier: "\(identifier)-plus") { change(by: step) }
            }
            if showsBarbell {
                if let platesExpanded {
                    platesDisclosure(platesExpanded)
                    if platesExpanded.wrappedValue {
                        barbell
                        plateButtons
                    }
                } else {
                    barbell
                    plateButtons
                }
            }
        }
        .sensoryFeedback(trigger: value) { old, new in
            let added = new - old
            guard added != 0 else { return nil }
            if added < 0 { return .impact(flexibility: .soft, intensity: 0.55) }
            return .impact(flexibility: .rigid, intensity: min(1, 0.45 + added / 60))
        }
    }

    private func platesDisclosure(_ expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(LooprMotion.stateChange) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: "circle.grid.2x1")
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    LooprText("Plates", style: .rowTitle)
                    LooprText(Self.platesSummary(total: value, bar: bar), style: .caption, color: .inkSecondary)
                        .contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: LooprSpacing.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.loopr(.inkMuted))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LooprSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .background(Color.loopr(.surface), in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plates, \(Self.platesSummary(total: value, bar: bar))")
        .accessibilityHint(expanded.wrappedValue ? "Hides the bar" : "Shows the bar and plate buttons")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("\(identifier)-plates-toggle")
    }

    private func change(by amount: Double) {
        let next = min(range.upperBound, max(range.lowerBound, ((value + amount) / 0.25).rounded() * 0.25))
        guard next != value else { return }
        withAnimation(spring) { value = next }
    }

    private func stepButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .background(Color.loopr(.surface), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Barbell

    private var barbell: some View {
        VStack(spacing: LooprSpacing.xs) {
            LooprBarbellGraphic(plates: plates)
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Takes the outer pair off, the way you would unload a bar.
                    guard let outer = plates.last else { return }
                    change(by: -outer * 2)
                }
                .accessibilityHidden(true)
            HStack {
                LooprText("Bar \(LooprPlateMath.format(bar)) kg", style: .caption, color: .inkMuted)
                Spacer()
                if let caption = LooprPlateMath.caption(total: value, bar: bar) {
                    LooprText(caption, style: .caption, color: .inkSecondary)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("\(identifier)-plates")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var plateButtons: some View {
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? LooprSpacing.xxs : LooprSpacing.xs) {
            ForEach(LooprPlateMath.buttons, id: \.self) { plate in
                Button {
                    change(by: (value < bar ? bar - value : 0) + plate * 2)
                } label: {
                    LooprPlateFace(weight: plate, showsUnit: true)
                        .frame(maxWidth: .infinity)
                        .frame(height: LooprSpacing.interactiveRowHeight)
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityLabel("Add a pair of \(LooprPlateMath.format(plate)) kilogram plates")
                .accessibilityIdentifier("\(identifier)-plate-\(LooprPlateMath.format(plate))")
                .disabled(value + plate * 2 > range.upperBound)
            }
        }
    }
}

/// Plate colours, after the competition code most gyms follow (25 red, 20 blue, 15 yellow, 10 green,
/// 5 white), softened into Loopr's palette so a loaded bar reads at a glance.
public enum LooprPlateColor {
    public static func token(_ plate: Double) -> LooprColorToken {
        switch plate {
        case 25...: .heart
        case 20..<25: .sleep
        case 15..<20: .energy
        case 10..<15: .recoveryHigh
        case 5..<10: .ink
        case 2.5..<5: .strain
        default: .inkMuted
        }
    }
}

/// A plate button: the plate's colour as a ring around its weight.
struct LooprPlateFace: View {
    @Environment(\.colorScheme) private var colorScheme
    let weight: Double
    var showsUnit = false

    var body: some View {
        let tint = Color.loopr(LooprPlateColor.token(weight))
        ZStack {
            Circle().fill(Color.loopr(.surface))
            Circle().fill(tint.opacity(LooprAppearance.isDark(colorScheme) ? 0.12 : 0.1))
            Circle().strokeBorder(tint.opacity(0.9), lineWidth: 3).padding(3)
            VStack(spacing: 0) {
                Text(LooprPlateMath.format(weight))
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(.ink))
                    .minimumScaleFactor(0.6)
                if showsUnit {
                    Text("kg")
                        .looprTypography(.confidence)
                        .foregroundStyle(Color.loopr(.inkMuted))
                }
            }
            .lineLimit(1)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The whole bar from the side: a knurled shaft, a collar each side, and the plates stacked out from
/// the collars, heaviest inside. The bar never changes size, so only plates move: a new pair slides on
/// from the sleeve ends and a removed pair slides off them.
///
/// A target can be drawn as empty plate outlines past the loaded plates, as the Fitness week does: one
/// pair per session done and one outlined pair per session still to go. When a session lands, its
/// outline gives way and the plate slides on in its place.
public struct LooprBarbellGraphic: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let plates: [Double]
    private let outlines: Int
    private let outlineWeight: Double
    private let tint: LooprColorToken?

    public init(plates: [Double]) {
        self.init(plates: plates, outlines: 0)
    }

    /// - Parameters:
    ///   - outlines: Empty plate pairs drawn past the loaded ones, dashed, for a target still to load.
    ///   - outlineWeight: The plate size an outline takes. The last loaded plate's when nil, or 20 kg.
    ///   - tint: One colour for every plate, in place of the competition colours.
    public init(plates: [Double], outlines: Int, outlineWeight: Double? = nil, tint: LooprColorToken? = nil) {
        self.plates = plates
        self.outlines = max(outlines, 0)
        self.outlineWeight = outlineWeight ?? plates.last ?? 20
        self.tint = tint
    }

    /// Plate height as a share of the tallest. 10 kg and up share the 450 mm bumper diameter in most gyms,
    /// but steel plates shrink; a step per weight reads better than a wall of equal discs.
    static func heightShare(_ plate: Double) -> CGFloat {
        switch plate {
        case 20...: 1
        case 15..<20: 0.9
        case 10..<15: 0.78
        case 5..<10: 0.58
        case 2.5..<5: 0.44
        default: 0.36
        }
    }

    static func thickness(_ plate: Double) -> CGFloat {
        switch plate {
        case 25...: 17
        case 20..<25: 15
        case 15..<20: 13
        case 10..<15: 11
        case 5..<10: 8
        case 2.5..<5: 6
        default: 5
        }
    }

    /// A plate and its place on the sleeve. A plate keeps its identity while the plates inside it stay,
    /// so going from 25 + 5 to 25 + 5 + 2.5 adds one plate instead of redrawing three.
    struct Slot: Identifiable, Equatable {
        let index: Int
        let weight: Double
        /// An empty plate still to load. It keeps its own identity, so loading it swaps the outline for a plate.
        var isOutline = false
        var id: String { isOutline ? "outline-\(index)" : "\(index)-\(weight)" }
    }

    /// The loaded plates, then the outlines past them, one slot per plate on each side.
    nonisolated static func slots(plates: [Double], outlines: Int, outlineWeight: Double) -> [Slot] {
        plates.enumerated().map { Slot(index: $0.offset, weight: $0.element) }
            + (0..<max(outlines, 0)).map { Slot(index: plates.count + $0, weight: outlineWeight, isOutline: true) }
    }

    private var slots: [Slot] { Self.slots(plates: plates, outlines: outlines, outlineWeight: outlineWeight) }
    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.74) }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let sleeve = width * 0.34
            let gap: CGFloat = 2
            let needed = slots.reduce(0) { $0 + Self.thickness($1.weight) + gap }
            // A very heavy bar squeezes its plates instead of running off the sleeve.
            let squeeze = min(1, (sleeve - 14) / max(needed, 1))
            ZStack {
                bar(width: width, height: height, sleeve: sleeve)
                HStack(spacing: 0) {
                    side(slots.reversed(), height: height, squeeze: squeeze, gap: gap, edge: .leading)
                        .frame(width: sleeve, alignment: .trailing)
                    Spacer(minLength: 0)
                    side(slots, height: height, squeeze: squeeze, gap: gap, edge: .trailing)
                        .frame(width: sleeve, alignment: .leading)
                }
                .animation(spring, value: slots)
            }
        }
    }

    private func side(_ slots: [Slot], height: CGFloat, squeeze: CGFloat, gap: CGFloat, edge: HorizontalEdge) -> some View {
        let outward: CGFloat = edge == .trailing ? 44 : -44
        return HStack(spacing: gap * squeeze) {
            ForEach(slots) { slot in
                Group {
                    if slot.isOutline {
                        outline(slot.weight, height: height * 0.92 * Self.heightShare(slot.weight),
                                width: Self.thickness(slot.weight) * squeeze)
                    } else {
                        plate(slot.weight, height: height * 0.92 * Self.heightShare(slot.weight),
                              width: Self.thickness(slot.weight) * squeeze)
                    }
                }
                    .transition(.asymmetric(
                        insertion: .offset(x: outward).combined(with: .opacity),
                        removal: .offset(x: outward).combined(with: .opacity)))
            }
        }
        // The plates sit on the collar, with room for the collar itself.
        .padding(edge == .trailing ? .leading : .trailing, 7)
    }

    private func bar(width: CGFloat, height: CGFloat, sleeve: CGFloat) -> some View {
        ZStack {
            // Floor shadow.
            Ellipse()
                .fill(Color.black.opacity(isDark ? 0.5 : 0.12))
                .frame(width: width * 0.9, height: 10)
                .blur(radius: 8)
                .offset(y: height * 0.5 - 4)
            // Shaft with knurling between the collars.
            Capsule()
                .fill(steel)
                .overlay(knurl.clipShape(Capsule()).padding(.horizontal, width * 0.12))
                .frame(width: width - sleeve * 2 + 8, height: 7)
            HStack(spacing: 0) {
                sleeveView(width: sleeve)
                Spacer(minLength: 0)
                sleeveView(width: sleeve).scaleEffect(x: -1)
            }
        }
    }

    /// One sleeve, drawn from its outer end to the collar.
    private func sleeveView(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Capsule().fill(steel).frame(width: width - 6, height: 14)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(steel)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: 6, height: 26)
        }
    }

    private var steel: LinearGradient {
        let top = Color(white: isDark ? 0.78 : 0.86), middle = Color(white: isDark ? 0.46 : 0.6), bottom = Color(white: isDark ? 0.3 : 0.48)
        return LinearGradient(colors: [top, middle, bottom], startPoint: .top, endPoint: .bottom)
    }

    private var knurl: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.22)))
                x += 3
            }
        }
    }

    /// A plate still to load: a dashed outline in muted ink, no fill and no shadow.
    private func outline(_ weight: Double, height: CGFloat, width: CGFloat) -> some View {
        let radius = min(4, width / 2.4)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.loopr(.inkMuted), style: StrokeStyle(lineWidth: 1.3, dash: [3, 3]))
            .frame(width: width, height: height)
    }

    /// A plate seen edge on: its colour, lit from above, with a darker rim and a raised lip at the edge.
    private func plate(_ weight: Double, height: CGFloat, width: CGFloat) -> some View {
        let tint = Color.loopr(self.tint ?? LooprPlateColor.token(weight))
        let radius = min(4, width / 2.4)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.32), .clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(isDark ? 0.45 : 0.22), lineWidth: 0.75))
            // The lip: a lighter band near each end of the plate's edge.
            .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.25)).frame(width: max(1, width - 4), height: 1.5).padding(.top, 3) }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(isDark ? 0.4 : 0.16), radius: 3, y: 2)
    }
}

/// How many reps the set was: a strip of numbers to tap. Last time's count is underlined. VoiceOver
/// reads it as one adjustable value.
///
/// The strip marks no records. A set is a record only once it is logged and beats a best, and the set
/// table says so on that row.
public struct LooprRepsStrip: View {
    @Binding private var reps: Int
    private let lastTime: Int?
    private let accent: LooprColorToken
    private let identifier: String
    private let range: ClosedRange<Int>

    /// - Parameters:
    ///   - best: Ignored. Kept so older call sites still compile.
    ///   - limit: The highest count offered: 100 for a loaded lift, up to 1,000 for bodyweight work.
    public init(reps: Binding<Int>, lastTime: Int?, best: Int? = nil, limit: Int = 100, accent: LooprColorToken,
                identifier: String) {
        _reps = reps; self.lastTime = lastTime; self.accent = accent; self.identifier = identifier
        // The strip grows past the current count, so a long set is a few taps away, not a long scroll.
        let current = reps.wrappedValue
        let top = max(20, (lastTime ?? 0) + 6, current + max(6, current / 5))
        range = 1...min(max(limit, 1), top)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                LooprText("Reps done", style: .sectionLabel, color: .inkSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Reps")
                    .accessibilityValue("\(reps) reps")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: if reps < range.upperBound { reps += 1 }
                        case .decrement: if reps > range.lowerBound { reps -= 1 }
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier(identifier)
                Spacer()
                if lastTime != nil {
                    HStack(spacing: LooprSpacing.xxs) {
                        Capsule().fill(Color.loopr(.inkMuted)).frame(width: 12, height: 3)
                        LooprText("last time", style: .caption, color: .inkMuted)
                    }
                    .accessibilityHidden(true)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: LooprSpacing.xs) {
                        ForEach(Array(range), id: \.self) { count in
                            chip(count).id(count)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .onAppear { proxy.scrollTo(reps, anchor: .center) }
                .onChange(of: reps) { _, new in
                    withAnimation(LooprMotion.stateChange) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: reps)
    }

    private func chip(_ count: Int) -> some View {
        let selected = count == reps
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { reps = count }
        } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .looprTypography(.metricCompact)
                    .foregroundStyle(selected ? accent.filledLabelColor : Color.loopr(.ink))
                Capsule()
                    .fill(selected ? accent.filledLabelColor.opacity(0.6) : Color.loopr(.inkMuted))
                    .frame(width: 14, height: 3)
                    .opacity(count == lastTime ? 1 : 0)
            }
            .frame(width: 56, height: 64)
            .background(selected ? Color.loopr(accent) : Color.loopr(.surface),
                        in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .scaleEffect(selected ? 1.04 : 1)
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityLabel("\(count) reps")
        .accessibilityValue(count == lastTime ? "Last time" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-\(count)")
    }
}

#Preview("Load picker") {
    @Previewable @State var kg = 100.0
    @Previewable @State var reps = 8
    ScrollView {
        VStack(spacing: LooprSpacing.xl) {
            LooprLoadPicker(value: $kg, lastTime: 100, showsBarbell: true, accent: .movement, identifier: "kg")
            LooprRepsStrip(reps: $reps, lastTime: 7, best: 8, accent: .movement, identifier: "reps")
        }
        .padding()
    }
    .background(Color.loopr(.background))
}
