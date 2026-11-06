import AnalyticsKit
import DesignSystem
import SwiftUI

/// The page every blood test screen sits on: Data's colour field behind the scroll view, with the tab's gutters, so
/// the blood tests read as part of Data and not as a settings list (DESIGN_LANGUAGE check 4).
struct LabsPage<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = LooprSpacing.lg, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ZStack {
            LooprColorField(accent: .brand)
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.tabBarClearance)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
    }
}

/// A section on a blood test screen: a sentence-case header and one card of rows.
struct LabsSection<Content: View>: View {
    private let title: String
    private let detail: String?
    private let identifier: String?
    private let content: Content

    init(_ title: String, detail: String? = nil, identifier: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail, identifier: identifier)
            LooprCard(density: .flush) {
                VStack(alignment: .leading, spacing: LooprSpacing.none) { content }
            }
        }
    }
}

/// The small label over a hero, in Data's accent: "Blood tests", "Lab report".
struct LabsEyebrow: View {
    let text: String

    var body: some View {
        LooprText(text, style: .sectionLabel, color: LooprColorToken.brand.textInk)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The lab's own flag as printed ("H", "L", "*"), in a neutral outline. Loopr never colours a flag as good or bad.
struct LabFlagBadge: View {
    let flag: String

    var body: some View {
        Text(verbatim: flag)
            .looprTypography(.chip)
            .foregroundStyle(Color.loopr(.ink))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay { Capsule().strokeBorder(Color.loopr(.inkSecondary), lineWidth: 1) }
            .accessibilityLabel("Lab flag \(flag)")
    }
}

/// Every blood draw as a dot on a line from the first to the newest, larger for a report with more values. It draws
/// the list's shape at a glance; the rows under it hold the words.
struct LabDrawStrip: View {
    struct Draw: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let values: Int
    }

    let draws: [Draw]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dates = draws.map(\.date)
            let first = dates.min() ?? Date()
            let last = dates.max() ?? first
            let span = max(last.timeIntervalSince(first), 1)
            let most = Double(max(draws.map(\.values).max() ?? 1, 1))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
                ForEach(draws) { draw in
                    let fraction = draws.count == 1 ? 0.5 : draw.date.timeIntervalSince(first) / span
                    let size = 8 + 10 * (Double(draw.values) / most)
                    Circle()
                        .fill(Color.loopr(.brand))
                        .frame(width: size, height: size)
                        .shadow(color: Color.loopr(.brand).opacity(0.5), radius: 4)
                        .position(x: 9 + (width - 18) * fraction, y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) { endLabels.offset(y: 16) }
        .padding(.bottom, draws.count >= 2 ? 16 : 0)
        .accessibilityHidden(true)
    }

    /// The first and the last draw's day under the line's two ends, so the spacing reads as time (ICP R3-LAB-9).
    @ViewBuilder private var endLabels: some View {
        let dates = draws.map(\.date)
        if draws.count >= 2, let first = dates.min(), let last = dates.max() {
            HStack {
                LooprText(LabsDisplay.day(first, calendar: .current), style: .caption, color: .inkSecondary)
                Spacer(minLength: LooprSpacing.sm)
                LooprText(LabsDisplay.day(last, calendar: .current), style: .caption, color: .inkSecondary)
            }
        }
    }
}
