import DesignSystem
import SwiftUI

/// The overnight check, when two or more signals sit outside the usual range.
struct TodayHeadsUpRow: View {
    let headsUp: TodayHeadsUp
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Color.loopr(.caution))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(headsUp.title, style: .prose)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText("View overnight check", style: .label, color: .brand)
                }
                Spacer(minLength: 0)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm)
            .looprCardBackground()
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityIdentifier("today-heads-up")
        .padding(.horizontal, LooprSpacing.screenGutter)
    }
}
