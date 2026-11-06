import SwiftUI

/// A logged amount with an optional target, progress guide and add affordance.
public struct LooprIntakeRow: View {
    /// A one-tap add beside the row, such as a glass of water. The row itself still opens the editor.
    public struct QuickAdd {
        public let label: String
        public let identifier: String
        public let action: () -> Void
        public init(label: String, identifier: String, action: @escaping () -> Void) {
            self.label = label; self.identifier = identifier; self.action = action
        }
    }
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var quickAdds = 0
    private let title: String
    private let symbol: String
    private let accent: LooprColorToken
    private let value: String
    private let unit: String
    private let detail: String?
    private let progress: Double?
    private let target: Double?
    private let showsProgress: Bool
    private let showsPlus: Bool
    private let identifier: String
    private let spoken: String
    private let quickAdd: QuickAdd?
    private let action: () -> Void

    public init(title: String, symbol: String, accent: LooprColorToken, value: String, unit: String,
                detail: String? = nil, progress: Double? = nil, target: Double? = nil,
                showsProgress: Bool = false, showsPlus: Bool = false, identifier: String,
                accessibilityLabel: String, quickAdd: QuickAdd? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.accent = accent; self.value = value; self.unit = unit
        self.detail = detail; self.progress = progress; self.target = target
        self.showsProgress = showsProgress; self.showsPlus = showsPlus
        self.identifier = identifier; spoken = accessibilityLabel; self.action = action
        self.quickAdd = quickAdd
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.sm) {
            row
            if let quickAdd {
                Button {
                    quickAdds += 1
                    quickAdd.action()
                } label: {
                    // Glass, not a filled circle: the plus sits beside the row without competing with the screen's
                    // one primary control.
                    Image(systemName: "plus")
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(accent))
                        .symbolEffect(.bounce, value: quickAdds)
                        .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
                        .looprGlass(in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.looprPressableCard)
                .sensoryFeedback(.impact(weight: .medium), trigger: quickAdds)
                .accessibilityLabel(quickAdd.label)
                .accessibilityIdentifier(quickAdd.identifier)
            }
        }
    }

    private var row: some View {
        Button(action: action) {
            let layout = dynamicType.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm))
                : AnyLayout(HStackLayout(spacing: LooprSpacing.sm))
            layout {
                HStack(spacing: LooprSpacing.sm) {
                    Image(systemName: symbol).looprTypography(.rowTitle).foregroundStyle(Color.loopr(accent))
                        .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
                        .background(Color.loopr(accent).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(title, style: .rowTitle)
                        if showsProgress { LooprLinearProgress(value: progress, target: target, accent: accent) }
                        if let detail { LooprText(detail, style: .caption, color: .inkSecondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                        LooprText(value, style: .metricValue)
                        LooprText(unit, style: .metricUnit, color: .inkSecondary)
                    }.fixedSize(horizontal: !dynamicType.isAccessibilitySize, vertical: true)
                    if showsPlus && quickAdd == nil {
                        Image(systemName: "plus").looprTypography(.title).foregroundStyle(Color.loopr(.inkSecondary))
                            .frame(width: LooprSpacing.headerControlDiameter, height: LooprSpacing.headerControlDiameter)
                            .overlay(Circle().stroke(Color.loopr(.divider), lineWidth: 1))
                    }
                }
            }.padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: LooprSpacing.interactiveRowHeight).contentShape(Rectangle())
        }.buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore).accessibilityLabel(spoken)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
    }
}

#Preview {
    LooprCard {
        LooprIntakeRow(title: "Water", symbol: "drop.fill", accent: .brand, value: "1.2", unit: "of 2.5 L",
            progress: 1200, target: 2500, showsProgress: true, showsPlus: true,
            identifier: "water-preview", accessibilityLabel: "Water, 1.2 of 2.5 litres") {}
    }.padding()
}
