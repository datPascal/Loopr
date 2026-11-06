import SwiftUI

/// The LV-01.4 pieces in the gallery: provenance chips, the coach orb, press tilt, detents and the
/// entrance store. Part of the craft section.
struct LooprCraftDetailGallery: View {
    /// One chip per source, with the qualifiers the contract uses.
    static let chips: [(id: String, provenance: LooprProvenance, qualifier: String?)] = [
        ("band", .band(device: "Band"), "2 min ago"),
        ("health", .appleHealth(source: "Apple Watch"), "42-day median"),
        ("health-typed", .appleHealth(source: "Health", typedIn: true), nil),
        ("food-logged", .food(.logged), nil),
        ("food-barcode", .food(.barcode), nil),
        ("food-photo", .food(.photoEstimate), nil),
        ("lab", .lab(name: "City Lab"), "12 Oct"),
        ("typed", .typedIn, nil),
        ("estimated", .estimated(method: "PhenoAge"), nil),
        ("phone", .onThisPhone, nil),
        ("absent", .absent, nil)
    ]

    static let entranceTab = "gallery"

    @State private var weight = 78.4
    @State private var entrance = false
    @State private var ruleKept: LooprHaptic?
    @State private var methodTaps = 0
    @Environment(\.looprEntranceStore) private var entranceStore

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Provenance chips", detail: "Where each number came from. The last one has a method page.")
                LooprFlowLayout(spacing: LooprSpacing.xs) {
                    ForEach(Self.chips, id: \.id) { chip in
                        ProvenanceChip(chip.provenance, qualifier: chip.qualifier, absent: .notMeasured,
                                       identifier: "gallery-provenance-\(chip.id)")
                    }
                    ProvenanceChip(.onThisPhone, qualifier: "outcome fixed on day 1", tint: .protocol,
                                   identifier: "gallery-provenance-action") { methodTaps += 1 }
                }
                // Compact: the source only, for a small cell. It wraps rather than cutting a word.
                HStack(alignment: .top, spacing: LooprSpacing.xs) {
                    ForEach(Self.chips.prefix(3), id: \.id) { chip in
                        ProvenanceChip(chip.provenance, qualifier: chip.qualifier, style: .compact,
                                       identifier: "gallery-provenance-compact-\(chip.id)")
                            .frame(width: 96, alignment: .leading)
                    }
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Coach orb", detail: "Turns slowly. Still under Reduce Motion and in Low Power Mode.")
                HStack(spacing: LooprSpacing.md) {
                    ForEach(LooprCoachOrb.Size.allCases, id: \.self) { size in
                        LooprCoachOrb(size: size)
                    }
                    LooprCoachOrb(size: .sm, accessibilityLabel: "Ask Loopr")
                        .accessibilityIdentifier("gallery-coach-orb")
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Press tilt", detail: "Hold the card. It leans towards your finger, up to 4°.")
                LooprSurface(emphasis: .hero(.energy)) {
                    LooprText("Hold me", style: .rowTitle)
                        .frame(maxWidth: .infinity, minHeight: 88)
                }
                .looprPressTilt()
                .accessibilityIdentifier("gallery-press-tilt")
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Detents", detail: "Each step ticks, at most 30 a second. A kept rule plays a soft success.")
                LooprRulerPicker("Weight", value: $weight, in: 30...250, unit: "kg", accent: .energy)
                    .accessibilityIdentifier("gallery-detent-ruler")
                LooprGlassButton("Keep a rule", symbol: "checkmark", identifier: "gallery-rule-kept") { ruleKept = .ruleKept }
                    .looprHaptic(ruleKept)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Entrance", detail: "Plays on the first visit of the day, then shows the final state.")
                HStack {
                    LooprText(entrance ? "Playing today's entrance" : "Final state", style: .label)
                        .opacity(entrance ? 0.6 : 1)
                        .animation(.easeOut(duration: LooprMotion.reveal), value: entrance)
                    Spacer()
                    LooprGlassButton("Reset", identifier: "gallery-entrance-reset") {
                        entranceStore.reset([Self.entranceTab])
                    }
                }
                .looprEntrance(tab: Self.entranceTab, animates: $entrance)
                .accessibilityIdentifier("gallery-entrance")
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Method pieces", detail: "A waterfall of terms, a typeset formula and a code card.")
                LooprWaterfall(model: Self.waterfall, startLabel: "Start",
                               valueFormat: { $0.formatted(.number.precision(.fractionLength(1))) },
                               identifier: "gallery-waterfall")
                LooprFormula(lines: Self.formula, caption: "Each step adds its term to the running total.",
                             identifier: "gallery-formula")
                LooprCodeCard(path: "LooprPackages/Sources/DesignSystem/LooprWaterfall.swift", lines: 30...58,
                              rows: [LooprCodeCardRow("Type", "LooprWaterfallModel")], actionTitle: "View on GitHub",
                              identifier: "gallery-code-card", actionIdentifier: "gallery-code-card-action") { methodTaps += 1 }
            }
        }
    }

    static let waterfall = LooprWaterfallModel(start: 50, steps: [
        LooprWaterfallStep(id: "a", label: "First term", value: 6.5),
        LooprWaterfallStep(id: "b", label: "Second term", value: -2.25),
        LooprWaterfallStep(id: "c", label: "Third term", value: 0.4)
    ], totalLabel: "Result")

    static let formula = [LooprFormulaLine([
        .variable("total"), .op("="), .variable("start"), .op("+"), .function("Σ"), .variable("term")
    ])]
}

/// Lays chips out in rows that wrap.
struct LooprFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
