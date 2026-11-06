import DesignSystem
import SwiftUI

/// "Longevity lens this week" (contract p-food): protein per kilogram, fibre a day, the ultra-processed share with its
/// coverage, and alcohol-free days, two to a row. Each tile shows its value and a small bar, or what it still needs.
struct FoodLensTilesView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tiles: [FoodLensTile]
    /// Opens a tile's method page. Nil until method pages exist, and the tiles are then plain.
    let method: ((FoodLensTile.Kind) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Longevity lens", detail: "This week, from the days you finished")
            let columns = dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .topLeading)] : [GridItem(.flexible(), spacing: 14, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: LooprSpacing.md) {
                ForEach(tiles) { tile in
                    if let method {
                        Button { method(tile.kind) } label: { content(tile) }
                            .buttonStyle(.looprPressableCard)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(tile.accessibilityLabel)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Shows how this is worked out")
                            .accessibilityIdentifier(tile.identifier)
                    } else {
                        content(tile)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(tile.accessibilityLabel)
                            .accessibilityIdentifier(tile.identifier)
                    }
                }
            }
            .padding(LooprSpacing.md + 2)
            .looprCardBackground()
        }
    }

    private func content(_ tile: FoodLensTile) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs + 2) {
            LooprText(tile.title, style: .label, color: .inkSecondary)
            if let value = tile.value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(LooprHeroNumberFormat.text(value, fractionDigits: tile.fractionDigits, locale: LooprUnitFormatter.displayLocale))
                        .looprTypography(.metric)
                        .foregroundStyle(Color.loopr(tile.isProvisional ? .inkSecondary : .ink))
                        .contentTransition(.numericText(value: value))
                    Text(tile.unit).looprTypography(.metricUnit).foregroundStyle(Color.loopr(.inkSecondary))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                Text("–").looprTypography(.metric).foregroundStyle(Color.loopr(.inkMuted)).accessibilityHidden(true)
            }
            bar(tile)
            LooprText(tile.note, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let provenance = tile.provenance {
                // The source alone, wrapping when narrow. The coverage reads in the note, so no word is cut off.
                ProvenanceChip(provenance, qualifier: tile.provenanceQualifier, style: .compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func bar(_ tile: FoodLensTile) -> some View {
        Capsule()
            .fill(Color.loopr(.divider))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                if let fill = tile.bar {
                    GeometryReader { proxy in
                        Capsule().fill(Color.loopr(Self.token(tile.kind)))
                            .frame(width: max(proxy.size.width * fill, fill > 0 ? 4 : 0))
                    }
                }
            }
            .accessibilityHidden(true)
    }

    static func token(_ kind: FoodLensTile.Kind) -> LooprColorToken {
        switch kind {
        case .protein: .heart
        case .fibre: .brand
        case .upf: .energy
        case .alcoholFree: .protocol
        }
    }
}
