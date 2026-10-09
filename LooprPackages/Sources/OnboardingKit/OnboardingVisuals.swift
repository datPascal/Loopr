#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit

// Onboarding's pictures. The brand mark and the step heroes are built from
// the tabs' own parts (`LooprProgressRing`, `LooprSurface`, the chip style of
// `LooprRangePicker`); what remains here is only what DesignSystem has no
// part for: the band, an iOS Settings row, a notification banner. They are
// decorative, hidden from VoiceOver, and hold still under Reduce Motion.

/// Shared reduce-motion check: the system setting or Loopr's own override.
struct OnboardingMotion {
    let systemReduceMotion: Bool

    var isReduced: Bool {
        systemReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    func animation(_ base: Animation) -> Animation? {
        isReduced ? nil : base
    }
}

/// Sizes the heroes share, built from the spacing scale.
enum OnboardingMetrics {
    /// The hero ring, the same size as the tabs' ring heroes.
    static let heroRing: CGFloat = LooprSpacing.hero * 4 + LooprSpacing.sm
    /// A compact ring, as in Today's row of three.
    static let compactRing: CGFloat = LooprSpacing.hero * 2 + LooprSpacing.sm
    /// The band picture's width on the band steps.
    static let bandWidth: CGFloat = LooprSpacing.hero * 7
    /// A step card's picture tile.
    static let tile: CGFloat = LooprSpacing.interactiveRowHeight
    /// The progress track's thickness.
    static let track: CGFloat = LooprSpacing.hairline * 3
}

// MARK: - Brand mark

/// Loopr's mark, as on the app icon: one ring in the brand teal around the
/// wordmark. The ring is the tabs' own progress ring, drawn full.
struct OnboardingBrandMark: View {
    var diameter: CGFloat = OnboardingMetrics.heroRing + LooprSpacing.xxl

    var body: some View {
        LooprProgressRing(
            value: 1,
            scale: LooprRingScale(fullValue: 1),
            text: "Loopr",
            accent: .brand,
            diameter: diameter
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Band

/// The band pictures the design lane renders into the app bundle. Each is
/// optional: until a file ships, the drawn band stands in.
enum OnboardingBandAsset: String, CaseIterable {
    case product = "band-product"
    case pairing = "band-product-pairing"
    case tap = "band-product-tap"

    var image: UIImage? {
        UIImage(named: rawValue, in: .main, with: nil)
    }

    /// The first of `preferred` that ships, if any.
    static func firstAvailable(_ preferred: [OnboardingBandAsset]) -> UIImage? {
        firstAvailableAsset(preferred)?.1
    }

    static func firstAvailableAsset(_ preferred: [OnboardingBandAsset]) -> (OnboardingBandAsset, UIImage)? {
        for asset in preferred {
            if let image = asset.image { return (asset, image) }
        }
        return nil
    }

    /// Where the side light sits in `band-product-pairing.png`, as a share
    /// of the square picture.
    static let pairingLight = UnitPoint(x: 0.40, y: 0.31)
}

/// A WHOOP 4.0 seen from the side, with the side light that pulses blue in
/// pairing mode. It uses the rendered product picture when the app has one.
struct OnboardingBandArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lit = false

    var preferred: [OnboardingBandAsset] = [.pairing, .product]
    var showsLight = true

    var body: some View {
        Group {
            if let (asset, image) = OnboardingBandAsset.firstAvailableAsset(preferred) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        // The pairing still has its side light lit; a glow
                        // on that spot makes it pulse as the real one does.
                        if showsLight, asset == .pairing {
                            GeometryReader { proxy in
                                let size = min(proxy.size.width, proxy.size.height)
                                Circle()
                                    .fill(Color.loopr(.sleepSweep))
                                    .frame(width: size * 0.16, height: size * 0.16)
                                    .blur(radius: size * 0.05)
                                    .opacity(lit ? (isDark ? 0.95 : 0.55) : 0.2)
                                    // Adding light reads as a glow on the dark
                                    // page and as a white smear on the light one.
                                    .blendMode(isDark ? .plusLighter : .normal)
                                    .position(
                                        x: proxy.size.width * OnboardingBandAsset.pairingLight.x,
                                        y: proxy.size.height * OnboardingBandAsset.pairingLight.y
                                    )
                            }
                        }
                    }
            } else {
                drawn
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard showsLight, !OnboardingMotion(systemReduceMotion: reduceMotion).isReduced else {
                lit = showsLight
                return
            }
            withAnimation(.easeInOut(duration: LooprMotion.reveal).repeatForever(autoreverses: true)) { lit = true }
        }
    }

    /// The band is black in both appearances, as the real one is.
    private var drawn: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = width * 0.36
            let strapHeight = height * 0.34
            let podWidth = width * 0.40
            let podHeight = height * 0.66
            let radius = podHeight * 0.30
            ZStack {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [bandTop, bandBottom], startPoint: .top, endPoint: .bottom))
                    .overlay { weave.clipShape(Capsule(style: .continuous)) }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: LooprSpacing.hairline)
                    }
                    .frame(width: width, height: strapHeight)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [bandTop, bandBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.loopr(.brandSweep).opacity(isDark ? 0.18 : 0.10), lineWidth: LooprSpacing.hairline)
                    }
                    .overlay(alignment: .top) {
                        // A soft sheen along the top edge of the pod.
                        Capsule(style: .continuous)
                            .fill(highlight.opacity(isDark ? 0.08 : 0.14))
                            .frame(width: podWidth * 0.72, height: LooprSpacing.hairline * 2)
                            .padding(.top, podHeight * 0.12)
                    }
                    .frame(width: podWidth, height: podHeight)
                    .shadow(color: shade.opacity(isDark ? 0.5 : 0.18), radius: LooprSpacing.sm, y: LooprSpacing.xs)

                if showsLight {
                    light(size: podHeight * 0.14)
                        .offset(x: podWidth / 2)
                }
            }
            .frame(width: width, height: height)
            .frame(maxHeight: .infinity)
        }
        .aspectRatio(1 / 0.36, contentMode: .fit)
    }

    private var bandTop: Color { isDark ? Color.loopr(.surfaceElevated) : Color.loopr(.ink).opacity(0.86) }
    private var bandBottom: Color { isDark ? Color.loopr(.surfaceSunk) : Color.loopr(.ink) }
    /// Light catching the band: the page's lightest ink in each appearance.
    private var highlight: Color { Color.loopr(isDark ? .ink : .background) }
    private var shade: Color { Color.loopr(isDark ? .background : .ink) }

    private var weave: some View {
        Canvas { context, size in
            let spacing = max(size.height / 3, 4)
            var x: CGFloat = spacing
            while x < size.width - spacing {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height * 0.3))
                path.addLine(to: CGPoint(x: x, y: size.height * 0.7))
                context.stroke(path, with: .color(highlight.opacity(isDark ? 0.06 : 0.10)), lineWidth: LooprSpacing.hairline)
                x += spacing
            }
        }
    }

    private func light(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.loopr(.sleepSweep))
                .frame(width: size * 5, height: size * 5)
                .blur(radius: size * 1.4)
                .opacity(lit ? 0.85 : 0.2)
            Capsule(style: .continuous)
                .fill(Color.loopr(.sleepSweep))
                .frame(width: size * 0.9, height: size * 1.8)
                .opacity(lit ? 1 : 0.5)
        }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

// MARK: - Pairing hero

/// The band inside rings that ripple while Loopr waits for the sheet or the
/// band, and hold still otherwise. A connected band gets the ring drawn full.
struct OnboardingPairingHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanding = false

    let phase: OnboardingPairingPhase
    let accent: LooprColorToken

    var body: some View {
        ZStack {
            if phase == .connected {
                LooprProgressRing(
                    value: 1,
                    scale: LooprRingScale(fullValue: 1),
                    text: "",
                    accent: accent,
                    diameter: OnboardingMetrics.heroRing + LooprSpacing.xl
                )
            } else {
                ForEach(0 ..< 3, id: \.self) { ring in
                    Circle()
                        .stroke(Color.loopr(accent).opacity(ringOpacity(ring)), lineWidth: LooprSpacing.hairline)
                        .frame(width: ringDiameter(ring), height: ringDiameter(ring))
                        .scaleEffect(animating ? (expanding ? 1.06 : 0.94) : 1)
                        .opacity(animating ? (expanding ? 0.4 : 1) : 1)
                        .animation(
                            animating
                                ? .easeInOut(duration: LooprMotion.reveal * 1.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(ring) * LooprMotion.fast)
                                : nil,
                            value: expanding
                        )
                }
            }
            // The lit still only while the band should be in pairing mode.
            OnboardingBandArt(preferred: bandLit ? [.pairing, .product] : [.product], showsLight: bandLit)
                .frame(width: OnboardingMetrics.heroRing)
            if phase == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .looprTypography(.metricCompact)
                    .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                    .background(Circle().fill(Color.loopr(.background)).padding(LooprSpacing.xxs))
                    .offset(x: OnboardingMetrics.heroRing * 0.36, y: -OnboardingMetrics.heroRing * 0.36)
            }
        }
        .frame(height: OnboardingMetrics.heroRing + LooprSpacing.hero)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .onAppear(perform: startIfNeeded)
        .onChange(of: phase) { _, _ in startIfNeeded() }
    }

    private var animating: Bool {
        phase.isWorking && !OnboardingMotion(systemReduceMotion: reduceMotion).isReduced
    }

    private var bandLit: Bool { phase != .connected && !phase.isProblem }

    private func ringDiameter(_ ring: Int) -> CGFloat {
        OnboardingMetrics.heroRing * [0.9, 1.12, 1.34][ring]
    }

    private func ringOpacity(_ ring: Int) -> Double {
        let base = [0.5, 0.3, 0.16][ring]
        return phase.isWorking ? base : base * 0.7
    }

    private func startIfNeeded() {
        expanding = false
        guard animating else { return }
        Task { @MainActor in expanding = true }
    }
}

// MARK: - Settings row illustration

/// The row the person looks for in Settings › Privacy & Security ›
/// Bluetooth: the WHOOP app with its switch turned off.
struct OnboardingSettingsMock: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: LooprColorToken

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Text(OnboardingCopy.Handover.mockPath.uppercased())
                .looprTypography(.headerMeta)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .padding(.horizontal, LooprSpacing.xxs)
            VStack(spacing: LooprSpacing.none) {
                row(highlighted: false)
                LooprHairline()
                row(highlighted: true)
            }
            .background(rowFill, in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                    .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: isDark ? LooprSpacing.hairline : LooprSpacing.none)
            }
            HStack(spacing: LooprSpacing.xxs) {
                Spacer()
                Image(systemName: "arrow.turn.left.up")
                Text(OnboardingCopy.Handover.mockCaption)
            }
            .looprTypography(.label)
            .foregroundStyle(Color.loopr(accent.textInk))
            .padding(.trailing, LooprSpacing.xs)
        }
        .frame(maxWidth: OnboardingMetrics.bandWidth + LooprSpacing.hero)
        .accessibilityHidden(true)
    }

    private func row(highlighted: Bool) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            RoundedRectangle(cornerRadius: LooprRadius.surfaceShadow * 4, style: .continuous)
                .fill(Color.loopr(highlighted ? .ink : .inkMuted).opacity(highlighted ? 0.9 : 0.35))
                .frame(width: LooprSpacing.xxl - LooprSpacing.xxs, height: LooprSpacing.xxl - LooprSpacing.xxs)
            if highlighted {
                LooprText(OnboardingCopy.Handover.mockApp, style: .settingsRow)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.loopr(.inkMuted).opacity(0.3))
                    .frame(width: LooprSpacing.hero * 2, height: LooprSpacing.xs)
            }
            Spacer(minLength: LooprSpacing.sm)
            Toggle("", isOn: .constant(!highlighted))
                .labelsHidden()
                .tint(Color.loopr(.recoveryHigh))
                .allowsHitTesting(false)
                .opacity(highlighted ? 1 : 0.45)
                .padding(LooprSpacing.xxs)
                .overlay {
                    if highlighted {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.loopr(accent), lineWidth: LooprSpacing.hairline * 2)
                    }
                }
        }
        .padding(.horizontal, LooprSpacing.md)
        .padding(.vertical, LooprSpacing.xs)
    }

    private var rowFill: Color { isDark ? Color.loopr(.surface) : Color.loopr(.sheetFill) }
    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

// MARK: - Notification illustration

/// Two of Loopr's real notifications as lock screen banners, in glass.
struct OnboardingNotificationMock: View {
    var body: some View {
        // A short list, as Notification Centre shows them. Glass is see
        // through, so the banners sit apart instead of stacked.
        VStack(spacing: LooprSpacing.xs) {
            ForEach(Array(OnboardingCopy.Notifications.sample.enumerated()), id: \.offset) { index, sample in
                banner(title: sample.title, detail: sample.detail)
                    .opacity(index == 0 ? 1 : 0.7)
                    .scaleEffect(index == 0 ? 1 : 0.96)
            }
        }
        .frame(maxWidth: OnboardingMetrics.bandWidth + LooprSpacing.hero * 2)
        .accessibilityHidden(true)
    }

    private func banner(title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            appIcon
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                HStack(alignment: .firstTextBaseline) {
                    LooprText(title, style: .rowTitle)
                    Spacer(minLength: LooprSpacing.xs)
                    LooprText(OnboardingCopy.Notifications.sampleTime, style: .caption, color: .inkSecondary)
                }
                LooprText(detail, style: .prose, color: .inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, LooprSpacing.md)
        .padding(.vertical, LooprSpacing.sm)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: LooprRadius.card + LooprSpacing.xxs, style: .continuous))
    }

    /// Loopr's icon in miniature: the ring on the icon's own ground, dark
    /// or light as the icon is.
    private var appIcon: some View {
        RoundedRectangle(cornerRadius: LooprSpacing.xs + LooprSpacing.hairline, style: .continuous)
            .fill(Color.loopr(.sheetFill))
            .overlay {
                Circle()
                    .strokeBorder(Color.loopr(.brandSweep), lineWidth: LooprSpacing.hairline * 2)
                    .padding(LooprSpacing.xs - LooprSpacing.hairline)
                    .shadow(color: Color.loopr(.brand), radius: LooprSpacing.xxs)
            }
            .frame(width: LooprSpacing.xxl + LooprSpacing.xxs, height: LooprSpacing.xxl + LooprSpacing.xxs)
    }
}

// MARK: - Cards and rows

/// One numbered step: a picture tile, the step number as an eyebrow, a
/// title and a sentence, and optional extra content such as a button.
struct OnboardingStepCard<Tile: View, Extra: View>: View {
    let number: Int
    let title: String
    let detail: String
    let accent: LooprColorToken
    let tile: Tile
    let extra: Extra

    init(
        number: Int,
        title: String,
        detail: String,
        accent: LooprColorToken,
        @ViewBuilder tile: () -> Tile,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.number = number
        self.title = title
        self.detail = detail
        self.accent = accent
        self.tile = tile()
        self.extra = extra()
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .top, spacing: LooprSpacing.md) {
                    tile
                        .frame(width: OnboardingMetrics.tile, height: OnboardingMetrics.tile)
                        .background(
                            Color.loopr(accent).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        Text("STEP \(number)")
                            .looprTypography(.sectionLabel)
                            .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                        LooprText(title, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprText(detail, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(number). \(title). \(detail)")
                }
                extra
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A picture tile made from an SF Symbol in the step's accent.
struct OnboardingSymbolTile: View {
    let symbol: String
    let accent: LooprColorToken

    var body: some View {
        Image(systemName: symbol)
            .looprTypography(.metricCompact)
            .foregroundStyle(Color.loopr(accent.spectralChipLabel))
            .symbolRenderingMode(.hierarchical)
    }
}

/// A picture tile from a band picture, or a symbol when it has not shipped.
struct OnboardingBandTile: View {
    let preferred: [OnboardingBandAsset]
    let fallbackSymbol: String
    let accent: LooprColorToken

    var body: some View {
        if let image = OnboardingBandAsset.firstAvailable(preferred) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(LooprSpacing.xxs)
        } else {
            OnboardingSymbolTile(symbol: fallbackSymbol, accent: accent)
        }
    }
}

/// An icon, a title and a sentence: one row of a list card.
struct OnboardingInfoRow: View {
    let symbol: String
    let title: String
    let detail: String
    var accent: LooprColorToken = .brand

    var body: some View {
        HStack(alignment: .top, spacing: LooprSpacing.md) {
            Image(systemName: symbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(accent.spectralChipLabel))
                .frame(width: LooprSpacing.xxl, height: LooprSpacing.xxl)
                .background(Color.loopr(accent).opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(detail, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LooprSpacing.none)
        }
        .padding(.vertical, LooprSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// A list card: rows on one surface, split by hairlines.
struct OnboardingListCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.none) {
                content
            }
            .padding(.vertical, -LooprSpacing.xs)
        }
    }
}

/// One Apple Health type as a small tag: symbol and name.
struct OnboardingTypeTag: View {
    @Environment(\.colorScheme) private var colorScheme
    let type: OnboardingHealthType
    let accent: LooprColorToken

    var body: some View {
        HStack(spacing: LooprSpacing.xxs + LooprSpacing.hairline) {
            Image(systemName: type.symbol)
                .looprTypography(.metricUnit)
                .accessibilityHidden(true)
            Text(type.name)
                .looprTypography(.caption)
        }
        .foregroundStyle(Color.loopr(.ink))
        .padding(.horizontal, LooprSpacing.sm - LooprSpacing.hairline)
        .padding(.vertical, LooprSpacing.xs - LooprSpacing.hairline)
        .background(Color.loopr(accent).opacity(isDark ? 0.13 : 0.08), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.loopr(accent).opacity(isDark ? 0.28 : 0.2), lineWidth: LooprSpacing.hairline)
        }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

// MARK: - Progress

/// A segmented track under the header: one segment per step, filled up to
/// and including the current one.
struct OnboardingProgressTrack: View {
    let step: Int
    let total: Int
    let accent: LooprColorToken

    var body: some View {
        HStack(spacing: LooprSpacing.xxs) {
            ForEach(1 ... max(total, 1), id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index <= step ? Color.loopr(accent) : Color.loopr(.divider))
                    .frame(height: OnboardingMetrics.track)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Choice chips

/// A row of selectable capsules in the tabs' range-picker style. Unlike a
/// segmented control it allows no selection, which is how "not answered"
/// stays absent.
struct OnboardingChoiceChips<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value?
    var accent: LooprColorToken = .brand
    var allowsDeselect = true
    /// One row of equal segments on a track, as `LooprRangePicker` draws
    /// its ranges. For short option lists that must not wrap.
    var segmented = false
    var identifier: (Value) -> String? = { _ in nil }

    var body: some View {
        Group {
            if segmented {
                HStack(spacing: LooprSpacing.xxs) { chips(fill: true) }
                    .padding(LooprSpacing.xxs - LooprSpacing.hairline)
                    .background(Color.loopr(.ink).opacity(isDark ? 0.05 : 0.04), in: Capsule(style: .continuous))
            } else {
                OnboardingFlowLayout(spacing: LooprSpacing.xs) { chips(fill: false) }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func chips(fill: Bool) -> some View {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    if selected, allowsDeselect { selection = nil } else { selection = option }
                } label: {
                    Text(label(option))
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(selected ? accent.spectralChipLabel : .ink))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, fill ? LooprSpacing.xxs : LooprSpacing.md)
                        .frame(maxWidth: fill ? .infinity : nil, minHeight: LooprSpacing.formButtonHeight)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected
                                    ? Color.loopr(accent).opacity(isDark ? 0.16 : 0.12)
                                    : fill ? Color.clear : Color.loopr(.ink).opacity(isDark ? 0.06 : 0.05))
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    selected ? Color.loopr(accent).opacity(isDark ? 0.34 : 0.28) : Color.clear,
                                    lineWidth: LooprSpacing.hairline
                                )
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityHint(title)
                .modifier(OptionalIdentifier(identifier: identifier(option)))
            }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// Wraps chips onto new lines at large Dynamic Type sizes.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
