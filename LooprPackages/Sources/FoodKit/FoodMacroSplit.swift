import DesignSystem
import SwiftUI

/// How a day's calories split between protein, carbs and fat: one bar in the macro colours, with
/// grams and share underneath. Segments slide when the numbers change.
public struct FoodMacroSplit: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    private let protein: Double
    private let carbs: Double
    private let fat: Double
    private let showsLegend: Bool

    public init(protein: Double, carbs: Double, fat: Double, showsLegend: Bool = true) {
        self.protein = max(0, protein); self.carbs = max(0, carbs); self.fat = max(0, fat); self.showsLegend = showsLegend
    }

    private var parts: [(FoodNutrient, String, Double, Double)] {
        [(.protein, "Protein", protein, protein * 4), (.carbs, "Carbs", carbs, carbs * 4), (.fat, "Fat", fat, fat * 9)]
    }
    private var total: Double { parts.map(\.3).reduce(0, +) }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(parts, id: \.0) { part in
                        Capsule()
                            .fill(Color.loopr(part.0.accent))
                            .frame(width: max(0, (geometry.size.width - 6) * share(part.3)))
                    }
                }
            }
            .frame(height: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: [protein, carbs, fat])
            if showsLegend {
                let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.sm))
                layout {
                    ForEach(parts, id: \.0) { part in
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                            Circle().fill(Color.loopr(part.0.accent)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(part.2.rounded())) g")
                                    .looprTypography(.metricValue)
                                    .foregroundStyle(Color.loopr(.ink))
                                    .contentTransition(.numericText(value: part.2))
                                LooprText("\(part.1) · \(Int((share(part.3) * 100).rounded()))%", style: .caption, color: .inkSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .animation(LooprMotion.stateChange, value: [protein, carbs, fat])
            }
        }
        .accessibilityElement(children: .contain)
        // Without the legend the bar is decoration; the caller says the numbers.
        .accessibilityHidden(!showsLegend)
    }

    private func share(_ energy: Double) -> Double { total > 0 ? energy / total : 1.0 / 3 }
}

#Preview {
    FoodMacroSplit(protein: 168, carbs: 150, fat: 45).padding()
}
