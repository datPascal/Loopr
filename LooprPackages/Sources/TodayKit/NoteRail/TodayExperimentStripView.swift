import DesignSystem
import Foundation
import SwiftUI

/// "Experiment · night 9 of 14" with the title, the outcome, tonight's arm and one bead per night. Tapping it opens
/// the Protocol tab on its Experiments segment.
struct TodayExperimentStripView: View {
    let strip: TodayExperimentStrip
    let open: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The heading and the card stack at their own heights: the heading is a plain row (a column at accessibility
        // sizes), and the whole strip takes its ideal height, so the card can never be squeezed up into the heading.
        let heading = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: LooprSpacing.sm))
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            heading {
                Text("Experiment")
                    .looprTypography(.title)
                    .foregroundStyle(Color.loopr(.ink))
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(strip.progress)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LooprSpacing.xxs)
            Button { open() } label: {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                        Text(strip.title)
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.ink))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    Text(strip.detail)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if !strip.beads.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(strip.beads.enumerated()), id: \.offset) { _, bead in
                                TodayExperimentBeadView(bead: bead)
                            }
                        }
                        .padding(.top, LooprSpacing.xs)
                    }
                }
                .padding(.vertical, LooprSpacing.md)
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .looprCardBackground()
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strip.accessibilityLabel)
            .accessibilityHint("Opens your experiments in Protocol.")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("today-experiment")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TodayExperimentBeadView: View {
    let bead: TodayExperimentBead

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            switch bead.phase {
            case .tonight:
                shape.strokeBorder(Color.loopr(.protocol), lineWidth: 1.5)
            case .past:
                shape.fill(bead.arm == .on ? Color.loopr(.protocol) : Color.loopr(.inkMuted).opacity(0.55))
            case .future:
                shape.fill(Color.loopr(.divider))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
        .accessibilityHidden(true)
    }
}
