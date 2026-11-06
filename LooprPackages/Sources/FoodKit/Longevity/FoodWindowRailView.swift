import DesignSystem
import SwiftUI

/// The eating-window rail (contract p-food): a time track with the window from the first meal to the kitchen's
/// closing time, a "now" marker on today, the closing line, each meal as its camera sticker (or a drawn one) at the
/// time it was eaten, and a ghost sticker for the next meal that opens the camera.
struct FoodWindowRailView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rail: FoodWindowRail
    /// The camera's sticker per meal id.
    let stickers: [UUID: Image]
    /// True while the tab plays its entrance: the stickers press on one after another.
    let animates: Bool
    let open: (UUID) -> Void
    let log: (FoodMealSlot) -> Void
    @State private var trackWidth: CGFloat = 300
    @State private var stuck = false

    static let sticker: CGFloat = 56
    static let trackHeight: CGFloat = 96
    static let lineY: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your eating window", detail: detail)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs + 2) {
                track
                axis
                labels
                if rail.isEmpty {
                    LooprText(rail.nowMinute == nil ? "Nothing logged on this day." : "Nothing logged yet today.", style: .body, color: .inkSecondary)
                        .padding(.top, LooprSpacing.xxs)
                }
            }
            .padding(LooprSpacing.md)
            .looprCardBackground()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("food-window-rail")
        }
        .onAppear { if !animates { stuck = true } }
        .onChange(of: animates, initial: true) { _, playing in
            guard playing, !LooprMotion.reducesMotion(reduceMotion) else { stuck = true; return }
            stuck = false
            DispatchQueue.main.async { stuck = true }
        }
    }

    private var detail: String? {
        if let window = rail.windowText(locale: locale) { return window }
        return rail.closesMinute.map { "Kitchen closes \(LooprClockFormat.text(minuteOfDay: $0, locale: locale))" }
    }

    private func x(_ minute: Int) -> CGFloat { CGFloat(rail.fraction(of: minute)) * trackWidth }

    // MARK: Track

    private var track: some View {
        let placements = rail.placements(trackWidth: Double(trackWidth), stickerWidth: Double(Self.sticker))
        let meals = Dictionary(rail.meals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ZStack(alignment: .topLeading) {
            Capsule().fill(Color.loopr(.divider))
                .frame(width: trackWidth, height: 2)
                .position(x: trackWidth / 2, y: Self.lineY)
            if let window = rail.window {
                let start = x(window.lowerBound), end = max(x(window.upperBound), start + 4)
                Capsule()
                    .fill(LinearGradient(colors: [Color.loopr(.energy), Color.loopr(.energy).opacity(0.4)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: end - start, height: 4)
                    .position(x: (start + end) / 2, y: Self.lineY)
            }
            markers
            ForEach(placements) { placement in
                if let id = placement.mealID, let meal = meals[id] {
                    sticker(meal, at: placement)
                } else if let ghost = rail.ghost {
                    ghostSticker(ghost, at: placement)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.trackHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = max($0, 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rail.accessibilitySummary(locale: locale))
    }

    @ViewBuilder private var markers: some View {
        let nowX = rail.nowMinute.map(x)
        let closeX = rail.closesMinute.map(x)
        // Two markers closer than their words: each label leans away from the other line.
        let gap = nowX.flatMap { now in closeX.map { $0 - now } }
        let crowded = gap.map { abs($0) < 72 } ?? false
        let lean: CGFloat = (gap ?? 0) >= 0 ? 1 : -1
        if let closeX, let minute = rail.closesMinute {
            Path { path in path.move(to: .init(x: closeX, y: 14)); path.addLine(to: .init(x: closeX, y: Self.trackHeight - 6)) }
                .stroke(Color.loopr(.protocol), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            markerLabel("closes \(LooprClockFormat.text(minuteOfDay: minute, locale: locale))", token: .protocol,
                        x: crowded ? closeX + lean * 34 : closeX, y: 4)
        }
        if let nowX {
            Capsule().fill(Color.loopr(.brand))
                .frame(width: 1.5, height: Self.trackHeight - 20)
                .shadow(color: Color.loopr(.brand), radius: 5)
                .position(x: nowX, y: 14 + (Self.trackHeight - 20) / 2)
            markerLabel("now", token: .brand, x: crowded ? nowX - lean * 20 : nowX, y: 4)
        }
    }

    private func markerLabel(_ text: String, token: LooprColorToken, x: CGFloat, y: CGFloat) -> some View {
        Text(text)
            .font(.custom("SpaceGrotesk-SemiBold", size: 10.5, relativeTo: .caption2))
            .foregroundStyle(Color.loopr(token.textInk))
            .fixedSize()
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .position(x: min(max(x, 30), max(trackWidth - 30, 30)), y: y)
            .accessibilityHidden(true)
    }

    private func sticker(_ meal: FoodRailMeal, at placement: FoodRailPlacement) -> some View {
        let lean = FoodWindowRail.rotation(for: meal.id)
        let delay = 0.3 + Double(placement.stack) * 0.2 + Double(placement.order) * 0.08
        return Button { open(meal.id) } label: {
            FoodRailSticker(meal: meal, image: stickers[meal.id], size: Self.sticker)
                .rotationEffect(.degrees(stuck ? lean : lean - 25))
                .scaleEffect(stuck ? 1 : 0.2)
                .offset(y: stuck ? 0 : -40)
                .opacity(stuck ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.62).delay(stuck ? delay : 0), value: stuck)
                .looprPressTilt(maxDegrees: 4)
                .frame(width: Self.sticker, height: Self.sticker)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .zIndex(Double(placement.order) + 1)
        .position(x: CGFloat(placement.x), y: Self.lineY)
        .accessibilityLabel(stickerLabel(meal))
        .accessibilityHint("Opens the meal")
        .accessibilityIdentifier("food-window-meal-\(meal.id.uuidString)")
    }

    private func stickerLabel(_ meal: FoodRailMeal) -> String {
        let energy = meal.energy.flatMap { LooprUnitFormatter.number($0, digits: 0) }.map { ", \($0) kilocalories" } ?? ""
        return "\(meal.slot.title) at \(LooprClockFormat.text(minuteOfDay: meal.minute, locale: locale))\(energy). \(meal.title)"
    }

    private func ghostSticker(_ ghost: FoodRailGhost, at placement: FoodRailPlacement) -> some View {
        Button { log(ghost.slot) } label: {
            Circle()
                .strokeBorder(Color.loopr(.inkMuted), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.loopr(.inkMuted))
                }
                .frame(width: Self.sticker, height: Self.sticker)
                .contentShape(Circle())
        }
        .buttonStyle(.looprPressableCard)
        .position(x: CGFloat(placement.x), y: Self.lineY)
        .accessibilityLabel("Log \(ghost.slot.title.lowercased()) with the camera")
        .accessibilityIdentifier("food-window-ghost")
    }

    // MARK: Axis and labels

    private var axis: some View {
        ZStack(alignment: .topLeading) {
            ForEach(rail.ticks, id: \.self) { minute in
                Text(hourText(minute))
                    .font(.custom("SpaceGrotesk-Regular", size: 10.5, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(Color.loopr(.inkMuted))
                    .fixedSize()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .position(x: min(max(x(minute), 10), max(trackWidth - 10, 10)), y: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func hourText(_ minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: (minute / 60) % 24)) ?? Date()
        var style = Date.FormatStyle(date: .omitted, time: .omitted).hour(.twoDigits(amPM: .narrow))
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }

    @ViewBuilder private var labels: some View {
        let stacks = rail.stacks(trackWidth: Double(trackWidth), stickerWidth: Double(Self.sticker))
        let ghost = rail.placements(trackWidth: Double(trackWidth), stickerWidth: Double(Self.sticker)).first { $0.mealID == nil }
        if !stacks.isEmpty || ghost != nil {
            FoodRailLabelLayout(trackWidth: trackWidth) {
                ForEach(stacks) { stack in
                    railLabel(FoodWindowRail.label(for: stack.meals, locale: locale), dim: false)
                        .layoutValue(key: FoodRailLabelCentre.self, value: CGFloat(stack.centre))
                }
                if let ghost, let slot = rail.ghost?.slot {
                    railLabel(slot.title.lowercased(), dim: true)
                        .layoutValue(key: FoodRailLabelCentre.self, value: CGFloat(ghost.x))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func railLabel(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.custom("SpaceGrotesk-Regular", size: 11.5, relativeTo: .caption))
            .monospacedDigit()
            .foregroundStyle(Color.loopr(dim ? .inkMuted : .inkSecondary))
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}

/// Where a rail label wants its centre, in points from the track's leading edge.
struct FoodRailLabelCentre: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Lays the rail's labels under their stickers. A label that would touch the one before it drops to a second row,
/// through `FoodWindowRail.labelRows`.
struct FoodRailLabelLayout: Layout {
    let trackWidth: CGFloat
    static let rowGap: CGFloat = 2

    private func measure(_ subviews: Subviews) -> (sizes: [CGSize], rows: [(x: Double, row: Int)]) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: trackWidth, height: nil)) }
        let rows = FoodWindowRail.labelRows(centres: subviews.map { Double($0[FoodRailLabelCentre.self]) },
                                            widths: sizes.map { Double($0.width) }, trackWidth: Double(trackWidth))
        return (sizes, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (sizes, rows) = measure(subviews)
        let line = sizes.map(\.height).max() ?? 0
        let used = (rows.map(\.row).max() ?? -1) + 1
        return CGSize(width: proposal.width ?? trackWidth, height: CGFloat(used) * line + CGFloat(max(used - 1, 0)) * Self.rowGap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, rows) = measure(subviews)
        let line = sizes.map(\.height).max() ?? 0
        for (index, subview) in subviews.enumerated() {
            let place = rows[index]
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(place.x), y: bounds.minY + CGFloat(place.row) * (line + Self.rowGap)),
                          anchor: .top, proposal: ProposedViewSize(width: sizes[index].width, height: sizes[index].height))
        }
    }
}

/// A meal on the rail: the camera's sticker when the meal has a photo, otherwise the shared `LooprDrawnSticker`, a soft
/// disc in the meal's colours with the first item's initial, or the meal's symbol when the name has no letter.
struct FoodRailSticker: View {
    let meal: FoodRailMeal
    let image: Image?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFit()
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 7, y: 6)
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    /// The shared drawn sticker, so a meal without a photo looks the same here and on Today's dial.
    private var drawn: some View {
        LooprDrawnSticker(meal: meal.slot.title, initial: meal.initial, diameter: size, rim: 3.5)
    }
}
